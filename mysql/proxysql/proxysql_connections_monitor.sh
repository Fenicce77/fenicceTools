#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Initialization and CLI
# ==============================================================================
initialize_defaults() {
    LOGIN_PATH=""
    REFRESH_TIME=5
    USER_FILTER=""
    OUTPUT_FILE=""
    VIEW_MODE="CONN"
    SORT_MODE="CONN"
    THRESHOLD=0
    PAUSED=false
    QUERY_TIMEOUT=5
    MYSQL_BIN=${MYSQL_BIN:-mysql}
    MYSQL_PID=""
    MYSQL_INPUT_FD=""
    MYSQL_OUTPUT_FD=""
    MYSQL_SESSION_DIR=""
    MYSQL_INPUT_PIPE=""
    MYSQL_OUTPUT_PIPE=""
    MYSQL_ERROR_FILE=""
    MYSQL_REQUEST_SEQUENCE=0
    QUERY_RESULT=""
    LAST_DB_ERROR=""
    LAST_SAMPLE_STALE=false
    PREV_DATA=""
    FORMATTED_OUTPUT=""
    F_POOL=""
    F_PING=""
    PROXY_VERSION=""
    PROXY_HOSTNAME="Unknown"
    TERM_WIDTH=130
    TERM_GEOMETRY_DIRTY=true
    SEP_LINE=""
    SEP_THIN=""
    TIMESTAMP=""
    TIMESTAMP_SECOND=-1
    RUNNING=true
}

initialize_colors() {
    blk=$(tput blink 2>/dev/null || true)
    bld=$(tput bold 2>/dev/null || true)
    red=${bld}$(tput setaf 1 2>/dev/null || true)
    grn=${bld}$(tput setaf 2 2>/dev/null || true)
    yel=${bld}$(tput setaf 3 2>/dev/null || true)
    blu=${bld}$(tput setaf 4 2>/dev/null || true)
    mag=${bld}$(tput setaf 5 2>/dev/null || true)
    cyn=${bld}$(tput setaf 6 2>/dev/null || true)
    wht=${bld}$(tput setaf 7 2>/dev/null || true)
    off=$(tput sgr0 2>/dev/null || true)
}

usage_text() {
    printf '\033[H\033[2J'
    printf '%b\n' "${cyn}=================================================================================${off}"
    printf '%b\n' "${bld} ProxySQL Ultimate Monitor (DBA Edition) ${off}"
    printf '%b\n' "${cyn}=================================================================================${off}"
    printf '%b\n\n' "${blu}Usage:${off} $0 ${mag}--login-path=NAME${off} ${wht}[OPTIONS]${off}"
    printf '%b\n' "${yel}Mandatory Parameters:${off}"
    printf '%b\n\n' "  ${mag}--login-path=NAME${off}      MySQL login-path file to connect to ProxySQL admin."
    printf '%b\n' "${yel}Optional Parameters:${off}"
    printf '%b\n' "  ${grn}-r, --refresh-time=N${off}   Refresh time in seconds. Supports floats e.g., 0.5 (Default: ${bld}5${off})."
    printf '%b\n' "  ${grn}-u, --user-filter=STR${off}  Filter by user (string match or comma-separated list)."
    printf '%b\n' "  ${grn}-t, --threshold=N${off}      Alert threshold for active connections (Default: 0)."
    printf '%b\n' "  ${grn}-o, --output-file=FILE${off} File path to save the continuous output log."
    printf '%b\n\n' "  ${grn}-h, --help${off}             Shows this help and exits."
    printf '%b\n' "${yel}Use Cases and Examples:${off}"
    printf '%b\n' "  ${wht}1. Sub-second monitoring execution as system user:${off}"
    printf '%b\n\n' "     su - rmateos -c \"$0 ${mag}--login-path=proxysql_admin${off} ${grn}-r 0.5${off}\""
    printf '%b\n\n' "${cyn}=================================================================================${off}"
}

usage() {
    local status=${1:-1}
    usage_text
    exit "$status"
}

print_error() {
    printf '%b\n' "${red}Error: $1${off}" >&2
}

