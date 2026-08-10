#!/usr/bin/env bash
set -euo pipefail

initialize_defaults() {
    MYSQL_BIN_ENV=${MYSQL_BIN:-}
    MYSQL_BIN_OPTION=""
    MYSQL_BIN=""
    LOGIN_PATH=""
    DATABASE=""
    TABLE_PREFIX=""
    ROWS=""
    UNIT="day"
    RETENTION_DAYS=30
    INDEX_FACTOR=0.3
    ENVIRONMENT=""
    ALLOW_PRODUCTION=false
    OUTPUT_FILE=""
    OUTPUT_FORMAT=""
    NO_COLOR=false
    WORK_DIR=""
    EXPORT_TEMP=""
    MYSQL_OUTPUT=""
    MYSQL_ERROR=""
    SERVER_VERSION="Unknown"
    BUFFER_POOL_BYTES=0
    BUFFER_POOL_GB="Unknown"
    DAILY_ROWS=0
    DISPLAY_INPUT=""
    UNIT_DIVISOR=1
    UNIT_LABEL="Day"
    DAILY_TOTAL_COLUMN=""
    SQL_DATABASE=""
    SQL_TABLE_PATTERN=""
    PROJECTION_QUERY=""
}

initialize_colors() {
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_BOLD=""
    COLOR_RESET=""
    if [[ "$NO_COLOR" == false && -t 1 && "${TERM:-dumb}" != dumb ]]; then
        COLOR_RED=$(printf '\033[0;31m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_CYAN=$(printf '\033[0;36m')
        COLOR_GREEN=$(printf '\033[0;32m')
        COLOR_BOLD=$(printf '\033[1m')
        COLOR_RESET=$(printf '\033[0m')
    fi
}

show_help() {
    initialize_colors
    printf '%s%s%s\n\n' "$COLOR_CYAN" 'MySQL Storage and Memory Estimator' "$COLOR_RESET"
    printf '%sUsage:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%s -l LOGIN_PATH -d DATABASE -t PREFIX -r ROWS --environment ENV [OPTIONS]%s\n\n' \
        "$COLOR_CYAN" "$0" "$COLOR_RESET"

    printf '%sRequired options:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-l, --login-path' "$COLOR_RESET" "$COLOR_CYAN" 'NAME' "$COLOR_RESET" 'MySQL login-path for the target server'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-d, --database' "$COLOR_RESET" "$COLOR_CYAN" 'NAME' "$COLOR_RESET" 'Database containing the table family'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-t, --table-prefix' "$COLOR_RESET" "$COLOR_CYAN" 'PREFIX' "$COLOR_RESET" 'Table LIKE prefix; % is appended internally'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-r, --rows' "$COLOR_RESET" "$COLOR_CYAN" 'NUMBER' "$COLOR_RESET" 'Rows inserted per selected time unit'
    printf '  %s%-29s%s %s%-20s%s %s\n\n' "$COLOR_GREEN" '--environment' "$COLOR_RESET" "$COLOR_CYAN" 'ENV' "$COLOR_RESET" 'development, test, staging, or production'

    printf '%sProjection options:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-u, --unit' "$COLOR_RESET" "$COLOR_CYAN" 'hour|day' "$COLOR_RESET" 'Input time unit (default: day)'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-k, --retention' "$COLOR_RESET" "$COLOR_CYAN" 'DAYS' "$COLOR_RESET" 'Retention period (default: 30)'
    printf '  %s%-29s%s %s%-20s%s %s\n\n' "$COLOR_GREEN" '-i, --index-factor' "$COLOR_RESET" "$COLOR_CYAN" '0..1000' "$COLOR_RESET" 'Index-size multiplier, up to 6 decimals (default: 0.3)'

    printf '%sSafety:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '--allow-production' "$COLOR_RESET" "$COLOR_CYAN" '' "$COLOR_RESET" 'Required only when environment is production'
    printf '%s  The estimator executes read-only metadata queries. Prefixes containing %% are rejected;%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '%s  underscores remain active SQL LIKE wildcards.%s\n\n' "$COLOR_YELLOW" "$COLOR_RESET"

    printf '%sOutput and runtime:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '-o, --output-file' "$COLOR_RESET" "$COLOR_CYAN" 'FILE' "$COLOR_RESET" 'Atomic CSV or TSV report'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '--format' "$COLOR_RESET" "$COLOR_CYAN" 'csv|tsv' "$COLOR_RESET" 'Report format; inferred from file extension'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '--mysql-bin' "$COLOR_RESET" "$COLOR_CYAN" 'PATH' "$COLOR_RESET" 'Local MySQL client executable'
    printf '  %s%-29s%s %s%-20s%s %s\n' "$COLOR_GREEN" '--no-color' "$COLOR_RESET" "$COLOR_CYAN" '' "$COLOR_RESET" 'Disable ANSI colors'
    printf '  %s%-29s%s %s%-20s%s %s\n\n' "$COLOR_GREEN" '-h, --help' "$COLOR_RESET" "$COLOR_CYAN" '' "$COLOR_RESET" 'Show this help and exit'

    printf '%sExit status:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s0%s success; %s2%s CLI validation; %s3%s dependency, connection, or report error; %s4%s projection error\n' \
        "$COLOR_GREEN" "$COLOR_RESET" "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_CYAN" "$COLOR_RESET"
    printf '  %s129%s SIGHUP; %s130%s SIGINT or SIGTERM\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_CYAN" "$COLOR_RESET"

    printf '%sExamples:%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '  %s%s -l development-db -d app -t logs_ -r 50000 --environment development%s\n' "$COLOR_CYAN" "$0" "$COLOR_RESET"
    printf '  %s%s -l staging-db -d app -t events_ -r 2500 -u hour -k 15 -i 0.5 --environment staging%s\n' "$COLOR_CYAN" "$0" "$COLOR_RESET"
    printf '  %s%s -l production-db -d app -t audit_ -r 100000 --environment production --allow-production -o storage.csv%s\n' "$COLOR_CYAN" "$0" "$COLOR_RESET"
}

cli_error() {
    printf 'ERROR: %s\nTry --help for usage.\n' "$1" >&2
    exit 2
}

runtime_error() {
    printf 'ERROR: %s\n' "$2" >&2
    exit "$1"
}

require_value() {
    [[ -n "${2-}" && "${2-}" != -* ]] || cli_error "Option $1 requires a value."
}

normalize_positive_integer() {
    local value=$1
    NORMALIZED_INTEGER=""
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "$value" == 0* && ${#value} -gt 1 ]]; do
        value=${value#0}
    done
    [[ "$value" != 0 && ${#value} -le 15 ]] || return 1
    NORMALIZED_INTEGER=$value
}

normalize_index_factor() {
    local value=$1 integer fraction
    NORMALIZED_FACTOR=""
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    case "$value" in
        *.*) integer=${value%%.*}; fraction=${value#*.} ;;
        *) integer=$value; fraction="" ;;
    esac
    while [[ "$integer" == 0* && ${#integer} -gt 1 ]]; do
        integer=${integer#0}
    done
    [[ ${#fraction} -le 6 ]] || return 1
    if [[ ${#integer} -gt 4 || (${#integer} -eq 4 && "$integer" != 1000) ]]; then
        return 1
    fi
    if [[ "$integer" == 1000 && -n "$fraction" && "$fraction" != "${fraction//[!0]/}" ]]; then
        return 1
    fi
    NORMALIZED_FACTOR=$integer
    [[ -z "$fraction" ]] || NORMALIZED_FACTOR="$integer.$fraction"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --login-path=*) LOGIN_PATH=${1#*=}; [[ -n "$LOGIN_PATH" ]] || cli_error 'Option --login-path requires a value.' ;;
            -l|--login-path) require_value "$1" "${2-}"; LOGIN_PATH=$2; shift ;;
            --database=*) DATABASE=${1#*=}; [[ -n "$DATABASE" ]] || cli_error 'Option --database requires a value.' ;;
            -d|--database) require_value "$1" "${2-}"; DATABASE=$2; shift ;;
            --table-prefix=*) TABLE_PREFIX=${1#*=}; [[ -n "$TABLE_PREFIX" ]] || cli_error 'Option --table-prefix requires a value.' ;;
            -t|--table-prefix) require_value "$1" "${2-}"; TABLE_PREFIX=$2; shift ;;
            --rows=*) ROWS=${1#*=}; [[ -n "$ROWS" ]] || cli_error 'Option --rows requires a value.' ;;
            -r|--rows) require_value "$1" "${2-}"; ROWS=$2; shift ;;
            --unit=*) UNIT=${1#*=}; [[ -n "$UNIT" ]] || cli_error 'Option --unit requires a value.' ;;
            -u|--unit) require_value "$1" "${2-}"; UNIT=$2; shift ;;
            --retention=*) RETENTION_DAYS=${1#*=}; [[ -n "$RETENTION_DAYS" ]] || cli_error 'Option --retention requires a value.' ;;
            -k|--retention) require_value "$1" "${2-}"; RETENTION_DAYS=$2; shift ;;
            --index-factor=*) INDEX_FACTOR=${1#*=}; [[ -n "$INDEX_FACTOR" ]] || cli_error 'Option --index-factor requires a value.' ;;
            -i|--index-factor) require_value "$1" "${2-}"; INDEX_FACTOR=$2; shift ;;
            --environment=*) ENVIRONMENT=${1#*=}; [[ -n "$ENVIRONMENT" ]] || cli_error 'Option --environment requires a value.' ;;
            --environment) require_value "$1" "${2-}"; ENVIRONMENT=$2; shift ;;
            --allow-production) ALLOW_PRODUCTION=true ;;
            --output-file=*) OUTPUT_FILE=${1#*=}; [[ -n "$OUTPUT_FILE" ]] || cli_error 'Option --output-file requires a value.' ;;
            -o|--output-file) require_value "$1" "${2-}"; OUTPUT_FILE=$2; shift ;;
            --format=*) OUTPUT_FORMAT=${1#*=}; [[ -n "$OUTPUT_FORMAT" ]] || cli_error 'Option --format requires a value.' ;;
            --format) require_value "$1" "${2-}"; OUTPUT_FORMAT=$2; shift ;;
            --mysql-bin=*) MYSQL_BIN_OPTION=${1#*=}; [[ -n "$MYSQL_BIN_OPTION" ]] || cli_error 'Option --mysql-bin requires a value.' ;;
            --mysql-bin) require_value "$1" "${2-}"; MYSQL_BIN_OPTION=$2; shift ;;
            --no-color) NO_COLOR=true ;;
            --)
                shift
                [[ $# -eq 0 ]] || cli_error "Unexpected argument: $1"
                break
                ;;
            -*) cli_error "Unknown option: $1" ;;
            *) cli_error "Unexpected argument: $1" ;;
        esac
        shift
    done
}

validate_arguments() {
    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
    [[ -n "$DATABASE" ]] || cli_error '--database is required.'
    [[ -n "$TABLE_PREFIX" ]] || cli_error '--table-prefix is required.'
    [[ -n "$ROWS" ]] || cli_error '--rows is required.'
    [[ -n "$ENVIRONMENT" ]] || cli_error '--environment is required.'
    case "$ENVIRONMENT" in development|test|staging|production) : ;; *) cli_error "Invalid environment: $ENVIRONMENT" ;; esac
    if [[ "$ENVIRONMENT" == production && "$ALLOW_PRODUCTION" != true ]]; then
        cli_error 'Production requires --allow-production.'
    fi
    if [[ "$ENVIRONMENT" != production && "$ALLOW_PRODUCTION" == true ]]; then
        cli_error '--allow-production is valid only for production.'
    fi
    [[ ${#DATABASE} -le 64 ]] || cli_error '--database must contain 1 to 64 characters.'
    [[ "$DATABASE" != *' ' ]] || cli_error '--database must not end with a space.'
    if [[ "$DATABASE" =~ [[:cntrl:]] ]]; then
        cli_error '--database must not contain control characters.'
    fi
    [[ "$TABLE_PREFIX" != *%* ]] || cli_error '--table-prefix must not contain %.'
    normalize_positive_integer "$ROWS" || cli_error '--rows must be a positive integer up to 15 digits.'
    ROWS=$NORMALIZED_INTEGER
    normalize_positive_integer "$RETENTION_DAYS" || cli_error '--retention must be a positive integer up to 15 digits.'
    RETENTION_DAYS=$NORMALIZED_INTEGER
    normalize_index_factor "$INDEX_FACTOR" || cli_error '--index-factor must be between 0 and 1000 with at most 6 decimal places.'
    INDEX_FACTOR=$NORMALIZED_FACTOR
    UNIT=$(printf '%s' "$UNIT" | tr '[:upper:]' '[:lower:]')
    case "$UNIT" in hour|day) : ;; *) cli_error '--unit must be hour or day.' ;; esac
    case "$OUTPUT_FORMAT" in ""|csv|tsv) : ;; *) cli_error "Invalid output format: $OUTPUT_FORMAT" ;; esac
    [[ -z "$OUTPUT_FORMAT" || -n "$OUTPUT_FILE" ]] || cli_error '--format requires --output-file.'
    if [[ -n "$OUTPUT_FILE" ]]; then
        [[ ! -d "$OUTPUT_FILE" ]] || cli_error "Output file cannot be a directory: $OUTPUT_FILE"
        local output_parent
        output_parent=$(dirname "$OUTPUT_FILE")
        [[ -d "$output_parent" && -w "$output_parent" ]] || cli_error "Output directory is not writable: $output_parent"
        [[ ! -e "$OUTPUT_FILE" || -w "$OUTPUT_FILE" ]] || cli_error "Output file is not writable: $OUTPUT_FILE"
        if [[ -z "$OUTPUT_FORMAT" ]]; then
            case "$OUTPUT_FILE" in *.tsv) OUTPUT_FORMAT=tsv ;; *) OUTPUT_FORMAT=csv ;; esac
        fi
    fi
}

