# shellcheck shell=bash
#
# topology.sh - Phase 3: replica set topology, node health probes and the
# election of the node that launches a backup.
#
# Rules (agreed with rmateos):
#   - Keep backing up on the node that took the last base ("owner").
#   - Move to another node only if the owner is unavailable: host or mongod
#     down, pbm-agent not ok, or overloaded (replication lag, queued
#     operations, WiredTiger dirty cache over thresholds).
#   - Never the PRIMARY (unless ALLOW_PRIMARY=true).
# Every node runs the same algorithm on the same data, so they all agree on
# the order without talking to each other.
#
# Requires: common.sh, mongo.sh, pbm.sh, jq.

# ---------------------------------------------------------------------------
# Node naming
# ---------------------------------------------------------------------------
# node_key HOST[:PORT] - normalized comparison key: lowercase short host + port.
# "Node03.example.private:27017" -> "node03:27017"
node_key() {
    local h p
    h=$(lower "$1")
    p=27017
    if [[ $h == *:* ]]; then
        p=${h##*:}
        h=${h%:*}
    fi
    printf '%s:%s\n' "${h%%.*}" "$p"
}

# same_node A B - true if A and B refer to the same mongod.
same_node() {
    [[ $(node_key "$1") == "$(node_key "$2")" ]]
}

# ---------------------------------------------------------------------------
# Per-node connection
# ---------------------------------------------------------------------------
# uri_for_host HOST:PORT - PBM_MONGODB_URI rewritten to connect directly to
# one member: same credentials and options, replicaSet removed,
# directConnection=true and short timeouts added.
uri_for_host() {
    local host=$1 rest authority creds='' query='' path dbname
    case $PBM_MONGODB_URI in
        mongodb://*) rest=${PBM_MONGODB_URI#mongodb://} ;;
        *) return 1 ;;  # mongodb+srv:// cannot address a single member
    esac
    authority=${rest%%/*}
    path=''
    [[ $rest == */* ]] && path=${rest#*/}
    if [[ $authority == *@* ]]; then
        creds="${authority%@*}@"
    fi
    # Keep the default auth database ("/admin?...") if present.
    dbname=${path%%\?*}
    [[ $path == *\?* ]] && query=${path#*\?}
    query=$(printf '%s' "$query" | tr '&' '\n' \
        | grep -v -E '^(replicaSet|directConnection|serverSelectionTimeoutMS|connectTimeoutMS)=' \
        | grep -v '^$' | paste -sd '&' - || true)
    query="${query:+${query}&}directConnection=true&serverSelectionTimeoutMS=${PROBE_TIMEOUT_MS:-5000}&connectTimeoutMS=${PROBE_TIMEOUT_MS:-5000}"
    printf 'mongodb://%s%s/%s?%s\n' "$creds" "$host" "$dbname" "$query"
}

# probe_node HOST:PORT - print one JSON line with the node's health:
#   {"reachable":true,"primary":bool,"state":"SECONDARY","lag":N,"oplog_window_sec":N,
#    "queue":N,"dirty_pct":N}
#   {"reachable":false,"error":"..."}
probe_node() {
    local host=$1 uri js out
    if ! uri=$(uri_for_host "$host"); then
        jq -cn '{reachable: false, error: "unsupported URI scheme for direct connection"}'
        return 0
    fi
    js='var o = {reachable: true};'
    js+='try {'
    js+=' var h; try { h = db.adminCommand({hello: 1}); } catch (e) { h = {ok: 0}; }'
    js+=' if (!h.ok) { h = db.adminCommand({isMaster: 1}); }'
    js+=' o.primary = !!(h.isWritablePrimary || h.ismaster);'
    js+=' var rs = db.adminCommand({replSetGetStatus: 1}), me = null, pr = null;'
    js+=' (rs.members || []).forEach(function (m) { if (m.self) { me = m; } if (m.stateStr === "PRIMARY") { pr = m; } });'
    js+=' o.state = me ? String(me.stateStr) : "UNKNOWN";'
    js+=' o.lag = (me && pr) ? Math.max(0, Math.round((pr.optimeDate - me.optimeDate) / 1000)) : null;'
    js+=' var ss = db.adminCommand({serverStatus: 1});'
    js+=' o.queue = (ss.globalLock && ss.globalLock.currentQueue) ? Number(ss.globalLock.currentQueue.total) : null;'
    js+=' var c = ss.wiredTiger ? ss.wiredTiger.cache : null;'
    js+=' o.dirty_pct = c ? Math.round(1000 * Number(c["tracked dirty bytes in the cache"]) / Number(c["maximum bytes configured"])) / 10 : null;'
    # Oplog window = wall time of the newest minus the oldest oplog entry.
    js+=' try {'
    js+='  var ol = db.getSiblingDB("local").getCollection("oplog.rs");'
    js+='  var f = ol.find({}, {wall: 1}).sort({$natural: 1}).limit(1).toArray()[0];'
    js+='  var l = ol.find({}, {wall: 1}).sort({$natural: -1}).limit(1).toArray()[0];'
    js+='  o.oplog_window_sec = (f && l && f.wall && l.wall) ? Math.round((l.wall - f.wall) / 1000) : null;'
    js+=' } catch (e) { o.oplog_window_sec = null; }'
    js+='} catch (e) { o = {reachable: true, error: String(e.message || e)}; }'
    js+='print(JSON.stringify(o));'
    if ! out=$("$MONGO_SHELL" --quiet "$uri" --eval "$js" 2>&1); then
        jq -cn --arg e "$(printf '%s' "$out" | tail -n 1 | cut -c1-200)" '{reachable: false, error: $e}'
        return 0
    fi
    out=$(printf '%s\n' "$out" | grep '^{' | tail -n 1)
    if [[ -z $out ]]; then
        jq -cn '{reachable: false, error: "no output from mongo shell"}'
    else
        printf '%s\n' "$out"
    fi
}

# ---------------------------------------------------------------------------
# Election
# ---------------------------------------------------------------------------
# cluster_nodes_json STATUS_JSON - print the nodes of the (single) replica set
# as reported by "pbm status": [{"host","role","agent","ok","errors"}, ...].
# Normalized across PBM versions (checked in the PBM source):
#   - PBM 2.5.0 reports host as "<replset>/<host>:<port>" and leaves role
#     empty for secondaries; PBM 2.12.0 reports "<host>:<port>" and "S".
#   - Empty role -> "S", as "pbm status" text output does.
# Fails if the cluster is sharded (more than one replica set).
cluster_nodes_json() {
    local n
    n=$(printf '%s\n' "$1" | jq '.cluster | length')
    [[ $n == 1 ]] || return 1
    printf '%s\n' "$1" | jq -c '[.cluster[0].nodes[] | {
        host: (.host | sub("^[^/]*/"; "")),
        role: (if (.role // "") == "" then "S" else .role end),
        agent: (.agent // ""),
        ok: (.ok == true),
        errors: (.errors // [])
    }]'
}

# elect_nodes STATUS_JSON OWNER_HOST - probe every member and print the
# ordered candidate list as a JSON array, one object per member:
#   {"host","role","agent_ok","owner":bool,"eligible":bool,"reason","rank",
#    "probe":{...}}
# rank is 0-based among eligible nodes (null when not eligible). Order:
#   1. the owner (node of the last base), 2. PREFERRED_NODES in their order,
#   3. the rest sorted by host name.
elect_nodes() {
    local status=$1 owner=$2 nodes host role probe all='[]' i=0 pref_idx p
    nodes=$(cluster_nodes_json "$status") || return 1

    while IFS= read -r host; do
        [[ -n $host ]] || continue
        role=$(printf '%s\n' "$nodes" | jq -r --arg h "$host" '.[] | select(.host == $h) | .role')
        # Probe only nodes that can be candidates; skip arbiters and dead agents.
        if [[ $role == A ]]; then
            probe='{"reachable":null,"skipped":"arbiter"}'
        else
            probe=$(probe_node "$host")
        fi
        pref_idx=999
        i=0
        for p in ${PREFERRED_NODES:-}; do
            if same_node "$p" "$host"; then
                pref_idx=$i
                break
            fi
            i=$((i + 1))
        done
        local is_owner=false
        if [[ -n $owner ]] && same_node "$owner" "$host"; then
            is_owner=true
        fi
        all=$(printf '%s\n' "$all" | jq -c \
            --argjson n "$(printf '%s\n' "$nodes" | jq -c --arg h "$host" '.[] | select(.host == $h)')" \
            --argjson probe "$probe" --argjson owner "$is_owner" --argjson pref "$pref_idx" \
            '. + [{host: $n.host, role: $n.role, agent_ok: ($n.ok == true), agent: $n.agent, agent_errors: $n.errors,
                   owner: $owner, pref: $pref, probe: $probe}]')
    done <<EOF
$(printf '%s\n' "$nodes" | jq -r '.[].host')
EOF

    printf '%s\n' "$all" | jq -c \
        --argjson lag "${MAX_REPL_LAG_SEC:-60}" \
        --argjson queue "${MAX_QUEUE:-50}" \
        --argjson dirty "${MAX_WT_DIRTY_PCT:-20}" \
        --argjson allow_primary "$( [[ ${ALLOW_PRIMARY:-false} == true ]] && echo true || echo false )" '
        def reason:
            if .role == "A" then "arbiter"
            elif .role == "D" then "delayed member"
            elif (.agent_ok | not) then "pbm-agent not ok"
                + (if (.agent_errors | length) > 0 then ": \(.agent_errors | join("; "))"
                   elif .agent == "NOT FOUND" or .agent == "" then ": agent not registered (pbm-agent not running on this member?)"
                   else "" end)
            elif .probe.reachable != true then "mongod unreachable: \(.probe.error // "unknown")"
            elif .probe.error != null then "probe failed: \(.probe.error)"
            elif (.probe.primary or .role == "P") and ($allow_primary | not) then "primary"
            elif (.probe.state != "SECONDARY" and .probe.state != "PRIMARY") then "state \(.probe.state)"
            elif .probe.lag != null and .probe.lag > $lag then "replication lag \(.probe.lag)s > \($lag)s"
            elif .probe.queue != null and .probe.queue > $queue then "queued operations \(.probe.queue) > \($queue)"
            elif .probe.dirty_pct != null and .probe.dirty_pct > $dirty then "WiredTiger dirty cache \(.probe.dirty_pct)% > \($dirty)%"
            else null end;
        map(. + {reason: reason})
        | map(. + {eligible: (.reason == null),
                   is_primary: (.probe.primary == true or .role == "P")})
        # owner first, then preferred order, then name; primaries last (only
        # relevant with ALLOW_PRIMARY=true)
        | sort_by([(if .is_primary then 1 else 0 end), (if .owner then 0 else 1 end), .pref, .host])
        | reduce .[] as $n ({out: [], r: 0};
              if $n.eligible then .out += [$n + {rank: .r}] | .r += 1
              else .out += [$n + {rank: null}] end)
        | .out
        | map(del(.pref, .is_primary))'
}

# self_entry ELECTION_JSON - print the entry of this node, or nothing.
self_entry() {
    local host
    while IFS= read -r host; do
        [[ -n $host ]] || continue
        if is_local_node "$host"; then
            printf '%s\n' "$1" | jq -c --arg h "$host" '.[] | select(.host == $h)'
            return 0
        fi
    done <<EOF
$(printf '%s\n' "$1" | jq -r '.[].host')
EOF
}

# election_table ELECTION_JSON - human-readable lines for the log.
election_table() {
    printf '%s\n' "$1" | jq -r '.[] |
        "\(if .rank != null then "#\(.rank)" else "--" end) \(.host) role=\(if .role == "" then "?" else .role end)"
        + (if .owner then " owner" else "" end)
        + " lag=\(.probe.lag // "-") queue=\(.probe.queue // "-") dirty=\(.probe.dirty_pct // "-")%"
        + (if .eligible then " ELIGIBLE" else " SKIP(\(.reason))" end)'
}