require_option_value() {
    local option=$1
    local value=$2

    if [[ -z "$value" ]]; then
        print_error "Option $option requires a value."
        return 1
    fi
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --login-path=*) LOGIN_PATH="${1#*=}" ;;
            --login-path) require_option_value "$1" "${2-}"; LOGIN_PATH=$2; shift ;;
            -r|--refresh-time) require_option_value "$1" "${2-}"; REFRESH_TIME=$2; shift ;;
            --refresh-time=*) REFRESH_TIME="${1#*=}" ;;
            -u|--user-filter) require_option_value "$1" "${2-}"; USER_FILTER=$2; shift ;;
            --user-filter=*) USER_FILTER="${1#*=}" ;;
            -t|--threshold) require_option_value "$1" "${2-}"; THRESHOLD=$2; shift ;;
            --threshold=*) THRESHOLD="${1#*=}" ;;
            -o|--output-file) require_option_value "$1" "${2-}"; OUTPUT_FILE=$2; shift ;;
            --output-file=*) OUTPUT_FILE="${1#*=}" ;;
            -h|--help) usage 0 ;;
            *) print_error "Unknown parameter: $1"; usage 1 ;;
        esac
        shift
    done
}

validate_arguments() {
    if [[ -z "$LOGIN_PATH" ]]; then
        print_error "The --login-path parameter is mandatory."
        usage 1
    fi
    if ! is_positive_refresh "$REFRESH_TIME"; then
        print_error "Refresh time must be an integer or a float (e.g., 0.5)."
        return 1
    fi
    if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]]; then
        print_error "Connection threshold must be a non-negative integer."
        return 1
    fi
}

initialize_monitor() {
    if ! start_mysql_session || ! execute_query "SELECT @@version;"; then
        printf '%b\n' "${red}Critical Error: Could not connect to ProxySQL using login-path '$LOGIN_PATH'.${off}" >&2
        return 1
    fi
    PROXY_VERSION=$QUERY_RESULT
    if [[ -z "$PROXY_VERSION" ]]; then
        LAST_DB_ERROR="ProxySQL returned an empty version"
        printf '%b\n' "${red}Critical Error: ProxySQL returned an empty version.${off}" >&2
        return 1
    fi

    PROXY_HOSTNAME=$(mysql_config_editor print --login-path="$LOGIN_PATH" 2>/dev/null |
        awk -F= 'tolower($1) ~ /host/ { gsub(/[ "]/, "", $2); print $2; exit }' || true)
    if [[ -z "$PROXY_HOSTNAME" ]]; then
        if execute_query "SELECT @@hostname;" && [[ -n "$QUERY_RESULT" ]]; then
            PROXY_HOSTNAME=$QUERY_RESULT
        else
            PROXY_HOSTNAME="Unknown"
        fi
    fi
}

# ==============================================================================
# Persistent MySQL Transport
# ==============================================================================
mysql_session_alive() {
    [[ -n "${MYSQL_PID:-}" ]] &&
        [[ "$MYSQL_PID" =~ ^[0-9]+$ ]] &&
        kill -0 "$MYSQL_PID" 2>/dev/null
}

stop_mysql_session() {
    if [[ -n "${MYSQL_INPUT_FD:-}" ]]; then
        exec 7>&- || true
        MYSQL_INPUT_FD=""
    fi
    if [[ -n "${MYSQL_OUTPUT_FD:-}" ]]; then
        exec 8<&- || true
        MYSQL_OUTPUT_FD=""
    fi
    if [[ -n "${MYSQL_PID:-}" ]] && [[ "$MYSQL_PID" =~ ^[0-9]+$ ]]; then
        if mysql_session_alive; then
            kill "$MYSQL_PID" 2>/dev/null || true
        fi
        wait "$MYSQL_PID" 2>/dev/null || true
    fi
    MYSQL_PID=""

    case "${MYSQL_SESSION_DIR:-}" in
        "${TMPDIR:-/tmp}"/proxysql-monitor.*)
            rm -f \
                "$MYSQL_SESSION_DIR/input" \
                "$MYSQL_SESSION_DIR/output" \
                "$MYSQL_SESSION_DIR/mysql.stderr"
            rmdir "$MYSQL_SESSION_DIR" 2>/dev/null || true
            ;;
    esac
    MYSQL_SESSION_DIR=""
    MYSQL_INPUT_PIPE=""
    MYSQL_OUTPUT_PIPE=""
    MYSQL_ERROR_FILE=""
}

