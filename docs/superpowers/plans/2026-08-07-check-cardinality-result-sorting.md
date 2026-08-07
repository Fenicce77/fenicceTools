# Check Cardinality Result Sorting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, deterministic descending ordering by cardinality or selectivity to `check_cardinality.sh`, with identical terminal and CSV/TSV row order and no additional MySQL work.

**Architecture:** Preserve `RESULT_FILE` as the physical-order analysis source and add `prepare_ordered_results`, which either aliases that file or creates one decorated/sorted/stripped view in `WORK_DIR`. Terminal formatting and export serialization consume `ORDERED_RESULT_FILE`; status checks continue to consume `RESULT_FILE`.

**Tech Stack:** Bash 3.2-compatible shell, POSIX/BSD/GNU `awk`, `sort`, and `cut`, fake-MySQL integration tests.

## Global Constraints

- Keep `set -euo pipefail` enabled.
- Support macOS Bash 3.2 and Linux without GNU-only shell or text-processing syntax.
- Declare the nontrivial AWK program in a shell string before invoking AWK.
- Support both `--sort-by=value` and `--sort-by value`.
- Accept only `cardinality` and `selectivity`; omitted sorting preserves `ORDINAL_POSITION` order.
- Sort the selected metric descending, then the other metric descending, then physical ordinal ascending.
- Numeric zero sorts before `N/A`; rows with status `ERROR` sort after non-error unavailable rows.
- Preserve unsigned 64-bit cardinality precision by comparing normalized textual digits, never shell/AWK floating-point cardinality values.
- Do not add SQL statements or change analysis/query order.
- Keep terminal wrapping, column widths, ANSI coloring, CSV/TSV schemas, and exit semantics unchanged.
- Treat metric sorting as index-candidate guidance, not an automatic composite-index prescription.

---

## File Map

- Modify `mysql/estimations/check_cardinality.sh`: CLI contract, ordered-result preparation, renderer/export data source, help and examples.
- Modify `mysql/estimations/tests/fake_mysql.sh`: deterministic metric, error, and unsigned-64-bit fixtures.
- Modify `mysql/estimations/tests/test_check_cardinality.sh`: CLI, ordering, precision, export consistency, and query-invariance regressions.
- Preserve `docs/superpowers/specs/2026-08-07-check-cardinality-result-sorting-design.md` unchanged as the approved design source.

### Task 1: Add the CLI contract and physical-order result view

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh:7-213, 661-765`
- Test: `mysql/estimations/tests/test_check_cardinality.sh:214-310, 734-776`

**Interfaces:**
- Consumes: existing `initialize_defaults`, `show_help`, `parse_arguments`, `validate_arguments`, `process_table`, `RESULT_FILE`, and `cli_error`.
- Produces: global `SORT_BY`, global `ORDERED_RESULT_FILE`, and `prepare_ordered_results()`; later tasks extend the function without changing its signature.

- [ ] **Step 1: Add failing CLI/help tests**

Extend `test_cli_help_and_compatibility` with assertions for the new help option and both accepted parser forms:

```bash
assert_contains "$STRIPPED_OUTPUT" '--sort-by'
assert_contains "$STRIPPED_OUTPUT" 'cardinality|selectivity'
assert_contains "$STRIPPED_OUTPUT" '--sort-by cardinality'
assert_contains "$STRIPPED_OUTPUT" '--sort-by selectivity'

run_case sort_separate -l x -d app -t users --mode metadata --sort-by cardinality --no-color
assert_status 0
run_case sort_equals -l x -d app -t users --mode metadata --sort-by=selectivity --no-color
assert_status 0
```

Extend `test_cli_validation_and_client_failures` with exact failure behavior:

```bash
run_case sort_missing -l x -d app -t users --sort-by
assert_status 2
assert_contains "$OUTPUT" 'Option --sort-by requires a value.'
assert_error_count "$OUTPUT" 1

run_case sort_empty -l x -d app -t users --sort-by=
assert_status 2
assert_contains "$OUTPUT" 'Option --sort-by requires a value.'
assert_error_count "$OUTPUT" 1

