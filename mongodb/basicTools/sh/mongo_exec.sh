#!/usr/bin/env bash
#
# Script Name: mongo_exec.sh
# Description: Wrapper to execute arbitrary JavaScript files against MongoDB instances
#              using an environment configuration file for credentials and topology.
# Compatibility: Linux (GNU coreutils) and macOS (BSD coreutils).
#

set -euo pipefail

# --- ANSI Terminal Styling Initialization ---
# Enforce raw octal literals via ANSI-C quoting ($'...') to guarantee portable byte emission
if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
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

# --- Logging Subroutines ---
log_info() {
    printf "%s[INFO]%s %s\n" "${COLOR_INFO}" "${COLOR_RESET}" "$1"
}

log_success() {
    printf "%s[SUCCESS]%s %s\n" "${COLOR_SUCCESS}" "${COLOR_RESET}" "$1"
}

log_warn() {
    printf "%s[WARN]%s %s\n" "${COLOR_WARN}" "${COLOR_RESET}" "$1" >&2
}

log_error() {
    printf "%s[ERROR]%s %s\n" "${COLOR_ERROR}" "${COLOR_RESET}" "$1" >&2
}

# --- CLI Documentation ---
show_help() {
    cat <<EOF
${COLOR_HEADER}NAME${COLOR_RESET}
    mongo_exec.sh - Execute MongoDB JavaScript files via configuration-driven connection.

${COLOR_HEADER}SYNOPSIS${COLOR_RESET}
    mongo_exec.sh -c <config_file> -f <script_file> [-- <extra_mongosh_args>...]
    mongo_exec.sh -h | --help

${COLOR_HEADER}DESCRIPTION${COLOR_RESET}
    Sources an environment configuration file containing credentials and cluster
    topology, constructs a standard MongoDB URI, and executes the specified JS
    payload using 'mongosh' (or legacy 'mongo' shell as fallback).

${COLOR_HEADER}CONFIG FILE FORMAT${COLOR_RESET}
    Required shell exports inside the config file:
        export MONGOADMINUSR="<username>"
        export MONGOADMINPAS="<password>"
        export ADMINDB="admin"
        export MONGOHOST="<replica_set_name>/<host1>:<port>,<host2>:<port>"
                         or "<host1>:<port>,<host2>:<port>"

${COLOR_HEADER}OPTIONS${COLOR_RESET}
    -c, --config <path>    Path to the database environment credentials file.
    -f, --file <path>      Path to the .js script to be executed.
    -h, --help             Display this help message and exit.
    --                     Separator; all following flags are forwarded to mongosh.

${COLOR_HEADER}EXAMPLES${COLOR_RESET}
    ${COLOR_MUTED}# Run audit script with production replica set configuration:${COLOR_RESET}
    ./mongo_exec.sh -c /etc/mongo/env.conf -f mongo_list_users.js

    ${COLOR_MUTED}# Pass arguments through mongosh down to the executed JS context:${COLOR_RESET}
    ./mongo_exec.sh -c ./env_local.conf -f mongo_list_users.js -- --json --user=rmateos

    ${COLOR_MUTED}# Connect with custom TLS certificates and extra runtime flags:${COLOR_RESET}
    ./mongo_exec.sh -c ./env_cloud.conf -f maintenance.js -- --tls --tlsAllowInvalidCertificates
EOF
}

# --- Parameter Parsing ---
CONFIG_FILE=""
SCRIPT_FILE=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ -n "${2:-}" ]] || { log_error "Option '$1' requires a valid file path."; exit 1; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        -f|--file)
            [[ -n "${2:-}" ]] || { log_error "Option '$1' requires a valid file path."; exit 1; }
            SCRIPT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        *)
            log_error "Unknown argument: $1"
            printf "\n" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

# --- Validations ---
if [[ -z "${CONFIG_FILE}" || -z "${SCRIPT_FILE}" ]]; then
    log_error "Both configuration file (-c) and target script (-f) are mandatory."
    printf "\n" >&2
    show_help >&2
    exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi

if [[ ! -r "${CONFIG_FILE}" ]]; then
    log_error "Configuration file is not readable: ${CONFIG_FILE}"
    exit 1
fi

if [[ ! -f "${SCRIPT_FILE}" ]]; then
    log_error "Script file not found: ${SCRIPT_FILE}"
    exit 1
fi

if [[ ! -r "${SCRIPT_FILE}" ]]; then
    log_error "Script file is not readable: ${SCRIPT_FILE}"
    exit 1
fi

# Locate client binary (mongosh prioritized over legacy mongo)
MONGO_BIN=""
if command -v mongosh >/dev/null 2>&1; then
    MONGO_BIN="mongosh"
elif command -v mongo >/dev/null 2>&1; then
    MONGO_BIN="mongo"
    log_warn "Binary 'mongosh' not found. Falling back to legacy 'mongo' shell."
else
    log_error "Neither 'mongosh' nor 'mongo' client binary found in PATH."
    exit 1
fi

# --- Source Configuration ---
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

REQUIRED_VARS=("MONGOADMINUSR" "MONGOADMINPAS" "ADMINDB" "MONGOHOST")
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR:-}" ]]; then
        log_error "Missing required environment variable '${VAR}' in '${CONFIG_FILE}'."
        exit 1
    fi
done

# --- URI Construction ---
REPLICA_SET_NAME=""
HOSTS="${MONGOHOST}"

if [[ "${MONGOHOST}" == *"/"* ]]; then
    REPLICA_SET_NAME="${MONGOHOST%%/*}"
    HOSTS="${MONGOHOST#*/}"
fi

# RFC 3986 URL Encoding for user and password
url_encode() {
    local string="${1}"
    local length="${#string}"
    local encoded=""
    local c
    for (( i = 0; i < length; i++ )); do
        c="${string:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) encoded+="${c}" ;;
            *) encoded+=$(printf '%%%02X' "'${c}") ;;
        esac
    done
    printf "%s" "${encoded}"
}

ENCODED_USER=$(url_encode "${MONGOADMINUSR}")
ENCODED_PASS=$(url_encode "${MONGOADMINPAS}")

URI="mongodb://${ENCODED_USER}:${ENCODED_PASS}@${HOSTS}/${ADMINDB}?authSource=${ADMINDB}"

if [[ -n "${REPLICA_SET_NAME}" ]]; then
    URI="${URI}&replicaSet=${REPLICA_SET_NAME}"
fi

log_info "Target Topology:   ${MONGOHOST}"
log_info "Authentication DB: ${ADMINDB}"
log_info "Executing Script:  ${SCRIPT_FILE}"

# --- Execution ---
CMD=(
    "${MONGO_BIN}"
    "${URI}"
    "--quiet"
    "--file" "${SCRIPT_FILE}"
)

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    CMD+=("${EXTRA_ARGS[@]}")
fi

exec "${CMD[@]}"