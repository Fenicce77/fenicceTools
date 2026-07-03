#!/usr/bin/env bash

# ============================================================================
# InnoDB Buffer Pool Impact Evaluator (macOS & Linux Compatible)
# MySQL Versions: 8.0 & 8.4
# ============================================================================

# --- Color Definitions (Cross-platform ANSI codes) ---
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'

show_help() {
    printf '%b\n' "${CYAN}======================================================================${RESET}"
    printf '%b\n' "${BOLD}InnoDB Buffer Pool Impact Evaluator${RESET}"
    printf '%b\n' "${CYAN}======================================================================${RESET}"
    printf '%b\n' "${YELLOW}Usage:${RESET} $0 [OPTIONS] <login-path> <database> <table> <queries.sql>\n"
    
    printf '%b\n' "${BOLD}Description:${RESET}"
    printf '%b\n' "  Evaluates the memory impact of a specific table and its indexes "
    printf '%b\n' "  on the InnoDB Buffer Pool before and after running a SQL workload."
    printf '%b\n' "  Designed for MySQL 8.0 and 8.4 environments (e.g., GCP Cloud SQL).\n"
    
    printf '%b\n' "${BOLD}Arguments:${RESET}"
    printf '%b\n' "  ${YELLOW}login-path${RESET}    The MySQL login-path configured via mysql_config_editor."
    printf '%b\n' "  ${YELLOW}database${RESET}      The target database schema name."
    printf '%b\n' "  ${YELLOW}table${RESET}         The target table name to evaluate."
    printf '%b\n' "  ${YELLOW}queries.sql${RESET}   A file containing the SQL queries to execute.\n"
    
    printf '%b\n' "${BOLD}Options:${RESET}"
    printf '%b\n' "  ${CYAN}-h, --help${RESET}    Show this help message and exit.\n"
    
    printf '%b\n' "${BOLD}Examples:${RESET}"
    printf '%b\n' "  1. Standard execution:"
    printf '%b\n' "     ${GREEN}./eval_impact.sh my_gcp_prod my_app users test_workload.sql${RESET}\n"
    
    printf '%b\n' "  2. Save the report to a text file for later review:"
    printf '%b\n' "     ${GREEN}./eval_impact.sh my_gcp_prod my_app users test_workload.sql > report.txt${RESET}"
    printf '%b\n' "${CYAN}======================================================================${RESET}"
}

