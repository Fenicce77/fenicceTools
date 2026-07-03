#!/usr/bin/env bash
#
# bp_tracker.sh v4.0
# Live Dashboard DBRE tool. Continuously monitors by default.

set -euo pipefail

# --- ANSI Color Definitions (Forced native expansion) ---
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_RED=$'\e[0;31m'
readonly C_GREEN=$'\e[0;32m'
readonly C_YELLOW=$'\e[0;33m'
readonly C_BLUE=$'\e[0;34m'
readonly C_MAGENTA=$'\e[0;35m'
readonly C_CYAN=$'\e[0;36m'

# --- Configuration & Defaults ---
LOGIN_PATH="default"
OUTPUT_FILE="bp_activity_$(date +%Y%m%d_%H%M%S).log"
POLL_INTERVAL=10
OBJECT_FILTER=""
USER_FILTER=""

# --- Help Function ---
show_help() {
    printf "\n${C_CYAN}${C_BOLD}======================================================${C_RESET}\n"
    printf "${C_CYAN}${C_BOLD}   InnoDB Buffer Pool Live Dashboard (v4.0)           ${C_RESET}\n"
    printf "${C_CYAN}${C_BOLD}======================================================${C_RESET}\n"
    printf "Starts a continuous monitoring loop immediately.\n"
    printf "Press 'm' during execution to open the settings menu.\n\n"
    
    printf "${C_YELLOW}${C_BOLD}OPTIONS:${C_RESET}\n"
    printf "  ${C_GREEN}-l${C_RESET} <login-path>   MySQL login path (Default: default)\n"
    printf "  ${C_GREEN}-o${C_RESET} <file>         Output log file (Default: auto-generated)\n"
    printf "  ${C_GREEN}-i${C_RESET} <seconds>      Refresh interval in seconds (Default: 10)\n"
    printf "  ${C_GREEN}-h${C_RESET}                Show this colored help menu\n\n"
}

# --- Parameter Validation ---
if [[ $# -eq 0 ]]; then
    printf "${C_RED}Error: No parameters provided. At least the login path is required.${C_RESET}\n" >&2
    show_help
    exit 1
fi

while getopts ":l:o:i:h" opt; do
    case "${opt}" in
        l) LOGIN_PATH="${OPTARG}" ;;
        o) OUTPUT_FILE="${OPTARG}" ;;
        i) POLL_INTERVAL="${OPTARG}" ;;
        h) show_help; exit 0 ;;
        \?) printf "${C_RED}${C_BOLD}[!] Invalid option: -%s${C_RESET}\n" "${OPTARG}" >&2; show_help; exit 1 ;;
        :) printf "${C_RED}${C_BOLD}[!] Option -%s requires an argument.${C_RESET}\n" "${OPTARG}" >&2; show_help; exit 1 ;;
    esac
done

# --- Helper Functions ---
log_and_print() {
    local color="$1"
    local msg="$2"
    # Print with color to stdout
    printf "%s%s%s\n" "${color}" "${msg}" "${C_RESET}"
    # Print without color to log file
    printf "%s | %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "${msg}" >> "${OUTPUT_FILE}"
}

print_header() {
    local title="$1"
    log_and_print "${C_MAGENTA}" "================================================================="
    log_and_print "${C_BOLD}${C_MAGENTA}" " ${title} | Object: [${OBJECT_FILTER:-ALL}] | User: [${USER_FILTER:-ALL}]"
    log_and_print "${C_MAGENTA}" "================================================================="
}

execute_sql() {
    mysql --login-path="${LOGIN_PATH}" -N -B -s -e "$1"
}

get_top_objects() {
    local query="
    SELECT 
        CONCAT(object_schema, '.', object_name) AS object,
        pages AS total_pages,
        ROUND(allocated / 1024 / 1024, 2) AS allocated_mb,
        ROUND(pages_old / pages * 100, 1) AS old_pct
    FROM sys.innodb_buffer_stats_by_table
    WHERE object_schema NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
      AND CONCAT(object_schema, '.', object_name) LIKE '%${OBJECT_FILTER}%'
      AND pages > 0
    ORDER BY pages DESC
    LIMIT 10;"
    
    local tmp_sql
    tmp_sql=$(mktemp)
    printf "%s" "$query" > "$tmp_sql"
    mysql --login-path="${LOGIN_PATH}" -t < "$tmp_sql"
    rm "$tmp_sql"
}

get_user_activity() {
    local query="
    SELECT user, time AS sec_running, state, LEFT(current_statement, 60) AS query_snippet
    FROM sys.session
    WHERE user NOT IN ('mysql.session', 'mysql.sys')
      AND user LIKE '%${USER_FILTER}%'
      AND current_statement IS NOT NULL
    ORDER BY time DESC LIMIT 5;"

    local tmp_sql
    tmp_sql=$(mktemp)
    printf "%s" "$query" > "$tmp_sql"
    mysql --login-path="${LOGIN_PATH}" -t < "$tmp_sql"
    rm "$tmp_sql"
}

get_churn_metrics() {
    execute_sql "SELECT PAGES_MADE_YOUNG, PAGES_NOT_MADE_YOUNG, PAGES_READ_RATE FROM information_schema.INNODB_BUFFER_POOL_STATS;"
}

