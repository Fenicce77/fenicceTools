#!/bin/bash

# Strict mode for better security and error handling
set -euo pipefail

# 1. Variable initialization and default values
LOGINPATH=""
DB_USER=""
DB_HOST=""
DB_PORT=""
DB_NAME="feniccedb"
NUM_DELETES=500
BLOCK_SIZE=100
USER_START_ID=""
USER_END_ID=""
FORCE_MODE=0

SCRIPT_NAME=$(basename "$0")
LOG_FILE="${SCRIPT_NAME%.*}.log"

# Log Rotation Logic
if [[ -f "$LOG_FILE" ]]; then
    LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [[ "$LINE_COUNT" -ge 10000 ]]; then
        ARCHIVE_DATE=$(date +"%Y%m%d_%H%M%S")
        ARCHIVE_LOG="${SCRIPT_NAME%.*}_${ARCHIVE_DATE}.log"
        mv "$LOG_FILE" "$ARCHIVE_LOG"
        echo -e "\033[0;32m[`date +"%Y-%m-%d %H:%M:%S"`] [INFO] Previous log reached $LINE_COUNT lines. Rotated to $ARCHIVE_LOG\033[0m"
    fi
fi

log_message() {
    local tag="$1"
    local msg="$2"
    local timestamp="[`date +"%Y-%m-%d %H:%M:%S"`]"
    local plain_text="$timestamp [$tag] $msg"
    
    local COLOR_RED='\033[0;31m'
    local COLOR_ORANGE='\033[0;33m'
    local COLOR_GREEN='\033[0;32m'
    local COLOR_RESET='\033[0m'
    
    echo "$plain_text" >> "$LOG_FILE"
    
    case "$tag" in
        "ERROR")   echo -e "${COLOR_RED}${plain_text}${COLOR_RESET}" ;;
        "WARNING") echo -e "${COLOR_ORANGE}${plain_text}${COLOR_RESET}" ;;
        "VERSION") echo -e "${COLOR_ORANGE}${plain_text}${COLOR_RESET}" ;;
        "OK")      echo -e "${COLOR_GREEN}${plain_text}${COLOR_RESET}" ;;
        *)         echo -e "${plain_text}" ;;
    esac
}

get_time() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then echo "$EPOCHREALTIME"
    elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'print time'
    else date +%s; fi
}

calc_time_diff() {
    local start=$1
    local end=$2
    awk "BEGIN {printf \"%.3f\", $end - $start}"
}

show_help() {
    echo "Usage: $0 -l <login-path> [-u <user>] [-h <host>] [-P <port>] [-d <database>] [-n <num_deletes>] [-b <block_size>] [-s <start_id>] [-e <end_id>] [-f]"
    echo "  -s : Primary Key ID to start deletion from (Optional)"
    echo "  -e : Primary Key ID to end deletion at (Optional)"
    echo "  -f : Force mode (no confirmation prompts)"
    exit 1
}

# Parameter processing
while getopts "l:u:h:P:d:n:b:s:e:f" opt; do
    case "$opt" in
        l) LOGINPATH="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        n) NUM_DELETES="$OPTARG" ;;
        b) BLOCK_SIZE="$OPTARG" ;;
        s) USER_START_ID="$OPTARG" ;;
        e) USER_END_ID="$OPTARG" ;;
        f) FORCE_MODE=1 ;;
        *) show_help ;;
    esac
done

if [[ -z "$LOGINPATH" ]]; then
    echo -e "\033[0;31mError: The -l (login-path) parameter is required.\033[0m"
    show_help
fi

if [[ "$BLOCK_SIZE" -lt 1 ]]; then
    log_message "WARNING" "Block size must be at least 1. Setting to default (100)."
    BLOCK_SIZE=100
fi

MYSQLBIN=$(command -v mysql)
MYSQL_OPTS_BASE=("--login-path=$LOGINPATH")
[[ -n "$DB_USER" ]] && MYSQL_OPTS_BASE+=("-u" "$DB_USER")
[[ -n "$DB_HOST" ]] && MYSQL_OPTS_BASE+=("-h" "$DB_HOST")
[[ -n "$DB_PORT" ]] && MYSQL_OPTS_BASE+=("-P" "$DB_PORT")
MYSQL_OPTS_BASE+=("-N")

log_message "INFO" "--- Starting script execution (DELETION BY PK MODE) ---"
[[ "$FORCE_MODE" -eq 1 ]] && log_message "VERSION" "FORCE MODE (-f) IS ENABLED. Prompts will be bypassed."

# 4. Connection & Version Test
log_message "INFO" "Testing connection to the MySQL server..."
if ! "$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    log_message "ERROR" "CRITICAL ERROR: Could not connect to the MySQL server."
    exit 1
fi
log_message "OK" "Connection successful."

MYSQL_FULL_VERSION=$("$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT @@version;" | tr -d '[:space:]')
log_message "VERSION" "Detected MySQL Server Version: $MYSQL_FULL_VERSION"

# 5. Check Schema
DB_EXISTS=$("$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';" | tr -d '[:space:]')
if [[ "$DB_EXISTS" -eq 0 ]]; then
    log_message "ERROR" "Database '$DB_NAME' does not exist. Cannot perform deletion."
    exit 1
fi
MYSQL_OPTS=("${MYSQL_OPTS_BASE[@]}" "-A" "$DB_NAME")

# 6. Check Table 't1'
TABLE_EXISTS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = 't1';" | tr -d '[:space:]')
if [[ "$TABLE_EXISTS" -eq 0 ]]; then
    log_message "ERROR" "Table 't1' does not exist in database '$DB_NAME'. Cannot perform deletion."
    exit 1