run_case sort_invalid -l x -d app -t users --sort-by ratio
assert_status 2
assert_contains "$OUTPUT" 'Invalid sort field: ratio'
assert_error_count "$OUTPUT" 1
```

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run:

```bash
TEST_FILTER=cli_help bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=cli_validation bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: `cli_help` fails because the option is absent; `cli_validation` fails because `--sort-by` is unknown.

- [ ] **Step 3: Implement option defaults, parsing, validation, and help**

In `initialize_defaults`, add:

```bash
SORT_BY=""
ORDERED_RESULT_FILE=""
```

In `parse_arguments`, add both forms before `--no-color`:

```bash
--sort-by=*)
    SORT_BY=${1#*=}
    [[ -n "$SORT_BY" ]] || cli_error "Option --sort-by requires a value."
    ;;
--sort-by)
    require_value "$1" "${2-}"
    SORT_BY=$2
    shift
    ;;
```

In `validate_arguments`, add:

```bash
case "$SORT_BY" in
    ""|cardinality|selectivity) : ;;
    *) cli_error "Invalid sort field: $SORT_BY" ;;
esac
```

Under `Output and runtime` in `show_help`, add:

```bash
printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--sort-by' "$help_reset" "$help_value" 'cardinality|selectivity' "$help_reset" 'Rank index candidates by metric, descending'
```

Add these examples, followed by a concise guidance note:

```bash
printf '  %s%s -l test-mysql -d app -t users --sort-by cardinality%s\n' "$help_value" "$0" "$help_reset"
printf '  %s%s -l test-mysql -d app -t users --sort-by selectivity%s\n\n' "$help_value" "$0" "$help_reset"

printf '%sIndex candidate guidance:%s\n' "$help_section" "$help_reset"
printf '%s  Metric ranking is guidance only. Validate predicates, joins, ranges, ORDER BY/%s\n' "$help_warning" "$help_reset"
printf '%s  GROUP BY, covering needs, workload frequency, and the leftmost-prefix rule.%s\n\n' "$help_warning" "$help_reset"
```

- [ ] **Step 4: Add the default ordered-view boundary and route both consumers through it**

Add this function immediately after `analyze_columns`:

```bash
prepare_ordered_results() {
    ORDERED_RESULT_FILE=$RESULT_FILE
}
```

In `process_table`, invoke it exactly once after column analysis:

```bash
analyze_columns "$table"
prepare_ordered_results
format_table_report "$table"
append_export_results "$table"
```

Change only the input redirection in `format_table_report` and `append_export_results`:

```bash
done < "$ORDERED_RESULT_FILE"
```

Leave both `grep` status checks pointed at `RESULT_FILE`.

- [ ] **Step 5: Run the focused and full suites**

Run:

```bash
TEST_FILTER=cli_help bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=cli_validation bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: the two focused tests pass; the full suite reports `36 passed, 0 failed` because Task 1 extends existing tests rather than registering a new test.

- [ ] **Step 6: Commit the CLI and data-flow boundary**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): add cardinality sort option"
```

