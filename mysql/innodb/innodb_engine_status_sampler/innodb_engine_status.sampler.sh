#!/usr/bin/env bash
set -euo pipefail

# Capture or display SHOW ENGINE INNODB STATUS output for a configured instance.

PROGRAM_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

INSTANCE_NAME=''
MODE='capture'
INTERVAL=5
SAMPLE_BASE_DIR='/data/innodb'
MYSQL_BIN='mysql'
NO_COLOR=false
LOCK_ACQUIRED=false
LOCK_FILE=''
LOCK_DIRECTORY=''
SAMPLE_DIR=''
CONFIG_FILE=''
SERVER_HOST=''
SERVER_PORT=''

COLOR_RESET=''
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_CYAN=''
COLOR_BOLD=''

initialize_colors() {
    if [[ "$NO_COLOR" == false && -t 1 && -n "${TERM:-}" && "${TERM:-}" != 'dumb' ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_RED=$'\033[0;31m'
        COLOR_GREEN=$'\033[0;32m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_CYAN=$'\033[0;36m'
        COLOR_BOLD=$'\033[1m'
    fi
}

show_help() {
    cat <<EOF
${COLOR_CYAN}${COLOR_BOLD}InnoDB Engine Status Sampler${COLOR_RESET}

Capture periodic SHOW ENGINE INNODB STATUS samples, or display one sample.
The required instance name resolves ${SCRIPT_DIR}/.conf/<instance_name>.cnf.

${COLOR_YELLOW}${COLOR_BOLD}Usage:${COLOR_RESET}
  ${PROGRAM_NAME} INSTANCE_NAME [OPTIONS]

${COLOR_YELLOW}${COLOR_BOLD}Modes:${COLOR_RESET}
  Default capture mode stores samples under:
    SAMPLE_DIR/YYYYMMDD/YYYYMMDD_HH.sample
  SAMPLE_DIR defaults to /data/innodb/<host>_<port>.

${COLOR_YELLOW}${COLOR_BOLD}Options:${COLOR_RESET}
  -i, --interval SECONDS       Capture interval in seconds; default: 5.
      --display                Print one status sample; do not write files or locks.
      --sample-base-dir PATH   Base directory for capture samples; default: /data/innodb.
      --mysql-bin PATH         MySQL client executable; default: mysql from PATH.
      --no-color               Disable ANSI colors.
  -h, --help                   Show this help and exit.

${COLOR_YELLOW}${COLOR_BOLD}Examples:${COLOR_RESET}
  ${PROGRAM_NAME} ke-primary
  ${PROGRAM_NAME} ke-primary --interval 10
  ${PROGRAM_NAME} ke-primary --sample-base-dir /srv/innodb/samples
  ${PROGRAM_NAME} ke-primary --display
EOF
}

error_exit() {
    printf '%bERROR:%b %s\n' "$COLOR_RED$COLOR_BOLD" "$COLOR_RESET" "$1" >&2
    show_help >&2
    exit 2
}

info() {
    printf '%bINFO:%b %s\n' "$COLOR_CYAN$COLOR_BOLD" "$COLOR_RESET" "$1"
}

warning() {
    printf '%bWARNING:%b %s\n' "$COLOR_YELLOW$COLOR_BOLD" "$COLOR_RESET" "$1" >&2
}

require_value() {
    local option_name=$1
    local value=${2:-}

    [[ -n "$value" && "$value" != '-' && "$value" != --* ]] || error_exit "$option_name requires a value."
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

preparse_no_color() {
    local argument

    for argument in "$@"; do
        if [[ "$argument" == '--no-color' ]]; then
            NO_COLOR=true
        fi
    done
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --no-color)
                NO_COLOR=true
                ;;
            --display)
                MODE='display'
                ;;
            -i|--interval)
                shift
                require_value '--interval' "${1:-}"
                INTERVAL=$1
                ;;
            --sample-base-dir)
                shift
                require_value '--sample-base-dir' "${1:-}"
                SAMPLE_BASE_DIR=$1
                ;;
            --mysql-bin)
                shift
                require_value '--mysql-bin' "${1:-}"
                MYSQL_BIN=$1
                ;;
            --)
                shift
                [[ $# -eq 1 ]] || error_exit 'exactly one instance name is required.'
                [[ -z "$INSTANCE_NAME" ]] || error_exit 'exactly one instance name is required.'
                INSTANCE_NAME=$1
                break
                ;;
            -*)
                error_exit "unknown option: $1"
                ;;
            *)
                [[ -z "$INSTANCE_NAME" ]] || error_exit 'exactly one instance name is required.'
                INSTANCE_NAME=$1
                ;;
        esac
        shift
    done
}

