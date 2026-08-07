#!/usr/bin/env bash
set -euo pipefail

# Sixteen digits permits practical zero-padded values while bounding normalization work.
TERMINAL_WIDTH_RAW_MAX_LENGTH=16

initialize_defaults() {
    MYSQL_BIN_ENV=${MYSQL_BIN:-}
    LOGIN_PATH=""
    DATABASE=""
    TABLE_STRING=""
    TABLE_FILE=""
    PERF_THRESHOLD=500000
    DRIFT_THRESHOLD=10
    REQUESTED_MODE="auto"
    MAX_EXECUTION_TIME_MS=30000
    ANALYZE_TABLE=false
    ENVIRONMENT=""
    OUTPUT_FILE=""
    OUTPUT_FORMAT=""
    MYSQL_BIN_OPTION=""
    TERMINAL_WIDTH_OPTION=""
    MYSQL_BIN=""
    NO_COLOR=false
    TABLE_ARRAY=()
    UNIQUE_TABLES=()
    WORK_DIR=""
    EXPORT_TEMP=""
    FINAL_STATUS=0
    SERVER_VERSION="N/A"
    SERVER_HOSTNAME="N/A"
    TABLES_REQUESTED=0
    TABLES_COMPLETED=0
    TABLES_WARNED=0
    TABLES_FAILED=0
    TABLES_EXACT=0
    TABLES_METADATA=0
    MYSQL_OUTPUT=""
    MYSQL_ERROR=""
    SORT_BY=""
    ORDERED_RESULT_FILE=""
}

initialize_colors() {
    COLOR_RED=""; COLOR_YELLOW=""; COLOR_CYAN=""; COLOR_GREEN=""; COLOR_BOLD=""; COLOR_RESET=""
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
    local help_title help_section help_option help_value help_warning help_error help_reset
    help_title=$(printf '\033[1;36m')
    help_section=$(printf '\033[1;33m')
    help_option=$(printf '\033[0;32m')
    help_value=$(printf '\033[0;36m')
    help_warning=$(printf '\033[0;33m')
    help_error=$(printf '\033[0;31m')
    help_reset=$(printf '\033[0m')

    printf '%s%s%s\n\n' "$help_title" 'MySQL Cardinality Analyzer' "$help_reset"
    printf '%sUsage:%s\n' "$help_section" "$help_reset"
    printf '  %s%s -l LOGIN_PATH -d DATABASE (-t TABLES | -f FILE) [OPTIONS]%s\n\n' \
        "$help_value" "$0" "$help_reset"

    printf '%sRequired:%s\n' "$help_section" "$help_reset"
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '-l, --login-path' "$help_reset" "$help_value" 'PATH' "$help_reset" 'MySQL login-path for the remote server'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '-d, --database' "$help_reset" "$help_value" 'NAME' "$help_reset" 'Database to analyze'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '-t, --tables' "$help_reset" "$help_value" 'LIST' "$help_reset" 'Comma-separated table names'
    printf '  %s%-32s%s %s%-19s%s %s\n\n' "$help_option" '-f, --table-file' "$help_reset" "$help_value" 'FILE' "$help_reset" 'Table names, one per line; comments use #'

    printf '%sAnalysis:%s\n' "$help_section" "$help_reset"
    printf '  %s%-32s%s %s%-19s%s %s%s%s%s\n' "$help_option" '--mode' "$help_reset" "$help_value" 'auto|metadata|exact' "$help_reset" 'Analysis mode (default: ' "$help_value" 'auto' "$help_reset)"
    printf '  %s%-32s%s %s%-19s%s %s%s%s%s\n' "$help_option" '-p, --performance-threshold' "$help_reset" "$help_value" 'ROWS' "$help_reset" 'Maximum estimate eligible for exact auto mode (default: ' "$help_value" '500000' "$help_reset)"
    printf '  %s%-32s%s %s%-19s%s %s%s%s%s\n' "$help_option" '-r, --drift-threshold' "$help_reset" "$help_value" 'PERCENT' "$help_reset" 'Drift warning threshold (default: ' "$help_value" '10' "$help_reset)"
    printf '  %s%-32s%s %s%-19s%s %s%s%s%s\n' "$help_option" '--max-execution-time-ms' "$help_reset" "$help_value" 'MS' "$help_reset" 'Exact-query timeout hint (default: ' "$help_value" '30000' "$help_reset)"
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--analyze-table' "$help_reset" "$help_value" '' "$help_reset" 'Run ANALYZE LOCAL TABLE before collection'
    printf '  %s%-32s%s %s%-19s%s %s\n\n' "$help_option" '--environment' "$help_reset" "$help_value" 'ENV' "$help_reset" 'development, test, staging, or production'

    printf '%sOutput and runtime:%s\n' "$help_section" "$help_reset"
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '-o, --output-file' "$help_reset" "$help_value" 'FILE' "$help_reset" 'Atomic CSV or TSV report'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--format' "$help_reset" "$help_value" 'csv|tsv' "$help_reset" 'Report format; inferred from extension when omitted'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--mysql-bin' "$help_reset" "$help_value" 'PATH' "$help_reset" 'Local MySQL client executable (optional)'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--terminal-width' "$help_reset" "$help_value" 'N' "$help_reset" 'Override terminal width (range: 120-10000)'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--sort-by' "$help_reset" "$help_value" 'cardinality|selectivity' "$help_reset" 'Rank index candidates by metric, descending'
    printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--no-color' "$help_reset" "$help_value" '' "$help_reset" 'Disable ANSI colors'
    printf '  %s%-32s%s %s%-19s%s %s\n\n' "$help_option" '-h, --help' "$help_reset" "$help_value" '' "$help_reset" 'Show this help and exit'

    printf '%sExamples:%s\n' "$help_section" "$help_reset"
    printf '  %s%s -l devel-mysql01 -d app -t users,orders%s\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s --login-path=staging-mysql --database=app --tables=users --mode=metadata%s\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s -l test-mysql -d app -t users --mode exact -o cardinality.csv%s\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s -l test-mysql -d app -t users --analyze-table --environment test%s\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s -l test-mysql -d app -t users --terminal-width 180%s\n\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s -l test-mysql -d app -t users --sort-by cardinality%s\n' "$help_value" "$0" "$help_reset"
    printf '  %s%s -l test-mysql -d app -t users --sort-by selectivity%s\n\n' "$help_value" "$0" "$help_reset"

    printf '%sIndex candidate guidance:%s\n' "$help_section" "$help_reset"
    printf '%s  Metric ranking is guidance only. Validate predicates, joins, ranges, ORDER BY/%s\n' "$help_warning" "$help_reset"
    printf '%s  GROUP BY, covering needs, workload frequency, and the leftmost-prefix rule.%s\n\n' "$help_warning" "$help_reset"

    printf '%sSafety:%s\n' "$help_section" "$help_reset"
    printf '%s  metadata mode never scans user tables. ANALYZE requires explicit development,%s\n' "$help_warning" "$help_reset"
    printf '%s  test, or staging and is always %s%srefused for production%s%s.%s\n' \
        "$help_warning" "$help_reset" "$help_error" "$help_reset" "$help_warning" "$help_reset"
}