### Task 2: Implement stable, precision-safe metric ordering

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh:415-420`
- Modify: `mysql/estimations/tests/fake_mysql.sh:15-105`
- Test: `mysql/estimations/tests/test_check_cardinality.sh:180-214, 330-390, 734-780`

**Interfaces:**
- Consumes: `SORT_BY`, `RESULT_FILE`, `WORK_DIR`, `TABLES_COMPLETED`, and the eleven-field result schema (`cardinality` field 5, `selectivity_pct` field 7, `status|error` field 11).
- Produces: `prepare_ordered_results()` sets `ORDERED_RESULT_FILE` to either `RESULT_FILE` or a complete sorted file; output rows retain the original eleven fields byte-for-byte.

- [ ] **Step 1: Add result-order extraction and equality helpers to the test harness**

Add after `report_row_fragments`:

```bash
capture_report_column_order() {
    REPORT_COLUMN_ORDER=$(printf '%s\n' "$OUTPUT" | awk '
function trim(value) { sub(/^[ ]+/, "", value); sub(/[ ]+$/, "", value); return value }
{
    separators = gsub(/\|/, "|")
    if (separators != 7) next
    first = $0
    sub(/[|].*$/, "", first)
    first = trim(first)
    if (first != "" && first != "COLUMN") print first
}')
}

assert_line_sequence() {
    [[ "$1" == "$2" ]] || fail "$LAST_CASE: unexpected row order [$1], expected [$2]"
}
```

The helper ignores multiline TYPE/INDEXES continuation lines because their first cell is empty.

- [ ] **Step 2: Add deterministic fake-MySQL sort fixtures**

In the early error-dispatch `case`, add:

```bash
sort_error:*cardinality:exact_column*'`error_metric`'*) printf '%s\n' 'forced metric failure' >&2; exit 1 ;;
```

In the table-metadata scenario switch, make the three sort scenarios use 100 estimated rows:

```bash
sort_metrics|sort_error|sort_uint64) printf 'InnoDB\t100\n' ;;
```

In the column-metadata scenario switch, add:

```bash
sort_metrics|sort_error)
    printf 'card_tie_low\tbigint unsigned\tbigint\tYES\t50\tN/A\tUNAVAILABLE\t0\t---\n'
    printf 'selectivity_tie_low\tbigint unsigned\tbigint\tYES\t20\tN/A\tUNAVAILABLE\t0\t---\n'
    printf 'card_tie_high\tbigint unsigned\tbigint\tYES\t50\tN/A\tUNAVAILABLE\t0\t---\n'
    printf 'zero_metric\tbigint unsigned\tbigint\tYES\t0\tN/A\tUNAVAILABLE\t0\t---\n'
    printf 'not_available\tbigint unsigned\tbigint\tYES\tN/A\tN/A\tUNAVAILABLE\t0\t---\n'
    printf 'stable_tie\tbigint unsigned\tbigint\tYES\t50\tN/A\tUNAVAILABLE\t0\t---\n'
    [[ "$scenario" != sort_error ]] || printf 'error_metric\tbigint unsigned\tbigint\tYES\tN/A\tN/A\tUNAVAILABLE\t0\t---\n'
    ;;
sort_uint64)
    printf 'below_uint64\tbigint unsigned\tbigint\tNO\t9999999999999999999\tidx_below\tLEADING_SINGLE\t1\tidx_below(#1)\n'
    printf 'max_uint64\tbigint unsigned\tbigint\tNO\t18446744073709551615\tidx_max\tLEADING_SINGLE\t1\tidx_max(#1)\n'
    printf 'small_value\tbigint unsigned\tbigint\tNO\t900\tidx_small\tLEADING_SINGLE\t1\tidx_small(#1)\n'
    ;;
```

In the exact-column response, add a `sort_metrics|sort_error` branch that keys off the quoted column name:

```bash
sort_metrics|sort_error)
    case "$query" in
        *'`card_tie_low`'*) printf '50\t100\n' ;;
        *'`selectivity_tie_low`'*) printf '20\t40\n' ;;
        *'`card_tie_high`'*) printf '50\t50\n' ;;
        *'`zero_metric`'*) printf '0\t100\n' ;;
        *'`not_available`'*) printf 'N/A\tN/A\n' ;;
        *'`stable_tie`'*) printf '50\t100\n' ;;
        *) printf 'fake_mysql: unknown sort column\n' >&2; exit 91 ;;
    esac
    ;;