start_mysql_session() {
    stop_mysql_session

    MYSQL_SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxysql-monitor.XXXXXX") ||
        return 1
    MYSQL_INPUT_PIPE="$MYSQL_SESSION_DIR/input"
    MYSQL_OUTPUT_PIPE="$MYSQL_SESSION_DIR/output"
    MYSQL_ERROR_FILE="$MYSQL_SESSION_DIR/mysql.stderr"

    if ! mkfifo "$MYSQL_INPUT_PIPE" "$MYSQL_OUTPUT_PIPE"; then
        stop_mysql_session
        return 1
    fi

    "$MYSQL_BIN" "--login-path=$LOGIN_PATH" --batch --raw \
        --skip-column-names --unbuffered --force \
        < "$MYSQL_INPUT_PIPE" > "$MYSQL_OUTPUT_PIPE" 2> "$MYSQL_ERROR_FILE" &
    MYSQL_PID=$!

    exec 7> "$MYSQL_INPUT_PIPE"
    MYSQL_INPUT_FD=7
    exec 8< "$MYSQL_OUTPUT_PIPE"
    MYSQL_OUTPUT_FD=8
    MYSQL_REQUEST_SEQUENCE=0

    if ! mysql_session_alive; then
        LAST_DB_ERROR="Unable to start the ProxySQL admin session"
        stop_mysql_session
        return 1
    fi
}

execute_query() {
    local sql=$1
    local line=""
    local result=""
    local begin_marker=""
    local end_marker=""
    local collecting=false

    QUERY_RESULT=""
    if ! mysql_session_alive; then
        LAST_DB_ERROR="ProxySQL admin session is not running"
        return 1
    fi

    MYSQL_REQUEST_SEQUENCE=$((MYSQL_REQUEST_SEQUENCE + 1))
    begin_marker="__PXMON_BEGIN_${$}_${MYSQL_REQUEST_SEQUENCE}__"
    end_marker="__PXMON_END_${$}_${MYSQL_REQUEST_SEQUENCE}__"

    if ! printf "SELECT '%s';\n%s\nSELECT '%s';\n" \
        "$begin_marker" "$sql" "$end_marker" >&7; then
        LAST_DB_ERROR="Unable to write to the ProxySQL admin session"
        return 1
    fi

    while IFS= read -r -t "$QUERY_TIMEOUT" -u 8 line; do
        if [[ "$line" == "$begin_marker" ]]; then
            collecting=true
        elif [[ "$line" == "$end_marker" ]]; then
            QUERY_RESULT=$result
            LAST_DB_ERROR=""
            return 0
        elif [[ "$collecting" == true ]]; then
            if [[ -n "$result" ]]; then
                result="${result}"$'\n'"${line}"
            else
                result=$line
            fi
        fi
    done

    LAST_DB_ERROR="Timed out waiting for ProxySQL response"
    return 1
}

execute_query_with_retry() {
    local sql=$1

    if execute_query "$sql"; then
        return 0
    fi

    stop_mysql_session
    if ! start_mysql_session; then
        LAST_DB_ERROR="Unable to reconnect to ProxySQL admin"
        return 1
    fi
    execute_query "$sql"
}

# ==============================================================================
# AWK Scripts Definition
# ==============================================================================

