#!/usr/bin/env bash
#
# Script Name: mongo_exec.sh
# Description: Run a JavaScript file against a MongoDB deployment (MongoDB 4.x - 8.x)
#              through mongosh or the legacy mongo shell. Credentials come from a
#              config file and never appear on the client's command line: they are
#              written to a 0600 preamble file (percent-encoded) that authenticates
#              with db.auth() and is removed on exit.
# Compatibility: bash >= 3.2 on Linux (GNU coreutils) and macOS (BSD coreutils).
#

set -euo pipefail

readonly VERSION="2.0.0"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# --- ANSI Terminal Styling ---------------------------------------------------
# Colors are enabled per file descriptor: logs go to stderr, help goes to stdout.
init_colors() {
    local fd="$1"
    if [[ -t "${fd}" && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_INFO=$'\033[1;34m'     # Bold Blue
        COLOR_SUCCESS=$'\033[1;32m'  # Bold Green
        COLOR_WARN=$'\033[1;33m'     # Bold Yellow
        COLOR_ERROR=$'\033[1;31m'    # Bold Red
        COLOR_HEADER=$'\033[1;36m'   # Bold Cyan
        COLOR_MUTED=$'\033[0;90m'    # Dimmed Gray
    else
        COLOR_RESET=""
        COLOR_INFO=""
        COLOR_SUCCESS=""
        COLOR_WARN=""
        COLOR_ERROR=""
        COLOR_HEADER=""
        COLOR_MUTED=""
    fi
}
init_colors 2

# --- Logging (stderr only: stdout belongs to the executed script) -------------
QUIET=0

log_info() {
    if [[ "${QUIET}" -eq 0 ]]; then
        printf "%s[INFO]%s %s\n" "${COLOR_INFO}" "${COLOR_RESET}" "$1" >&2
    fi
}

log_success() {
    if [[ "${QUIET}" -eq 0 ]]; then
        printf "%s[SUCCESS]%s %s\n" "${COLOR_SUCCESS}" "${COLOR_RESET}" "$1" >&2
    fi
}

log_warn() {
    printf "%s[WARN]%s %s\n" "${COLOR_WARN}" "${COLOR_RESET}" "$1" >&2
}

log_error() {
    printf "%s[ERROR]%s %s\n" "${COLOR_ERROR}" "${COLOR_RESET}" "$1" >&2
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# --- CLI Documentation --------------------------------------------------------
show_help() {
    init_colors 1
    cat <<EOF
${COLOR_HEADER}NAME${COLOR_RESET}
    ${SCRIPT_NAME} ${VERSION} - Run a MongoDB JavaScript file with config-driven credentials.

${COLOR_HEADER}SYNOPSIS${COLOR_RESET}
    ${SCRIPT_NAME} -c <config> -f <script.js> [-a <script_arg>]... [options] [-- <client_args>...]
    ${SCRIPT_NAME} -f <script.js> -a --help
    ${SCRIPT_NAME} -h | --help

${COLOR_HEADER}DESCRIPTION${COLOR_RESET}
    Sources a config file with credentials and topology, connects with a
    credential-less URI and authenticates through a generated preamble file
    (mode 0600, removed on exit), so the password never shows up in 'ps' or
    /proc/<pid>/cmdline. The preamble also exposes MONGO_EXEC_CTX to the script:
        MONGO_EXEC_CTX.args   script arguments given with -a (array of strings)
        MONGO_EXEC_CTX.color  true when stdout is a terminal (honours NO_COLOR)
        MONGO_EXEC_CTX.nodb   true when running without a connection

    Supported clients (both run the same preamble and script):
        mongosh               MongoDB 4.2+ (check your mongosh release notes for the
                              minimum server version it still supports).
        mongo (legacy)        MongoDB 4.x servers; use it when mongosh refuses
                              an old server's wire version.

${COLOR_HEADER}CONFIG FILE${COLOR_RESET}
    Must not be readable by group/others (chmod 600). Variables:
        export MONGOADMINUSR="<username>"                       (required)
        export MONGOADMINPAS="<password>"                       (required)
        export ADMINDB="admin"                                  (required, authSource)
        export MONGOHOST="<rs_name>/<host1>:<port>,<host2>:<port>"  (required)
                      or "<host1>:<port>,<host2>:<port>" or "<mongos>:<port>"
        export MONGO_URI_OPTIONS="tls=true&readPreference=secondaryPreferred" (optional)
        export MONGO_CLIENT_BIN="/opt/homebrew/bin/mongosh"     (optional)

${COLOR_HEADER}OPTIONS${COLOR_RESET}
    -c, --config <path>      Config file (not needed when the script runs with --nodb).
    -f, --file <path>        JavaScript file to run (must end in .js).
    -a, --arg <value>        Argument for the script (repeatable). Arguments for the
                             client go after '--' instead.
    -C, --client <bin>       Client: auto (default), mongosh, mongo, or a path.
                             Precedence: --client > MONGO_CLIENT_BIN > auto.
    -n, --nodb               Run without connecting (implied by '-a --help').
        --dry-run            Print the resolved client, URI and files, then exit.
        --allow-insecure-config
                             Only warn (instead of failing) when the config file is
                             group/world accessible.
    -q, --quiet              Suppress wrapper INFO/SUCCESS messages (stderr).
    -V, --version            Print the wrapper version and exit.
    -h, --help               Show this help and exit.
    --                       Everything after it is passed to the client unchanged.

${COLOR_HEADER}EXIT STATUS${COLOR_RESET}
    0 success, 1 wrapper error, 3 authentication failure, otherwise the exit
    code of the script / client (e.g. quit(n) in the script).

${COLOR_HEADER}EXAMPLES${COLOR_RESET}
    ${COLOR_MUTED}# Cluster-wide user audit:${COLOR_RESET}
    ./${SCRIPT_NAME} -c ~/.mongo/prod_rs.conf -f ../js/mongo_list_users.js

    ${COLOR_MUTED}# Single user, JSON output straight into jq (wrapper logs go to stderr):${COLOR_RESET}
    ./${SCRIPT_NAME} -q -c ~/.mongo/prod_rs.conf -f ../js/mongo_list_users.js \\
        -a --json -a --user=rmateos -a --auth-db=admin | jq .

    ${COLOR_MUTED}# Show the script's own help (no connection, no config needed):${COLOR_RESET}
    ./${SCRIPT_NAME} -f ../js/mongo_list_users.js -a --help

    ${COLOR_MUTED}# TLS options for the client after '--':${COLOR_RESET}
    ./${SCRIPT_NAME} -c ./env_cloud.conf -f maintenance.js -- --tls --tlsCAFile /etc/ssl/mongo-ca.pem

    ${COLOR_MUTED}# MongoDB 4.0/4.2 server with the legacy 4.4 shell:${COLOR_RESET}
    ./${SCRIPT_NAME} -c ./legacy_rs.conf -f ../js/mongo_list_users.js -C /opt/mongodb-4.4/bin/mongo
EOF
}

# --- Helpers ------------------------------------------------------------------

# Octal permission bits of a file (GNU stat first, BSD stat as fallback).
file_mode() {
    local f="$1" m=""
    if m="$(stat -c '%a' "${f}" 2>/dev/null)"; then
        printf '%s' "${m}"
    else
        stat -f '%Lp' "${f}"
    fi
}

# Percent-encode every byte. The output only contains [%0-9a-f], so it can be
# embedded in a JavaScript string literal without any escaping concerns.
pct_encode() {
    if [[ -z "$1" ]]; then
        return 0
    fi
    printf '%s' "$1" | od -A n -t x1 -v | tr -d ' \n' | sed 's/../%&/g'
}

# Resolve the client binary to an absolute path. Prints nothing if not found.
resolve_client() {
    local want="$1"
    case "${want}" in
        auto)
            command -v mongosh 2>/dev/null || command -v mongo 2>/dev/null || true
            ;;
        */*)
            if [[ -x "${want}" ]]; then
                printf '%s\n' "${want}"
            fi
            ;;
        *)
            command -v "${want}" 2>/dev/null || true
            ;;
    esac
}

# Classify the client: "mongosh" or "legacy".
client_flavor() {
    local bin="$1" ver=""
    case "$(basename "${bin}")" in
        mongosh*) printf 'mongosh'; return 0 ;;
        mongo)    printf 'legacy';  return 0 ;;
    esac
    ver="$("${bin}" --version 2>/dev/null | head -n 1 || true)"
    case "${ver}" in
        *"MongoDB shell version"*) printf 'legacy' ;;
        *)                         printf 'mongosh' ;;
    esac
}

# Write the preamble executed before the user script.
#   $1 output file, $2 "1" to authenticate, $3 "true"/"false" color, $4 "true"/"false" nodb
write_preamble() {
    local out="$1" do_auth="$2" color="$3" nodb="$4" arg
    {
        printf '// Generated by %s %s - removed on exit. Do not edit.\n' "${SCRIPT_NAME}" "${VERSION}"
        printf 'var MONGO_EXEC_CTX = (function () {\n'
        printf '  function d(s) { try { return decodeURIComponent(s); } catch (e) { return unescape(s); } }\n'
        printf '  var a = [];\n'
        for arg in ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}; do
            printf '  a.push(d("%s"));\n' "$(pct_encode "${arg}")"
        done
        printf '  return { wrapper: "%s", version: "%s", client: "%s", color: %s, nodb: %s, args: a };\n' \
            "${SCRIPT_NAME}" "${VERSION}" "${CLIENT_FLAVOR}" "${color}" "${nodb}"
        printf '})();\n'

        if [[ "${do_auth}" == "1" ]]; then
            cat <<'JS_HEAD'
(function () {
  function d(s) { try { return decodeURIComponent(s); } catch (e) { return unescape(s); } }
  // stderr only under mongosh (Node); the legacy shell has no stderr writer.
  var errOut = (typeof process !== "undefined" && process && process.versions &&
      typeof console !== "undefined" && typeof console.error === "function")
    ? function (m) { console.error(m); }
    : function (m) { print(m); };
JS_HEAD
            printf '  var user = d("%s");\n' "$(pct_encode "${MONGOADMINUSR}")"
            printf '  var pwd = d("%s");\n' "$(pct_encode "${MONGOADMINPAS}")"
            printf '  var src = d("%s");\n' "$(pct_encode "${ADMINDB}")"
            cat <<'JS_TAIL'
  var ok = false, reason = "", res = null;
  try {
    // mongosh returns { ok: 1 } (throws on failure); the legacy shell returns 1 / 0.
    res = db.getSiblingDB(src).auth(user, pwd);
    ok = (res === 1 || res === true || (res !== null && typeof res === "object" && res.ok === 1));
    if (!ok && res && res.errmsg) { reason = res.errmsg; }
  } catch (e) {
    reason = (e && e.message) ? e.message : String(e);
  }
  pwd = null;
  if (!ok) {
    errOut("[ERROR] Authentication failed for user '" + user + "' on authSource '" + src + "'" +
      (reason ? ": " + reason : ""));
    quit(3);
  }
})();
JS_TAIL
        fi
    } > "${out}"
}

# --- Parameter Parsing ----------------------------------------------------------
CONFIG_FILE=""
SCRIPT_FILE=""
CLIENT_OPT=""
NODB=0
DRY_RUN=0
ALLOW_INSECURE=0
SCRIPT_ARGS=()
EXTRA_ARGS=()

need_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        die "Option '$1' requires a value."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)  need_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
        -f|--file)    need_value "$@"; SCRIPT_FILE="$2"; shift 2 ;;
        -a|--arg)     need_value "$@"; SCRIPT_ARGS+=("$2"); shift 2 ;;
        -C|--client)  need_value "$@"; CLIENT_OPT="$2"; shift 2 ;;
        -n|--nodb)    NODB=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --allow-insecure-config) ALLOW_INSECURE=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -V|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${VERSION}"; exit 0 ;;
        -h|--help)    show_help; exit 0 ;;
        --)           shift; EXTRA_ARGS=("$@"); break ;;
        *)
            die "Unknown argument: '$1'. Script arguments go with -a (e.g. -a --json), client arguments after '--'. See --help."
            ;;
    esac
done

# The script's --help never needs a connection.
for _a in ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}; do
    if [[ "${_a}" == "--help" || "${_a}" == "-h" ]]; then
        NODB=1
    fi
done

# --- Validations ----------------------------------------------------------------
[[ -n "${SCRIPT_FILE}" ]] || { log_error "Target script (-f) is mandatory."; printf "\n" >&2; show_help >&2; exit 1; }
[[ -f "${SCRIPT_FILE}" ]] || die "Script file not found: ${SCRIPT_FILE}"
[[ -r "${SCRIPT_FILE}" ]] || die "Script file is not readable: ${SCRIPT_FILE}"
case "${SCRIPT_FILE}" in
    *.js) ;;
    *) die "Script file must have a .js extension (required by mongosh and mongo): ${SCRIPT_FILE}" ;;
esac

if [[ "${NODB}" -eq 0 ]]; then
    [[ -n "${CONFIG_FILE}" ]] || { log_error "Config file (-c) is mandatory unless --nodb is used."; printf "\n" >&2; show_help >&2; exit 1; }
    [[ -f "${CONFIG_FILE}" ]] || die "Configuration file not found: ${CONFIG_FILE}"
    [[ -r "${CONFIG_FILE}" ]] || die "Configuration file is not readable: ${CONFIG_FILE}"

    CONFIG_MODE="$(file_mode "${CONFIG_FILE}")"
    if (( 8#${CONFIG_MODE} & 8#077 )); then
        if [[ "${ALLOW_INSECURE}" -eq 1 ]]; then
            log_warn "Config file ${CONFIG_FILE} has mode ${CONFIG_MODE}; it contains credentials (chmod 600)."
        else
            die "Config file ${CONFIG_FILE} has mode ${CONFIG_MODE}; run 'chmod 600 ${CONFIG_FILE}' (or use --allow-insecure-config)."
        fi
    fi

    # Values must come from the config file, never from the caller's environment.
    unset MONGOADMINUSR MONGOADMINPAS ADMINDB MONGOHOST MONGO_URI_OPTIONS
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    for VAR in MONGOADMINUSR MONGOADMINPAS ADMINDB MONGOHOST; do
        if [[ -z "${!VAR:-}" ]]; then
            die "Missing required variable '${VAR}' in '${CONFIG_FILE}'."
        fi
    done
elif [[ -n "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]]; then
    # Only to pick up MONGO_CLIENT_BIN; credentials are not used in --nodb mode.
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

# --- Client Resolution ------------------------------------------------------------
# MONGOSHBINPATH is honoured for backwards compatibility with older config files.
CLIENT_WANT="${CLIENT_OPT:-${MONGO_CLIENT_BIN:-${MONGOSHBINPATH:-auto}}}"
MONGO_BIN="$(resolve_client "${CLIENT_WANT}" | head -n 1)"
[[ -n "${MONGO_BIN}" ]] || die "MongoDB client not found (requested: ${CLIENT_WANT}). Install mongosh or pass --client <path>."
CLIENT_FLAVOR="$(client_flavor "${MONGO_BIN}")"

if [[ "${CLIENT_FLAVOR}" == "legacy" ]]; then
    if [[ "${CLIENT_WANT}" == "auto" ]]; then
        log_warn "mongosh not found in PATH; falling back to the legacy mongo shell (${MONGO_BIN})."
    fi
    log_warn "Legacy mongo shell: intended for MongoDB 4.x servers; prefer mongosh for 5.0+."
fi

# --- URI Construction (no credentials) --------------------------------------------
URI=""
if [[ "${NODB}" -eq 0 ]]; then
    REPLICA_SET_NAME=""
    HOSTS="${MONGOHOST}"
    if [[ "${MONGOHOST}" == *"/"* ]]; then
        REPLICA_SET_NAME="${MONGOHOST%%/*}"
        HOSTS="${MONGOHOST#*/}"
    fi
    [[ -n "${HOSTS}" ]] || die "MONGOHOST has no hosts: '${MONGOHOST}'."

    URI_PARAMS=""
    if [[ -n "${REPLICA_SET_NAME}" ]]; then
        URI_PARAMS="replicaSet=${REPLICA_SET_NAME}"
    fi
    if [[ -n "${MONGO_URI_OPTIONS:-}" ]]; then
        URI_PARAMS="${URI_PARAMS:+${URI_PARAMS}&}${MONGO_URI_OPTIONS#\?}"
    fi
    URI="mongodb://${HOSTS}/${ADMINDB}${URI_PARAMS:+?${URI_PARAMS}}"
fi

# --- Preamble ------------------------------------------------------------------------
TMP_DIR=""
cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mongo_exec.XXXXXX")"
PREAMBLE="${TMP_DIR}/mongo_exec_preamble.js"

COLOR_JS="false"
if [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
    COLOR_JS="true"
fi

if [[ "${NODB}" -eq 1 ]]; then
    write_preamble "${PREAMBLE}" 0 "${COLOR_JS}" "true"
    CMD=("${MONGO_BIN}" --quiet --norc --nodb)
else
    write_preamble "${PREAMBLE}" 1 "${COLOR_JS}" "false"
    CMD=("${MONGO_BIN}" --quiet --norc)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    CMD+=("${EXTRA_ARGS[@]}")
fi
if [[ -n "${URI}" ]]; then
    CMD+=("${URI}")
fi
CMD+=("${PREAMBLE}" "${SCRIPT_FILE}")

# --- Execution -----------------------------------------------------------------------
if [[ "${NODB}" -eq 0 ]]; then
    log_info "Target topology:   ${MONGOHOST}"
    log_info "Auth user / DB:    ${MONGOADMINUSR} / ${ADMINDB}"
fi
log_info "Client:            ${MONGO_BIN} (${CLIENT_FLAVOR})"
log_info "Executing script:  ${SCRIPT_FILE}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    init_colors 1
    printf "%sDry run - command (preamble holds the credentials):%s\n" "${COLOR_HEADER}" "${COLOR_RESET}"
    printf '  %q' "${CMD[@]}"
    printf '\n'
    exit 0
fi

set +e
"${CMD[@]}"
RC=$?
set -e

if [[ "${RC}" -eq 0 ]]; then
    log_success "Script finished."
else
    log_error "Script exited with code ${RC}."
fi
exit "${RC}"
