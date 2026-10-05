# shellcheck shell=bash
#
# pbm.sh - Thin wrappers around the pbm CLI (PBM 2.x).
#
# Requires: common.sh, mongo.sh, jq.

# pbm_init - resolve the pbm binary and check the connection URI it needs.
pbm_init() {
    require_cmd pbm PBM_BIN
    [[ -n ${PBM_MONGODB_URI:-} ]] || die "PBM_MONGODB_URI is not set (check ${PBM_ENV_FILE:-/etc/sysconfig/pbm-conf})" 2
    export PBM_MONGODB_URI
}

# run_pbm ARGS... - run pbm, or only log the command in --dry-run mode.
run_pbm() {
    if [[ ${DRY_RUN:-0} == 1 ]]; then
        log INFO "$LOG_LABEL" "[DRY-RUN] would run: pbm $*"
        return 0
    fi
    "$PBM_BIN" "$@"
}

# pbm_running_op - print a short description of the operation PBM is currently
# running, or nothing when idle. Never fails: if the status cannot be read the
# caller just proceeds and PBM itself will reject a concurrent operation.
# Idle is {"running":{}} (verified, PBM 2.12.0). Busy is ANY non-empty object:
# the key names are only used for the log text, so detection does not depend
# on them.
pbm_running_op() {
    local out
    out=$("$PBM_BIN" status -s running -o json 2>/dev/null) \
        || out=$("$PBM_BIN" status -o json 2>/dev/null) \
        || return 0
    printf '%s\n' "$out" | jq -r '
        (.running // {}) as $r
        | if ($r | type) == "object" and ($r | length) > 0
          then "\($r.type // "operation") \($r.name // "-") (opid \($r.opID // $r.opid // "-"))"
          else empty end' 2>/dev/null || true
}

# pbm_wait_idle MAX_SEC - wait until PBM has no running operation.
# Returns 1 if still busy after MAX_SEC.
pbm_wait_idle() {
    local max=$1 waited=0 op
    op=$(pbm_running_op)
    while [[ -n $op ]]; do
        if (( waited >= max )); then
            log WARN "$LOG_LABEL" "PBM still busy after ${max}s: ${op}"
            return 1
        fi
        if (( waited == 0 )); then
            log INFO "$LOG_LABEL" "PBM is busy (${op}); waiting up to ${max}s"
        fi
        sleep "$WAIT_POLL_SEC"
        waited=$(( waited + WAIT_POLL_SEC ))
        op=$(pbm_running_op)
    done
    return 0
}

# ---------------------------------------------------------------------------
# Backup metadata (pbm status / describe-backup -o json)
# ---------------------------------------------------------------------------
# Verified against PBM 2.12.0 output (tests/fixtures/pbm-2.12.0-psmdb-8.0):
#   status [-s backups]
#            .backups.snapshot[] = {name, status, type, src, restoreTo, ...}
#            ("-s backups" returns only the "backups" key, same structure)
#            name is the start time (ISO-8601 UTC); src == "" for a base,
#            src == <previous backup name> for an incremental.
#   describe .opid, .type, .last_write_ts, .replsets[] = {name, status, node}

# pbm_snapshots_json - print the .backups.snapshot array.
pbm_snapshots_json() {
    local out
    out=$("$PBM_BIN" status -s backups -o json 2>/dev/null) \
        || out=$("$PBM_BIN" status -o json) \
        || return 1
    printf '%s\n' "$out" | jq -c '.backups.snapshot // []'
}

# last_done_backup_json base|incr|logical
#   Print one compact JSON line describing the newest backup in status "done":
#     base    -> incremental base (type "incremental", empty src)
#     incr    -> incremental on top of a previous backup (non-empty src)
#     logical -> logical snapshot (type "logical")
#   {"name":"...","opid":"...","type":"...","start_ts":N,"last_write_ts":N,
#    "last_transition_ts":N,"restore_to":N,"nodes":["host:port",...]}
#   start_ts comes from the name (start time), last_transition_ts is when it
#   finished, restore_to is the snapshot's "restoreTo" (consistency point).
#   Prints nothing if there is no such backup. Returns 1 if PBM cannot be queried.
last_done_backup_json() {
    local filter snaps snap name desc
    case $1 in
        base)    filter='.type == "incremental" and (.src // "") == ""' ;;
        incr)    filter='(.src // "") != ""' ;;
        logical) filter='.type == "logical"' ;;
        *) die "last_done_backup_json: invalid kind '$1'" 2 ;;
    esac
    snaps=$(pbm_snapshots_json) || return 1
    snap=$(printf '%s\n' "$snaps" | jq -c "
        [ .[] | select(.status == \"done\") | select(${filter}) ]
        | sort_by(.name) | last // empty")
    [[ -n $snap ]] || return 0
    name=$(printf '%s\n' "$snap" | jq -r '.name')

    desc=$("$PBM_BIN" describe-backup "$name" -o json) || return 1
    printf '%s\n' "$desc" | jq -c --argjson snap "$snap" '{
        name, opid, type,
        start_ts: (.name | fromdateiso8601),
        last_write_ts,
        last_transition_ts,
        restore_to: ($snap.restoreTo // .last_write_ts),
        nodes: [ .replsets[]?.node ]
    }'
}

# backup_summary JSON - one-line human summary for logs.
backup_summary() {
    [[ -n $1 ]] || { printf 'none\n'; return 0; }
    printf '%s\n' "$1" | jq -r '"name=\(.name) | opid=\(.opid) | type=\(.type) | nodes=\(.nodes | join(","))"'
}

# pbm_status_json - full "pbm status -o json" (cluster, pitr, running, backups).
pbm_status_json() {
    "$PBM_BIN" status -o json
}

# pbm_activity_since EPOCH - true if PBM is busy, or a backup (any status)
# started at/after EPOCH. Used by standby nodes to see if a higher-ranked
# node already launched the backup.
pbm_activity_since() {
    local snaps
    [[ -n $(pbm_running_op) ]] && return 0
    snaps=$(pbm_snapshots_json) || return 1
    printf '%s\n' "$snaps" | jq -e --argjson s "$1" \
        'any(.[]; (.name | try fromdateiso8601 catch 0) >= $s)' >/dev/null
}

# ---------------------------------------------------------------------------
# PITR (phase 4: Community logical scheme)
# ---------------------------------------------------------------------------
# pbm_config_get KEY - print a single PBM config value ("pbm config KEY"),
# or nothing if it cannot be read.
pbm_config_get() {
    "$PBM_BIN" config "$1" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true
}

# pbm_config_set KEY VALUE - "pbm config --set KEY=VALUE" (honors --dry-run).
pbm_config_set() {
    run_pbm config --set "$1=$2" >/dev/null
}

# pitr_ranges_json - print the saved PITR oplog ranges as a sorted JSON array
# of [start, end] UNIX seconds, merged across the output shapes PBM may use:
#   pbm list -o json   .pitr.ranges[] = {range: {start, end}}  (or {start, end})
#   pbm status -o json .backups.pitrChunks.pitrChunks[] = {range: {start, end}}
# NOTE: not verified against real PBM output with PITR enabled yet.
pitr_ranges_json() {
    local out
    if out=$("$PBM_BIN" list -o json 2>/dev/null) && [[ -n $out ]]; then
        printf '%s\n' "$out" | jq -c '
            [ (.pitr.ranges // [])[] | (.range // .) | select(.start != null and .end != null)
              | [(.start | floor), (.end | floor)] ] | sort'
        return 0
    fi
    out=$(pbm_status_json) || return 1
    printf '%s\n' "$out" | jq -c '
        [ (.backups.pitrChunks.pitrChunks // [])[] | (.range // .) | select(.start != null and .end != null)
          | [(.start | floor), (.end | floor)] ] | sort'
}

# pitr_coverage BASE_TS RANGES_JSON NOW MAX_LAG - check that saved oplog
# covers [BASE_TS, NOW - MAX_LAG] without gaps (ranges starting after NOW are
# ignored, so a later gap does not affect an earlier restore point). Prints:
#   {"ok":bool,"reason":"...","from":N,"to":N,"lag":N,"gaps":[[end,start],...]}
# Ranges separated by more than 1 second are a gap.
pitr_coverage() {
    jq -cn --argjson base "$1" --argjson r "$2" --argjson now "$3" --argjson maxlag "$4" '
        ($r | map(select(.[1] >= $base and .[0] <= $now))) as $after
        | ($after | map(select(.[0] <= $base + 1))) as $cov
        | if ($cov | length) == 0 then
            {ok: false, reason: "no saved oplog covers the base snapshot point (restoreTo \($base))",
             from: null, to: null, lag: null, gaps: []}
          else
            ($after | sort) as $s
            | [ range(1; $s | length) as $i
                | select($s[$i][0] > $s[$i - 1][1] + 1) | [$s[$i - 1][1], $s[$i][0]] ] as $gaps
            | (if ($gaps | length) > 0 then $gaps[0][0] else ($s | map(.[1]) | max) end) as $to
            | ($now - $to) as $lag
            | {from: $base, to: $to, lag: $lag, gaps: $gaps}
            | if ($gaps | length) > 0 then . + {ok: false, reason: "gap in saved oplog after the base snapshot"}
              elif $lag > $maxlag then . + {ok: false, reason: "saved oplog is \($lag)s behind (max \($maxlag)s)"}
              else . + {ok: true, reason: null} end
          end'
}

# ---------------------------------------------------------------------------
# Retention (phase 5)
# ---------------------------------------------------------------------------
# retention_plan SNAPSHOTS_JSON RETENTION_CUTOFF_EPOCH - decide a SAFE cleanup
# cutoff. Prints one JSON line:
#   {"action":"cleanup","cutoff":N,"anchor":"<name>","newest":"<name>",
#    "delete":["<name>",...]}
#   {"action":"skip","reason":"..."}
# A "full" is any successful backup with no source: physical/incremental base
# or logical snapshot. The cutoff is moved back to the START of the newest
# full that started at/before the retention cutoff (the anchor), so:
#   - whole chains are deleted or kept, never split (a base is never removed
#     while its incrementals stay, and the anchor keeps its PITR slices);
#   - the newest valid full is never deleted, even if backups stopped
#     running longer ago than the retention.
retention_plan() {
    jq -cn --argjson sn "$1" --argjson ret "$2" '
        [ $sn[] | select(.status == "done" and (.src // "") == ""
                         and (.type == "incremental" or .type == "physical" or .type == "logical")) ]
        | sort_by(.name) as $fulls
        | ($fulls | last) as $newest
        | ([ $fulls[] | select((.name | fromdateiso8601) <= $ret) ] | last) as $anchor
        | if $newest == null then
            {action: "skip", reason: "no successful full backup exists: nothing is deleted"}
          elif $anchor == null then
            {action: "skip", reason: "every full backup is newer than the retention cutoff: nothing to delete"}
          else
            ($anchor.name | fromdateiso8601) as $cut
            | {action: "cleanup", cutoff: $cut, anchor: $anchor.name, newest: $newest.name,
               delete: [ $sn[] | select((.name | fromdateiso8601) < $cut) | .name ] | sort}
          end'
}
