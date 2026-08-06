#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$TEST_DIR/../check_cardinality.sh"
FAKE_MYSQL="$TEST_DIR/fake_mysql.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cardinality-tests.XXXXXX")
QUERY_LOG="$TMP_ROOT/queries.log"
OUTPUT=""
STATUS=0
PASS=0
FAIL=0
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "$LAST_CASE: expected status $1, got $STATUS: $OUTPUT"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$LAST_CASE: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$LAST_CASE: unexpected [$2]"; }
assert_query_contains() { grep -F "$1" "$QUERY_LOG" >/dev/null 2>&1 || fail "$LAST_CASE: query log missing [$1]"; }
assert_query_not_contains() { if grep -F "$1" "$QUERY_LOG" >/dev/null 2>&1; then fail "$LAST_CASE: query log contains [$1]"; fi; }
assert_has_ansi() {
    case "$1" in
        *$'\033['*) : ;;
        *) fail "$LAST_CASE: expected ANSI color sequences" ;;
    esac
}
assert_no_ansi() {
    case "$1" in
        *$'\033['*) fail "$LAST_CASE: unexpected ANSI color sequences" ;;
        *) : ;;
    esac
}
strip_ansi() {
    STRIPPED_OUTPUT=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' | awk '{$1=$1; print}')
}