cli_error() { printf 'ERROR: %s\nTry --help for usage.\n' "$1" >&2; exit 2; }
runtime_error() { printf 'ERROR: %s\n' "$2" >&2; exit "$1"; }
require_value() { [[ -n "${2-}" && "${2-}" != -* ]] || cli_error "Option $1 requires a value."; }

normalize_terminal_width() {
    NORMALIZED_TERMINAL_WIDTH=$1
    [[ "$NORMALIZED_TERMINAL_WIDTH" =~ ^[0-9]+$ ]] || return 1
    [[ ${#NORMALIZED_TERMINAL_WIDTH} -le "$TERMINAL_WIDTH_RAW_MAX_LENGTH" ]] || return 1
    while [[ "$NORMALIZED_TERMINAL_WIDTH" == 0* && ${#NORMALIZED_TERMINAL_WIDTH} -gt 1 ]]; do
        NORMALIZED_TERMINAL_WIDTH=${NORMALIZED_TERMINAL_WIDTH#0}
    done
    case ${#NORMALIZED_TERMINAL_WIDTH} in
        3)
            case "$NORMALIZED_TERMINAL_WIDTH" in
                12[0-9]|1[3-9][0-9]|[2-9][0-9][0-9]) return 0 ;;
            esac
            ;;
        4) return 0 ;;
        5) [[ "$NORMALIZED_TERMINAL_WIDTH" == 10000 ]] && return 0 ;;
    esac
    return 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --login-path=*) LOGIN_PATH=${1#*=} ;;
            -l|--login-path) require_value "$1" "${2-}"; LOGIN_PATH=$2; shift ;;
            --database=*) DATABASE=${1#*=} ;;
            -d|--database) require_value "$1" "${2-}"; DATABASE=$2; shift ;;
            --tables=*) TABLE_STRING=${1#*=} ;;
            -t|--tables) require_value "$1" "${2-}"; TABLE_STRING=$2; shift ;;
            --table-file=*) TABLE_FILE=${1#*=} ;;
            -f|--table-file) require_value "$1" "${2-}"; TABLE_FILE=$2; shift ;;
            --performance-threshold=*) PERF_THRESHOLD=${1#*=} ;;
            -p|--performance-threshold) require_value "$1" "${2-}"; PERF_THRESHOLD=$2; shift ;;
            --drift-threshold=*) DRIFT_THRESHOLD=${1#*=} ;;
            -r|--drift-threshold) require_value "$1" "${2-}"; DRIFT_THRESHOLD=$2; shift ;;
            --mode=*) REQUESTED_MODE=${1#*=} ;;
            --mode) require_value "$1" "${2-}"; REQUESTED_MODE=$2; shift ;;
            --max-execution-time-ms=*) MAX_EXECUTION_TIME_MS=${1#*=} ;;
            --max-execution-time-ms) require_value "$1" "${2-}"; MAX_EXECUTION_TIME_MS=$2; shift ;;
            --analyze-table) ANALYZE_TABLE=true ;;
            --environment=*) ENVIRONMENT=${1#*=} ;;
            --environment) require_value "$1" "${2-}"; ENVIRONMENT=$2; shift ;;
            --output-file=*) OUTPUT_FILE=${1#*=} ;;
            -o|--output-file) require_value "$1" "${2-}"; OUTPUT_FILE=$2; shift ;;
            --format=*) OUTPUT_FORMAT=${1#*=} ;;
            --format) require_value "$1" "${2-}"; OUTPUT_FORMAT=$2; shift ;;
            --mysql-bin=*) MYSQL_BIN_OPTION=${1#*=} ;;
            --mysql-bin) require_value "$1" "${2-}"; MYSQL_BIN_OPTION=$2; shift ;;
            --terminal-width=*)
                TERMINAL_WIDTH_OPTION=${1#*=}
                [[ -n "$TERMINAL_WIDTH_OPTION" ]] || cli_error "Option --terminal-width requires a value."
                ;;
            --terminal-width)
                require_value "$1" "${2-}"
                TERMINAL_WIDTH_OPTION=$2
                shift
                ;;
            --sort-by=*)
                SORT_BY=${1#*=}
                [[ -n "$SORT_BY" ]] || cli_error "Option --sort-by requires a value."
                ;;
            --sort-by)
                require_value "$1" "${2-}"
                SORT_BY=$2
                shift
                ;;
            --no-color) NO_COLOR=true ;;
            --) shift; break ;;
            -*) cli_error "Unknown option: $1" ;;
            *) cli_error "Unexpected argument: $1" ;;
        esac
        shift
    done
}