resolve_mysql_bin() {
    local candidate
    if [[ -n "$MYSQL_BIN_OPTION" ]]; then
        candidate=$MYSQL_BIN_OPTION
    elif [[ -n "$MYSQL_BIN_ENV" ]]; then
        candidate=$MYSQL_BIN_ENV
    else
        candidate=mysql
    fi
    MYSQL_BIN=$(command -v "$candidate" 2>/dev/null || true)
    [[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || runtime_error 3 'MySQL client not found or not executable.'
}

create_workspace() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/estimate-storage.XXXXXX") || runtime_error 3 'Unable to create temporary workspace.'
}

cleanup() {
    [[ -z "${EXPORT_TEMP:-}" ]] || rm -f "$EXPORT_TEMP"
    case "${WORK_DIR:-}" in
        "${TMPDIR:-/tmp}"/estimate-storage.*) rm -rf "$WORK_DIR" ;;
    esac
}

sanitize_mysql_error() {
    local message=$1
    message=$(printf '%s' "$message" | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g')
    message=${message//$'\033'/}
    message=${message//$'\r'/ }
    message=${message//$'\n'/ }
    [[ -n "$message" ]] || message='no diagnostic returned'
    SANITIZED_MYSQL_ERROR=${message:0:240}
}

mysql_capture() {
    local sql=$1
    shift
    MYSQL_OUTPUT=""
    MYSQL_ERROR=""
    if MYSQL_OUTPUT=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" "$@" -e "$sql" 2>"$WORK_DIR/mysql.stderr"); then
        return 0
    fi
    MYSQL_ERROR=$(<"$WORK_DIR/mysql.stderr")
    return 1
}

sql_literal() {
    local hex
    hex=$(printf '%s' "$1" | od -An -tx1 | awk '{ for (i = 1; i <= NF; i++) printf "%s", $i }')
    SQL_LITERAL="CONVERT(X'$hex' USING utf8mb4)"
}

prepare_projection_inputs() {
    if [[ "$UNIT" == hour ]]; then
        DAILY_ROWS=$((ROWS * 24))
        DISPLAY_INPUT="$ROWS/hour"
        UNIT_DIVISOR=24
        UNIT_LABEL="Hour"
        DAILY_TOTAL_COLUMN='ROUND(SUM(daily_data_mb + daily_idx_mb), 2) AS Total_MB_Day,'
    else
        DAILY_ROWS=$ROWS
        DISPLAY_INPUT="$ROWS/day"
        UNIT_DIVISOR=1
        UNIT_LABEL="Day"
        DAILY_TOTAL_COLUMN=""
    fi
    sql_literal "$DATABASE"
    SQL_DATABASE=$SQL_LITERAL
    sql_literal "${TABLE_PREFIX}%"
    SQL_TABLE_PATTERN=$SQL_LITERAL
}

build_projection_query() {
    PROJECTION_QUERY="SELECT /* estimate-storage:projection */
    IFNULL(TABLE_NAME, 'TOTAL') AS Table_Name,
    CAST(SUM(daily_rows) / $UNIT_DIVISOR AS UNSIGNED) AS Rows_$UNIT_LABEL,
    CAST(SUM(daily_rows) * $RETENTION_DAYS AS DECIMAL(65,0)) AS Total_Rows,
    ROUND(SUM(daily_data_mb) / $UNIT_DIVISOR, 4) AS Data_MB_$UNIT_LABEL,
    ROUND(SUM(daily_idx_mb) / $UNIT_DIVISOR, 4) AS Idx_MB_$UNIT_LABEL,
    ROUND(SUM(daily_data_mb + daily_idx_mb) / $UNIT_DIVISOR, 4) AS Total_MB_$UNIT_LABEL,
    $DAILY_TOTAL_COLUMN
    ROUND((SUM(daily_data_mb + daily_idx_mb) * 30) / 1024, 2) AS Total_GB_Month,
    ROUND((SUM(daily_data_mb + daily_idx_mb) * $RETENTION_DAYS) / 1024, 2) AS Retention_GB,
    CONCAT(ROUND(((SUM(daily_data_mb + daily_idx_mb) * $RETENTION_DAYS) * 1024 * 1024 / @@innodb_buffer_pool_size) * 100, 2), '%') AS BP_Pct_Total
FROM (
    SELECT
        TABLE_NAME,
        $DAILY_ROWS AS daily_rows,
        (SUM(col_size) * $DAILY_ROWS * 1.2) / 1024 / 1024 AS daily_data_mb,
        (SUM(col_size) * $DAILY_ROWS * 1.2 * $INDEX_FACTOR) / 1024 / 1024 AS daily_idx_mb
    FROM (
        SELECT
            TABLE_NAME,
            CASE
                WHEN DATA_TYPE IN ('tinyint', 'bool', 'boolean') THEN 1
                WHEN DATA_TYPE = 'smallint' THEN 2
                WHEN DATA_TYPE = 'mediumint' THEN 3
                WHEN DATA_TYPE = 'int' THEN 4
                WHEN DATA_TYPE = 'bigint' THEN 8
                WHEN DATA_TYPE = 'float' THEN 4
                WHEN DATA_TYPE = 'double' THEN 8
                WHEN DATA_TYPE = 'decimal' THEN (NUMERIC_PRECISION / 2) + 1
                WHEN DATA_TYPE = 'date' THEN 3
                WHEN DATA_TYPE IN ('datetime', 'timestamp') THEN 8
                WHEN DATA_TYPE = 'time' THEN 3
                WHEN DATA_TYPE = 'year' THEN 1
                WHEN DATA_TYPE IN ('char', 'varchar', 'binary', 'varbinary') THEN CHARACTER_OCTET_LENGTH
                WHEN DATA_TYPE LIKE '%text%' OR DATA_TYPE LIKE '%blob%' OR DATA_TYPE IN ('json', 'geometry', 'point') THEN 1024
                ELSE 8
            END AS col_size
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = $SQL_DATABASE
          AND TABLE_NAME LIKE $SQL_TABLE_PATTERN
    ) AS col_data
    GROUP BY TABLE_NAME
) AS table_totals
GROUP BY TABLE_NAME WITH ROLLUP;"
}

check_connection() {
    local connection_sql
    connection_sql='SELECT /* estimate-storage:connection */ VERSION(), @@innodb_buffer_pool_size;'
    if ! mysql_capture "$connection_sql" --batch --raw --skip-column-names; then
        sanitize_mysql_error "$MYSQL_ERROR"
        runtime_error 3 "Unable to connect using login path '$LOGIN_PATH': $SANITIZED_MYSQL_ERROR"
    fi
    IFS=$'\t' read -r SERVER_VERSION BUFFER_POOL_BYTES <<EOF
$MYSQL_OUTPUT
EOF
    if [[ "$BUFFER_POOL_BYTES" =~ ^[0-9]+$ && "$BUFFER_POOL_BYTES" -gt 0 ]]; then
        BUFFER_POOL_GB=$(awk "BEGIN { printf \"%.2f\", $BUFFER_POOL_BYTES / 1024 / 1024 / 1024 }")
    else
        BUFFER_POOL_BYTES=0
        BUFFER_POOL_GB="Unknown"
    fi
}

print_summary() {
    printf '%s--------------------------------------------------------------------------------%s\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '%sMySQL Version:%s %s | %sBuffer Pool Size:%s %s GB\n' "$COLOR_YELLOW" "$COLOR_RESET" "$SERVER_VERSION" "$COLOR_YELLOW" "$COLOR_RESET" "$BUFFER_POOL_GB"
    printf '%sTarget DB:%s     %s.%s*\n' "$COLOR_YELLOW" "$COLOR_RESET" "$DATABASE" "$TABLE_PREFIX"
    printf '%sGrowth Rate:%s   %s | %sRetention:%s %s days\n' "$COLOR_YELLOW" "$COLOR_RESET" "$DISPLAY_INPUT" "$COLOR_YELLOW" "$COLOR_RESET" "$RETENTION_DAYS"
    printf '%sIndex Factor:%s  %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$INDEX_FACTOR"
    printf '%s--------------------------------------------------------------------------------%s\n' "$COLOR_CYAN" "$COLOR_RESET"
}

render_terminal_projection() {
    if "$MYSQL_BIN" --login-path="$LOGIN_PATH" --table -e "$PROJECTION_QUERY" --database="$DATABASE" 2>"$WORK_DIR/mysql.stderr"; then
        return 0
    fi
    MYSQL_ERROR=$(<"$WORK_DIR/mysql.stderr")
    sanitize_mysql_error "$MYSQL_ERROR"
    runtime_error 4 "Storage projection failed: $SANITIZED_MYSQL_ERROR"
}

convert_tsv_to_csv() {
    awk -F '\t' '
        {
            for (i = 1; i <= NF; i++) {
                value = $i
                gsub(/"/, "\"\"", value)
                printf "%s\"%s\"", (i == 1 ? "" : ","), value
            }
            printf "\n"
        }
    ' "$1" > "$2"
}

write_report() {
    local output_parent raw_report
    [[ -n "$OUTPUT_FILE" ]] || return 0
    output_parent=$(dirname "$OUTPUT_FILE")
    EXPORT_TEMP=$(mktemp "$output_parent/.estimate-storage.XXXXXX") || runtime_error 3 "Unable to create a temporary report in $output_parent"
    raw_report="$WORK_DIR/report.tsv"
    if ! "$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --column-names -e "$PROJECTION_QUERY" --database="$DATABASE" >"$raw_report" 2>"$WORK_DIR/mysql.stderr"; then
        MYSQL_ERROR=$(<"$WORK_DIR/mysql.stderr")
        sanitize_mysql_error "$MYSQL_ERROR"
        runtime_error 3 "Report query failed: $SANITIZED_MYSQL_ERROR"
    fi
    case "$OUTPUT_FORMAT" in
        csv) convert_tsv_to_csv "$raw_report" "$EXPORT_TEMP" || runtime_error 3 'Unable to convert the report to CSV.' ;;
        tsv) cp "$raw_report" "$EXPORT_TEMP" || runtime_error 3 'Unable to prepare the TSV report.' ;;
    esac
    mv -f "$EXPORT_TEMP" "$OUTPUT_FILE" || runtime_error 3 "Unable to publish report: $OUTPUT_FILE"
    EXPORT_TEMP=""
}

main() {
    initialize_defaults
    local argument
    for argument in "$@"; do
        [[ "$argument" != --no-color ]] || NO_COLOR=true
    done
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi
    parse_arguments "$@"
    validate_arguments
    resolve_mysql_bin
    create_workspace
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT TERM
    initialize_colors
    prepare_projection_inputs
    build_projection_query
    check_connection
    print_summary
    render_terminal_projection
    write_report
    printf '%s--------------------------------------------------------------------------------%s\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '%sDone.%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%sReport written:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$OUTPUT_FILE"
    fi
}

main "$@"
