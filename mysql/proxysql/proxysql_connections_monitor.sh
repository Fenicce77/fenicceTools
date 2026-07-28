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
    if [[ ! "$REFRESH_TIME" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        print_error "Refresh time must be an integer or a float (e.g., 0.5)."
        return 1
    fi
}

initialize_monitor() {
    local mysql_cmd=("$MYSQL_BIN" "--login-path=$LOGIN_PATH" -BN)

    PROXY_VERSION=$("${mysql_cmd[@]}" -e "SELECT @@version;" 2>/dev/null || true)
    if [[ -z "$PROXY_VERSION" ]]; then
        printf '%b\n' "${red}Critical Error: Could not connect to ProxySQL using login-path '$LOGIN_PATH'.${off}" >&2
        return 1
    fi

    PROXY_HOSTNAME=$(mysql_config_editor print --login-path="$LOGIN_PATH" 2>/dev/null |
        awk -F= 'tolower($1) ~ /host/ { gsub(/[ "]/, "", $2); print $2; exit }' || true)
    if [[ -z "$PROXY_HOSTNAME" ]]; then
        PROXY_HOSTNAME=$("${mysql_cmd[@]}" -e "SELECT @@hostname;" 2>/dev/null || printf 'Unknown')
    fi
    MYSQL_CMD="${MYSQL_BIN} --login-path=${LOGIN_PATH} -BN"
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
            rm -rf "$MYSQL_SESSION_DIR"
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
BEGIN { FS="\t"; total_conn = 0; total_diff = 0; if (filter != "") gsub(",", "|", filter); }
FNR==NR { if (NF > 0) prev[$1"\t"$2"\t"$3"\t"$4] = $5; next }
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

AWK_SCRIPT_POOL='
BEGIN { FS="\t" }
{
    if (NF > 0) {
        status_color = ($3 == "ONLINE") ? color_ok : color_err;
        hg = substr($1, 1, 10); bhost = substr($2, 1, 35); status_txt = substr($3, 1, 15)
        printf "%-10s | %-35s | %s%-15s%s | %-11s | %-11s | %-11s | %s\n", hg, bhost, status_color, status_txt, color_off, $4, $5, $6, $7
    }
}'

AWK_SCRIPT_PING='
BEGIN { FS="\t" }
{
    if (NF > 0) {
        ping_err = ($4 == "NULL" || $4 != "") ? color_err $4 color_off : color_ok "None" color_off
        hostname = substr($1, 1, 35); last_ping = substr($2, 1, 25); success = substr($3"us", 1, 15)
        printf "%-35s | %-25s | %-15s | %s\n", hostname, last_ping, success, ping_err
    }
}'

# ==============================================================================
# Main Monitoring Loop
# ==============================================================================
monitor_loop() {
    PREV_DATA=""
    clear

    while true; do
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 130)
    [[ -z "$TERM_WIDTH" || "$TERM_WIDTH" -lt 110 ]] && TERM_WIDTH=130
    SEP_LINE=$(printf "%*s" "$TERM_WIDTH" "" | tr " " "=")
    SEP_THIN=$(printf "%*s" "$TERM_WIDTH" "" | tr " " "-")
    
    if [[ "$PAUSED" == false ]]; then
        if [[ "$VIEW_MODE" == "CONN" ]]; then
            ORDER_CLAUSE=$([[ "$SORT_MODE" == "CONN" ]] && echo "ORDER BY COUNT(*) DESC" || echo "ORDER BY user ASC")
            QUERY="SELECT user, cli_host, COALESCE(srv_host, 'N/A'), COALESCE(db, 'N/A'), COUNT(*) 
                   FROM stats.stats_mysql_processlist 
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql') 
                   GROUP BY user, cli_host, srv_host, db $ORDER_CLAUSE;"
            CURR_DATA=$($MYSQL_CMD -e "$QUERY" 2>/dev/null || true)
            FORMATTED_OUTPUT=$(awk -v filter="$USER_FILTER" -v threshold="$THRESHOLD" -v color_alert="$red" -v color_up="$red" -v color_down="$grn" -v color_st="$wht" -v color_info="$blu" -v color_off="$off" -v bld="$bld" "$AWK_SCRIPT_CONN" <(echo "$PREV_DATA") <(echo "$CURR_DATA"))
            PREV_DATA="$CURR_DATA"
            
        elif [[ "$VIEW_MODE" == "QUERY" ]]; then
            QUERY="SELECT SessionID, hostgroup, user, cli_host, COALESCE(srv_host, 'Pending'), time_ms, info 
                   FROM stats.stats_mysql_processlist 
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql') 
                   AND info IS NOT NULL AND info != '' 
                   ORDER BY time_ms DESC;"
            CURR_DATA=$($MYSQL_CMD -e "$QUERY" 2>/dev/null || true)
            FORMATTED_OUTPUT=$(awk -v filter="$USER_FILTER" -v color_alert="$red" -v color_warn="$yel" -v color_st="$wht" -v color_info="$cyn" -v color_off="$off" -v bld="$bld" "$AWK_SCRIPT_QUERY" <(echo "$CURR_DATA"))
            
        elif [[ "$VIEW_MODE" == "DIGEST" ]]; then
            QUERY="SELECT digest, count_star, sum_time, min_time, max_time, digest_text 
                   FROM stats.stats_mysql_query_digest 
                   ORDER BY sum_time DESC LIMIT 15;"
            CURR_DATA=$($MYSQL_CMD -e "$QUERY" 2>/dev/null || true)
            FORMATTED_OUTPUT=$(awk -v term_cols="$TERM_WIDTH" -v color_info="$mag" -v color_off="$off" -v bld="$bld" "$AWK_SCRIPT_DIGEST" <(echo "$CURR_DATA"))
            
        elif [[ "$VIEW_MODE" == "BACKEND" ]]; then
            Q_POOL="SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR FROM stats.stats_mysql_connection_pool ORDER BY hostgroup, srv_host;"
            Q_PING="SELECT hostname, from_unixtime(time_start_us/1000/1000), ping_success_time_us, ping_error FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 8;"
            POOL_DATA=$($MYSQL_CMD -e "$Q_POOL" 2>/dev/null || true)
            PING_DATA=$($MYSQL_CMD -e "$Q_PING" 2>/dev/null || true)
            F_POOL=$(awk -v color_ok="$grn" -v color_err="$red" -v color_off="$off" "$AWK_SCRIPT_POOL" <(echo "$POOL_DATA"))
            F_PING=$(awk -v color_ok="$grn" -v color_err="$red" -v color_off="$off" "$AWK_SCRIPT_PING" <(echo "$PING_DATA"))
        fi
    fi

    # ==============================================================================
    # Render Output
    # ==============================================================================
    clear; echo -e "${cyn}${SEP_LINE}${off}"
    
    if [[ "$VIEW_MODE" == "CONN" ]]; then MODE_LABEL="${blu}CONNECTIONS POOL${off} (Sort: $SORT_MODE)"
    elif [[ "$VIEW_MODE" == "QUERY" ]]; then MODE_LABEL="${red}ACTIVE QUERIES IN FLIGHT${off}"
    elif [[ "$VIEW_MODE" == "DIGEST" ]]; then MODE_LABEL="${mag}QUERY DIGEST (Top 15 by sum_time)${off}"
    else MODE_LABEL="${yel}BACKEND HEALTH & PING${off}"; fi
    
    PAUSE_LBL=$([[ "$PAUSED" == true ]] && echo "${bld}${blk}${red} [PAUSED] ${off}" || echo "")
    echo -e "${bld} ProxySQL Monitor${off} | Server: ${cyn}${bld}$PROXY_HOSTNAME${off} | Mode: $MODE_LABEL | Date: ${wht}$TIMESTAMP${off} | Refresh: ${mag}${REFRESH_TIME}s${off}${PAUSE_LBL}"
    
    FILTERS=""
    [[ -n "$USER_FILTER" ]] && FILTERS=" ${bld}Filter:${off} ${grn}$USER_FILTER${off}"
    [[ "$THRESHOLD" -gt 0 ]] && FILTERS="$FILTERS | ${bld}Threshold:${off} ${red}>=$THRESHOLD conn${off}"
    [[ -n "$FILTERS" ]] && echo -e "$FILTERS"
    echo -e "${cyn}${SEP_LINE}${off}"
    
    if [[ "$VIEW_MODE" == "CONN" ]]; then
        printf "${cyn}${bld}%-20s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-28s${off} | ${cyn}${bld}%-20s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off}\n" "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONN" "DELTA"
        echo -e "${wht}${SEP_THIN}${off}"
        [[ -z "$FORMATTED_OUTPUT" ]] && echo -e "${wht}No active data to display.${off}" || echo -e "$FORMATTED_OUTPUT"
        
    elif [[ "$VIEW_MODE" == "QUERY" ]]; then
        printf "${cyn}${bld}%-8s${off} | ${cyn}${bld}%-4s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-28s${off} | ${cyn}${bld}%-9s${off} | ${cyn}${bld}%s${off}\n" "PSID" "HG" "USER" "SOURCE" "BACKEND" "TIME" "ACTIVE QUERY"
        echo -e "${wht}${SEP_THIN}${off}"
        [[ -z "$FORMATTED_OUTPUT" ]] && echo -e "${wht}No active data to display.${off}" || echo -e "$FORMATTED_OUTPUT"

    elif [[ "$VIEW_MODE" == "DIGEST" ]]; then
        printf "${cyn}${bld}%-18s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%-10s${off} | ${cyn}${bld}%s${off}\n" "DIGEST" "COUNT" "SUM_TIME" "MIN_TIME" "MAX_TIME" "QUERY TEXT"
        echo -e "${wht}${SEP_THIN}${off}"
        [[ -z "$FORMATTED_OUTPUT" ]] && echo -e "${wht}No active data to display.${off}" || echo -e "$FORMATTED_OUTPUT"
        
    elif [[ "$VIEW_MODE" == "BACKEND" ]]; then
        echo -e "${blu}${bld} MySQL Connection Pool (stats_mysql_connection_pool) ${off}"
        printf "${cyn}${bld}%-10s${off} | ${cyn}${bld}%-35s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%-11s${off} | ${cyn}${bld}%s${off}\n" "HOSTGROUP" "BACKEND HOST" "STATUS" "CONN USED" "CONN FREE" "CONN OK" "CONN ERR"
        echo -e "${wht}${SEP_THIN}${off}"
        [[ -z "$F_POOL" ]] && echo -e "No pool data." || echo -e "$F_POOL"
        echo -e "\n${blu}${bld} Server Ping Log (mysql_server_ping_log) ${off}"
        printf "${cyn}${bld}%-35s${off} | ${cyn}${bld}%-25s${off} | ${cyn}${bld}%-15s${off} | ${cyn}${bld}%s${off}\n" "HOSTNAME" "LAST PING DATETIME" "SUCCESS (us)" "PING ERROR"
        echo -e "${wht}${SEP_THIN}${off}"
        [[ -z "$F_PING" ]] && echo -e "No ping data." || echo -e "$F_PING"
    fi
    echo -e "${wht}${SEP_THIN}${off}"

    # ==============================================================================
    # File Logging (Only if data exists & Clean ANSI/Control Characters)
    # ==============================================================================
    if [[ -n "$OUTPUT_FILE" ]]; then
        HAS_DATA=false
        
        if [[ "$VIEW_MODE" == "CONN" || "$VIEW_MODE" == "QUERY" || "$VIEW_MODE" == "DIGEST" ]]; then
            [[ -n "$FORMATTED_OUTPUT" ]] && HAS_DATA=true
        elif [[ "$VIEW_MODE" == "BACKEND" ]]; then
            [[ -n "$F_POOL" || -n "$F_PING" ]] && HAS_DATA=true
        fi

        if [[ "$HAS_DATA" == true ]]; then
            {
                echo "=== $TIMESTAMP | MODE: $VIEW_MODE ==="
                if [[ "$VIEW_MODE" == "CONN" ]]; then
                    printf "%-20s | %-15s | %-28s | %-20s | %-10s | %-10s\n" "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONN" "DELTA"
                    echo -e "$FORMATTED_OUTPUT"
                elif [[ "$VIEW_MODE" == "QUERY" ]]; then
                    printf "%-8s | %-4s | %-15s | %-15s | %-28s | %-9s | %s\n" "PSID" "HG" "USER" "SOURCE" "BACKEND" "TIME" "ACTIVE QUERY"
                    echo -e "$FORMATTED_OUTPUT"
                elif [[ "$VIEW_MODE" == "DIGEST" ]]; then
                    printf "%-18s | %-10s | %-10s | %-10s | %-10s | %s\n" "DIGEST" "COUNT" "SUM_TIME" "MIN_TIME" "MAX_TIME" "QUERY TEXT"
                    echo -e "$FORMATTED_OUTPUT"
                elif [[ "$VIEW_MODE" == "BACKEND" ]]; then
                    if [[ -n "$F_POOL" ]]; then
                        echo -e "--- MySQL Connection Pool ---\n$(printf "%-10s | %-35s | %-15s | %-11s | %-11s | %-11s | %s\n" "HOSTGROUP" "BACKEND HOST" "STATUS" "CONN USED" "CONN FREE" "CONN OK" "CONN ERR")"
                        echo -e "$F_POOL"
                    fi
                    if [[ -n "$F_PING" ]]; then
                        echo -e "--- Server Ping Log ---\n$(printf "%-35s | %-25s | %-15s | %s\n" "HOSTNAME" "LAST PING DATETIME" "SUCCESS (us)" "PING ERROR")"
                        echo -e "$F_PING"
                    fi
                fi
            # sed regex strictly removes CSI codes, Charset definitions, Shift-In (\017) and Shift-Out (\016)
            } | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g; s/\033([a-zA-Z]//g; s/\017//g; s/\016//g' >> "$OUTPUT_FILE" || true
        fi
    fi

    # ==============================================================================
    # Interactivity
    # ==============================================================================
    echo -e "\n${bld}Interactive Options:${off}"
    echo -e " [${mag}v${off}] ${blu}Toggle View${off} (Conn/Query/Digest/Backend) | [${mag}r${off}] ${grn}Refresh${off} | [${mag}s${off}] ${grn}Sort${off} | [${mag}p${off}] ${yel}Pause${off} | [${mag}u${off}] ${grn}Filter${off} | [${mag}t${off}] ${red}Threshold${off} | [${mag}q${off}] ${red}Quit${off}"
    
    read -t "$REFRESH_TIME" -n 1 -s key || true
    
    case "$key" in
        q|Q) 
            echo -e "\n${bld}${red}Exiting monitor...${off}"; break ;;
        v|V) 
            PAUSED=false
            if [[ "$VIEW_MODE" == "CONN" ]]; then VIEW_MODE="QUERY"
            elif [[ "$VIEW_MODE" == "QUERY" ]]; then VIEW_MODE="DIGEST"
            elif [[ "$VIEW_MODE" == "DIGEST" ]]; then VIEW_MODE="BACKEND"
            else VIEW_MODE="CONN"; PREV_DATA=""; fi ;;
        r|R) 
            echo -e "\n"; read -p "Enter new refresh time (seconds, e.g. 0.5): " new_rt || true
            if [[ "$new_rt" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$new_rt > 0" | bc -l 2>/dev/null || echo 1) )); then
                REFRESH_TIME=$new_rt
            fi ;;
        s|S)
            PAUSED=false; [[ "$VIEW_MODE" == "CONN" ]] && SORT_MODE=$([[ "$SORT_MODE" == "CONN" ]] && echo "USER" || echo "CONN"); PREV_DATA="" ;;
        p|P)
            PAUSED=$([[ "$PAUSED" == true ]] && echo false || echo true) ;;
        u|U) 
            echo -e "\n"; read -p "Enter new user filter (empty to disable): " USER_FILTER || true ;;
        t|T)
            echo -e "\n"; read -p "Enter connection threshold (0 to disable): " new_th || true
            [[ "$new_th" =~ ^[0-9]+$ ]] && THRESHOLD=$new_th ;;
        esac
    done
}

main() {
    initialize_defaults
    initialize_colors
    parse_arguments "$@"
    validate_arguments
    initialize_monitor
    monitor_loop
}

initialize_defaults
initialize_colors

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