validate_arguments() {
    [[ -n "$LOGIN_PATH" ]] || cli_error "--login-path is required."
    [[ -n "$DATABASE" ]] || cli_error "--database is required."
    [[ -n "$TABLE_STRING" || -n "$TABLE_FILE" ]] || cli_error "Provide --tables or --table-file."
    [[ "$PERF_THRESHOLD" =~ ^[0-9]+$ && "$PERF_THRESHOLD" -gt 0 ]] || cli_error "Performance threshold must be a positive integer."
    [[ "$DRIFT_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || cli_error "Drift threshold must be a nonnegative number."
    [[ "$MAX_EXECUTION_TIME_MS" =~ ^[0-9]+$ && "$MAX_EXECUTION_TIME_MS" -gt 0 ]] || cli_error "Execution timeout must be a positive integer."
    if [[ -n "$TERMINAL_WIDTH_OPTION" ]]; then
        normalize_terminal_width "$TERMINAL_WIDTH_OPTION" ||
            cli_error "Terminal width must be an integer from 120 to 10000."
        TERMINAL_WIDTH_OPTION=$NORMALIZED_TERMINAL_WIDTH
    fi
    case "$REQUESTED_MODE" in auto|metadata|exact) : ;; *) cli_error "Invalid mode: $REQUESTED_MODE" ;; esac
    case "$SORT_BY" in ""|cardinality|selectivity) : ;; *) cli_error "Invalid sort field: $SORT_BY" ;; esac
    case "$ENVIRONMENT" in ""|development|test|staging|production) : ;; *) cli_error "Invalid environment: $ENVIRONMENT" ;; esac
    case "$OUTPUT_FORMAT" in ""|csv|tsv) : ;; *) cli_error "Invalid output format: $OUTPUT_FORMAT" ;; esac
    [[ -z "$OUTPUT_FORMAT" || -n "$OUTPUT_FILE" ]] || cli_error "--format requires --output-file."
    [[ -z "$OUTPUT_FILE" || ! -d "$OUTPUT_FILE" ]] || cli_error "Output file cannot be a directory: $OUTPUT_FILE"
    if [[ "$ANALYZE_TABLE" == true ]]; then
        case "$ENVIRONMENT" in
            development|test|staging) : ;;
            production) cli_error "--analyze-table is forbidden for production." ;;
            "") cli_error "--analyze-table requires --environment development|test|staging." ;;
        esac
    fi
    if [[ -n "$TABLE_FILE" ]]; then [[ -f "$TABLE_FILE" && -r "$TABLE_FILE" ]] || cli_error "Table file is not readable: $TABLE_FILE"; fi
    if [[ -n "$OUTPUT_FILE" && -z "$OUTPUT_FORMAT" ]]; then
        case "$OUTPUT_FILE" in *.tsv) OUTPUT_FORMAT=tsv ;; *) OUTPUT_FORMAT=csv ;; esac
    fi
}

resolve_mysql_bin() {
    if [[ -n "$MYSQL_BIN_OPTION" ]]; then MYSQL_BIN=$MYSQL_BIN_OPTION
    elif [[ -n "$MYSQL_BIN_ENV" ]]; then MYSQL_BIN=$MYSQL_BIN_ENV
    else MYSQL_BIN=$(command -v mysql 2>/dev/null || true)
    fi
    [[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || runtime_error 3 "MySQL client not found or not executable."
}

create_workspace() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/check-cardinality.XXXXXX") || runtime_error 3 "Unable to create temporary workspace."
}
cleanup() {
    [[ -z "${EXPORT_TEMP:-}" ]] || rm -f "$EXPORT_TEMP"
    case "${WORK_DIR:-}" in "${TMPDIR:-/tmp}"/check-cardinality.*) rm -rf "$WORK_DIR" ;; esac
}

