#!/opt/homebrew/bin/bash

#!/bin/bash

# ==============================================================================
# Color configuration for terminal output
# ==============================================================================
red='\033[0;31m'
grn='\033[0;32m'
yel='\033[0;33m'
mag='\033[0;35m'
cyn='\033[0;36m'
off='\033[0m'

# ==============================================================================
# Default Variables
# ==============================================================================
DELAY=5
LOGIN_PATH=""
FILTER_USER=""
FILTER_DB=""
FILTER_HOST=""
LOGGING_ENABLED=false
LOG_FILE=""
SCRIPT_NAME=$(basename "$0")

# ==============================================================================
# Usage / Help Function
# ==============================================================================
usage() {
    echo -e "${yel}Usage: $0 -l <login-path> [-t <delay>] [-u <user>] [-d <database>] [-h <host>] [-o]${off}"
    echo -e "  -l  MySQL login-path (Required)"
    echo -e "  -t  Delay in seconds (Default: 5)"
    echo -e "  -u  Filter by User"
    echo -e "  -d  Filter by Database schema"
    echo -e "  -h  Filter by Host IP/Name"
    echo -e "  -o  Enable output logging to file from start"
    exit 1
}

# ==============================================================================
# Parameter Parsing
# ==============================================================================
while getopts "l:t:u:d:h:o" opt; do
    case ${opt} in
        l ) LOGIN_PATH="$OPTARG" ;;
        t ) DELAY="$OPTARG" ;;
        u ) FILTER_USER="$OPTARG" ;;
        d ) FILTER_DB="$OPTARG" ;;
        h ) FILTER_HOST="$OPTARG" ;;
        o ) LOGGING_ENABLED=true ;;
        \? ) usage ;;
    esac
done

if [[ -z "$LOGIN_PATH" ]]; then
    echo -e "${red}[ERROR] Missing connection parameter (-l login-path).${off}\n"
    usage
fi

if ! [[ "$DELAY" =~ ^[0-9]+$ ]] || [ "$DELAY" -eq 0 ]; then
    echo -e "${red}[ERROR] The wait time ('$DELAY') must be a valid positive integer.${off}"
    exit 1
fi

MYSQLBIN=$(command -v mysql)
if [[ -z "$MYSQLBIN" ]]; then
    echo -e "${red}[ERROR] MySQL binary not found in the system.${off}"
    exit 1
fi

if [[ "$LOGGING_ENABLED" == true ]]; then
    LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"
fi

# ==============================================================================
# Terminal Management & Cleanup
# ==============================================================================
tput civis # Hide cursor

# Archivo temporal solo para el log plano (sin colores)
PLAIN_FILE=$(mktemp /tmp/mysql_monitor_plain.XXXXXX)

trap 'tput cvvis; rm -f "$PLAIN_FILE"; clear; echo -e "\n${yel}Monitoring finished.${off}"; exit 0' SIGINT SIGTERM

EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"
#EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','rmateos','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"

