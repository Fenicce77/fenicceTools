#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOGIN_PATH=''
REFRESH_TIME=5
FILTER_USER=''
FILTER_DATABASE=''
FILTER_HOST=''
LOGGING_ENABLED=false
DIFF_ENABLED=false
LOG_FILE=''
MYSQL_BIN=mysql
COLOR_ENABLED=true

setup_colors() {
    if [[ "$COLOR_ENABLED" == true ]]; then
        COLOR_RED=$'\033[0;31m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_CYAN=$'\033[0;36m'
        COLOR_RESET=$'\033[0m'
    else
        COLOR_RED=''
        COLOR_YELLOW=''
        COLOR_CYAN=''
        COLOR_RESET=''
    fi
}

show_help() {
    printf '%bUsage:%b %s -l LOGIN_PATH [options]\n' "$COLOR_YELLOW" "$COLOR_RESET" "$SCRIPT_NAME"
    printf '\n'
    printf '%bConnection options:%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '  -l, --login-path NAME       Required MySQL login path\n'
    printf '      --mysql-bin PATH        MySQL client binary path\n'
    printf '      --no-color              Disable ANSI color output\n'
    printf '\n'
    printf '%bRuntime options:%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '  -t, --refresh-time SECONDS Refresh interval (default: 5)\n'
    printf '  -u, --user USER[,USER]     Filter by MySQL user\n'
    printf '  -d, --database DATABASE    Filter by database\n'
    printf '  -h, --host HOST            Filter by host\n'
    printf '  -o, --logging              Enable snapshot logging\n'
    printf '      --diff                 Enable sample difference display\n'
    printf '      --log-file PATH        Destination for snapshot logging\n'
    printf '\n'
    printf '%bRuntime keys:%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '  [q] Quit  [m] Modify filters  [d] Toggle diff  [l] Toggle logging\n'
    printf '\n'
    printf '%bExamples:%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '  %s --login-path reporting\n' "$SCRIPT_NAME"
    printf '  %s -l reporting -t 10 -u app -d billing -h api\n' "$SCRIPT_NAME"
}

cli_error() {
    printf '%bERROR: %s%b\n\n' "$COLOR_RED" "$1" "$COLOR_RESET" >&2
    show_help >&2
    exit 2
}

require_value() {
    local option=$1
    local value=${2-}

    if [[ -z "$value" || "$value" == -* ]]; then
        cli_error "Option $option requires a value."
    fi
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        if [[ "$argument" == --no-color ]]; then
            COLOR_ENABLED=false
            setup_colors
            break
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --no-color)
                COLOR_ENABLED=false
                setup_colors
                shift
                ;;
            -l|--login-path)
                require_value "$1" "${2-}"
                LOGIN_PATH=$2
                shift 2
                ;;
            --login-path=*)
                require_value --login-path "${1#*=}"
                LOGIN_PATH=${1#*=}
                shift
                ;;
            -t|--refresh-time)
                require_value "$1" "${2-}"
                REFRESH_TIME=$2
                shift 2
                ;;
            --refresh-time=*)
                require_value --refresh-time "${1#*=}"
                REFRESH_TIME=${1#*=}
                shift
                ;;
            -u|--user)
                require_value "$1" "${2-}"
                FILTER_USER=$2
                shift 2
                ;;
            --user=*)
                require_value --user "${1#*=}"
                FILTER_USER=${1#*=}
                shift
                ;;
            -d|--database)
                require_value "$1" "${2-}"
                FILTER_DATABASE=$2
                shift 2
                ;;
            --database=*)
                require_value --database "${1#*=}"
                FILTER_DATABASE=${1#*=}
                shift
                ;;
            -h|--host)
                require_value "$1" "${2-}"
                FILTER_HOST=$2
                shift 2
                ;;
            --host=*)
                require_value --host "${1#*=}"
                FILTER_HOST=${1#*=}
                shift
                ;;
            -o|--logging)
                LOGGING_ENABLED=true
                shift
                ;;
            --diff)
                DIFF_ENABLED=true
                shift
                ;;
            --log-file|--mysql-bin)
                require_value "$1" "${2-}"
                if [[ "$1" == --log-file ]]; then
                    LOG_FILE=$2
                else
                    MYSQL_BIN=$2
                fi
                shift 2
                ;;
            --log-file=*|--mysql-bin=*)
                require_value "${1%%=*}" "${1#*=}"
                if [[ "$1" == --log-file=* ]]; then
                    LOG_FILE=${1#*=}
                else
                    MYSQL_BIN=${1#*=}
                fi
                shift
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || cli_error "Unexpected argument: $1"
                ;;
            -*)
                cli_error "Unknown option: $1"
                ;;
            *)
                cli_error "Unexpected argument: $1"
                ;;
        esac
    done

    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
}

setup_colors
parse_arguments "$@"
