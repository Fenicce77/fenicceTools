#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOGIN_PATH=''
INTERVAL=5
MYSQL_BIN=''
NO_COLOR=0
RESIZE_STATE=''

setup_terminal() {
    if [[ "$NO_COLOR" -eq 1 ]]; then
        COLOR_RED=''
        COLOR_GREEN=''
        COLOR_YELLOW=''
        COLOR_CYAN=''
        COLOR_RESET=''
    else
        COLOR_RED=$'\033[1;31m'
        COLOR_GREEN=$'\033[1;32m'
        COLOR_YELLOW=$'\033[1;33m'
        COLOR_CYAN=$'\033[1;36m'
        COLOR_RESET=$'\033[0m'
    fi
}

show_help() {
    cat <<EOF
${COLOR_CYAN}Usage:${COLOR_RESET} $SCRIPT_NAME --login-path NAME [OPTIONS]

Monitor the read-only InnoDB buffer pool resize status variables.

${COLOR_CYAN}Required:${COLOR_RESET}
  --login-path NAME       mysql_config_editor login path to use.

${COLOR_CYAN}Options:${COLOR_RESET}
  --interval SECONDS      Sampling interval; positive integer (default: 5).
  --mysql-bin PATH        Path to a regular executable mysql client.
  --no-color              Disable ANSI color output.
  -h, --help              Show this help and exit.

${COLOR_CYAN}Examples:${COLOR_RESET}
  $SCRIPT_NAME --login-path monitor
  $SCRIPT_NAME --login-path monitor --interval 10 --mysql-bin /usr/local/bin/mysql
EOF
}

cli_error() {
    printf '%sERROR: %s%s\n' "$COLOR_RED" "$1" "$COLOR_RESET" >&2
    show_help >&2
    exit 2
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        if [[ "$argument" == '--no-color' ]]; then
            NO_COLOR=1
            break
        fi
    done
    setup_terminal

    while (($#)); do
        case "$1" in
            --login-path)
                (($# >= 2)) || cli_error '--login-path requires a value.'
                LOGIN_PATH=$2
                shift 2
                ;;
            --interval)
                (($# >= 2)) || cli_error '--interval requires a value.'
                INTERVAL=$2
                shift 2
                ;;
            --mysql-bin)
                (($# >= 2)) || cli_error '--mysql-bin requires a value.'
                MYSQL_BIN=$2
                shift 2
                ;;
            --no-color)
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                cli_error "unknown option: $1"
                ;;
        esac
    done

    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
    [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || cli_error '--interval must be a positive integer.'

    if [[ -z "$MYSQL_BIN" ]]; then
        MYSQL_BIN=$(command -v mysql 2>/dev/null || true)
    fi
    [[ -n "$MYSQL_BIN" && -f "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || cli_error '--mysql-bin must reference a regular executable file.'
}

collect_resize_state() {
    RESIZE_STATE=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names -e "SELECT
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_code' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_progress' THEN VARIABLE_VALUE END),
    @@GLOBAL.innodb_buffer_pool_size
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN (
    'Innodb_buffer_pool_resize_status',
    'Innodb_buffer_pool_resize_status_code',
    'Innodb_buffer_pool_resize_status_progress'
);")
}

main() {
    parse_arguments "$@"
    collect_resize_state
    printf '%s\n' "$RESIZE_STATE"
}

main "$@"
