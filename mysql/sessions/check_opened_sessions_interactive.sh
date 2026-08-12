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
SAMPLE_ROWS=()
SAMPLE_TOTAL=0

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
            -l?*)
                require_value -l "${1#-l}"
                LOGIN_PATH=${1#-l}
                shift
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
            -t?*)
                require_value -t "${1#-t}"
                REFRESH_TIME=${1#-t}
                shift
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
            -u?*)
                require_value -u "${1#-u}"
                FILTER_USER=${1#-u}
                shift
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
            -d?*)
                require_value -d "${1#-d}"
                FILTER_DATABASE=${1#-d}
                shift
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
            -h?*)
                require_value -h "${1#-h}"
                FILTER_HOST=${1#-h}
                shift
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

    [[ "$REFRESH_TIME" =~ ^[1-9][0-9]*$ ]] || cli_error '--refresh-time must be a positive integer.'

    if [[ -n "$FILTER_USER" ]] && { [[ "$FILTER_USER" == ,* ]] || [[ "$FILTER_USER" == *, ]] || [[ "$FILTER_USER" == *,,* ]]; }; then
        cli_error '--user must not contain empty components.'
    fi

    if [[ ! -x "$MYSQL_BIN" ]] && ! command -v "$MYSQL_BIN" >/dev/null 2>&1; then
        cli_error '--mysql-bin must reference an executable file.'
    fi

    if [[ -n "$LOG_FILE" ]]; then
        local log_directory
        log_directory=$(dirname "$LOG_FILE")
        [[ ! -e "$LOG_FILE" ]] || cli_error '--log-file must not already exist.'
        [[ -d "$log_directory" && -w "$log_directory" ]] || cli_error '--log-file parent directory must be writable.'
    fi
}

sql_hex_literal() {
    local value=$1
    local hex
    hex=$(LC_ALL=C printf '%s' "$value" | od -An -tx1 -v | tr -d ' \n')
    printf 'CONVERT(0x%s USING utf8mb4)' "$hex"
}

like_literal() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//%/\\%}
    value=${value//_/\\_}
    printf '%s' "$value"
}

like_pattern_expression() {
    local value
    value=$(like_literal "$1")
    sql_hex_literal "%${value}%"
}

build_filter_clause() {
    local filters=''
    local user
    local quoted_users=''
    local users=()

    if [[ -n "$FILTER_USER" ]]; then
        IFS=',' read -r -a users <<< "$FILTER_USER"
        for user in "${users[@]}"; do
            if [[ -n "$quoted_users" ]]; then
                quoted_users+=', '
            fi
            quoted_users+=$(sql_hex_literal "$user")
        done
        filters+=" AND USER IN (${quoted_users})"
    fi

    if [[ -n "$FILTER_DATABASE" ]]; then
        filters+=" AND DB = $(sql_hex_literal "$FILTER_DATABASE")"
    fi

    if [[ -n "$FILTER_HOST" ]]; then
        filters+=" AND HOST LIKE $(like_pattern_expression "$FILTER_HOST") ESCAPE $(sql_hex_literal $'\\')"
    fi

    printf '%s' "$filters"
}

collect_sample() {
    local filters
    local query
    local output
    local record_type user database host sessions

    filters=$(build_filter_clause)
    query="SELECT 'ROW' AS record_type, USER, DB, HOST, COUNT(*) AS sessions
FROM information_schema.PROCESSLIST
WHERE 1 = 1${filters}
GROUP BY USER, DB, HOST
UNION ALL
SELECT 'TOTAL' AS record_type, NULL AS USER, NULL AS DB, NULL AS HOST, COUNT(*) AS sessions
FROM information_schema.PROCESSLIST
WHERE 1 = 1${filters};"
    output=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --skip-column-names -e "$query")

    SAMPLE_ROWS=()
    SAMPLE_TOTAL=0
    while IFS=$'\t' read -r record_type user database host sessions; do
        [[ -n "$record_type" ]] || continue
        if [[ "$record_type" == TOTAL ]]; then
            SAMPLE_TOTAL=$sessions
        elif [[ "$record_type" == ROW ]]; then
            SAMPLE_ROWS+=("$user"$'\t'"$database"$'\t'"$host"$'\t'"$sessions")
        fi
    done <<< "$output"
}

setup_colors
parse_arguments "$@"
collect_sample