resolve_mysql_bin() {
    if [[ "$MYSQL_BIN" == */* ]]; then
        [[ -x "$MYSQL_BIN" ]] || error_exit '--mysql-bin must reference an executable file.'
    else
        MYSQL_BIN=$(command -v "$MYSQL_BIN" 2>/dev/null || true)
        [[ -n "$MYSQL_BIN" ]] || error_exit 'MySQL client was not found in PATH.'
    fi
}

read_config_option() {
    local option_name=$1

    awk -F '=' -v option_name="$option_name" '
        $1 ~ "^[[:space:]]*" option_name "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$CONFIG_FILE"
}

resolve_instance() {
    [[ -n "$INSTANCE_NAME" ]] || error_exit 'instance name is required.'
    [[ "$INSTANCE_NAME" =~ ^[[:alnum:]_.-]+$ ]] || error_exit 'instance name contains unsupported characters.'
    is_positive_integer "$INTERVAL" || error_exit '--interval must be a positive integer.'

    CONFIG_FILE="$SCRIPT_DIR/.conf/${INSTANCE_NAME}.cnf"
    [[ -r "$CONFIG_FILE" ]] || error_exit "instance configuration is not readable: $CONFIG_FILE"

    if [[ "$INSTANCE_NAME" == 'betika-africa' ]]; then
        SERVER_HOST=$INSTANCE_NAME
        SAMPLE_DIR="$SAMPLE_BASE_DIR/$SERVER_HOST"
        return
    fi

    SERVER_HOST=$(read_config_option 'host')
    SERVER_PORT=$(read_config_option 'port')
    [[ -n "$SERVER_HOST" ]] || error_exit "instance configuration is missing host: $CONFIG_FILE"
    is_positive_integer "$SERVER_PORT" || error_exit "instance configuration has an invalid port: $CONFIG_FILE"
    SAMPLE_DIR="$SAMPLE_BASE_DIR/${SERVER_HOST}_${SERVER_PORT}"
}

cleanup_lock() {
    local exit_code=$?

    if [[ "$LOCK_ACQUIRED" == true ]]; then
        rm -f -- "$LOCK_FILE"
        rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
        LOCK_ACQUIRED=false
    fi
    exit "$exit_code"
}

acquire_lock() {
    local running_pid=''

    mkdir -p -- "$SAMPLE_DIR" || error_exit "cannot create sample directory: $SAMPLE_DIR"
    LOCK_FILE="$SAMPLE_DIR/lockfile.lock"
    LOCK_DIRECTORY="${LOCK_FILE}.d"

    if [[ -e "$LOCK_FILE" && ! -d "$LOCK_DIRECTORY" ]]; then
        running_pid=$(tr -d '[:space:]' < "$LOCK_FILE")
        if [[ "$running_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$running_pid" 2>/dev/null; then
            error_exit "capture is already running for $INSTANCE_NAME with PID $running_pid."
        fi
        warning "removing stale legacy lock for $INSTANCE_NAME."
        rm -f -- "$LOCK_FILE"
    fi

    if mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_FILE"
        LOCK_ACQUIRED=true
        return
    fi

    if [[ -r "$LOCK_FILE" ]]; then
        running_pid=$(tr -d '[:space:]' < "$LOCK_FILE")
    fi
    if [[ "$running_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$running_pid" 2>/dev/null; then
        error_exit "capture is already running for $INSTANCE_NAME with PID $running_pid."
    fi

    warning "removing stale lock for $INSTANCE_NAME."
    rm -f -- "$LOCK_FILE"
    rmdir "$LOCK_DIRECTORY" 2>/dev/null || error_exit "cannot recover stale lock: $LOCK_DIRECTORY"
    acquire_lock
}

check_connection() {
    "$MYSQL_BIN" --defaults-file="$CONFIG_FILE" --batch --skip-column-names --raw \
        --execute='SELECT 1;' >/dev/null
}

display_status() {
    printf 'SHOW ENGINE INNODB STATUS\\G\n' | \
        "$MYSQL_BIN" --defaults-file="$CONFIG_FILE" --batch --skip-column-names --raw
}

write_sample() {
    local day
    local hour
    local folder
    local sample_file
    local temporary_file

    day=$(date '+%Y%m%d')
    hour=$(date '+%Y%m%d_%H')
    folder="$SAMPLE_DIR/$day"
    sample_file="$folder/$hour.sample"
    mkdir -p -- "$folder" || return 1
    temporary_file=$(mktemp "$SAMPLE_DIR/.innodb-status.XXXXXX") || return 1

    if ! display_status > "$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    cat "$temporary_file" >> "$sample_file"
    rm -f -- "$temporary_file"
    info "saved sample: $sample_file"
}

capture_loop() {
    info "starting capture for $INSTANCE_NAME at $SERVER_HOST${SERVER_PORT:+:$SERVER_PORT}; interval: ${INTERVAL}s"

    while true; do
        if check_connection; then
            write_sample || warning "failed to write a status sample for $INSTANCE_NAME."
        else
            warning "connection check failed for $INSTANCE_NAME; no sample was written."
        fi
        sleep "$INTERVAL"
    done
}

main() {
    preparse_no_color "$@"
    initialize_colors
    parse_arguments "$@"
    resolve_instance
    resolve_mysql_bin

    if [[ "$MODE" == 'display' ]]; then
        display_status
        return
    fi

    acquire_lock
    trap cleanup_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    capture_loop
}

main "$@"
