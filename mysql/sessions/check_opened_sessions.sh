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
# Parameter validation
# ==============================================================================
if [[ -z "$1" ]]; then
    echo -e "${red}[ERROR] Missing connection parameter (login-path).${off}"
    echo -e "${yel}Usage     : $0 [LOGIN-PATH] [DELAY_SECONDS (optional)]${off}"
    echo -e "${yel}Example 1 (default 5s) : $0 prod${off}"
    echo -e "${yel}Example 2 (every 10s)  : $0 prod 10${off}\n"
    exit 1
fi

ENV="$1"
# Assign the second parameter to DELAY; if it doesn't exist, use 5 by default.
DELAY="${2:-5}"

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
# Query variables
# ==============================================================================
# Users to exclude to keep the query clean
EXCLUDED_USERS="'root','gsancliment','pmm_monitor','proxysql-monitor','rmateos','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler'"

SQL_QUERY="
SELECT USER, DB, substring_index(substring_index(HOST,':',1),'.',4) AS HH, count(*) AS total 
FROM information_schema.PROCESSLIST 
WHERE user NOT IN (${EXCLUDED_USERS}) 
GROUP BY USER, DB, HH 
ORDER BY total DESC, USER, DB, HH DESC;

SELECT count(*) AS total_connections 
FROM information_schema.PROCESSLIST;
"

# ==============================================================================
# Monitoring Loop
# ==============================================================================
clear
echo -e "====================================================================================="
echo -e "${cyn}Open connections: User - DB - Host Connection Source - Total Account${off} (delay ${DELAY}s)"
echo -e "====================================================================================="
echo ""

while true
do
    echo -e "-- ${cyn}Connections in${off} ${mag}$(hostname)${off} at ${grn}[$(date +"%Y-%m-%d %H:%M:%S")]${off}"
    
    $MYSQLBIN --login-path="${ENV}" -t -e "$SQL_QUERY"
    
    echo -e "Sleeping ${DELAY}s...\n"
    sleep "$DELAY"
done