fi

# 7. Initial counts and PK boundaries
INITROWS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT count(*) FROM t1;" | tr -d '[:space:]')
if [[ "$INITROWS" -eq 0 ]]; then
    log_message "WARNING" "Table 't1' is empty. Nothing to delete."
    exit 0
fi

MIN_ID=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT MIN(id) FROM t1;" | tr -d '[:space:]')
MAX_ID=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT MAX(id) FROM t1;" | tr -d '[:space:]')

log_message "INFO" "Table bounds -> Total Rows: $INITROWS | Min ID: $MIN_ID | Max ID: $MAX_ID"

# 8. Start ID Logic
START_ID=""
if [[ -n "$USER_START_ID" ]]; then
    EXACT_EXISTS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT COUNT(*) FROM t1 WHERE id = $USER_START_ID;" | tr -d '[:space:]')
    if [[ "$EXACT_EXISTS" -eq 0 ]]; then
        log_message "WARNING" "Provided Start ID ($USER_START_ID) DOES NOT exist."
        log_message "INFO" "The first available ID in the table is $MIN_ID."
        if [[ "$FORCE_MODE" -eq 1 ]]; then
            log_message "WARNING" "Force mode active: Automatically starting from $MIN_ID."
            START_ID=$MIN_ID
        else
            read -p "Do you want to start from the first available ID ($MIN_ID)? (y/n): " confirm_start
            if [[ "$confirm_start" =~ ^[Yy]$ ]]; then
                START_ID=$MIN_ID
            else
                log_message "ERROR" "Execution aborted by user."
                exit 0
            fi
        fi
    else
        log_message "OK" "Start ID ($USER_START_ID) exists. Proceeding..."
        START_ID=$USER_START_ID
    fi
else
    START_ID=$MIN_ID
fi

# 9. End ID Logic
END_ID=""
if [[ -n "$USER_END_ID" ]]; then
    END_ID=$USER_END_ID
    NUM_DELETES=$(( END_ID - START_ID + 1 ))
else
    END_ID=$(( START_ID + NUM_DELETES - 1 ))
fi

if (( END_ID > MAX_ID )); then
    log_message "WARNING" "Calculated End ID ($END_ID) exceeds Max ID ($MAX_ID). Capping upper limit."
    END_ID=$MAX_ID
    NUM_DELETES=$(( END_ID - START_ID + 1 ))
fi

log_message "INFO" "Executing bulk deletes (Range ID: $START_ID to $END_ID | Block size: $BLOCK_SIZE)..."

# 10. Optimized Bulk Delete by PK
TOTAL_DELETED_ROWS=0
NUM_BLOCKS=$(( (NUM_DELETES + BLOCK_SIZE - 1) / BLOCK_SIZE ))
GLOBAL_START_TIME=$(get_time)

for (( b=1; b<=NUM_BLOCKS; b++ )); do
    BLOCK_START_TIME=$(get_time)
    
    b_start=$(( START_ID + (b - 1) * BLOCK_SIZE ))
    b_end=$(( b_start + BLOCK_SIZE - 1 ))
    if (( b_end > END_ID )); then b_end=$END_ID; fi
    EXPECTED_ROWS=$(( b_end - b_start + 1 ))
    
    SQL_OUTPUT=$( (
        echo "BEGIN;"
        echo "DELETE FROM t1 WHERE id BETWEEN $b_start AND $b_end;"
        echo "SELECT ROW_COUNT();"
        echo "COMMIT;"
    ) | "$MYSQLBIN" "${MYSQL_OPTS[@]}" 2>&1 )
    
    ACTUAL_ROWS=$(echo "$SQL_OUTPUT" | tail -n 1)
    
    if [[ ! "$ACTUAL_ROWS" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "MySQL error in block $b: $SQL_OUTPUT"
        ACTUAL_ROWS=0
    fi

    BLOCK_END_TIME=$(get_time)
    BLOCK_DURATION=$(calc_time_diff "$BLOCK_START_TIME" "$BLOCK_END_TIME")
    TOTAL_DELETED_ROWS=$(( TOTAL_DELETED_ROWS + ACTUAL_ROWS ))
    
    if [[ "$ACTUAL_ROWS" -eq "$EXPECTED_ROWS" ]]; then
        log_message "OK" "Block $b/$NUM_BLOCKS | ID Range: $b_start-$b_end | Deleted: $ACTUAL_ROWS | Time: ${BLOCK_DURATION}s"
    else
        log_message "WARNING" "Block $b/$NUM_BLOCKS | ID Range: $b_start-$b_end | Targeted: $EXPECTED_ROWS | Actually Deleted: $ACTUAL_ROWS (Gaps found) | Time: ${BLOCK_DURATION}s"
    fi
done

GLOBAL_END_TIME=$(get_time)
GLOBAL_DURATION=$(calc_time_diff "$GLOBAL_START_TIME" "$GLOBAL_END_TIME")

FINALROWS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT count(*) FROM t1;" | tr -d '[:space:]')
log_message "INFO" "----------------------------------------"
log_message "INFO" "          EXECUTION STATISTICS          "
log_message "INFO" "----------------------------------------"
log_message "INFO" "Records in DB (Initial) : $INITROWS"
log_message "INFO" "Total Targeted PK Range : $NUM_DELETES records"
log_message "OK"   "Successfully Deleted    : $TOTAL_DELETED_ROWS records"
log_message "INFO" "Records in DB (Final)   : $FINALROWS"
log_message "INFO" "Total Execution Time    : ${GLOBAL_DURATION}s"
log_message "INFO" "----------------------------------------"
log_message "OK" "Script execution completed."