AWK_SCRIPT_CONN='
BEGIN { FS="\t"; reading_current = 0; total_conn = 0; total_diff = 0; if (filter != "") gsub(",", "|", filter); }
$0 == "__PXMON_CURRENT__" { reading_current = 1; next }
!reading_current { if (NF > 0) prev[$1"\t"$2"\t"$3"\t"$4] = $5; next }
{
    if (NF > 0) {
        if (filter != "" && $1 !~ "(" filter ")") next;
        key = $1"\t"$2"\t"$3"\t"$4; curr_val = $5; prev_val = prev[key] ? prev[key] : curr_val; diff = curr_val - prev_val
        total_conn += curr_val; total_diff += diff;
        
        if (diff > 0) diff_str = color_up "+" diff color_off
        else if (diff < 0) diff_str = color_down diff color_off
        else diff_str = color_st "0" color_off
        
        row_color = color_st; user_bld = "";
        if (threshold > 0 && curr_val >= threshold) { row_color = color_alert; user_bld = bld; }
        
        usr = substr($1, 1, 20); cli = substr($2, 1, 15); srv = substr($3, 1, 28); sch = substr($4, 1, 20)
        printf "%s%s%-20s%s | %-15s | %-28s | %-20s | %s%-10s%s | %s\n", row_color, user_bld, usr, color_off, cli, srv, sch, bld, curr_val, color_off, diff_str
    }
}
END {
    if (total_conn > 0) {
        if (total_diff > 0) diff_str_tot = color_up "+" total_diff color_off
        else if (total_diff < 0) diff_str_tot = color_down total_diff color_off
        else diff_str_tot = color_st "0" color_off
        printf "%s%-20s | %-15s | %-28s | %-20s | %-10s | %s%s\n", bld color_info, "GLOBAL TOTALS", "", "", "", total_conn, diff_str_tot, color_off
    }
}'

AWK_SCRIPT_QUERY='
BEGIN { FS="\t"; if (filter != "") gsub(",", "|", filter); }
{
    if (NF > 0) {
        if (filter != "" && $3 !~ "(" filter ")") next;
        time_ms_val = $6
        if (time_ms_val > 1000) time_color = color_alert
        else if (time_ms_val > 500) time_color = color_warn
        else time_color = color_st
        
        query = $7; 
        gsub(/\\[nrt]/, " ", query); 
        gsub(/[\r\n\t]+/, " ", query);
        sub(/^[ \t]+/, "", query); 
        
        psid = substr($1, 1, 8); hg = substr($2, 1, 4); usr = substr($3, 1, 15); cli = substr($4, 1, 15); backend = substr($5, 1, 28)
        printf "%-8s | %-4s | %-15s | %-15s | %-28s | %s%s%-9s%s | %s%s%s\n", psid, hg, usr, cli, backend, bld, time_color, time_ms_val"ms", color_off, color_info, query, color_off
    }
}'

AWK_SCRIPT_DIGEST='
BEGIN { FS="\t"; }
{
    if (NF > 0) {
        digest = substr($1, 1, 18); count = $2; sum_t = $3; min_t = $4; max_t = $5;
        
        q_text = $6; 
        gsub(/\\[nrt]/, " ", q_text); 
        gsub(/[\r\n\t]+/, " ", q_text);
        sub(/^[ \t]+/, "", q_text);
        
        max_q_len = term_cols - 75; if (max_q_len < 50) max_q_len = 50;
        if (length(q_text) > max_q_len) q_text = substr(q_text, 1, max_q_len - 3) "...";
        
        printf "%-18s | %-10s | %-10s | %-10s | %-10s | %s%s%s\n", digest, count, sum_t"ms", min_t"ms", max_t"ms", color_info, q_text, color_off
    }
}'

AWK_SCRIPT_BACKEND='
BEGIN { FS="\t"; section = "" }
$0 == "__PXMON_POOL__" { section = "P"; next }
$0 == "__PXMON_PING__" { section = "G"; next }
{
    if (NF > 0 && section == "P") {
        status_color = ($3 == "ONLINE") ? color_ok : color_err;
        hg = substr($1, 1, 10); bhost = substr($2, 1, 35); status_txt = substr($3, 1, 15)
        printf "P\t%-10s | %-35s | %s%-15s%s | %-11s | %-11s | %-11s | %s\n", hg, bhost, status_color, status_txt, color_off, $4, $5, $6, $7
    } else if (NF > 0 && section == "G") {
        ping_err = ($4 == "NULL" || $4 != "") ? color_err $4 color_off : color_ok "None" color_off
        hostname = substr($1, 1, 35); last_ping = substr($2, 1, 25); success = substr($3"us", 1, 15)
        printf "G\t%-35s | %-25s | %-15s | %s\n", hostname, last_ping, success, ping_err
    }
}'