# ==============================================================================
# Interactive Monitoring Loop
# ==============================================================================
while true; do
    WHERE_CLAUSE="user NOT IN (${EXCLUDED_USERS})"
    
    if [[ -n "$FILTER_USER" ]]; then
        WHERE_CLAUSE="${WHERE_CLAUSE} AND USER = '${FILTER_USER}'"
    fi
    if [[ -n "$FILTER_DB" ]]; then
        WHERE_CLAUSE="${WHERE_CLAUSE} AND DB = '${FILTER_DB}'"
    fi
    if [[ -n "$FILTER_HOST" ]]; then
        WHERE_CLAUSE="${WHERE_CLAUSE} AND HOST LIKE '%${FILTER_HOST}%'"
    fi

    # Raw TSV output para procesar fácilmente
    MAIN_QUERY="SELECT USER, DB, substring_index(substring_index(HOST,':',1),'.',4) AS HH, count(*) AS total FROM information_schema.PROCESSLIST WHERE ${WHERE_CLAUSE} GROUP BY USER, DB, HH ORDER BY total DESC, USER, DB, HH DESC;"
    TOTAL_QUERY="SELECT count(*) FROM information_schema.PROCESSLIST WHERE ${WHERE_CLAUSE};"

    MAIN_DATA=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -e "$MAIN_QUERY" 2>&1)
    TOTAL_CONNECTIONS=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "$TOTAL_QUERY" 2>&1)
    CURRENT_TIME=$(date +'%Y-%m-%d %H:%M:%S')

    # 3. Process Data: Strict width truncation and alignment (No DIFF column)
    COLORIZED_OUT=$(echo "$MAIN_DATA" | awk -v plain_file="$PLAIN_FILE" '
    BEGIN {
        FS="\t"
        OFS="\t"
        split("\033[32m \033[33m \033[34m \033[35m \033[36m \033[91m \033[92m \033[93m \033[94m \033[95m \033[96m", colors, " ")
        c_idx = 1
        reset = "\033[0m"
        
        # STRICT FORMATTING: 4 columns only
        fmt = "%-25.25s | %-25.25s | %-18.18s | %-7.7s"
        
        header = sprintf(fmt, "USER", "DB", "HOST (HH)", "TOTAL")
        sep    = "--------------------------+---------------------------+--------------------+--------"
        
        print header
        print sep
        print header > plain_file
        print sep > plain_file
    }
    NR>1 {
        # Strip carriage returns (\r) that MySQL might output and that break terminal alignment
        gsub(/\r/, "", $0)
        
        u=$1; d=$2; h=$3; t=$4
        
        # Replace empty values with a dash to keep it clean
        if (d == "" || d == "NULL") d = "-"
        if (h == "" || h == "NULL") h = "-"
        
        if (d != "-") {
            if (!(d in cmap)) {
                cmap[d] = colors[c_idx]
                c_idx = (c_idx % 11) + 1
            }
            c = cmap[d]
        } else {
            c = reset
        }
        
        line = sprintf(fmt, u, d, h, t)
        print c line reset      
        print line > plain_file 
    }')
    
    # 4. Clear screen and print Header
    clear 
    echo -e "${cyn}=====================================================================================${off}"
    echo -e "MySQL Active Monitor  |  Host: ${mag}$(hostname)${off}  |  Time: ${grn}${CURRENT_TIME}${off}  |  Delay: ${DELAY}s"
    
    if [[ "$LOGGING_ENABLED" == true ]]; then
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${grn}[LOG ON: $LOG_FILE]${off}"
    else
        echo -e "${yel}Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}  |  ${red}[LOG OFF]${off}"
    fi
    echo -e "Total Filtered Connections: ${grn}${TOTAL_CONNECTIONS}${off}"
    echo -e "${cyn}=====================================================================================${off}"

    # 5. Print the beautifully colorized and perfectly aligned Table
    echo -e "$COLORIZED_OUT"

    # 6. Write to Log file (Plain text)
    if [[ "$LOGGING_ENABLED" == true ]]; then
        {
            echo "====================================================================================="
            echo "Time: ${CURRENT_TIME} | Host: $(hostname)"
            echo "Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}"
            echo "Total Filtered Connections: ${TOTAL_CONNECTIONS}"
            echo "====================================================================================="
            cat "$PLAIN_FILE"
            echo -e "\n"
        } >> "$LOG_FILE"
    fi

    # 7. Print Interactive Menu Footer
    echo -e "\n${cyn}Interactive Commands:${off}"
    echo -e "  [u] User filter  |  [d] DB filter   |  [h] Host filter   |  [c] Clear filters"
    echo -e "  [t] Change delay |  [l] Toggle Log  |  [r] Refresh now   |  [q] Quit"
    echo -n "Press key: "

    # 8. Wait for user input (Variable limpiada para evitar loops infinitos del filtro)
    key=""
    read -t "$DELAY" -n 1 -s key

    # 9. Handle Interactive Keystrokes
    case "$key" in
        q|Q)
            tput cvvis
            clear
            echo -e "${yel}Exiting monitor...${off}"
            if [[ "$LOGGING_ENABLED" == true ]]; then
                echo -e "Log saved in: ${grn}$LOG_FILE${off}"
            fi
            exit 0
            ;;
        u|U)
            tput cvvis
            echo -e "\n"
            read -p "Enter exact USER to filter: " FILTER_USER
            tput civis
            ;;
        d|D)
            tput cvvis
            echo -e "\n"
            read -p "Enter exact DB to filter: " FILTER_DB
            tput civis
            ;;
        h|H)
            tput cvvis
            echo -e "\n"
            read -p "Enter partial HOST to filter: " FILTER_HOST
            tput civis
            ;;
        t|T)
            tput cvvis
            echo -e "\n"
            read -p "Enter new delay in seconds: " NEW_DELAY
            if [[ "$NEW_DELAY" =~ ^[0-9]+$ ]] && [ "$NEW_DELAY" -gt 0 ]; then
                DELAY="$NEW_DELAY"
            else
                echo -e "${red}Invalid input. Keeping delay at ${DELAY}s.${off}"
                sleep 1.5
            fi
            tput civis
            ;;
        l|L)
            tput cvvis
            if [[ "$LOGGING_ENABLED" == true ]]; then
                LOGGING_ENABLED=false
                echo -e "\n${yel}Logging disabled.${off}"
            else
                LOGGING_ENABLED=true
                LOG_FILE="${SCRIPT_NAME}_$(date +'%Y%m%d%S').log"
                echo -e "\n${grn}Logging enabled. Writing to: $LOG_FILE${off}"
            fi
            sleep 1.5
            tput civis
            ;;
        c|C)
            FILTER_USER=""
            FILTER_DB=""
            FILTER_HOST=""
            ;;
        r|R)
            # Refresh inmediato
            ;;
    esac
done