```

- [ ] **Step 3: Add failing ordering tests**

Add and register `test_result_sorting_rules`:

```bash
test_result_sorting_rules() {
    local expected

    run_scenario sort_metrics -l x -d app -t users --mode exact --no-color
    assert_status 0
    capture_report_column_order
    expected=$(printf '%s\n' card_tie_low selectivity_tie_low card_tie_high zero_metric not_available stable_tie)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"

    run_scenario sort_metrics -l x -d app -t users --mode exact --sort-by cardinality --no-color
    assert_status 0
    capture_report_column_order
    expected=$(printf '%s\n' card_tie_high card_tie_low stable_tie selectivity_tie_low zero_metric not_available)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"

    run_scenario sort_metrics -l x -d app -t users --mode exact --sort-by=selectivity --no-color
    assert_status 0
    capture_report_column_order
    expected=$(printf '%s\n' card_tie_high card_tie_low stable_tie selectivity_tie_low zero_metric not_available)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"

    run_scenario sort_error -l x -d app -t users --mode exact --sort-by cardinality --no-color
    assert_status 4
    capture_report_column_order
    expected=$(printf '%s\n' card_tie_high card_tie_low stable_tie selectivity_tie_low zero_metric not_available error_metric)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"
    assert_contains "$OUTPUT" 'forced metric failure'
}
```

Register it after `mode_metadata`:

```bash
run_test result_sorting test_result_sorting_rules
```

- [ ] **Step 4: Run the focused test and confirm physical-order output still appears for sorted cases**

Run:

```bash
TEST_FILTER=result_sorting bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because `prepare_ordered_results` still aliases `RESULT_FILE` for every invocation.

- [ ] **Step 5: Implement textual numeric decoration and portable sorting**

Replace the Task 1 `prepare_ordered_results` body with:

```bash
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
```

Key ranks are `0` for numeric, `1` for unavailable, and `2` for `ERROR`. Integer-component length is numeric-descending and equal-length digits are bytewise-descending under `LC_ALL=C`; the original input line number is numeric-ascending.

- [ ] **Step 6: Add and run the unsigned-64-bit precision regression**

Add and register:

```bash
test_result_sorting_preserves_unsigned_precision() {
    run_scenario sort_uint64 -l x -d app -t users --mode metadata --sort-by cardinality --no-color
    assert_status 0
    capture_report_column_order
    expected=$(printf '%s\n' max_uint64 below_uint64 small_value)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"
    assert_contains "$OUTPUT" '18446744073709551615'
}
```

```bash
run_test sort_uint64 test_result_sorting_preserves_unsigned_precision
```

Run:

```bash
TEST_FILTER=result_sorting bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=sort_uint64 bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: both focused tests pass.

- [ ] **Step 7: Run shell syntax checks and the full suite**

Run:

```bash
bash -n mysql/estimations/check_cardinality.sh
bash -n mysql/estimations/tests/fake_mysql.sh
bash -n mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: syntax checks exit 0 and the suite reports `38 passed, 0 failed`.

- [ ] **Step 8: Commit the sorter and core regressions**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/fake_mysql.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): rank cardinality results"
```

### Task 3: Verify export parity, unchanged SQL, and presentation invariants

**Files:**
- Test: `mysql/estimations/tests/test_check_cardinality.sh:180-214, 700-785`

**Interfaces:**
- Consumes: `capture_report_column_order`, `run_scenario`, `QUERY_LOG`, terminal output, TSV export column field 9, and CSV rows whose ninth quoted field is the column name.
- Produces: integration evidence that one ordered view drives terminal, CSV, and TSV without affecting SQL or presentation behavior.

- [ ] **Step 1: Add machine-output order helpers**

Add after `capture_report_column_order`:

```bash
capture_tsv_column_order() {
    TSV_COLUMN_ORDER=$(awk -F '\t' 'NR > 1 { print $9 }' "$1")
}