format_conn_data() {
    local previous=$1
    local current=$2
    local input="${previous}"$'\n__PXMON_CURRENT__\n'"${current}"

    FORMATTED_OUTPUT=$(awk \
        -v filter="$USER_FILTER" \
        -v threshold="$THRESHOLD" \
        -v color_alert="$red" \
        -v color_up="$red" \
        -v color_down="$grn" \
        -v color_st="$wht" \
        -v color_info="$blu" \
        -v color_off="$off" \
        -v bld="$bld" \
        "$AWK_SCRIPT_CONN" <<< "$input")
}

format_query_data() {
    local data=$1

    FORMATTED_OUTPUT=$(awk \
        -v filter="$USER_FILTER" \
        -v color_alert="$red" \
        -v color_warn="$yel" \
        -v color_st="$wht" \
        -v color_info="$cyn" \
        -v color_off="$off" \
        -v bld="$bld" \
        "$AWK_SCRIPT_QUERY" <<< "$data")
}

format_digest_data() {
    local data=$1

    FORMATTED_OUTPUT=$(awk \
        -v term_cols="$TERM_WIDTH" \
        -v color_info="$mag" \
        -v color_off="$off" \
        -v bld="$bld" \
        "$AWK_SCRIPT_DIGEST" <<< "$data")
}

format_backend_data() {
    local data=$1
    local formatted=""
    local section=""
    local line=""

    F_POOL=""
    F_PING=""
    formatted=$(awk \
        -v color_ok="$grn" \
        -v color_err="$red" \
        -v color_off="$off" \
        "$AWK_SCRIPT_BACKEND" <<< "$data")

    while IFS=$'\t' read -r section line; do
        case "$section" in
            P)
                F_POOL="${F_POOL}${F_POOL:+$'\n'}${line}"
                ;;
            G)
                F_PING="${F_PING}${F_PING:+$'\n'}${line}"
                ;;
        esac
    done <<< "$formatted"
}

sample_current_view() {
    local query=""
    local current_data=""

    case "$VIEW_MODE" in
        CONN)
            if [[ "$SORT_MODE" == "CONN" ]]; then
                ORDER_CLAUSE="ORDER BY COUNT(*) DESC"
            else
                ORDER_CLAUSE="ORDER BY user ASC"
            fi
            query="SELECT user, cli_host, COALESCE(srv_host, 'N/A'), COALESCE(db, 'N/A'), COUNT(*)
                   FROM stats.stats_mysql_processlist
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
                   GROUP BY user, cli_host, srv_host, db ${ORDER_CLAUSE};"
            ;;
        QUERY)
            query="SELECT SessionID, hostgroup, user, cli_host, COALESCE(srv_host, 'Pending'), time_ms, info
                   FROM stats.stats_mysql_processlist
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
                     AND info IS NOT NULL AND info != ''
                   ORDER BY time_ms DESC;"
            ;;
        DIGEST)
            query="SELECT digest, count_star, sum_time, min_time, max_time, digest_text
                   FROM stats.stats_mysql_query_digest
                   ORDER BY sum_time DESC LIMIT 15;"
            ;;
        BACKEND)
            query="SELECT '__PXMON_POOL__';
                   SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
                   FROM stats.stats_mysql_connection_pool
                   ORDER BY hostgroup, srv_host;
                   SELECT '__PXMON_PING__';
                   SELECT hostname, from_unixtime(time_start_us/1000/1000), ping_success_time_us, ping_error
                   FROM monitor.mysql_server_ping_log
                   ORDER BY time_start_us DESC LIMIT 8;"
            ;;
    esac

    if ! execute_query_with_retry "$query"; then
        LAST_SAMPLE_STALE=true
        return 1
    fi

    current_data=$QUERY_RESULT
    LAST_SAMPLE_STALE=false
    case "$VIEW_MODE" in
        CONN)
            format_conn_data "$PREV_DATA" "$current_data"
            PREV_DATA=$current_data
            ;;
        QUERY)
            format_query_data "$current_data"
            ;;
        DIGEST)
            format_digest_data "$current_data"
            ;;
        BACKEND)
            format_backend_data "$current_data"
            ;;
    esac
}