take_snapshot() {
    printf "\033c" # Clears the terminal screen for a clean dashboard view
    print_header "LIVE DASHBOARD SNAPSHOT"
    
    log_and_print "${C_CYAN}" "Top Memory Objects:"
    local top_objs
    top_objs=$(get_top_objects)
    printf "%s%s%s\n" "${C_CYAN}" "${top_objs}" "${C_RESET}"
    printf "%s\n" "${top_objs}" >> "${OUTPUT_FILE}"
    
    log_and_print "${C_GREEN}" "Active User Queries:"
    local user_act
    user_act=$(get_user_activity)
    printf "%s%s%s\n" "${C_GREEN}" "${user_act}" "${C_RESET}"
    printf "%s\n" "${user_act}" >> "${OUTPUT_FILE}"
    
    read -r P_YOUNG P_NOT_YOUNG P_READ_RATE <<< "$(get_churn_metrics)"
    local churn_msg="Churn -> Made Young: ${P_YOUNG} | Evicted: ${P_NOT_YOUNG} | Read Rate: ${P_READ_RATE}/s"
    
    if [[ "${P_READ_RATE}" -gt 5000 ]]; then
         log_and_print "${C_RED}${C_BOLD}" "[!] HIGH CHURN: ${churn_msg}"
    else
         log_and_print "${C_YELLOW}" "${churn_msg}"
    fi
    printf "\n"
}

interactive_menu() {
    printf "\033c"
    while true; do
        printf "\n${C_BLUE}${C_BOLD}========== TRACKER SETTINGS ==========${C_RESET}\n"
        printf " Filters -> Object: [${C_CYAN}%s${C_RESET}] | User: [${C_GREEN}%s${C_RESET}] | Interval: [${C_MAGENTA}%ss${C_RESET}]\n" "${OBJECT_FILTER:-ALL}" "${USER_FILTER:-ALL}" "${POLL_INTERVAL}"
        printf "${C_BLUE}--------------------------------------${C_RESET}\n"
        printf " [${C_CYAN}1${C_RESET}] Return to Live Dashboard (Resume)\n"
        printf " [${C_CYAN}2${C_RESET}] Set Object Filter (Table/Schema)\n"
        printf " [${C_CYAN}3${C_RESET}] Set User Filter\n"
        printf " [${C_CYAN}4${C_RESET}] Set Refresh Interval\n"
        printf " [${C_RED}Q${C_RESET}] Quit Completely\n"
        printf "${C_BLUE}======================================${C_RESET}\n"
        printf "${C_BOLD}Select an option:${C_RESET} "
        read -r choice
        printf "\n"

        case "${choice}" in
            1) break ;; # Break loop to return to main dashboard
            2) 
                printf "Enter object keyword (or leave blank for ALL): "
                read -r OBJECT_FILTER
                ;;
            3) 
                printf "Enter username keyword (or leave blank for ALL): "
                read -r USER_FILTER
                ;;
            4)
                printf "Enter new interval in seconds (current: %s): " "${POLL_INTERVAL}"
                read -r new_int
                if [[ "${new_int}" =~ ^[0-9]+$ ]]; then
                    POLL_INTERVAL="${new_int}"
                else
                    printf "${C_RED}Invalid number.${C_RESET}\n"
                fi
                ;;
            [qQ]) 
                log_and_print "${C_GREEN}${C_BOLD}" "Exiting tracker. Complete session saved to ${OUTPUT_FILE}."
                exit 0 
                ;;
            *) printf "${C_RED}Invalid selection.${C_RESET}\n" ;;
        esac
    done
}

# --- Main Initialization ---
> "${OUTPUT_FILE}"
printf "\033c"
log_and_print "${C_GREEN}${C_BOLD}" "Initializing Tracker..."
log_and_print "${C_RESET}" "Target: ${C_CYAN}${LOGIN_PATH}${C_RESET} | Log: ${C_CYAN}${OUTPUT_FILE}${C_RESET}"

DB_VERSION=$(execute_sql "SELECT VERSION();")
log_and_print "${C_RESET}" "Target Version: ${C_YELLOW}${DB_VERSION}${C_RESET}"

if [[ "${DB_VERSION}" == 8.4* ]]; then
    log_and_print "${C_RED}" "Note: MySQL 8.4 LTS detected. AHI metrics excluded."
fi

sleep 2 # Brief pause to read init messages

# --- The Live Dashboard Loop ---
while true; do
    take_snapshot
    
    printf "${C_BOLD}Waiting %ss for next refresh...${C_RESET}\n" "${POLL_INTERVAL}"
    printf "${C_YELLOW}Press [m] to open Menu | Press [q] to Quit${C_RESET}\n"
    
    # -n 1 reads a single character immediately (no need to press Enter)
    if read -t "${POLL_INTERVAL}" -n 1 -r input; then
        if [[ "${input}" == "q" || "${input}" == "Q" ]]; then
            printf "\n"
            log_and_print "${C_GREEN}${C_BOLD}" "Exiting tracker. Session saved to ${OUTPUT_FILE}."
            exit 0
        elif [[ "${input}" == "m" || "${input}" == "M" ]]; then
            interactive_menu
        fi
    fi
done