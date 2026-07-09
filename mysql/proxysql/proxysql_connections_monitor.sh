#!/usr/bin/env bash

# ==============================================================================
# ANSI Colors Configuration
# ==============================================================================
blk=$(tput blink)
bld=$(tput bold)
red=${bld}$(tput setaf 1)    # Red (Connection increase)
grn=${bld}$(tput setaf 2)    # Green (Connection decrease)
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
cyn=${bld}$(tput setaf 6)    # Cyan (Stable / UI elements)
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Reset

# ==============================================================================
# Default Variables
# ==============================================================================
LOGIN_PATH=""
REFRESH_TIME=5
USER_FILTER=""
OUTPUT_FILE=""

# ==============================================================================
# Help Function
# ==============================================================================
usage() {
    echo -e "${cyn}Usage:${off} $0 --login-path=NAME [OPTIONS]"
    echo ""
    echo -e "${bld}Mandatory Parameters:${off}"
    echo "  --login-path=NAME      MySQL login-path file to connect to ProxySQL admin."
    echo ""
    echo -e "${bld}Optional Parameters:${off}"
    echo "  -r, --refresh-time=N   Refresh time in seconds (Default: 5)."
    echo "  -f, --user-filter=STR  Filter by user (string or comma-separated list e.g., user1,user2)."
    echo "  -o, --output-file=FILE File path to save the output log."
    echo "  -h, --help             Shows this help and exits."
    echo ""
    echo -e "${bld}Usage Example:${off}"
    echo "  $0 --login-path=proxysql_admin -r 2 -f my_app_user -o /tmp/proxy_activity.log"
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
        -f|--user-filter) USER_FILTER="$2" ; shift ;;
        --user-filter=*) USER_FILTER="${1#*=}" ;;
        -o|--output-file) OUTPUT_FILE="$2"; shift ;;
        --output-file=*) OUTPUT_FILE="${1#*=}" ;;
        -h|--help) usage ;;
        *) echo -e "${red}Error: Unknown parameter: $1${off}"; usage ;;
    esac
    shift
done

if [[ -z "$LOGIN_PATH" ]]; then
    echo -e "${red}Error: The --login-path parameter is mandatory.${off}\n"
    usage
fi

# ==============================================================================
# Connection and Version Validation
# ==============================================================================
MYSQL_CMD="mysql --login-path=$LOGIN_PATH -BN"

PROXY_VERSION=$($MYSQL_CMD -e "SELECT @@version;" 2>/dev/null)
if [[ $? -ne 0 || -z "$PROXY_VERSION" ]]; then
    echo -e "${red}Critical Error: Could not connect to ProxySQL using login-path '$LOGIN_PATH'.${off}"
    exit 1
fi

# ==============================================================================
# Main Monitoring Loop
# ==============================================================================
PREV_DATA=""

# Clear initial screen
clear

while true; do
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Query ProxySQL: Grouped by user, source, backend, and schema. 
    # Admin and monitor users are natively excluded.
    QUERY="SELECT user, cli_host, COALESCE(srv_host, 'N/A'), COALESCE(db, 'N/A'), COUNT(*) 
           FROM stats.stats_mysql_processlist 
           WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql') 
           GROUP BY user, cli_host, srv_host, db;"
           
    CURR_DATA=$($MYSQL_CMD -e "$QUERY" 2>/dev/null)

    # AWK processing to calculate delta and format tabular output.
    # Previous and current data are passed as virtual file descriptors.
    FORMATTED_OUTPUT=$(awk -v filter="$USER_FILTER" -v color_up="$red" -v color_down="$grn" -v color_st="$wht" -v color_off="$off" -v bld="$bld" '
    BEGIN { 
        FS="\t"; 
        # Convert commas in the filter to Regex OR format (e.g., user1|user2)
        if (filter != "") gsub(",", "|", filter);
    }
    
    # Read PREV_DATA
    FNR==NR {
        if (NF > 0) prev[$1"\t"$2"\t"$3"\t"$4] = $5;
        next
    }
    
    # Read CURR_DATA
    {
        if (NF > 0) {
            # Apply user filter if it exists
            if (filter != "" && $1 !~ "(" filter ")") next;

            key = $1"\t"$2"\t"$3"\t"$4
            curr_val = $5
            prev_val = prev[key] ? prev[key] : curr_val # If it didn't exist before, initial delta is 0
            diff = curr_val - prev_val
            
            # Delta Colors
            if (diff > 0) {
                diff_str = color_up "+" diff color_off
            } else if (diff < 0) {
                diff_str = color_down diff color_off
            } else {
                diff_str = color_st "0" color_off
            }
            
            # Print formatted row
            printf "%-20s | %-16s | %-20s | %-15s | %-11s | %s\n", $1, $2, $3, $4, bld curr_val color_off, diff_str
        }
    }' <(echo "$PREV_DATA") <(echo "$CURR_DATA"))

    # Update state for the next iteration
    PREV_DATA="$CURR_DATA"

    # ==============================================================================
    # Render Output on Screen
    # ==============================================================================
    clear
    echo -e "${cyn}==================================================================================================${off}"
    echo -e "${bld} ProxySQL Monitor${off} | Version: ${yel}$PROXY_VERSION${off} | Date: ${wht}$TIMESTAMP${off} | Refresh: ${yel}${REFRESH_TIME}s${off}"
    if [[ -n "$USER_FILTER" ]]; then
        echo -e " ${bld}Active Filter:${off} ${blu}$USER_FILTER${off}"
    fi
    echo -e "${cyn}==================================================================================================${off}"
    
    # Headers
    printf "${bld}%-20s | %-16s | %-20s | %-15s | %-11s | %-10s${off}\n" "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONNECTIONS" "DELTA"
    echo -e "--------------------------------------------------------------------------------------------------"
    
    # Data
    if [[ -z "$FORMATTED_OUTPUT" ]]; then
        echo -e "${wht}No active connections to display based on current criteria.${off}"
    else
        echo -e "$FORMATTED_OUTPUT"
    fi
    echo -e "--------------------------------------------------------------------------------------------------"

    # Save to file if configured (stripping ANSI color characters)
    if [[ -n "$OUTPUT_FILE" ]]; then
        {
            echo "=== $TIMESTAMP ==="
            printf "%-20s | %-16s | %-20s | %-15s | %-11s | %-10s\n" "USER" "SOURCE (Cli)" "BACKEND (Srv)" "SCHEMA" "CONNECTIONS" "DELTA"
            echo -e "$FORMATTED_OUTPUT"
        } | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' >> "$OUTPUT_FILE"
    fi

    # ==============================================================================
    # Runtime Interactivity
    # ==============================================================================
    echo -e "\n${cyn}Options:${off} [${wht}q${off}] Quit | [${wht}r${off}] Refresh | [${wht}f${off}] Filter | [${wht}o${off}] Output File"
    
    # Interactive wait based on refresh time
    read -t "$REFRESH_TIME" -n 1 -s key
    case "$key" in
        q|Q) 
            echo -e "\n${blu}Exiting monitor...${off}"
            break 
            ;;
        r|R) 
            echo -e "\n"
            read -p "Enter new refresh time (seconds): " new_rt
            if [[ "$new_rt" =~ ^[0-9]+$ ]] && [ "$new_rt" -gt 0 ]; then
                REFRESH_TIME=$new_rt
            fi
            ;;
        f|F) 
            echo -e "\n"
            read -p "Enter new filter (empty to disable): " USER_FILTER
            ;;
        o|O)
            echo -e "\n"
            read -p "Enter new file path (empty to disable): " OUTPUT_FILE
            ;;
    esac
done