trim() { TRIMMED=$(printf '%s' "$1" | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'); }
build_table_list() {
    local item line list_file="$WORK_DIR/tables.all"
    : > "$list_file"
    if [[ -n "$TABLE_STRING" ]]; then
        while IFS= read -r item; do trim "$item"; [[ -z "$TRIMMED" ]] || printf '%s\n' "$TRIMMED" >> "$list_file"; done <<EOF
$(printf '%s' "$TABLE_STRING" | tr ',' '\n')
EOF
    fi
    if [[ -n "$TABLE_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            trim "$line"; [[ -z "$TRIMMED" || "$TRIMMED" == \#* ]] || printf '%s\n' "$TRIMMED" >> "$list_file"
        done < "$TABLE_FILE"
    fi
    sort -u "$list_file" > "$WORK_DIR/tables.unique"
    while IFS= read -r item || [[ -n "$item" ]]; do [[ -z "$item" ]] || UNIQUE_TABLES+=("$item"); done < "$WORK_DIR/tables.unique"
    [[ ${#UNIQUE_TABLES[@]} -gt 0 ]] || cli_error "No valid tables were provided."
    TABLES_REQUESTED=${#UNIQUE_TABLES[@]}
}

sql_literal() {
    local hex
    hex=$(printf '%s' "$1" | od -An -tx1 | awk '{for (i=1; i<=NF; i++) printf "%s", $i}')
    SQL_LITERAL="CONVERT(X'$hex' USING utf8mb4)"
}
quote_identifier() { QUOTED_IDENTIFIER=$(printf '%s' "$1" | sed 's/`/``/g'); QUOTED_IDENTIFIER="\`$QUOTED_IDENTIFIER\`"; }

mysql_query() {
    local sql=$1 stderr_file="$WORK_DIR/mysql.stderr"
    MYSQL_OUTPUT=""; MYSQL_ERROR=""
    if MYSQL_OUTPUT=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names -e "$sql" 2>"$stderr_file"); then return 0; fi
    MYSQL_ERROR=$(<"$stderr_file"); return 1
}
mysql_query_headers() {
    local sql=$1 stderr_file="$WORK_DIR/mysql.stderr"
    MYSQL_OUTPUT=""; MYSQL_ERROR=""
    if MYSQL_OUTPUT=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --column-names -e "$sql" 2>"$stderr_file"); then return 0; fi
    MYSQL_ERROR=$(<"$stderr_file"); return 1
}

check_connection() {
    if ! mysql_query "SELECT /* cardinality:connection */ 1, VERSION(), @@hostname;"; then runtime_error 3 "Unable to connect using login path '$LOGIN_PATH': $MYSQL_ERROR"; fi
    SERVER_VERSION=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $2}')
    SERVER_HOSTNAME=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $3}')
}

run_analyze_table() {
    local table=$1 row msg_type msg_text ok=true
    quote_identifier "$DATABASE"; local qdb=$QUOTED_IDENTIFIER
    quote_identifier "$table"; local qtable=$QUOTED_IDENTIFIER
    if ! mysql_query "ANALYZE LOCAL TABLE $qdb.$qtable;"; then printf '%sERROR%s: ANALYZE failed for %s.%s: %s\n' "$COLOR_RED" "$COLOR_RESET" "$DATABASE" "$table" "$MYSQL_ERROR" >&2; return 1; fi
    while IFS=$'\t' read -r _ _ msg_type msg_text; do
        printf 'ANALYZE: %s - %s\n' "$msg_type" "$msg_text"
        [[ "$(printf '%s' "$msg_type" | tr '[:upper:]' '[:lower:]')" == status && "$(printf '%s' "$msg_text" | tr '[:lower:]' '[:upper:]')" == OK ]] || ok=false
    done <<EOF
$MYSQL_OUTPUT
EOF
    [[ "$ok" == true ]]
}

load_table_metadata() {
    local table=$1 sql
    sql_literal "$DATABASE"; local ldb=$SQL_LITERAL
    sql_literal "$table"; local ltable=$SQL_LITERAL
    sql="SELECT /* cardinality:table_metadata */ ENGINE, COALESCE(CAST(TABLE_ROWS AS CHAR), 'NULL') FROM information_schema.TABLES WHERE TABLE_SCHEMA=$ldb AND TABLE_NAME=$ltable;"
    mysql_query "$sql" || return 1
    [[ -n "$MYSQL_OUTPUT" ]] || { MYSQL_ERROR="Table not found or inaccessible"; return 1; }
    TABLE_ENGINE=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $1}')
    ESTIMATED_ROWS=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $2}')
    [[ "$ESTIMATED_ROWS" != NULL && -n "$ESTIMATED_ROWS" ]] || ESTIMATED_ROWS=N/A
}

load_column_metadata() {
    local table=$1 sql
    sql_literal "$DATABASE"; local ldb=$SQL_LITERAL
    sql_literal "$table"; local ltable=$SQL_LITERAL
    sql="SET SESSION group_concat_max_len=@@max_allowed_packet;
WITH index_sizes AS (
  SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COUNT(*) AS index_columns
  FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA=$ldb AND TABLE_NAME=$ltable
  GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
), ranked AS (
  SELECT s.COLUMN_NAME, s.CARDINALITY, s.INDEX_NAME, s.NON_UNIQUE,
         s.SEQ_IN_INDEX, z.index_columns,
         ROW_NUMBER() OVER (PARTITION BY s.COLUMN_NAME ORDER BY
           CASE WHEN s.SEQ_IN_INDEX=1 AND z.index_columns=1 AND s.NON_UNIQUE=0 THEN 1
                WHEN s.SEQ_IN_INDEX=1 AND z.index_columns=1 THEN 2
                WHEN s.SEQ_IN_INDEX=1 THEN 3 ELSE 4 END,
           CASE WHEN s.INDEX_NAME='PRIMARY' THEN 0 ELSE 1 END, s.INDEX_NAME) AS rn
  FROM information_schema.STATISTICS s JOIN index_sizes z
    ON z.TABLE_SCHEMA=s.TABLE_SCHEMA AND z.TABLE_NAME=s.TABLE_NAME AND z.INDEX_NAME=s.INDEX_NAME
), index_lists AS (
  SELECT COLUMN_NAME, GROUP_CONCAT(CONCAT(INDEX_NAME,'(#',SEQ_IN_INDEX,')') ORDER BY INDEX_NAME,SEQ_IN_INDEX SEPARATOR ', ') AS indexes
  FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=$ldb AND TABLE_NAME=$ltable GROUP BY COLUMN_NAME
)
SELECT /* cardinality:column_metadata */ c.COLUMN_NAME, c.COLUMN_TYPE, c.DATA_TYPE, c.IS_NULLABLE,
       CASE WHEN r.SEQ_IN_INDEX=1 THEN COALESCE(CAST(r.CARDINALITY AS CHAR),'N/A') ELSE 'N/A' END,
       CASE WHEN r.SEQ_IN_INDEX=1 THEN r.INDEX_NAME ELSE 'N/A' END,
       CASE WHEN r.SEQ_IN_INDEX<>1 OR r.SEQ_IN_INDEX IS NULL THEN 'UNAVAILABLE'
            WHEN r.index_columns=1 AND r.INDEX_NAME='PRIMARY' THEN 'PRIMARY_SINGLE'
            WHEN r.index_columns=1 AND r.NON_UNIQUE=0 THEN 'UNIQUE_SINGLE'
            WHEN r.index_columns=1 THEN 'LEADING_SINGLE' ELSE 'LEADING_COMPOSITE' END,
       COALESCE(r.index_columns,0), COALESCE(i.indexes,'---')
FROM information_schema.COLUMNS c
LEFT JOIN ranked r ON r.COLUMN_NAME=c.COLUMN_NAME AND r.rn=1
LEFT JOIN index_lists i ON i.COLUMN_NAME=c.COLUMN_NAME
WHERE c.TABLE_SCHEMA=$ldb AND c.TABLE_NAME=$ltable ORDER BY c.ORDINAL_POSITION;"
    mysql_query "$sql"
}

choose_effective_mode() {
    case "$REQUESTED_MODE" in
        exact|metadata) EFFECTIVE_MODE=$REQUESTED_MODE ;;
        auto) if [[ "$ESTIMATED_ROWS" =~ ^[0-9]+$ && "$ESTIMATED_ROWS" -le "$PERF_THRESHOLD" ]]; then EFFECTIVE_MODE=exact; else EFFECTIVE_MODE=metadata; fi ;;
    esac
}

calculate_metrics() {
    local card=$1 denominator=$2
    if [[ "$card" =~ ^[0-9]+$ && "$denominator" =~ ^[0-9]+$ && "$denominator" -gt 0 ]]; then
        METRICS=$(awk -v c="$card" -v d="$denominator" 'BEGIN { printf "%.4f\t%.2f", c/d, (c/d)*100 }')
        RATIO=${METRICS%%$'\t'*}; SELECTIVITY_PCT=${METRICS#*$'\t'}
    else RATIO=N/A; SELECTIVITY_PCT=N/A
    fi
}
calculate_drift() {
    local exact=$1 estimate=$2
    if [[ ! "$estimate" =~ ^[0-9]+$ ]]; then DRIFT_PCT=N/A; return; fi
    DRIFT_PCT=$(awk -v exact="$exact" -v estimate="$estimate" 'BEGIN { if (exact==0) {printf "0.00"; exit} d=exact-estimate; if(d<0)d=-d; printf "%.2f",(d/exact)*100 }')
}
drift_exceeds_threshold() { awk -v d="$1" -v t="$DRIFT_THRESHOLD" 'BEGIN { exit !(d>t) }'; }

run_exact_count() {
    local table=$1 sql
    quote_identifier "$DATABASE"; local qdb=$QUOTED_IDENTIFIER
    quote_identifier "$table"; local qtable=$QUOTED_IDENTIFIER
    sql="EXPLAIN SELECT /*+ MAX_EXECUTION_TIME($MAX_EXECUTION_TIME_MS) */ /* cardinality:count_explain */ COUNT(*) FROM $qdb.$qtable;"
    if mysql_query_headers "$sql"; then
        COUNT_ACCESS=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {for(i=1;i<=NF;i++){if($i=="type")t=i;if($i=="key")k=i}} NR==2 {if(t)type=$t;if(k)key=$k} END{print (type==""?"N/A":type) "\t" (key==""||key=="NULL"?"N/A":key)}')
        COUNT_INDEX=${COUNT_ACCESS#*$'\t'}; COUNT_ACCESS=${COUNT_ACCESS%%$'\t'*}
    else COUNT_ACCESS=N/A; COUNT_INDEX=N/A
    fi
    sql="SELECT /*+ MAX_EXECUTION_TIME($MAX_EXECUTION_TIME_MS) */ /* cardinality:exact_count */ COUNT(*) FROM $qdb.$qtable;"
    mysql_query "$sql" || return 1
    EXACT_ROWS=$(printf '%s\n' "$MYSQL_OUTPUT" | awk 'NR==1 {print $1}')
    [[ "$EXACT_ROWS" =~ ^[0-9]+$ ]]
}

build_eligibility_predicate() {
    local quoted_column=$1 data_type=$2
    case "$data_type" in
        char|varchar|tinytext|text|mediumtext|longtext|binary|varbinary|tinyblob|blob|mediumblob|longblob)
            ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL AND OCTET_LENGTH($quoted_column) > 0" ;;
        date|datetime|timestamp)
            ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL AND CAST($quoted_column AS CHAR) NOT LIKE '0000-00-00%'" ;;
        *) ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL" ;;
    esac
}

