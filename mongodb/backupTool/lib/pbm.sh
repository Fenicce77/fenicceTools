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

# last_done_backup_json base|incr
#   Print one compact JSON line describing the newest backup in status "done":
#     base -> incremental base (type "incremental", empty src)
#     incr -> incremental on top of a previous backup (non-empty src)
#   {"name":"...","opid":"...","type":"...","start_ts":N,"last_write_ts":N,
#    "nodes":["host:port",...]}
#   Prints nothing if there is no such backup. Returns 1 if PBM cannot be queried.
last_done_backup_json() {
    local filter snaps name desc
    case $1 in
        base) filter='.type == "incremental" and (.src // "") == ""' ;;
        incr) filter='(.src // "") != ""' ;;
        *) die "last_done_backup_json: invalid kind '$1'" 2 ;;
    esac
    snaps=$(pbm_snapshots_json) || return 1
    name=$(printf '%s\n' "$snaps" | jq -r "
        [ .[] | select(.status == \"done\") | select(${filter}) ]
        | sort_by(.name) | last | .name // empty")
    [[ -n $name ]] || return 0

    desc=$("$PBM_BIN" describe-backup "$name" -o json) || return 1
    printf '%s\n' "$desc" | jq -c '{
        name, opid, type,
        start_ts: (.name | fromdateiso8601),
        last_write_ts,
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