run_case() {
    LAST_CASE=$1; shift
    : > "$QUERY_LOG"
    set +e
    OUTPUT=$(FAKE_MYSQL_QUERY_LOG="$QUERY_LOG" FAKE_MYSQL_SCENARIO=baseline MYSQL_BIN="$FAKE_MYSQL" "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
}
run_scenario() {
    local scenario=$1; shift
    LAST_CASE=$scenario
    : > "$QUERY_LOG"
    set +e
    OUTPUT=$(FAKE_MYSQL_QUERY_LOG="$QUERY_LOG" FAKE_MYSQL_SCENARIO="$scenario" MYSQL_BIN="$FAKE_MYSQL" "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
}
report_line() {
    local pattern=$1
    REPORT_LINE=$(printf '%s\n' "$OUTPUT" | awk -v pattern="$pattern" 'index($0, pattern) == 1 {print; exit}')
    [[ -n "$REPORT_LINE" ]] || fail "$LAST_CASE: report row not found for $pattern"
}

test_cli_help_and_compatibility() {
    run_case no_args; assert_status 0; assert_contains "$OUTPUT" 'MySQL Cardinality Analyzer'; strip_ansi "$OUTPUT"; assert_contains "$STRIPPED_OUTPUT" '--mode auto|metadata|exact'
    run_case help --help; assert_status 0
    run_case short -l test -d app -t users -p 500000 -r 10 --no-color; assert_status 0
    run_case long --login-path=test --database=app --tables=users --performance-threshold=500000 --drift-threshold=10 --mode=auto --max-execution-time-ms=30000 --mysql-bin="$FAKE_MYSQL" --no-color; assert_status 0
}

test_help_is_always_colored_and_runtime_no_color_is_preserved() {
    run_case no_args
    assert_status 0
    assert_has_ansi "$OUTPUT"
    assert_contains "$OUTPUT" 'MySQL Cardinality Analyzer'
    assert_contains "$OUTPUT" 'Usage:'
    assert_contains "$OUTPUT" 'Required:'
    assert_contains "$OUTPUT" 'Analysis:'
    assert_contains "$OUTPUT" 'Output and runtime:'
    assert_contains "$OUTPUT" 'Examples:'
    assert_contains "$OUTPUT" 'Safety:'
    assert_contains "$OUTPUT" 'Disable ANSI colors'
    assert_not_contains "$OUTPUT" 'Disable ANSI colors for runtime reports'
    assert_contains "$OUTPUT" 'Show this help and exit'
    assert_not_contains "$OUTPUT" 'Show this always-colored help and exit'
    assert_contains "$OUTPUT" 'metadata mode never scans user tables. ANALYZE requires explicit development,'
    assert_contains "$OUTPUT" $'\033[0;32m-l, --login-path'
    assert_contains "$OUTPUT" $'\033[0;36mauto|metadata|exact\033[0m'
    assert_contains "$OUTPUT" $'\033[0;36m500000\033[0m'
    assert_contains "$OUTPUT" $'\033[0;33m  test, or staging and is always \033[0m'
    assert_contains "$OUTPUT" $'\033[0;31mrefused for production\033[0m'

    run_case short_help -h
    assert_status 0
    assert_has_ansi "$OUTPUT"

    run_case long_help --help
    assert_status 0
    assert_has_ansi "$OUTPUT"

    run_case no_color_before_help --no-color --help
    assert_status 0
    assert_has_ansi "$OUTPUT"

    run_case no_color_after_help --help --no-color
    assert_status 0
    assert_has_ansi "$OUTPUT"

    run_case runtime_no_color -l test -d app -t users --mode metadata --no-color
    assert_status 0
    assert_no_ansi "$OUTPUT"
}

test_cli_validation_and_client_failures() {
    run_case missing --login-path; assert_status 2
    run_case bad_mode -l x -d app -t users --mode unsafe; assert_status 2
    run_case bad_number -l x -d app -t users -p -1; assert_status 2
    run_case format_without_file -l x -d app -t users --format csv; assert_status 2
    run_case bad_env -l x -d app -t users --environment qa; assert_status 2
    run_case missing_client -l x -d app -t users --mysql-bin "$TMP_ROOT/nope"; assert_status 3
    run_scenario connection_error -l x -d app -t users; assert_status 3
}

test_cli_table_file_and_deduplication() {
    printf '# comment\n users \n\norders\nusers\n' > "$TMP_ROOT/tables.txt"
    run_case tables -l x -d app -t 'orders, users' -f "$TMP_ROOT/tables.txt" --mode metadata --no-color
    assert_status 0
    count=$(grep -c 'cardinality:table_metadata' "$QUERY_LOG" || true)
    [[ "$count" -eq 2 ]] || fail "expected two deduplicated metadata queries, got $count"
}

test_mode_metadata_is_scan_safe() {
    run_scenario large -l x -d app -t users --mode auto --no-color; assert_status 0
    assert_query_not_contains 'cardinality:exact_count'; assert_query_not_contains 'cardinality:exact_column'; assert_contains "$OUTPUT" 'metadata'
    run_scenario missing_estimate -l x -d app -t users --mode auto --no-color; assert_status 0; assert_query_not_contains 'cardinality:exact_count'
    run_scenario large -l x -d app -t users --mode metadata --no-color; assert_contains "$OUTPUT" 'tenant_id'; assert_contains "$OUTPUT" 'unavail'; assert_contains "$OUTPUT" 'N/A'; assert_not_contains "$OUTPUT" 'Drift: N/A%'
}

test_exact_optimizer_shortcuts_and_predicates() {
    run_scenario exact_keys -l x -d app -t users --mode exact --max-execution-time-ms 12345 --no-color; assert_status 0
    assert_query_contains 'cardinality:count_explain'; assert_query_contains 'cardinality:exact_count'; assert_query_contains 'MAX_EXECUTION_TIME(12345)'
    assert_query_not_contains 'FORCE INDEX'; assert_query_not_contains 'USE INDEX'; assert_contains "$OUTPUT" 'idx_small'
    assert_query_contains 'cardinality:exact_unique_nullable'; assert_query_contains 'COUNT(`external_id`)'
    assert_query_contains 'OCTET_LENGTH(`name`) > 0'; assert_query_contains "CAST(\`created_on\` AS CHAR) NOT LIKE '0000-00-00%'"
    assert_query_contains '`zero_value` IS NOT NULL'; assert_query_not_contains '`zero_value` <> 0'
}

test_exact_threshold_and_drift() {
    run_scenario threshold -l x -d app -t users --mode auto -p 500000 --no-color; assert_status 0; assert_query_contains 'cardinality:exact_count'
    run_scenario empty -l x -d app -t users --mode exact --no-color; assert_status 0; assert_contains "$OUTPUT" '0.00%'
    run_scenario drift -l x -d app -t users --mode exact -r 10 --no-color; assert_status 0; assert_contains "$OUTPUT" 'WARNING'; assert_query_not_contains 'ANALYZE'
}

test_analyze_guard_and_order() {
    run_case missing_env -l x -d app -t users --analyze-table; assert_status 2; assert_query_not_contains 'ANALYZE'
    run_case prod -l x -d app -t users --analyze-table --environment production; assert_status 2; assert_query_not_contains 'ANALYZE'
    run_case staging -l x -d app -t users --analyze-table --environment staging --mode metadata --no-color; assert_status 0
    first=$(grep -n 'ANALYZE LOCAL TABLE' "$QUERY_LOG" | head -n 1 | cut -d: -f1 || true)
    second=$(grep -n 'cardinality:table_metadata' "$QUERY_LOG" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || fail 'ANALYZE must precede metadata'
}

test_export_is_clean_and_complete() {
    out="$TMP_ROOT/report.csv"
    run_case export -l x -d 'app\path' -t users --mode metadata -o "$out" --format csv
    assert_status 0
    [[ -f "$out" ]] || fail 'CSV was not created'
    header=$(head -n 1 "$out")
    assert_contains "$header" '"database","table","engine","requested_mode","effective_mode"'; assert_contains "$header" 'existing_indexes'; assert_not_contains "$(LC_ALL=C tr -cd '\033' < "$out")" $'\033'
    expected='"database","table","engine","requested_mode","effective_mode","estimated_rows","exact_rows","drift_pct","column","data_type","nullable","eligible_rows","cardinality","ratio","selectivity_pct","source","source_index","existing_indexes","status","error"'
    [[ "$header" == "$expected" ]] || fail "unexpected CSV header: $header"
    assert_contains "$(sed -n '2p' "$out")" '"app\path"'
}

test_partial_failure_continues_and_preserves_export() {
    out="$TMP_ROOT/atomic.csv"
    printf 'existing report\n' > "$out"
    run_scenario partial -l x -d app -t 'bad,good' --mode metadata -o "$out" --format csv --no-color
    assert_status 4
    assert_query_contains "TABLE_NAME=CONVERT(X'626164' USING utf8mb4)"
    assert_query_contains "TABLE_NAME=CONVERT(X'676f6f64' USING utf8mb4)"
    [[ "$(<"$out")" == 'existing report' ]] || fail 'partial failure replaced existing report'
}

test_analyze_failure_continues_without_retry() {
    run_scenario analyze_error -l x -d app -t 'bad,good' --mode metadata --analyze-table --environment test --no-color
    assert_status 4
    count=$(grep -c 'ANALYZE LOCAL TABLE.*`bad`' "$QUERY_LOG" || true)
    [[ "$count" -eq 1 ]] || fail "bad table ANALYZE count was $count"
    assert_query_contains 'ANALYZE LOCAL TABLE `app`.`good`'
}

test_exact_column_failure_continues_later_columns() {
    run_scenario timeout -l x -d app -t users --mode exact --no-color
    assert_status 4
    assert_query_contains '`slow_col`'
    assert_query_contains '`after_slow`'
    assert_contains "$OUTPUT" 'maximum statement execution time exceeded'
    assert_contains "$OUTPUT" 'completed=0'
    assert_contains "$OUTPUT" 'failed=1'
}

test_sql_literals_and_identifiers_are_escaped() {
    run_scenario exact_keys -l x -d "o'hare" -t 'odd`table' --mode exact --no-color
    assert_status 0
    assert_query_contains "TABLE_SCHEMA=CONVERT(X'6f2768617265' USING utf8mb4)"
    assert_query_contains 'FROM `o'"'"'hare`.`odd``table`'

    run_scenario large -l x -d "x\\' OR 1=1 #" -t users --mode metadata --no-color
    assert_status 0
    assert_query_contains "CONVERT(X'785c27204f5220313d312023' USING utf8mb4)"
    assert_query_not_contains ' OR 1=1 #'
}

test_metadata_index_list_raises_group_concat_limit() {
    run_scenario large -l x -d app -t users --mode metadata --no-color
    assert_status 0
    assert_query_contains 'SET SESSION group_concat_max_len=@@max_allowed_packet'
}

test_output_file_rejects_directory_target() {
    mkdir "$TMP_ROOT/output-dir"
    run_case output_dir -l x -d app -t users -o "$TMP_ROOT/output-dir" --format csv --no-color
    assert_status 2
    assert_query_not_contains 'cardinality:connection'
}

test_empty_analyze_result_is_failure() {
    run_scenario analyze_empty -l x -d app -t users --mode metadata --analyze-table --environment test --no-color
    assert_status 4
    assert_contains "$OUTPUT" 'failed=1'
}

test_terminal_rows_align_within_fallback_width() {
    run_case alignment -l x -d app -t users --mode metadata --no-color
    assert_status 0
    header=$(printf '%s\n' "$OUTPUT" | awk '/^COLUMN[ ]+\|/ {print; exit}')
    row=$(printf '%s\n' "$OUTPUT" | awk '/^id[ ]+\|/ {print; exit}')
    [[ ${#header} -le 120 && ${#row} -le 120 ]] || fail "fallback rows exceed 120 columns: ${#header}/${#row}"
    header_pipes=$(printf '%s' "$header" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    row_pipes=$(printf '%s' "$row" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    [[ "$header_pipes" == "$row_pipes" ]] || fail "separator offsets differ: $header_pipes / $row_pipes"
}

test_adaptive_report_prioritizes_column_and_indexes() {
    run_scenario layout_common -l x -d app -t transactions --mode exact --no-color
    assert_status 0

    report_line 'COLUMN'
    header=$REPORT_LINE
    report_line 'vendor_transaction_id'
    vendor_row=$REPORT_LINE
    report_line 'processing_status'
    status_row=$REPORT_LINE

    [[ ${#header} -eq 120 && ${#vendor_row} -eq 120 && ${#status_row} -eq 120 ]] ||
        fail "adaptive fallback rows are not exactly 120 columns"
    assert_contains "$vendor_row" 'vendor_transaction_id'
    assert_not_contains "$vendor_row" 'vendor_transaction...'
    assert_contains "$vendor_row" 'exact/key'
    assert_not_contains "$vendor_row" 'exact_key_shortcut'
    assert_contains "$vendor_row" 'idx_aviator_v...'
    assert_contains "$OUTPUT" 'exact/uniq'

    header_pipes=$(printf '%s' "$header" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    row_pipes=$(printf '%s' "$vendor_row" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    [[ "$header_pipes" == "$row_pipes" ]] ||
        fail "adaptive separator offsets differ: $header_pipes / $row_pipes"
}

test_adaptive_report_borrows_from_indexes_for_long_columns() {
    run_scenario layout_borrow -l x -d app -t transactions --mode exact --no-color
    assert_status 0
    report_line 'applied_multiplier_reference_key'
    assert_contains "$REPORT_LINE" 'applied_multiplier_reference_key'
    assert_contains "$REPORT_LINE" 'idx_aviat...'
    [[ ${#REPORT_LINE} -eq 120 ]] || fail "borrowed-width row is not 120 columns"
}

test_adaptive_report_preserves_large_numeric_alignment() {
    run_scenario layout_numeric -l x -d app -t transactions --mode exact --no-color
    assert_status 0
    report_line 'COLUMN'
    header=$REPORT_LINE
    report_line 'vendor_transaction_id'
    numeric_row=$REPORT_LINE
    assert_contains "$numeric_row" '123456789'
    [[ ${#numeric_row} -eq 120 ]] || fail "large-numeric row is not 120 columns: ${#numeric_row}"
    header_pipes=$(printf '%s' "$header" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    row_pipes=$(printf '%s' "$numeric_row" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    [[ "$header_pipes" == "$row_pipes" ]] || fail "large-numeric separator offsets differ"
}

test_adaptive_report_assigns_wider_terminal_to_indexes() {
    TERM=xterm COLUMNS=160 run_scenario layout_common -l x -d app -t transactions --mode exact --no-color
    assert_status 0
    report_line 'COLUMN'
    [[ ${#REPORT_LINE} -eq 160 ]] || fail "wide header is not 160 columns: ${#REPORT_LINE}"
    report_line 'vendor_transaction_id'
    [[ ${#REPORT_LINE} -eq 160 ]] || fail "wide row is not 160 columns: ${#REPORT_LINE}"
    assert_contains "$REPORT_LINE" 'idx_aviator_vendor_transaction(#1), uk_vendor_transac...'
}

test_adaptive_report_handles_divergent_metadata_metrics() {
    run_scenario layout_divergent -l x -d app -t transactions --mode metadata --no-color
    assert_status 0
    report_line 'COLUMN'
    header=$REPORT_LINE
    report_line 'vendor'
    divergent_row=$REPORT_LINE
    assert_contains "$divergent_row" '18446744073709551615'
    assert_contains "$divergent_row" 'e+'
    [[ ${#divergent_row} -eq 120 ]] || fail "divergent metadata row is not 120 columns: ${#divergent_row}"
    header_pipes=$(printf '%s' "$header" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    row_pipes=$(printf '%s' "$divergent_row" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    [[ "$header_pipes" == "$row_pipes" ]] || fail "divergent metadata separator offsets differ"
}

test_adaptive_report_does_not_compact_exports() {
    out="$TMP_ROOT/layout.csv"
    run_scenario layout_common -l x -d app -t transactions --mode exact \
        --no-color -o "$out" --format csv
    assert_status 0
    row=$(sed -n '2p' "$out")
    assert_contains "$row" '"vendor_transaction_id"'
    assert_contains "$row" '"exact_key_shortcut"'
    assert_contains "$row" '"uk_vendor_transaction"'
    assert_contains "$row" '"idx_aviator_vendor_transaction(#1), uk_vendor_transaction(#1)"'
}

test_report_displays_full_types_and_compacts_enum() {
    run_scenario layout_types -l x -d app -t transactions --mode metadata --no-color
    assert_status 0
    assert_contains "$OUTPUT" 'bigint unsigned'
    assert_contains "$OUTPUT" 'ENUM'
    assert_not_contains "$OUTPUT" "enum('new'"
    assert_not_contains "$OUTPUT" 'bigint unsi...'

    report_line 'COLUMN'
    header=$REPORT_LINE
    report_line 'unsigned_counter'
    ordinary_row=$REPORT_LINE
    [[ ${#header} -eq 120 && ${#ordinary_row} -eq 120 ]] ||
        fail "type layout is not exactly 120 columns"
}

run_test() {
    local name=$1 fn=$2
    [[ -z "${TEST_FILTER:-}" || "$name" == *"$TEST_FILTER"* ]] || return 0
    if ( "$fn" ); then printf 'ok - %s\n' "$name"; PASS=$((PASS + 1)); else printf 'not ok - %s\n' "$name"; FAIL=$((FAIL + 1)); fi
}

run_test cli_help test_cli_help_and_compatibility
run_test help_color test_help_is_always_colored_and_runtime_no_color_is_preserved
run_test cli_validation test_cli_validation_and_client_failures
run_test cli_tables test_cli_table_file_and_deduplication
run_test mode_metadata test_mode_metadata_is_scan_safe
run_test exact_analysis test_exact_optimizer_shortcuts_and_predicates
run_test exact_drift test_exact_threshold_and_drift
run_test analyze_guard test_analyze_guard_and_order
run_test export_report test_export_is_clean_and_complete
run_test partial_atomic test_partial_failure_continues_and_preserves_export
run_test analyze_continue test_analyze_failure_continues_without_retry
run_test exact_continue test_exact_column_failure_continues_later_columns
run_test sql_escaping test_sql_literals_and_identifiers_are_escaped
run_test metadata_concat_limit test_metadata_index_list_raises_group_concat_limit
run_test output_directory test_output_file_rejects_directory_target
run_test analyze_empty test_empty_analyze_result_is_failure
run_test alignment_fallback test_terminal_rows_align_within_fallback_width
run_test adaptive_priority test_adaptive_report_prioritizes_column_and_indexes
run_test adaptive_borrow test_adaptive_report_borrows_from_indexes_for_long_columns
run_test adaptive_numeric test_adaptive_report_preserves_large_numeric_alignment
run_test adaptive_wide test_adaptive_report_assigns_wider_terminal_to_indexes
run_test adaptive_divergent test_adaptive_report_handles_divergent_metadata_metrics
run_test adaptive_export test_adaptive_report_does_not_compact_exports
run_test wrapped_type_display test_report_displays_full_types_and_compacts_enum
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