capture_csv_column_order() {
    CSV_COLUMN_ORDER=$(awk -F '","' 'NR > 1 {
        value = $9
        sub(/^"/, "", value)
        sub(/"$/, "", value)
        print value
    }' "$1")
}
```

The fake fixture contains no embedded comma or quote in the column-name field, so the CSV helper remains deliberately fixture-scoped; production CSV escaping stays covered by existing export tests.

- [ ] **Step 2: Add the cross-output and query-invariance regression**

Add and register:

```bash
test_sorted_outputs_match_without_database_overhead() {
    local baseline_queries terminal_order expected csv_file tsv_file default_tsv

    default_tsv="$TMP_ROOT/default-order.tsv"
    run_scenario sort_metrics -l x -d app -t users --mode exact --no-color -o "$default_tsv" --format tsv
    assert_status 0
    capture_report_column_order
    expected=$(printf '%s\n' card_tie_low selectivity_tie_low card_tie_high zero_metric not_available stable_tie)
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$expected"
    capture_tsv_column_order "$default_tsv"
    assert_line_sequence "$TSV_COLUMN_ORDER" "$expected"

    run_scenario sort_metrics -l x -d app -t users --mode exact --no-color
    assert_status 0
    baseline_queries=$(<"$QUERY_LOG")

    run_scenario sort_metrics -l x -d app -t users --mode exact --sort-by selectivity --no-color
    assert_status 0
    [[ "$(<"$QUERY_LOG")" == "$baseline_queries" ]] || fail "$LAST_CASE: sorting changed SQL count or order"
    capture_report_column_order
    terminal_order=$REPORT_COLUMN_ORDER
    expected=$(printf '%s\n' card_tie_high card_tie_low stable_tie selectivity_tie_low zero_metric not_available)
    assert_line_sequence "$terminal_order" "$expected"

    csv_file="$TMP_ROOT/sorted.csv"
    run_scenario sort_metrics -l x -d app -t users --mode exact --sort-by selectivity --no-color -o "$csv_file" --format csv
    assert_status 0
    capture_report_column_order
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$terminal_order"
    capture_csv_column_order "$csv_file"
    assert_line_sequence "$CSV_COLUMN_ORDER" "$terminal_order"

    tsv_file="$TMP_ROOT/sorted.tsv"
    run_scenario sort_metrics -l x -d app -t users --mode exact --sort-by selectivity --no-color -o "$tsv_file" --format tsv
    assert_status 0
    capture_report_column_order
    assert_line_sequence "$REPORT_COLUMN_ORDER" "$terminal_order"
    capture_tsv_column_order "$tsv_file"
    assert_line_sequence "$TSV_COLUMN_ORDER" "$terminal_order"
}
```

```bash
run_test sorted_output_parity test_sorted_outputs_match_without_database_overhead
```

- [ ] **Step 3: Run the new test and the presentation regressions**

Run:

```bash
TEST_FILTER=sorted_output_parity bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=alignment bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=wrapped bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=adaptive bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: all selected tests pass. The existing alignment, wrapping, ANSI/error-order, and export-value tests demonstrate that sorting changed row sequence only.

Then exercise sorted output through the pseudo-terminal color and width paths:

```bash
run_scenario_tty sort_metrics -l x -d app -t users --mode exact --sort-by cardinality
assert_status 0
assert_has_ansi "$OUTPUT"

run_scenario_tty_width 160 layout_wrapped -l x -d app -t transactions \
    --mode metadata --sort-by cardinality --no-color
assert_status 0
assert_table_width_and_alignment 160
```

Place these invocations at the end of `test_sorted_outputs_match_without_database_overhead`. Expected: the sorted TTY output contains ANSI sequences and the sorted wrapped report retains exact 160-column geometry and separator alignment.

- [ ] **Step 4: Run final cross-platform-oriented verification**

Run:

```bash
bash -n mysql/estimations/check_cardinality.sh
bash -n mysql/estimations/tests/fake_mysql.sh
bash -n mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
git diff --check
git status --short
```

Expected: syntax checks and `git diff --check` exit 0; the suite reports `39 passed, 0 failed`; `git status --short` lists only the intended test changes before commit.

- [ ] **Step 5: Manually inspect the always-colored help contract**

Run:

```bash
mysql/estimations/check_cardinality.sh --help
```

Expected: `--sort-by cardinality|selectivity`, both examples, and the index-guidance text are visible and aligned; ANSI color remains present even when help is requested with `--no-color`.

- [ ] **Step 6: Commit the integration regressions**

```bash
git add mysql/estimations/tests/test_check_cardinality.sh
git commit -m "test(mysql): verify sorted output consistency"
```

- [ ] **Step 7: Review the final branch delta**

Run:

```bash
git diff --stat 985b686..HEAD
git log --oneline 985b686..HEAD
```

Expected: the delta contains the approved design, CLI/data-flow changes, sorter, fake fixtures, and integration tests in focused commits; no SQL-producing function is changed.