# ==============================================================================
# Terminal, Rendering, and Interaction
# ==============================================================================
mark_terminal_geometry_dirty() {
    TERM_GEOMETRY_DIRTY=true
}

refresh_terminal_geometry() {
    local spaces=""

    if [[ "$TERM_GEOMETRY_DIRTY" != true ]]; then
        return 0
    fi
    if [[ -t 1 ]]; then
        TERM_WIDTH=$(tput cols 2>/dev/null || printf '130')
    fi
    [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]] || TERM_WIDTH=130
    [[ "$TERM_WIDTH" -ge 110 ]] || TERM_WIDTH=130
    printf -v spaces '%*s' "$TERM_WIDTH" ''
    SEP_LINE=${spaces// /=}
    SEP_THIN=${spaces// /-}
    TERM_GEOMETRY_DIRTY=false
}

refresh_timestamp() {
    if [[ "$TIMESTAMP_SECOND" != "$SECONDS" ]]; then
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        TIMESTAMP_SECOND=$SECONDS
    fi
}

is_positive_refresh() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
        [[ ! "$1" =~ ^0+(\.0+)?$ ]]
}

render_screen() {
    local mode_label=""
    local pause_label=""
    local stale_label=""
    local filters=""

    printf '\033[H\033[2J'
    printf '%b\n' "${cyn}${SEP_LINE}${off}"

    case "$VIEW_MODE" in
        CONN)
            mode_label="${blu}CONNECTIONS POOL${off} (Sort: $SORT_MODE)"
            ;;
        QUERY)
            mode_label="${red}ACTIVE QUERIES IN FLIGHT${off}"
            ;;
        DIGEST)
            mode_label="${mag}QUERY DIGEST (Top 15 by sum_time)${off}"
            ;;
        BACKEND)
            mode_label="${yel}BACKEND HEALTH & PING${off}"
            ;;
    esac

    if [[ "$PAUSED" == true ]]; then
        pause_label="${bld}${blk}${red} [PAUSED] ${off}"
    fi
    if [[ "$LAST_SAMPLE_STALE" == true ]]; then
        stale_label="${bld}${yel} [STALE: ${LAST_DB_ERROR:-ProxySQL unavailable}] ${off}"
    fi

    printf '%b\n' "${bld} ProxySQL Monitor${off} | Server: ${cyn}${bld}$PROXY_HOSTNAME${off} | Mode: $mode_label | Date: ${wht}$TIMESTAMP${off} | Refresh: ${mag}${REFRESH_TIME}s${off}${pause_label}${stale_label}"

    if [[ -n "$USER_FILTER" ]]; then
        filters=" ${bld}Filter:${off} ${grn}$USER_FILTER${off}"
    fi
    if [[ "$THRESHOLD" -gt 0 ]]; then
        filters="$filters | ${bld}Threshold:${off} ${red}>=$THRESHOLD conn${off}"
    fi
    if [[ -n "$filters" ]]; then
        printf '%b\n' "$filters"
    fi
    printf '%b\n' "${cyn}${SEP_LINE}${off}"

    case "$VIEW_MODE" in
        CONN)
            printf "${cyn}${bld}%-20s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-28s${off} | ${cyn}${bld}%-20s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off}\n" \
                "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONN" "DELTA"
            printf '%b\n' "${wht}${SEP_THIN}${off}"
            if [[ -z "$FORMATTED_OUTPUT" ]]; then
                printf '%b\n' "${wht}No active data to display.${off}"
            else
                printf '%b\n' "$FORMATTED_OUTPUT"
            fi
            ;;
        QUERY)
            printf "${cyn}${bld}%-8s${off} | ${cyn}${bld}%-4s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-28s${off} | ${cyn}${bld}%-9s${off} | ${cyn}${bld}%s${off}\n" \
                "PSID" "HG" "USER" "SOURCE" "BACKEND" "TIME" "ACTIVE QUERY"
            printf '%b\n' "${wht}${SEP_THIN}${off}"
            if [[ -z "$FORMATTED_OUTPUT" ]]; then
                printf '%b\n' "${wht}No active data to display.${off}"
            else
                printf '%b\n' "$FORMATTED_OUTPUT"
            fi
            ;;
        DIGEST)
            printf "${cyn}${bld}%-18s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%s${off}\n" \
                "DIGEST" "COUNT" "SUM_TIME" "MIN_TIME" "MAX_TIME" "QUERY TEXT"
            printf '%b\n' "${wht}${SEP_THIN}${off}"
            if [[ -z "$FORMATTED_OUTPUT" ]]; then
                printf '%b\n' "${wht}No active data to display.${off}"
            else
                printf '%b\n' "$FORMATTED_OUTPUT"
            fi
            ;;
        BACKEND)
            printf '%b\n' "${blu}${bld} MySQL Connection Pool (stats_mysql_connection_pool) ${off}"
            printf "${cyn}${bld}%-10s${off} | ${cyn}${bld}%-35s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%s${off}\n" \
                "HOSTGROUP" "BACKEND HOST" "STATUS" "CONN USED" "CONN FREE" "CONN OK" "CONN ERR"
            printf '%b\n' "${wht}${SEP_THIN}${off}"
            if [[ -z "$F_POOL" ]]; then
                printf '%s\n' "No pool data."
            else
                printf '%b\n' "$F_POOL"
            fi
            printf '\n%b\n' "${blu}${bld} Server Ping Log (mysql_server_ping_log) ${off}"
            printf "${cyn}${bld}%-35s${off} | ${cyn}${bld}%-25s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%s${off}\n" \
                "HOSTNAME" "LAST PING DATETIME" "SUCCESS (us)" "PING ERROR"
            printf '%b\n' "${wht}${SEP_THIN}${off}"
            if [[ -z "$F_PING" ]]; then
                printf '%s\n' "No ping data."
            else
                printf '%b\n' "$F_PING"
            fi
            ;;
    esac

    printf '%b\n' "${wht}${SEP_THIN}${off}"
}

