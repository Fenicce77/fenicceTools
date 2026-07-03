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

# ==============================================================================
# Usage / Help Function
# ==============================================================================
usage() {
    echo -e "${yel}Usage: $0 -l <login-path> [-t <delay>] [-u <user>] [-d <database>] [-h <host>]${off}"
    echo -e "  -l  MySQL login-path (Required)"
    echo -e "  -t  Delay in seconds (Default: 5)"
    echo -e "  -u  Filter by User"
    echo -e "  -d  Filter by Database schema"
    echo -e "  -h  Filter by Host IP/Name (allows partial match)"
    echo -e "\n${cyn}Examples:${off}"
    echo -e "  $0 -l prod"
    echo -e "  $0 -l prod -t 10 -u admin_user"
    echo -e "  $0 -l stg -d my_database -h 192.168.1"
    exit 1
}

# ==============================================================================
# Parameter Parsing using getopts
# ==============================================================================
while getopts "l:t:u:d:h:" opt; do
    case ${opt} in
        l ) LOGIN_PATH="$OPTARG" ;;
        t ) DELAY="$OPTARG" ;;
        u ) FILTER_USER="$OPTARG" ;;
        d ) FILTER_DB="$OPTARG" ;;
        h ) FILTER_HOST="$OPTARG" ;;
        \? ) usage ;;
    esac
done

# Validate required parameter
if [[ -z "$LOGIN_PATH" ]]; then
    echo -e "${red}[ERROR] Missing connection parameter (-l login-path).${off}\n"
    usage
fi

# Validate that DELAY is a valid integer
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
    echo -e "${red}[ERROR] The wait time ('$DELAY') must be a valid integer.${off}"
    exit 1
fi

# Safe search for the MySQL binary
MYSQLBIN=$(command -v mysql)

if [[ -z "$MYSQLBIN" ]]; then
    echo -e "${red}[ERROR] MySQL binary not found in the system.${off}"
    exit 1
fi

# ==============================================================================
# Signal trapping (To exit cleanly when pressing Ctrl+C)
# ==============================================================================
trap "echo -e '\n${yel}Monitoring finished.${off}'; exit 0" SIGINT

# ==============================================================================
# Query variables & Dynamic Filtering
# ==============================================================================
EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','rmateos','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"

# Base WHERE condition
WHERE_CLAUSE="user NOT IN (${EXCLUDED_USERS})"

# Append filters if they were provided
if [[ -n "$FILTER_USER" ]]; then
    WHERE_CLAUSE="${WHERE_CLAUSE} AND USER = '${FILTER_USER}'"
fi

if [[ -n "$FILTER_DB" ]]; then
    WHERE_CLAUSE="${WHERE_CLAUSE} AND DB = '${FILTER_DB}'"
fi

if [[ -n "$FILTER_HOST" ]]; then
    WHERE_CLAUSE="${WHERE_CLAUSE} AND HOST LIKE '%${FILTER_HOST}%'"
fi

SQL_QUERY="
SELECT USER, DB, substring_index(substring_index(HOST,':',1),'.',4) AS HH, count(*) AS total 
FROM information_schema.PROCESSLIST 
WHERE ${WHERE_CLAUSE} 
GROUP BY USER, DB, HH 
ORDER BY total DESC, USER, DB, HH DESC;

SELECT count(*) AS filtered_total_connections 
FROM information_schema.PROCESSLIST
WHERE ${WHERE_CLAUSE};
"

# ==============================================================================
# Monitoring Loop
# ==============================================================================
clear
echo -e "====================================================================================="
echo -e "${cyn}Open connections: User - DB - Host Connection Source - Total Account${off} (delay ${DELAY}s)"

# Show active filters in the header if any exist
if [[ -n "$FILTER_USER" || -n "$FILTER_DB" || -n "$FILTER_HOST" ]]; then
    echo -e "${yel}Active Filters -> User: ${FILTER_USER:-ALL} | DB: ${FILTER_DB:-ALL} | Host: ${FILTER_HOST:-ALL}${off}"
fi
echo -e "====================================================================================="
echo ""

while true
do
    echo -e "-- ${cyn}Connections in${off} ${mag}$(hostname)${off} at ${grn}[$(date +"%Y-%m-%d %H:%M:%S")]${off}"
    
    $MYSQLBIN --login-path="${LOGIN_PATH}" -t -e "$SQL_QUERY"
    
    echo -e "Sleeping ${DELAY}s...\n"
    sleep "$DELAY"
done