append_result() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >> "$RESULT_FILE"; }

analyze_columns() {
    local table=$1 column column_type data_type nullable metadata_card source_index key_kind index_columns existing_indexes
    local eligible card source status error qcol qdb qtable sql value
    RESULT_FILE="$WORK_DIR/results.$TABLES_COMPLETED.tsv"; : > "$RESULT_FILE"
    while IFS=$'\t' read -r column column_type data_type nullable metadata_card source_index key_kind index_columns existing_indexes; do
        [[ -n "$column" ]] || continue
        eligible=$ESTIMATED_ROWS; card=$metadata_card; source=metadata; status=OK; error=""
        if [[ "$EFFECTIVE_MODE" == exact ]]; then
            source=exact
            if [[ "$key_kind" == PRIMARY_SINGLE || ( "$key_kind" == UNIQUE_SINGLE && "$nullable" == NO ) ]]; then
                eligible=$EXACT_ROWS; card=$EXACT_ROWS; source=exact_key_shortcut
            else
                quote_identifier "$column"; qcol=$QUOTED_IDENTIFIER
                quote_identifier "$DATABASE"; qdb=$QUOTED_IDENTIFIER
                quote_identifier "$table"; qtable=$QUOTED_IDENTIFIER
                if [[ "$key_kind" == UNIQUE_SINGLE && "$nullable" == YES ]]; then
                    sql="SELECT /*+ MAX_EXECUTION_TIME($MAX_EXECUTION_TIME_MS) */ /* cardinality:exact_unique_nullable */ COUNT($qcol) FROM $qdb.$qtable;"
                    if mysql_query "$sql"; then value=$(printf '%s\n' "$MYSQL_OUTPUT" | awk 'NR==1 {print $1}'); eligible=$value; card=$value; source=exact_unique_nullable
                    else eligible=N/A; card=N/A; status=ERROR; error=$MYSQL_ERROR; FINAL_STATUS=4; fi
                else
                    build_eligibility_predicate "$qcol" "$data_type"
                    sql="SELECT /*+ MAX_EXECUTION_TIME($MAX_EXECUTION_TIME_MS) */ /* cardinality:exact_column */ COUNT(DISTINCT CASE WHEN $ELIGIBILITY_PREDICATE THEN $qcol END), COUNT(CASE WHEN $ELIGIBILITY_PREDICATE THEN 1 END) FROM $qdb.$qtable;"
                    if mysql_query "$sql"; then card=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $1}'); eligible=$(printf '%s\n' "$MYSQL_OUTPUT" | awk -F '\t' 'NR==1 {print $2}')
                    else eligible=N/A; card=N/A; status=ERROR; error=$MYSQL_ERROR; FINAL_STATUS=4; fi
                fi
            fi
        elif [[ "$key_kind" == UNAVAILABLE ]]; then source=UNAVAILABLE; source_index=N/A; eligible=$ESTIMATED_ROWS; card=N/A; status=WARNING
        fi
        calculate_metrics "$card" "$eligible"
        append_result "$column" "$column_type" "$nullable" "$eligible" "$card" "$RATIO" "$SELECTIVITY_PCT" "$source" "$source_index" "$existing_indexes" "$status|$error"
    done <<EOF
$COLUMN_METADATA
EOF
}

prepare_ordered_results() {
    local sorted_file awk_program tab
    ORDERED_RESULT_FILE=$RESULT_FILE
    [[ -n "$SORT_BY" ]] || return 0

    sorted_file="$WORK_DIR/results.sorted.$TABLES_COMPLETED.tsv"
    tab=$'\t'
    awk_program='
function metric_key(value, scale, force_error,    parts, part_count, integer, fraction) {
    if (force_error) return "2\t0\t0"
    if (value !~ /^[0-9]+([.][0-9]+)?$/) return "1\t0\t0"
    part_count = split(value, parts, ".")
    integer = parts[1]
    sub(/^0+/, "", integer)
    if (integer == "") integer = "0"
    fraction = (part_count > 1 ? parts[2] : "")
    while (length(fraction) < scale) fraction = fraction "0"
    fraction = substr(fraction, 1, scale)
    return "0\t" length(integer) "\t" integer fraction
}
{
    split($11, status_parts, "|")
    force_error = (status_parts[1] == "ERROR")
    if (sort_by == "cardinality") {
        primary = metric_key($5, 0, force_error)
        secondary = metric_key($7, 2, force_error)
    } else {
        primary = metric_key($7, 2, force_error)
        secondary = metric_key($5, 0, force_error)
    }
    print primary "\t" secondary "\t" NR "\t" $0
}'

    if ! LC_ALL=C awk -F "$tab" -v sort_by="$SORT_BY" "$awk_program" "$RESULT_FILE" |
        LC_ALL=C sort -t "$tab" -k1,1n -k2,2nr -k3,3r -k4,4n -k5,5nr -k6,6r -k7,7n |
        cut -f8- > "$sorted_file"; then
        rm -f "$sorted_file"
        runtime_error 3 "Unable to order cardinality results by $SORT_BY."
    fi
    ORDERED_RESULT_FILE=$sorted_file
}