# Handle zero arguments or Help Flag
if [[ "$#" -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Argument Validation for incorrect number of arguments
if [ "$#" -ne 4 ]; then
    printf '%b\n' "${RED}Error: Invalid number of arguments. Expected 4, got $#.${RESET}\n"
    show_help
    exit 1
fi

LOGIN_PATH=$1
DB_NAME=$2
TABLE_NAME=$3
QUERY_FILE=$4

# Check if query file exists
if [ ! -f "$QUERY_FILE" ]; then
    printf '%b\n' "${RED}Error: Query file '${QUERY_FILE}' not found!${RESET}"
    exit 1
fi

# Function to fetch table-level stats from sys schema
get_table_stats() {
    mysql --login-path="$LOGIN_PATH" -N -B -e "
        SELECT 
            IFNULL(pages, 0), 
            IFNULL(allocated, '0 bytes'), 
            IFNULL(data, '0 bytes'), 
            IFNULL(pages_old, 0), 
            IFNULL(pages_hashed, 0), 
            IFNULL(rows_cached, 0)
        FROM sys.innodb_buffer_stats_by_table 
        WHERE object_schema = '$DB_NAME' AND object_name = '$TABLE_NAME';
    "
}

printf '%b\n' "${CYAN}======================================================================${RESET}"
printf '%b\n' " ${BOLD}Starting Evaluation for Table:${RESET} ${GREEN}${TABLE_NAME}${RESET} ${BOLD}(Database:${RESET} ${GREEN}${DB_NAME}${RESET}${BOLD})${RESET}"
printf '%b\n' "${CYAN}======================================================================${RESET}"

# ---------------------------------------------------------
# 1. Capture Baseline
# ---------------------------------------------------------
printf '%b\n' "${YELLOW}[1/3] Capturing baseline buffer pool state...${RESET}"
BASELINE=$(get_table_stats)

if [ -z "$BASELINE" ]; then
    printf '%b\n' "      ${YELLOW}-> Table not in buffer pool yet. Baseline set to zero.${RESET}"
    BASELINE="0\t0 bytes\t0 bytes\t0\t0\t0"
fi

IFS=$'\t' read -r B_PAGES B_ALLOC B_DATA B_OLD B_HASH B_ROWS <<< "$BASELINE"

# ---------------------------------------------------------
# 2. Execute Workload
# ---------------------------------------------------------
printf '%b\n' "${YELLOW}[2/3] Executing queries from ${QUERY_FILE}...${RESET}"
mysql --login-path="$LOGIN_PATH" "$DB_NAME" < "$QUERY_FILE" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    printf '%b\n' "${RED}Error executing queries. Please check your SQL file for syntax errors or connection issues.${RESET}"
    exit 1
fi

# ---------------------------------------------------------
# 3. Capture Post-Execution State
# ---------------------------------------------------------
printf '%b\n' "${YELLOW}[3/3] Capturing post-execution buffer pool state...${RESET}"
POST_STATE=$(get_table_stats)

if [ -z "$POST_STATE" ]; then
    POST_STATE="0\t0 bytes\t0 bytes\t0\t0\t0"
fi

IFS=$'\t' read -r P_PAGES P_ALLOC P_DATA P_OLD P_HASH P_ROWS <<< "$POST_STATE"

# ---------------------------------------------------------
# 4. Display Final Report
# ---------------------------------------------------------
echo ""
printf '%b\n' "${CYAN}======================================================================${RESET}"
printf '%b\n' "                      ${BOLD}IMPACT ANALYSIS REPORT${RESET}                          "
printf '%b\n' "${CYAN}======================================================================${RESET}"
printf '%b\n' "${BOLD}--- TABLE LEVEL SUMMARY ---${RESET}"
printf "${CYAN}%-20s | %-15s | %-15s${RESET}\n" "Metric" "Before" "After Workload"
printf "${CYAN}%-20s | %-15s | %-15s${RESET}\n" "--------------------" "---------------" "---------------"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Total Pages" "$B_PAGES" "$P_PAGES"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Allocated Memory" "$B_ALLOC" "$P_ALLOC"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Actual Data" "$B_DATA" "$P_DATA"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Pages in Old LRU" "$B_OLD" "$P_OLD"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Hashed Pages (AHI)" "$B_HASH" "$P_HASH"
printf "%-20s | ${YELLOW}%-15s${RESET} | ${GREEN}%-15s${RESET}\n" "Rows Cached" "$B_ROWS" "$P_ROWS"
echo ""

printf '%b\n' "${BOLD}--- POST-WORKLOAD INDEX BREAKDOWN ---${RESET}"
mysql --login-path="$LOGIN_PATH" -t -e "
    SELECT 
        INDEX_NAME AS 'Index Name',
        COUNT(*) AS 'Total Pages',
        CONCAT(ROUND(COUNT(*) * 16384 / 1024 / 1024, 2), ' MiB') AS 'Allocated Memory',
        CONCAT(ROUND(SUM(DATA_SIZE) / 1024 / 1024, 2), ' MiB') AS 'Actual Data',
        SUM(IF(IS_OLD = 'YES', 1, 0)) AS 'Pages in Old LRU',
        SUM(IF(IS_HASHED = 'YES', 1, 0)) AS 'Hashed Pages (AHI)'
    FROM information_schema.INNODB_BUFFER_PAGE_LRU
    WHERE TABLE_NAME LIKE '%${TABLE_NAME}%'
    GROUP BY INDEX_NAME
    ORDER BY COUNT(*) DESC;
"
printf '%b\n' "${CYAN}======================================================================${RESET}"