log_current_view() {
    local has_data=false

    if [[ "$LAST_SAMPLE_STALE" == true ]]; then
        return 0
    fi

    if [[ -n "$OUTPUT_FILE" ]]; then
        if [[ "$VIEW_MODE" == "CONN" || "$VIEW_MODE" == "QUERY" || "$VIEW_MODE" == "DIGEST" ]]; then
            [[ -n "$FORMATTED_OUTPUT" ]] && has_data=true
        elif [[ "$VIEW_MODE" == "BACKEND" ]]; then
            [[ -n "$F_POOL" || -n "$F_PING" ]] && has_data=true
        fi

        if [[ "$has_data" == true ]]; then
            {
                printf '=== %s | MODE: %s ===\n' "$TIMESTAMP" "$VIEW_MODE"
                case "$VIEW_MODE" in
                    CONN)
                        printf "%-20s | %-15s | %-28s | %-20s | %-10s | %-10s\n" \
                            "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONN" "DELTA"
                        printf '%b\n' "$FORMATTED_OUTPUT"
                        ;;
                    QUERY)
                        printf "%-8s | %-4s | %-15s | %-15s | %-28s | %-9s | %s\n" \
                            "PSID" "HG" "USER" "SOURCE" "BACKEND" "TIME" "ACTIVE QUERY"
                        printf '%b\n' "$FORMATTED_OUTPUT"
                        ;;
                    DIGEST)
                        printf "%-18s | %-10s | %-10s | %-10s | %-10s | %s\n" \
                            "DIGEST" "COUNT" "SUM_TIME" "MIN_TIME" "MAX_TIME" "QUERY TEXT"
                        printf '%b\n' "$FORMATTED_OUTPUT"
                        ;;
                    BACKEND)
                        if [[ -n "$F_POOL" ]]; then
                            printf '%s\n' "--- MySQL Connection Pool ---"
                            printf "%-10s | %-35s | %-15s | %-11s | %-11s | %-11s | %s\n" \
                                "HOSTGROUP" "BACKEND HOST" "STATUS" "CONN USED" "CONN FREE" "CONN OK" "CONN ERR"
                            printf '%b\n' "$F_POOL"
                        fi
                        if [[ -n "$F_PING" ]]; then
                            printf '%s\n' "--- Server Ping Log ---"
                            printf "%-35s | %-25s | %-15s | %s\n" \
                                "HOSTNAME" "LAST PING DATETIME" "SUCCESS (us)" "PING ERROR"
                            printf '%b\n' "$F_PING"
                        fi
                        ;;
                esac
            # Remove CSI codes, charset definitions, Shift-In, and Shift-Out.
            } | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g; s/\033([a-zA-Z]//g; s/\017//g; s/\016//g' >> "$OUTPUT_FILE" || true
        fi
    fi
}

