#!/bin/bash

set -euo pipefail

# 1. Variable initialization
LOGINPATH=""
DB_USER=""
DB_HOST=""
DB_PORT=""
DB_NAME="feniccedb"
NUM_INSERTS=500
BLOCK_SIZE=100
DDL_FILE=""
PARALLEL_THREADS=1

SCRIPT_NAME=$(basename "$0")
LOG_FILE="${SCRIPT_NAME%.*}.log"
TMP_DIR=$(mktemp -d -t feniccedb_insert.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

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
        "VERSION") echo -e "${COLOR_ORANGE}${plain_text}${COLOR_RESET}" ;; # Etiqueta personalizada en naranja
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

validate_ddl() {
    local ddl_content="$1"
    if ! echo "$ddl_content" | grep -qiE "\`?id\`?[[:space:]]+bigint.*auto_increment"; then return 1; fi
    if ! echo "$ddl_content" | grep -qiE "\`?created_ts\`?[[:space:]]+timestamp"; then return 1; fi
    if ! echo "$ddl_content" | grep -qiE "\`?updated_ts\`?[[:space:]]+timestamp"; then return 1; fi
    if ! echo "$ddl_content" | grep -qiE "idx_created[[:space:]]*\([[:space:]]*\`?created_ts\`?[[:space:]]*\)"; then return 1; fi
    if ! echo "$ddl_content" | grep -qiE "idx_id_created[[:space:]]*\([[:space:]]*\`?id\`?[[:space:]]*,[[:space:]]*\`?created_ts\`?[[:space:]]*\)"; then return 1; fi
    return 0
}

show_help() {
    echo "Usage: $0 -l <login-path> [-u <user>] [-h <host>] [-P <port>] [-d <database>] [-n <num_inserts>] [-b <block_size>] [-f <ddl_file.sql>] [-p <parallel_threads>]"
    exit 1
}

while getopts "l:u:h:P:d:n:b:f:p:" opt; do
    case "$opt" in
        l) LOGINPATH="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        n) NUM_INSERTS="$OPTARG" ;;
        b) BLOCK_SIZE="$OPTARG" ;;
        f) DDL_FILE="$OPTARG" ;;
        p) PARALLEL_THREADS="$OPTARG" ;;
        *) show_help ;;
    esac
done

if [[ -z "$LOGINPATH" ]]; then
    echo -e "\033[0;31mError: The -l (login-path) parameter is required.\033[0m"
    show_help
fi

if [[ "$BLOCK_SIZE" -lt 1 ]]; then BLOCK_SIZE=100; fi
if [[ "$PARALLEL_THREADS" -lt 1 ]]; then PARALLEL_THREADS=1; fi

MYSQLBIN=$(command -v mysql)

MYSQL_OPTS_BASE=("--login-path=$LOGINPATH")
[[ -n "$DB_USER" ]] && MYSQL_OPTS_BASE+=("-u" "$DB_USER")
[[ -n "$DB_HOST" ]] && MYSQL_OPTS_BASE+=("-h" "$DB_HOST")
[[ -n "$DB_PORT" ]] && MYSQL_OPTS_BASE+=("-P" "$DB_PORT")
MYSQL_OPTS_BASE+=("-N")

HOST_FROM="${DB_HOST:-$(hostname)}"

log_message "INFO" "--- Starting script execution ---"
log_message "INFO" "Parallel Threads: $PARALLEL_THREADS | IPC Temp Dir: $TMP_DIR"

# 4. Connection Test
log_message "INFO" "Testing connection to the MySQL server..."
if ! "$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    log_message "ERROR" "CRITICAL ERROR: Could not connect to the MySQL server."
    exit 1
fi
log_message "OK" "Connection successful."

# --- DYNAMIC VERSION DETECTION ---
MYSQL_FULL_VERSION=$("$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT @@version;" | tr -d '[:space:]')
CLEAN_VERSION=$(echo "$MYSQL_FULL_VERSION" | sed 's/-.*//')
MYSQL_MAJOR=$(echo "$CLEAN_VERSION" | cut -d. -f1)
MYSQL_MINOR=$(echo "$CLEAN_VERSION" | cut -d. -f2)

# Mostrar la versión en naranja
log_message "VERSION" "Detected MySQL Server Version: $MYSQL_FULL_VERSION"

# Adjust logic based on exact version branch
if [[ "$MYSQL_MAJOR" -eq 5 ]] && [[ "$MYSQL_MINOR" -eq 7 ]]; then
    log_message "INFO" "Applying MySQL 5.7.x configuration..."
    DB_COLLATION="utf8mb4_unicode_ci"
    INSERT_HEADER="INSERT INTO t1 (k, host, hostfrom, created_ts) VALUES "
elif [[ "$MYSQL_MAJOR" -eq 8 ]] && [[ "$MYSQL_MINOR" -eq 0 ]]; then
    log_message "INFO" "Applying MySQL 8.0.x configuration..."
    DB_COLLATION="utf8mb4_0900_ai_ci"
    INSERT_HEADER="INSERT INTO t1 (k, host, hostfrom, created_ts) VALUES "
