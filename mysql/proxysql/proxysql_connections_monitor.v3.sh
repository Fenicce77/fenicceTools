#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ANSI Colors Configuration
# ==============================================================================
blk=$(tput blink || true)
bld=$(tput bold || true)
red=${bld}$(tput setaf 1 || true)
grn=${bld}$(tput setaf 2 || true)
yel=${bld}$(tput setaf 3 || true)
blu=${bld}$(tput setaf 4 || true)
mag=${bld}$(tput setaf 5 || true)
cyn=${bld}$(tput setaf 6 || true)
wht=${bld}$(tput setaf 7 || true)
off=$(tput sgr0 || true)

# ==============================================================================
# Default Variables & States
# ==============================================================================
LOGIN_PATH=""
REFRESH_TIME=5
USER_FILTER=""
OUTPUT_FILE=""
VIEW_MODE="CONN"     # "CONN", "QUERY", "DIGEST", or "BACKEND"
SORT_MODE="CONN"
THRESHOLD=0
PAUSED=false

# ==============================================================================
# Help Function
# ==============================================================================
usage() {
    clear
    echo -e "${cyn}=================================================================================${off}"
    echo -e "${bld} ProxySQL Ultimate Monitor (DBA Edition) ${off}"
    echo -e "${cyn}=================================================================================${off}"
    echo -e "${blu}Usage:${off} $0 ${mag}--login-path=NAME${off} ${wht}[OPTIONS]${off}\n"
    
    echo -e "${yel}Mandatory Parameters:${off}"
    echo -e "  ${mag}--login-path=NAME${off}      MySQL login-path file to connect to ProxySQL admin.\n"
    
    echo -e "${yel}Optional Parameters:${off}"
    echo -e "  ${grn}-r, --refresh-time=N${off}   Refresh time in seconds. Supports floats e.g., 0.5 (Default: ${bld}5${off})."
    echo -e "  ${grn}-u, --user-filter=STR${off}  Filter by user (string match or comma-separated list)."
    echo -e "  ${grn}-t, --threshold=N${off}      Alert threshold for active connections (Default: 0)."
    echo -e "  ${grn}-o, --output-file=FILE${off} File path to save the continuous output log."
    echo -e "  ${grn}-h, --help${off}             Shows this help and exits.\n"
    
    echo -e "${yel}Use Cases and Examples:${off}"
    echo -e "  ${wht}1. Sub-second monitoring execution as system user:${off}"
    echo -e "     su - rmateos -c \"$0 ${mag}--login-path=proxysql_admin${off} ${grn}-r 0.5${off}\"\n"
    echo -e "${cyn}=================================================================================${off}\n"
    exit 1
}

# ==============================================================================
# Parameter Parsing
# ==============================================================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --login-path=*) LOGIN_PATH="${1#*=}" ;;
        --login-path) LOGIN_PATH="$2"; shift ;;
        -r|--refresh-time) REFRESH_TIME="$2"; shift ;;
        --refresh-time=*) REFRESH_TIME="${1#*=}" ;;
        -u|--user-filter) USER_FILTER="$2" ; shift ;;
        --user-filter=*) USER_FILTER="${1#*=}" ;;
        -t|--threshold) THRESHOLD="$2" ; shift ;;
        --threshold=*) THRESHOLD="${1#*=}" ;;
        -o|--output-file) OUTPUT_FILE="$2"; shift ;;
        --output-file=*) OUTPUT_FILE="${1#*=}" ;;
        -h|--help) usage ;;
        *) echo -e "${red}Error: Unknown parameter: $1${off}"; usage ;;
    esac
    shift || true
done

if [[ -z "$LOGIN_PATH" ]]; then
    echo -e "${red}Error: The --login-path parameter is mandatory.${off}\n"
    usage
fi

if [[ ! "$REFRESH_TIME" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo -e "${red}Error: Refresh time must be an integer or a float (e.g., 0.5).${off}\n"
    exit 1
fi

MYSQL_CMD="mysql --login-path=$LOGIN_PATH -BN"

PROXY_VERSION=$($MYSQL_CMD -e "SELECT @@version;" 2>/dev/null || true)
if [[ -z "$PROXY_VERSION" ]]; then
    echo -e "${red}Critical Error: Could not connect to ProxySQL using login-path '$LOGIN_PATH'.${off}"
    exit 1
fi

PROXY_HOSTNAME=$(mysql_config_editor print --login-path="$LOGIN_PATH" 2>/dev/null | grep -i 'host' | cut -d'=' -f2 | tr -d ' "' || true)
if [[ -z "$PROXY_HOSTNAME" ]]; then
    PROXY_HOSTNAME=$($MYSQL_CMD -e "SELECT @@hostname;" 2>/dev/null || echo "Unknown")
fi

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