toggle_view() {
    PAUSED=false
    case "$VIEW_MODE" in
        CONN) VIEW_MODE="QUERY" ;;
        QUERY) VIEW_MODE="DIGEST" ;;
        DIGEST) VIEW_MODE="BACKEND" ;;
        BACKEND)
            VIEW_MODE="CONN"
            PREV_DATA=""
            ;;
    esac
}

toggle_sort() {
    PAUSED=false
    [[ "$VIEW_MODE" == "CONN" ]] || return 0
    if [[ "$SORT_MODE" == "CONN" ]]; then
        SORT_MODE="USER"
    else
        SORT_MODE="CONN"
    fi
    PREV_DATA=""
}

toggle_pause() {
    if [[ "$PAUSED" == true ]]; then
        PAUSED=false
    else
        PAUSED=true
    fi
}

handle_key() {
    local key=${1:-}
    local new_rt=""
    local new_th=""

    case "$key" in
        q|Q)
            printf '\n%b\n' "${bld}${red}Exiting monitor...${off}"
            RUNNING=false
            ;;
        v|V)
            toggle_view
            ;;
        r|R)
            printf '\n'
            read -r -p "Enter new refresh time (seconds, e.g. 0.5): " new_rt || true
            if is_positive_refresh "$new_rt"; then
                REFRESH_TIME=$new_rt
            fi
            ;;
        s|S)
            toggle_sort
            ;;
        p|P)
            toggle_pause
            ;;
        u|U)
            printf '\n'
            read -r -p "Enter new user filter (empty to disable): " USER_FILTER || true
            ;;
        t|T)
            printf '\n'
            read -r -p "Enter connection threshold (0 to disable): " new_th || true
            if [[ "$new_th" =~ ^[0-9]+$ ]]; then
                THRESHOLD=$new_th
            fi
            ;;
    esac
}

cleanup() {
    stop_mysql_session
    printf '%b' "${off:-}"
}

monitor_loop() {
    local key=""

    while [[ "$RUNNING" == true ]]; do
        refresh_terminal_geometry
        refresh_timestamp
        if [[ "$PAUSED" == false ]]; then
            sample_current_view || true
        fi
        render_screen
        log_current_view

        printf '\n%b\n' "${bld}Interactive Options:${off}"
        printf '%b\n' " [${mag}v${off}] ${blu}Toggle View${off} (Conn/Query/Digest/Backend) | [${mag}r${off}] ${grn}Refresh${off} | [${mag}s${off}] ${grn}Sort${off} | [${mag}p${off}] ${yel}Pause${off} | [${mag}u${off}] ${grn}Filter${off} | [${mag}t${off}] ${red}Threshold${off} | [${mag}q${off}] ${red}Quit${off}"

        key=""
        read -r -t "$REFRESH_TIME" -n 1 -s key || true
        handle_key "$key"
    done
}

main() {
    initialize_defaults
    initialize_colors
    parse_arguments "$@"
    validate_arguments
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap mark_terminal_geometry_dirty WINCH
    initialize_monitor
    monitor_loop
}

initialize_defaults
initialize_colors

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