elif [[ "$MYSQL_MAJOR" -eq 8 ]] && [[ "$MYSQL_MINOR" -ge 4 ]]; then
    log_message "INFO" "Applying MySQL 8.4.x (LTS) configuration..."
    DB_COLLATION="utf8mb4_0900_ai_ci"
    INSERT_HEADER="INSERT INTO t1 (k, host, hostfrom, created_ts) VALUES "
else
    log_message "WARNING" "Unknown MySQL branch ($MYSQL_MAJOR.$MYSQL_MINOR). Using safe 5.x defaults."
    DB_COLLATION="utf8mb4_unicode_ci"
    INSERT_HEADER="INSERT INTO t1 (k, host, hostfrom, created_ts) VALUES "
fi

DEFAULT_DDL="CREATE TABLE IF NOT EXISTS \`t1\` (
   \`id\` bigint NOT NULL AUTO_INCREMENT,
   \`k\` int(11) NOT NULL DEFAULT '0',
   \`host\` char(120) NOT NULL DEFAULT '',
   \`hostfrom\` char(120) NOT NULL DEFAULT '',
   \`created_ts\` timestamp default current_timestamp,
   \`updated_ts\` timestamp default current_timestamp on update current_timestamp,
   PRIMARY KEY (\`id\`),
   KEY \`idx_internal_id\` (\`k\`),
   KEY \`idx_internal_id_created\` (\`k\`,\`created_ts\`),
   KEY \`idx_internal_id_updated\` (\`k\`,\`updated_ts\`),
   KEY \`idx_host\` (\`host\`),
   KEY \`idx_hostfrom\` (\`hostfrom\`),
   KEY \`idx_k_host\` (\`k\`,\`host\`),
   KEY \`idx_k_hostfrom\` (\`k\`,\`hostfrom\`),
   KEY \`idx_created\` (\`created_ts\`),
   KEY \`idx_id_created\` (\`id\`,\`created_ts\`)
 ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=$DB_COLLATION;"

# 5. Check/Create Schema
log_message "INFO" "Checking if database '$DB_NAME' exists..."
DB_EXISTS=$("$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';" | tr -d '[:space:]')

if [[ "$DB_EXISTS" -eq 0 ]]; then
    log_message "WARNING" "Database '$DB_NAME' does not exist."
    read -p "Do you want to create database '$DB_NAME' now? (y/n): " confirm_db
    if [[ "$confirm_db" =~ ^[Yy]$ ]]; then
        log_message "INFO" "Creating database '$DB_NAME' with collation $DB_COLLATION..."
        "$MYSQLBIN" "${MYSQL_OPTS_BASE[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE $DB_COLLATION;"
        log_message "OK" "Database created successfully."
    else
        log_message "WARNING" "Database creation aborted."
        exit 0
    fi
else
    log_message "OK" "Database '$DB_NAME' already exists. Proceeding..."
fi

MYSQL_OPTS=("${MYSQL_OPTS_BASE[@]}" "-A" "$DB_NAME")

# 6. Check/Create Table 't1'
log_message "INFO" "Checking if table 't1' exists..."
TABLE_EXISTS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = 't1';" | tr -d '[:space:]')

if [[ "$TABLE_EXISTS" -eq 0 ]]; then
    log_message "WARNING" "Table 't1' does not exist in database '$DB_NAME'."
    read -p "Do you want to create table 't1' now? (y/n): " confirm_tbl
    if [[ "$confirm_tbl" =~ ^[Yy]$ ]]; then
        ACTUAL_DDL="$DEFAULT_DDL"
        if [[ -n "$DDL_FILE" ]] && [[ -f "$DDL_FILE" ]]; then
            FILE_CONTENT=$(<"$DDL_FILE")
            if validate_ddl "$FILE_CONTENT"; then
                log_message "OK" "Provided DDL file passed validation."
                if [[ "$MYSQL_MAJOR" -eq 5 ]] && [[ "$MYSQL_MINOR" -eq 7 ]]; then
                    FILE_CONTENT=$(echo "$FILE_CONTENT" | sed 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g')
                    log_message "INFO" "Adapted DDL collation for MySQL 5.7.x compatibility."
                fi
                ACTUAL_DDL="$FILE_CONTENT"
            else
                log_message "WARNING" "Provided DDL file FAILED validation. Falling back to default script DDL."
            fi
        fi
        log_message "INFO" "Creating table 't1'..."
        "$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "$ACTUAL_DDL"
        log_message "OK" "Table 't1' created successfully."
    else
        log_message "WARNING" "Table creation aborted."
        exit 0
    fi
else
    log_message "OK" "Table 't1' already exists. Proceeding..."
fi

INITROWS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT count(*) FROM t1;")
log_message "INFO" "Initial records in t1: ${INITROWS}"
log_message "INFO" "Executing bulk inserts (Total: $NUM_INSERTS, Block size: $BLOCK_SIZE, Threads: $PARALLEL_THREADS)..."

run_worker() {
    local thread_id=$1
    local t_start=$2
    local t_end=$3
    
    local thread_inserted_rows=0
    local t_total=$(( t_end - t_start + 1 ))
    local num_blocks=$(( (t_total + BLOCK_SIZE - 1) / BLOCK_SIZE ))
    
    for (( b=1; b<=num_blocks; b++ )); do
        local block_start_time=$(get_time)
        local b_start=$(( t_start + (b - 1) * BLOCK_SIZE ))
        local b_end=$(( b_start + BLOCK_SIZE - 1 ))
        if (( b_end > t_end )); then b_end=$t_end; fi
        local expected_rows=$(( b_end - b_start + 1 ))
        
        set +e
        local sql_output
        sql_output=$( (
            echo "BEGIN;"
            echo "SELECT SLEEP(3);"
            echo "$INSERT_HEADER"
            for (( i=b_start; i<=b_end; i++ )); do
                if (( i == b_end )); then
                    echo "(${i}, @@hostname, '${HOST_FROM}', NOW());"
                else
                    echo "(${i}, @@hostname, '${HOST_FROM}', NOW()),"
                fi
            done
            echo "SELECT ROW_COUNT();"
            echo "COMMIT;"
        ) | "$MYSQLBIN" "${MYSQL_OPTS[@]}" 2>&1 )
        set -e
        
        local actual_rows
        actual_rows=$(echo "$sql_output" | tail -n 1)
        
        if [[ ! "$actual_rows" =~ ^[0-9]+$ ]]; then
            log_message "ERROR" "[Thread-$thread_id] MySQL error in block $b: $sql_output"
            actual_rows=0
        fi

        local block_end_time=$(get_time)
        local block_duration=$(calc_time_diff "$block_start_time" "$block_end_time")
        thread_inserted_rows=$(( thread_inserted_rows + actual_rows ))
        
        if [[ "$actual_rows" -eq "$expected_rows" ]]; then
            log_message "OK" "[Thread-$thread_id] Block $b/$num_blocks | Expected: $expected_rows | Inserted: $actual_rows | Time: ${block_duration}s"
        else
            log_message "WARNING" "[Thread-$thread_id] Block $b/$num_blocks | Expected: $expected_rows | Inserted: $actual_rows | Time: ${block_duration}s"
        fi
    done
    
    echo "$thread_inserted_rows" > "$TMP_DIR/$thread_id.out"
}

GLOBAL_START_TIME=$(get_time)

current_start=1
for (( t=1; t<=PARALLEL_THREADS; t++ )); do
    t_inserts=$(( NUM_INSERTS / PARALLEL_THREADS ))
    if (( t <= (NUM_INSERTS % PARALLEL_THREADS) )); then
        t_inserts=$(( t_inserts + 1 ))
    fi
    current_end=$(( current_start + t_inserts - 1 ))
    
    if (( t_inserts > 0 )); then
        log_message "INFO" "Spawning Thread-$t for range $current_start to $current_end ($t_inserts inserts)"
        run_worker "$t" "$current_start" "$current_end" &
    fi
    current_start=$(( current_end + 1 ))
done

wait
log_message "INFO" "All parallel threads completed."

GLOBAL_ACTUAL_INSERTS=0
for result_file in "$TMP_DIR"/*.out; do
    if [[ -f "$result_file" ]]; then
        thread_result=$(<"$result_file")
        GLOBAL_ACTUAL_INSERTS=$(( GLOBAL_ACTUAL_INSERTS + thread_result ))
    fi
done

GLOBAL_END_TIME=$(get_time)
GLOBAL_DURATION=$(calc_time_diff "$GLOBAL_START_TIME" "$GLOBAL_END_TIME")

FINALROWS=$("$MYSQLBIN" "${MYSQL_OPTS[@]}" -e "SELECT count(*) FROM t1;")

log_message "INFO" "----------------------------------------"
log_message "INFO" "          EXECUTION STATISTICS          "
log_message "INFO" "----------------------------------------"
log_message "INFO" "Records in DB (Initial) : $INITROWS"

if [[ "$GLOBAL_ACTUAL_INSERTS" -eq "$NUM_INSERTS" ]]; then
    log_message "OK" "Global Expected Inserts : $NUM_INSERTS | Actual Inserts: $GLOBAL_ACTUAL_INSERTS"
else
    log_message "WARNING" "Mismatch! Expected Inserts : $NUM_INSERTS | Actual Inserts: $GLOBAL_ACTUAL_INSERTS"
fi

log_message "INFO" "Records in DB (Final)   : $FINALROWS"
log_message "INFO" "Total Execution Time    : ${GLOBAL_DURATION}s"
log_message "INFO" "----------------------------------------"
log_message "OK" "Script execution completed."