truncate_text() { local text=$1 width=$2; if [[ ${#text} -le $width ]]; then TRUNCATED=$text; elif [[ $width -le 3 ]]; then TRUNCATED=$(printf '%s' "$text" | awk -v w="$width" '{print substr($0,1,w)}'); else TRUNCATED=$(printf '%s' "$text" | awk -v w="$width" '{print substr($0,1,w-3) "..."}'); fi; }
normalize_display_type() {
    local raw_type=$1 lower_type
    lower_type=$(printf '%s' "$raw_type" | tr '[:upper:]' '[:lower:]')
    case "$lower_type" in
        enum\(*) DISPLAY_TYPE=ENUM ;;
        *) DISPLAY_TYPE=$raw_type ;;
    esac
}
wrap_type() {
    local text=$1 width=$2 awk_program
    awk_program='
{ text = $0 }
END {
    rest = text
    while (length(rest) > width) {
        cut = width
        for (i = width; i >= 1; i--) {
            if (substr(rest, i, 1) == ",") { cut = i; break }
        }
        print substr(rest, 1, cut)
        rest = substr(rest, cut + 1)
    }
    print rest
}'
    WRAPPED_TEXT=$(printf '%s\n' "$text" | awk -v width="$width" "$awk_program")
}

wrap_indexes() {
    local text=$1 width=$2 awk_program
    awk_program='
function emit_long(value,    chunk) {
    while (length(value) > width) {
        print substr(value, 1, width)
        value = substr(value, width + 1)
    }
    return value
}
{ text = $0 }
END {
    count = split(text, items, /, /)
    line = ""
    for (n = 1; n <= count; n++) {
        entry = items[n] (n < count ? "," : "")
        if (length(entry) > width) {
            if (line != "") { print line; line = "" }
            entry = emit_long(entry)
        }
        if (entry == "") continue
        candidate = (line == "" ? entry : line " " entry)
        if (length(candidate) <= width) line = candidate
        else { if (line != "") print line; line = entry }
    }
    if (line != "" || text == "") print line
}'
    WRAPPED_TEXT=$(printf '%s\n' "$text" | awk -v width="$width" "$awk_program")
}

pop_wrapped_line() {
    local queue=$1
    case "$queue" in
        *$'\n'*)
            WRAPPED_HEAD=${queue%%$'\n'*}
            WRAPPED_TAIL=${queue#*$'\n'}
            ;;
        *)
            WRAPPED_HEAD=$queue
            WRAPPED_TAIL=""
            ;;
    esac
}

render_report_line() {
    RENDERED_LINE=$(printf "%-${COLUMN_WIDTH}s | %-${TYPE_WIDTH}s | %${ELIGIBLE_WIDTH}s | %${CARDINALITY_WIDTH}s | %${RATIO_WIDTH}s | %${SELECTIVITY_WIDTH}s | %-${SOURCE_WIDTH}s | %-${INDEXES_WIDTH}s" \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")
}

valid_automatic_width() {
    normalize_terminal_width "$1"
}

read_stty_columns() {
    local size="" stty_rows=""
    DETECTED_COLUMNS=""
    if [[ -t 0 ]]; then
        size=$(stty size 2>/dev/null || true)
    elif [[ -t 1 ]]; then
        size=$(stty size 2>/dev/null </dev/tty || true)
    fi
    if [[ -n "$size" ]]; then
        read -r stty_rows DETECTED_COLUMNS <<EOF
$size
EOF
    fi
}

refresh_terminal_width() {
    local cols=""
    TERM_WIDTH=120

    if [[ -n "$TERMINAL_WIDTH_OPTION" ]]; then
        TERM_WIDTH=$TERMINAL_WIDTH_OPTION
        return 0
    fi

    read_stty_columns
    if valid_automatic_width "$DETECTED_COLUMNS"; then
        TERM_WIDTH=$NORMALIZED_TERMINAL_WIDTH
        return 0
    fi

    cols=${COLUMNS:-}
    if valid_automatic_width "$cols"; then
        TERM_WIDTH=$NORMALIZED_TERMINAL_WIDTH
        return 0
    fi

    cols=$(tput cols 2>/dev/null || true)
    if valid_automatic_width "$cols"; then TERM_WIDTH=$NORMALIZED_TERMINAL_WIDTH; fi
    return 0
}

calculate_report_widths() {
    local max_column=0 max_type=4 name type nullable eligible card ratio pct
    local source source_index indexes status_error name_length type_length text_budget desired_column
    local pct_display indexes_shortage reducible reduction metric_length

    ELIGIBLE_WIDTH=8
    CARDINALITY_WIDTH=11
    RATIO_WIDTH=6
    SELECTIVITY_WIDTH=8

    while IFS=$'\t' read -r name type nullable eligible card ratio pct source source_index indexes status_error; do
        normalize_display_type "$type"
        type_length=${#DISPLAY_TYPE}
        [[ "$type_length" -le "$max_type" ]] || max_type=$type_length
        name_length=${#name}
        if [[ "$name_length" -gt "$max_column" ]]; then max_column=$name_length; fi
        [[ ${#eligible} -le $ELIGIBLE_WIDTH ]] || ELIGIBLE_WIDTH=${#eligible}
        [[ ${#card} -le $CARDINALITY_WIDTH ]] || CARDINALITY_WIDTH=${#card}
        metric_length=${#ratio}
        [[ "$metric_length" -le 8 ]] || metric_length=8
        [[ "$metric_length" -le "$RATIO_WIDTH" ]] || RATIO_WIDTH=$metric_length
        if [[ "$pct" == N/A ]]; then pct_display=$pct; else pct_display="${pct}%"; fi
        metric_length=${#pct_display}
        [[ "$metric_length" -le 10 ]] || metric_length=10
        [[ "$metric_length" -le "$SELECTIVITY_WIDTH" ]] || SELECTIVITY_WIDTH=$metric_length
    done < "$RESULT_FILE"

    TYPE_WIDTH=12
    [[ "$max_type" -le "$TYPE_WIDTH" ]] || TYPE_WIDTH=$max_type
    SOURCE_WIDTH=10
    desired_column=24
    if [[ "$max_column" -gt "$desired_column" ]]; then desired_column=$max_column; fi
    [[ "$desired_column" -le 32 ]] || desired_column=32

    text_budget=$((TERM_WIDTH - 21 - ELIGIBLE_WIDTH - CARDINALITY_WIDTH - RATIO_WIDTH - SELECTIVITY_WIDTH))
    COLUMN_WIDTH=$desired_column
    INDEXES_WIDTH=$((text_budget - TYPE_WIDTH - SOURCE_WIDTH - COLUMN_WIDTH))
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((TYPE_WIDTH - 8))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        TYPE_WIDTH=$((TYPE_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((COLUMN_WIDTH - 8))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        COLUMN_WIDTH=$((COLUMN_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((TYPE_WIDTH - 8))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        TYPE_WIDTH=$((TYPE_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((SOURCE_WIDTH - 6))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        SOURCE_WIDTH=$((SOURCE_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((COLUMN_WIDTH - 3))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        COLUMN_WIDTH=$((COLUMN_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((TYPE_WIDTH - 3))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        TYPE_WIDTH=$((TYPE_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        indexes_shortage=$((12 - INDEXES_WIDTH))
        reducible=$((SOURCE_WIDTH - 3))
        reduction=$indexes_shortage
        [[ "$reduction" -le "$reducible" ]] || reduction=$reducible
        SOURCE_WIDTH=$((SOURCE_WIDTH - reduction))
        INDEXES_WIDTH=$((INDEXES_WIDTH + reduction))
    fi
    [[ "$INDEXES_WIDTH" -ge 12 ]] || INDEXES_WIDTH=12
}

compact_source_label() {
    case "$1" in
        exact_key_shortcut) DISPLAY_SOURCE=exact/key ;;
        exact_unique_nullable) DISPLAY_SOURCE=exact/uniq ;;
        exact) DISPLAY_SOURCE=exact ;;
        metadata) DISPLAY_SOURCE=metadata ;;
        UNAVAILABLE) DISPLAY_SOURCE=unavail ;;
        *) DISPLAY_SOURCE=$1 ;;
    esac
}

compact_derived_metric() {
    local value=$1 suffix=$2 width=$3
    DISPLAY_METRIC="${value}${suffix}"
    if [[ ${#DISPLAY_METRIC} -gt "$width" && "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        DISPLAY_METRIC=$(awk -v value="$value" -v suffix="$suffix" 'BEGIN {printf "%.2e%s", value, suffix}')
    fi
    if [[ ${#DISPLAY_METRIC} -gt "$width" && "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        DISPLAY_METRIC=$(awk -v value="$value" -v suffix="$suffix" 'BEGIN {printf "%.1e%s", value, suffix}')
    fi
    if [[ ${#DISPLAY_METRIC} -gt "$width" ]]; then
        truncate_text "$DISPLAY_METRIC" "$width"
        DISPLAY_METRIC=$TRUNCATED
    fi
}

format_table_report() {
    local table=$1 row_color line column type nullable eligible card ratio pct source source_index indexes status_error status error drift_display
    local type_lines index_lines type_queue index_queue type_fragment index_fragment first_line
    refresh_terminal_width
    calculate_report_widths
    printf '\n%sTABLE%s: %s.%s\n' "$COLOR_BOLD" "$COLOR_RESET" "$DATABASE" "$table"
    if [[ "$DRIFT_PCT" == N/A ]]; then drift_display=N/A; else drift_display="${DRIFT_PCT}%"; fi
    printf 'Engine: %s | Requested: %s | Effective: %s | Estimated rows: %s | Exact rows: %s | Drift: %s | Count access/key: %s/%s\n' "$TABLE_ENGINE" "$REQUESTED_MODE" "$EFFECTIVE_MODE" "$ESTIMATED_ROWS" "$EXACT_ROWS" "$drift_display" "$COUNT_ACCESS" "$COUNT_INDEX"
    render_report_line COLUMN TYPE ELIGIBLE CARDINALITY RATIO SELECT. SOURCE INDEXES
    line=$RENDERED_LINE
    printf '%s%s%s\n' "$COLOR_BOLD" "$line" "$COLOR_RESET"
    while IFS=$'\t' read -r column type nullable eligible card ratio pct source source_index indexes status_error; do
        status=${status_error%%|*}; error=${status_error#*|}
        normalize_display_type "$type"
        wrap_type "$DISPLAY_TYPE" "$TYPE_WIDTH"
        type_lines=$WRAPPED_TEXT
        wrap_indexes "$indexes" "$INDEXES_WIDTH"
        index_lines=$WRAPPED_TEXT
        truncate_text "$column" "$COLUMN_WIDTH"; column=$TRUNCATED
        compact_source_label "$source"; truncate_text "$DISPLAY_SOURCE" "$SOURCE_WIDTH"; source=$TRUNCATED
        compact_derived_metric "$ratio" "" "$RATIO_WIDTH"; ratio=$DISPLAY_METRIC
        if [[ "$pct" == N/A ]]; then
            compact_derived_metric "$pct" "" "$SELECTIVITY_WIDTH"
        else
            compact_derived_metric "$pct" "%" "$SELECTIVITY_WIDTH"
        fi
        pct=$DISPLAY_METRIC
        case "$status" in ERROR) row_color=$COLOR_RED ;; WARNING) row_color=$COLOR_YELLOW ;; *) [[ "$EFFECTIVE_MODE" == exact ]] && row_color=$COLOR_GREEN || row_color=$COLOR_CYAN ;; esac
        type_queue=$type_lines
        index_queue=$index_lines
        first_line=true
        while [[ -n "$type_queue" || -n "$index_queue" || "$first_line" == true ]]; do
            pop_wrapped_line "$type_queue"
            type_fragment=$WRAPPED_HEAD
            type_queue=$WRAPPED_TAIL
            pop_wrapped_line "$index_queue"
            index_fragment=$WRAPPED_HEAD
            index_queue=$WRAPPED_TAIL

            if [[ "$first_line" == true ]]; then
                render_report_line "$column" "$type_fragment" "$eligible" "$card" "$ratio" "$pct" "$source" "$index_fragment"
                first_line=false
            else
                render_report_line "" "$type_fragment" "" "" "" "" "" "$index_fragment"
            fi
            printf '%s%s%s\n' "$row_color" "$RENDERED_LINE" "$COLOR_RESET"
        done
        [[ -z "$error" ]] || printf '%s  Error: %s%s\n' "$COLOR_RED" "$error" "$COLOR_RESET"
    done < "$ORDERED_RESULT_FILE"
}

csv_escape() {
    CSV_ESCAPED=${1//\"/\"\"}
    CSV_ESCAPED="\"$CSV_ESCAPED\""
}
tsv_sanitize() { TSV_SANITIZED=$(printf '%s' "$1" | tr '\t\r\n' '   '); }
export_row() {
    local first=true value
    if [[ "$OUTPUT_FORMAT" == csv ]]; then
        for value in "$@"; do csv_escape "$value"; [[ "$first" == true ]] || printf ',' >> "$EXPORT_TEMP"; printf '%s' "$CSV_ESCAPED" >> "$EXPORT_TEMP"; first=false; done
    else
        for value in "$@"; do tsv_sanitize "$value"; [[ "$first" == true ]] || printf '\t' >> "$EXPORT_TEMP"; printf '%s' "$TSV_SANITIZED" >> "$EXPORT_TEMP"; first=false; done
    fi
    printf '\n' >> "$EXPORT_TEMP"
}
initialize_export() {
    [[ -n "$OUTPUT_FILE" ]] || return 0
    local output_dir; output_dir=$(dirname "$OUTPUT_FILE")
    [[ -d "$output_dir" && -w "$output_dir" ]] || runtime_error 3 "Output directory is not writable: $output_dir"
    EXPORT_TEMP=$(mktemp "$output_dir/.check-cardinality.XXXXXX") || runtime_error 3 "Unable to create report temporary file."
    export_row database table engine requested_mode effective_mode estimated_rows exact_rows drift_pct column data_type nullable eligible_rows cardinality ratio selectivity_pct source source_index existing_indexes status error
}
append_export_results() {
    [[ -n "$OUTPUT_FILE" ]] || return 0
    local table=$1 column type nullable eligible card ratio pct source source_index indexes status_error status error
    while IFS=$'\t' read -r column type nullable eligible card ratio pct source source_index indexes status_error; do
        status=${status_error%%|*}; error=${status_error#*|}
        export_row "$DATABASE" "$table" "$TABLE_ENGINE" "$REQUESTED_MODE" "$EFFECTIVE_MODE" "$ESTIMATED_ROWS" "$EXACT_ROWS" "$DRIFT_PCT" "$column" "$type" "$nullable" "$eligible" "$card" "$ratio" "$pct" "$source" "$source_index" "$indexes" "$status" "$error"
    done < "$ORDERED_RESULT_FILE"
}

process_table() {
    local table=$1 warned=false
    if [[ "$ANALYZE_TABLE" == true ]] && ! run_analyze_table "$table"; then TABLES_FAILED=$((TABLES_FAILED + 1)); FINAL_STATUS=4; return; fi
    if ! load_table_metadata "$table"; then printf '%sERROR%s: %s.%s: %s\n' "$COLOR_RED" "$COLOR_RESET" "$DATABASE" "$table" "$MYSQL_ERROR" >&2; TABLES_FAILED=$((TABLES_FAILED + 1)); FINAL_STATUS=4; return; fi
    choose_effective_mode
    EXACT_ROWS=N/A; DRIFT_PCT=N/A; COUNT_ACCESS=N/A; COUNT_INDEX=N/A
    if [[ "$EFFECTIVE_MODE" == exact ]]; then
        TABLES_EXACT=$((TABLES_EXACT + 1))
        if ! run_exact_count "$table"; then printf '%sERROR%s: exact count failed for %s.%s: %s\n' "$COLOR_RED" "$COLOR_RESET" "$DATABASE" "$table" "$MYSQL_ERROR" >&2; TABLES_FAILED=$((TABLES_FAILED + 1)); FINAL_STATUS=4; return; fi
        calculate_drift "$EXACT_ROWS" "$ESTIMATED_ROWS"
        if [[ "$DRIFT_PCT" != N/A ]] && drift_exceeds_threshold "$DRIFT_PCT"; then warned=true; printf '%sWARNING%s: row-estimate drift %s%% exceeds %s%%; consider guarded ANALYZE.\n' "$COLOR_YELLOW" "$COLOR_RESET" "$DRIFT_PCT" "$DRIFT_THRESHOLD"; fi
    else TABLES_METADATA=$((TABLES_METADATA + 1))
    fi
    if ! load_column_metadata "$table"; then printf '%sERROR%s: column metadata failed for %s.%s: %s\n' "$COLOR_RED" "$COLOR_RESET" "$DATABASE" "$table" "$MYSQL_ERROR" >&2; TABLES_FAILED=$((TABLES_FAILED + 1)); FINAL_STATUS=4; return; fi
    COLUMN_METADATA=$MYSQL_OUTPUT
    if [[ -z "$COLUMN_METADATA" ]]; then printf '%sERROR%s: no column metadata returned for %s.%s\n' "$COLOR_RED" "$COLOR_RESET" "$DATABASE" "$table" >&2; TABLES_FAILED=$((TABLES_FAILED + 1)); FINAL_STATUS=4; return; fi
    analyze_columns "$table"
    prepare_ordered_results
    format_table_report "$table"
    append_export_results "$table"
    if grep -F 'ERROR|' "$RESULT_FILE" >/dev/null 2>&1; then
        TABLES_FAILED=$((TABLES_FAILED + 1))
        FINAL_STATUS=4
    else
        TABLES_COMPLETED=$((TABLES_COMPLETED + 1))
    fi
    if [[ "$warned" == true ]] || grep -F 'WARNING|' "$RESULT_FILE" >/dev/null 2>&1; then TABLES_WARNED=$((TABLES_WARNED + 1)); fi
}

main() {
    initialize_defaults
    if [[ $# -eq 0 ]]; then show_help; exit 0; fi
    parse_arguments "$@"
    validate_arguments
    initialize_colors
    resolve_mysql_bin
    create_workspace
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    build_table_list
    check_connection
    initialize_export
    printf '%sMySQL Cardinality Analyzer%s | Server: %s | Version: %s\n' "$COLOR_BOLD" "$COLOR_RESET" "$SERVER_HOSTNAME" "$SERVER_VERSION"
    local table
    for table in "${UNIQUE_TABLES[@]}"; do process_table "$table"; done
    printf '\nSummary: requested=%s completed=%s warned=%s failed=%s exact=%s metadata=%s\n' "$TABLES_REQUESTED" "$TABLES_COMPLETED" "$TABLES_WARNED" "$TABLES_FAILED" "$TABLES_EXACT" "$TABLES_METADATA"
    if [[ "$FINAL_STATUS" -eq 0 && -n "$OUTPUT_FILE" ]]; then
        if ! mv "$EXPORT_TEMP" "$OUTPUT_FILE"; then runtime_error 3 "Unable to publish report: $OUTPUT_FILE"; fi
        EXPORT_TEMP=""; printf 'Report: %s\n' "$OUTPUT_FILE"
    fi
    exit "$FINAL_STATUS"
}

main "$@"
