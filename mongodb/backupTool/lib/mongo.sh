# shellcheck shell=bash
#
# mongo.sh - MongoDB shell wrapper (mongosh, or legacy mongo as fallback),
# URI parsing and local node identity.
#
# Requires: common.sh, jq.

# mongo_init - resolve the shell binary and validate PBM_MONGODB_URI.
mongo_init() {
    [[ -n ${PBM_MONGODB_URI:-} ]] || die "PBM_MONGODB_URI is not set (check ${PBM_ENV_FILE:-/etc/sysconfig/pbm-conf})" 2
    if [[ -n $MONGO_SHELL && -x $MONGO_SHELL ]]; then
        return 0
    fi
    MONGO_SHELL=$(command -v mongosh 2>/dev/null || command -v mongo 2>/dev/null) \
        || die "Neither mongosh nor mongo found in PATH" 2
}

# mongo_eval JS - run JS against PBM_MONGODB_URI and print its output.
mongo_eval() {
    "$MONGO_SHELL" --quiet "$PBM_MONGODB_URI" --eval "$1"
}

# uri_param URI KEY - print the value of query parameter KEY, in any position.
uri_param() {
    printf '%s\n' "$1" | sed -n "s/.*[?&]$2=\([^&]*\).*/\1/p"
}

# host_strip_port HOST:PORT - print HOST (works for any port, not only 27017).
host_strip_port() {
    printf '%s\n' "${1%:*}"
}

# lower STRING - lowercase (bash 3.2 has no ${var,,}).
lower() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# Local node identity
# ---------------------------------------------------------------------------
# local_node_names - print every name this node may be known by (lowercase):
# hostname, short and FQDN forms, plus LOCAL_NODE_NAMES from the config.
local_node_names() {
    {
        hostname 2>/dev/null || true
        hostname -s 2>/dev/null || true
        hostname -f 2>/dev/null || true
        local n
        for n in $LOCAL_NODE_NAMES; do
            printf '%s\n' "$n"
        done
    } | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u
}

# is_local_node HOST[:PORT] - exact (not substring) match against this node.
# Also matches the short form, so "node01.example.com" == "node01".
is_local_node() {
    local host short name
    host=$(lower "$(host_strip_port "$1")")
    short=${host%%.*}
    while IFS= read -r name; do
        if [[ $name == "$host" || $name == "$short" || ${name%%.*} == "$short" ]]; then
            return 0
        fi
    done <<EOF
$(local_node_names)
EOF
    return 1
}
