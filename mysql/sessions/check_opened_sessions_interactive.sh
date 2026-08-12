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
SCREEN_REFRESH_ENABLED=false
TERMINAL_OWNED=false
CURSOR_HIDDEN=false
SAMPLE_ROWS=()
SAMPLE_TOTAL=0
PREVIOUS_ROWS=()
PREVIOUS_SAMPLE_AVAILABLE=false
RUNTIME_MESSAGE=''
EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"

is_interactive_terminal() {
    [[ -t 1 && -t 0 && -n "${TERM-}" && "$TERM" != dumb ]]
}

setup_colors() {
    COLOR_RED=''
    COLOR_YELLOW=''
    COLOR_CYAN=''
    COLOR_RESET=''
    SCREEN_REFRESH_ENABLED=false

    if is_interactive_terminal; then
        SCREEN_REFRESH_ENABLED=true
    fi

    if [[ "$COLOR_ENABLED" == true && "$SCREEN_REFRESH_ENABLED" == true ]]; then
        COLOR_RED=$'\033[0;31m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_CYAN=$'\033[0;36m'
        COLOR_RESET=$'\033[0m'
    fi
}

refresh_screen() {
    if [[ "$SCREEN_REFRESH_ENABLED" == true ]]; then
        printf '\033[H\033[2J'
    fi
}

hide_cursor() {
    [[ "$TERMINAL_OWNED" == true && "$CURSOR_HIDDEN" == false ]] || return 0

    CURSOR_HIDDEN=true
    printf '\033[?25l'
}

show_cursor() {
    [[ "$TERMINAL_OWNED" == true && "$CURSOR_HIDDEN" == true ]] || return 0

    printf '\033[?25h'
    CURSOR_HIDDEN=false
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
    printf '\n'
    printf '%bDisplay limitation:%b column widths assume one terminal cell per shell character; wide or combining Unicode may misalign.\n' \
        "$COLOR_CYAN" "$COLOR_RESET"
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

validate_user_filter_value() {
    local value=$1

    [[ -z "$value" ]] || { [[ "$value" != ,* ]] && [[ "$value" != *, ]] && [[ "$value" != *,,* ]]; }
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

    if ! validate_user_filter_value "$FILTER_USER"; then
        cli_error '--user must not contain empty components.'
    fi

    local resolved_mysql_bin
    resolved_mysql_bin=$(command -v "$MYSQL_BIN" 2>/dev/null || true)
    if [[ ! -f "$resolved_mysql_bin" || ! -x "$resolved_mysql_bin" ]]; then
        cli_error '--mysql-bin must reference an executable file.'
    fi
    MYSQL_BIN=$resolved_mysql_bin

    if [[ "$LOGGING_ENABLED" == true && -z "$LOG_FILE" ]]; then
        LOG_FILE="open_sessions_$(date '+%Y%m%d_%H%M%S').log"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        local log_directory
        log_directory=$(dirname "$LOG_FILE")
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
    local filters=" AND USER NOT IN (${EXCLUDED_USERS})"
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
    local normalized_host
    local query
    local output
    local line record_type user database host sessions row_data

    filters=$(build_filter_clause)
    # PROCESSLIST.HOST appends the client port. Preserve the legacy IPv4/hostname
    # normalization and remove only that final component for IPv6. MySQL may
    # expose IPv6 either bracketed or unbracketed, so grouping cannot split on
    # the first colon. The raw HOST value remains the host-filter target.
    normalized_host="CASE
        WHEN HOST IS NULL THEN NULL
        WHEN LEFT(HOST, 1) = '[' AND LOCATE(']:', HOST) > 0
            THEN SUBSTRING(HOST, 2, LOCATE(']:', HOST) - 2)
        WHEN LEFT(HOST, 1) = '[' AND RIGHT(HOST, 1) = ']'
            THEN SUBSTRING(HOST, 2, LENGTH(HOST) - 2)
        WHEN LENGTH(HOST) - LENGTH(REPLACE(HOST, ':', '')) > 1
            THEN LEFT(HOST, LENGTH(HOST) - LENGTH(SUBSTRING_INDEX(HOST, ':', -1)) - 1)
        ELSE SUBSTRING_INDEX(SUBSTRING_INDEX(HOST, ':', 1), '.', 4)
    END"
    query="SELECT 'ROW' AS record_type, USER, DB, ${normalized_host} AS normalized_host, COUNT(*) AS sessions
FROM information_schema.PROCESSLIST
WHERE 1 = 1${filters}
GROUP BY USER, DB, normalized_host
UNION ALL
SELECT 'TOTAL' AS record_type, NULL AS USER, NULL AS DB, NULL AS HOST, COUNT(*) AS sessions
FROM information_schema.PROCESSLIST
WHERE 1 = 1${filters}
ORDER BY record_type, USER, DB, normalized_host;"
    output=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --skip-column-names -e "$query")

    SAMPLE_ROWS=()
    SAMPLE_TOTAL=0
    while IFS= read -r line; do
        record_type=${line%%$'\t'*}
        [[ -n "$record_type" ]] || continue
        if [[ "$record_type" == TOTAL ]]; then
            SAMPLE_TOTAL=${line##*$'\t'}
        elif [[ "$record_type" == ROW ]]; then
            row_data=${line#*$'\t'}
            IFS=$'\t' read -r user database host sessions <<< "$row_data"
            SAMPLE_ROWS+=("$user"$'\t'"$database"$'\t'"$host"$'\t'"$sessions")
        fi
    done <<< "$output"
}

claim_log_file() {
    [[ -n "$LOG_FILE" ]] || return 0

    set -C
    if ! exec 3>"$LOG_FILE"; then
        set +C
        cli_error '--log-file must not already exist.'
    fi
    set +C
}

reserve_runtime_log_file() {
    set -C
    if ! exec 3>"$LOG_FILE"; then
        set +C
        return 1
    fi
    set +C
}

filter_label() {
    local value=$1
    local fallback=$2

    if [[ -n "$value" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

state_label() {
    if [[ "$1" == true ]]; then
        printf 'ON'
    else
        printf 'OFF'
    fi
}

previous_sessions() {
    local wanted_user=$1
    local wanted_database=$2
    local wanted_host=$3
    local row user database host sessions

    for row in "${PREVIOUS_ROWS[@]}"; do
        IFS=$'\t' read -r user database host sessions <<< "$row"
        if [[ "$user" == "$wanted_user" && "$database" == "$wanted_database" && "$host" == "$wanted_host" ]]; then
            printf '%s' "$sessions"
            return 0
        fi
    done
    printf '0'
}

render_frame() {
    local user_width=4
    local database_width=8
    local host_width=4
    local sessions_width=8
    local delta_width=5
    local row user database host sessions previous delta delta_text
    local timestamp

    for row in "${SAMPLE_ROWS[@]}"; do
        IFS=$'\t' read -r user database host sessions <<< "$row"
        (( ${#user} > user_width )) && user_width=${#user}
        (( ${#database} > database_width )) && database_width=${#database}
        (( ${#host} > host_width )) && host_width=${#host}
        (( ${#sessions} > sessions_width )) && sessions_width=${#sessions}
        if [[ "$DIFF_ENABLED" == true ]]; then
            if [[ "$PREVIOUS_SAMPLE_AVAILABLE" == true ]]; then
                previous=$(previous_sessions "$user" "$database" "$host")
                delta=$((sessions - previous))
            else
                delta=0
            fi
            printf -v delta_text '%+d' "$delta"
            (( ${#delta_text} > delta_width )) && delta_width=${#delta_text}
        fi
    done

    timestamp=$(date '+%F %T')
    printf '%bOpen MySQL Sessions%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf 'Timestamp: %s | Refresh interval: %ss | Diff: %s | Logging: %s\n' \
        "$timestamp" "$REFRESH_TIME" "$(state_label "$DIFF_ENABLED")" "$(state_label "$LOGGING_ENABLED")"
    printf 'Filters: user=%s database=%s host=%s\n' \
        "$(filter_label "$FILTER_USER" '<all>')" \
        "$(filter_label "$FILTER_DATABASE" '<all>')" \
        "$(filter_label "$FILTER_HOST" '<all>')"
    printf 'Total matching connections: %s\n\n' "$SAMPLE_TOTAL"
    printf '%-*s  %-*s  %-*s  %*s' \
        "$user_width" 'User' "$database_width" 'Database' "$host_width" 'Host' "$sessions_width" 'Sessions'
    [[ "$DIFF_ENABLED" == true ]] && printf '  %*s' "$delta_width" 'Delta'
    printf '\n'
    printf '%-*s  %-*s  %-*s  %*s' \
        "$user_width" "$(printf '%*s' "$user_width" '' | tr ' ' '-')" \
        "$database_width" "$(printf '%*s' "$database_width" '' | tr ' ' '-')" \
        "$host_width" "$(printf '%*s' "$host_width" '' | tr ' ' '-')" \
        "$sessions_width" "$(printf '%*s' "$sessions_width" '' | tr ' ' '-')"
    [[ "$DIFF_ENABLED" == true ]] && printf '  %*s' "$delta_width" "$(printf '%*s' "$delta_width" '' | tr ' ' '-')"
    printf '\n'

    for row in "${SAMPLE_ROWS[@]}"; do
        IFS=$'\t' read -r user database host sessions <<< "$row"
        printf '%b%-*s%b  %b%-*s%b  %b%-*s%b  %b%*s%b' \
            "$COLOR_CYAN" "$user_width" "$user" "$COLOR_RESET" \
            "$COLOR_CYAN" "$database_width" "$database" "$COLOR_RESET" \
            "$COLOR_CYAN" "$host_width" "$host" "$COLOR_RESET" \
            "$COLOR_YELLOW" "$sessions_width" "$sessions" "$COLOR_RESET"
        if [[ "$DIFF_ENABLED" == true ]]; then
            if [[ "$PREVIOUS_SAMPLE_AVAILABLE" == true ]]; then
                previous=$(previous_sessions "$user" "$database" "$host")
                delta=$((sessions - previous))
            else
                delta=0
            fi
            printf -v delta_text '%+d' "$delta"
            printf '  %b%*s%b' "$COLOR_YELLOW" "$delta_width" "$delta_text" "$COLOR_RESET"
        fi
        printf '\n'
    done

    if [[ "$SCREEN_REFRESH_ENABLED" == true ]]; then
        if [[ -n "$RUNTIME_MESSAGE" ]]; then
            printf '\n%b%s%b\n' "$COLOR_RED" "$RUNTIME_MESSAGE" "$COLOR_RESET"
        fi
        printf '\n%bInteractive options:%b %b[q]%b Quit  %b[m]%b Modify filters  %b[d]%b Toggle diff  %b[l]%b Toggle logging | Diff: %s | Logging: %s\n' \
            "$COLOR_CYAN" "$COLOR_RESET" \
            "$COLOR_YELLOW" "$COLOR_RESET" \
            "$COLOR_YELLOW" "$COLOR_RESET" \
            "$COLOR_YELLOW" "$COLOR_RESET" \
            "$COLOR_YELLOW" "$COLOR_RESET" \
            "$(state_label "$DIFF_ENABLED")" "$(state_label "$LOGGING_ENABLED")"
    fi
}

append_log() {
    local saved_color_enabled=$COLOR_ENABLED
    local saved_screen_refresh_enabled=$SCREEN_REFRESH_ENABLED
    local saved_color_red=$COLOR_RED
    local saved_color_yellow=$COLOR_YELLOW
    local saved_color_cyan=$COLOR_CYAN
    local saved_color_reset=$COLOR_RESET
    local errexit_enabled=false
    local log_status=0

    [[ "$LOGGING_ENABLED" == true && -n "$LOG_FILE" ]] || return 0

    COLOR_ENABLED=false
    SCREEN_REFRESH_ENABLED=false
    COLOR_RED=''
    COLOR_YELLOW=''
    COLOR_CYAN=''
    COLOR_RESET=''

    [[ $- == *e* ]] && errexit_enabled=true
    set +e
    render_frame >&3
    log_status=$?
    if [[ "$log_status" -eq 0 ]]; then
        printf '\n' >&3
        log_status=$?
    fi

    COLOR_ENABLED=$saved_color_enabled
    SCREEN_REFRESH_ENABLED=$saved_screen_refresh_enabled
    COLOR_RED=$saved_color_red
    COLOR_YELLOW=$saved_color_yellow
    COLOR_CYAN=$saved_color_cyan
    COLOR_RESET=$saved_color_reset

    [[ "$errexit_enabled" == true ]] && set -e
    return "$log_status"
}

toggle_diff() {
    if [[ "$DIFF_ENABLED" == true ]]; then
        DIFF_ENABLED=false
    else
        DIFF_ENABLED=true
    fi
    RUNTIME_MESSAGE=''
}

toggle_logging() {
    if [[ "$LOGGING_ENABLED" == true ]]; then
        LOGGING_ENABLED=false
        RUNTIME_MESSAGE=''
        return 0
    fi

    if [[ -z "$LOG_FILE" ]]; then
        LOG_FILE="open_sessions_$(date '+%Y%m%d_%H%M%S').log"
        if ! reserve_runtime_log_file; then
            LOG_FILE=''
            RUNTIME_MESSAGE='ERROR: Log file already exists; logging remains OFF.'
            return 0
        fi
    fi

    LOGGING_ENABLED=true
    RUNTIME_MESSAGE=''
}

prompt_filters() {
    local candidate_user candidate_database candidate_host

    show_cursor
    printf '\nModify filters (blank keeps current value)\n'
    printf 'User [%s]: ' "$(filter_label "$FILTER_USER" '<all>')"
    IFS= read -r candidate_user || candidate_user=''
    printf 'Database [%s]: ' "$(filter_label "$FILTER_DATABASE" '<all>')"
    IFS= read -r candidate_database || candidate_database=''
    printf 'Host [%s]: ' "$(filter_label "$FILTER_HOST" '<all>')"
    IFS= read -r candidate_host || candidate_host=''
    hide_cursor

    [[ -n "$candidate_user" ]] || candidate_user=$FILTER_USER
    [[ -n "$candidate_database" ]] || candidate_database=$FILTER_DATABASE
    [[ -n "$candidate_host" ]] || candidate_host=$FILTER_HOST

    if ! validate_user_filter_value "$candidate_user"; then
        RUNTIME_MESSAGE='ERROR: --user must not contain empty components. Filters unchanged.'
        return 0
    fi

    FILTER_USER=$candidate_user
    FILTER_DATABASE=$candidate_database
    FILTER_HOST=$candidate_host
    RUNTIME_MESSAGE=''
}

handle_key() {
    case "${1-}" in
        q|Q) return 10 ;;
        m|M) prompt_filters ;;
        d|D) toggle_diff ;;
        l|L) toggle_logging ;;
    esac
}

restore_terminal() {
    local exit_status=$?

    set +e
    if [[ -n "$LOG_FILE" ]]; then
        exec 3>&-
    fi
    show_cursor
    return "$exit_status"
}

run_interactive() {
    local key=''
    local key_status

    trap restore_terminal EXIT
    trap 'exit 130' HUP INT TERM
    TERMINAL_OWNED=true
    hide_cursor

    while true; do
        collect_sample
        refresh_screen
        render_frame
        append_log
        PREVIOUS_ROWS=("${SAMPLE_ROWS[@]}")
        PREVIOUS_SAMPLE_AVAILABLE=true

        key=''
        if IFS= read -rsn 1 -t "$REFRESH_TIME" key; then
            if handle_key "$key"; then
                :
            else
                key_status=$?
                if [[ "$key_status" -eq 10 ]]; then
                    break
                fi
                return "$key_status"
            fi
        fi
    done
}

setup_colors
parse_arguments "$@"
setup_colors
claim_log_file
if [[ "$SCREEN_REFRESH_ENABLED" == true ]]; then
    run_interactive
else
    collect_sample
    refresh_screen
    render_frame
    append_log
fi
