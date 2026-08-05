# Check Cardinality Adaptive Report Width Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reallocate the 120-column terminal report so common column names are complete, index lists receive more width, source labels are compact, and exported values remain unchanged.

**Architecture:** Extend the existing fake MySQL integration boundary with two layout fixtures, then compute terminal widths from a fixed numeric budget plus the longest result-column name. Keep normalized TSV rows and CSV/TSV exports untouched; compact source labels exist only inside terminal rendering.

**Tech Stack:** macOS Bash 3.2, portable AWK/shell integration tests, ANSI-safe `printf` terminal rendering.

## Global Constraints

- Preserve `set -euo pipefail` and Bash 3.2 compatibility.
- Keep every rendered fallback row at or below 120 visible characters for the tested numeric ranges.
- Use 24 characters for ordinary `COLUMN` values and 20 for `INDEXES` at the fallback.
- Allow `COLUMN` to borrow up to 8 characters from `INDEXES`; never reduce `INDEXES` below 12.
- Allocate terminal width above 120 to `INDEXES` after satisfying actual column names up to 32 characters.
- Do not append `source_index` to terminal `SOURCE` values.
- Preserve complete normalized and CSV/TSV `source`, `source_index`, column, type, and index-list values.
- Keep ANSI variables outside padded field values.
- Do not change SQL, cardinality calculations, report status, or row colors.

---

### Task 1: Adaptive Terminal Geometry and Compact Sources

**Files:**
- Modify: `mysql/estimations/tests/fake_mysql.sh`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`
- Modify: `mysql/estimations/check_cardinality.sh:378-414`

**Interfaces:**
- Consumes: `RESULT_FILE`, `TERM_WIDTH`, normalized 11-field result rows, `truncate_text`, and existing terminal colors.
- Produces: `calculate_report_widths`, `compact_source_label`, `COLUMN_WIDTH`, `TYPE_WIDTH`, `SOURCE_WIDTH`, `INDEXES_WIDTH`, and an aligned terminal report.

- [ ] **Step 1: Add two deterministic fake layout scenarios**

In the `cardinality:table_metadata` fixture, keep the normal `InnoDB\t100`
response for both new scenarios. In `cardinality:column_metadata`, add:

```bash
layout_common)
    printf 'vendor_transaction_id\tvarchar(128)\tvarchar\tNO\t100\tuk_vendor_transaction\tUNIQUE_SINGLE\t1\tidx_aviator_vendor_transaction(#1), uk_vendor_transaction(#1)\n'
    printf 'processing_status\ttinyint unsigned\ttinyint\tYES\t20\tidx_aviator_status_created\tLEADING_SINGLE\t1\tidx_aviator_status_created(#1)\n'
    printf 'wallet_reference\tvarchar(128)\tvarchar\tYES\t95\tuk_wallet_reference\tUNIQUE_SINGLE\t1\tuk_wallet_reference(#1)\n'
    ;;
layout_borrow)
    printf 'applied_multiplier_reference\tvarchar(128)\tvarchar\tNO\t100\tuk_applied_multiplier_reference\tUNIQUE_SINGLE\t1\tidx_aviator_applied_multiplier_reference(#1)\n'
    ;;
```

The existing exact-count fixture returns `100`; the unique-not-null rows will
therefore exercise `exact_key_shortcut` without adding fake query branches.

- [ ] **Step 2: Add failing fallback geometry and source-label tests**

Add a helper that extracts a terminal table row without interpreting a mock:

```bash
report_line() {
    local pattern=$1
    REPORT_LINE=$(printf '%s\n' "$OUTPUT" | awk -v pattern="$pattern" 'index($0, pattern) == 1 {print; exit}')
    [[ -n "$REPORT_LINE" ]] || fail "$LAST_CASE: report row not found for $pattern"
}
```

Add the common-width test:

```bash
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
    assert_contains "$vendor_row" 'idx_aviator_vendo...'
    assert_contains "$OUTPUT" 'exact/uniq'

    header_pipes=$(printf '%s' "$header" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    row_pipes=$(printf '%s' "$vendor_row" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
    [[ "$header_pipes" == "$row_pipes" ]] ||
        fail "adaptive separator offsets differ: $header_pipes / $row_pipes"
}
```

Add the borrowing-boundary test:

```bash
test_adaptive_report_borrows_from_indexes_for_long_columns() {
    run_scenario layout_borrow -l x -d app -t transactions --mode exact --no-color
    assert_status 0
    report_line 'applied_multiplier_reference'
    assert_contains "$REPORT_LINE" 'applied_multiplier_reference'
    assert_contains "$REPORT_LINE" 'idx_aviator_a...'
    [[ ${#REPORT_LINE} -eq 120 ]] || fail "borrowed-width row is not 120 columns"
}
```

Register both tests:

```bash
run_test adaptive_priority test_adaptive_report_prioritizes_column_and_indexes
run_test adaptive_borrow test_adaptive_report_borrows_from_indexes_for_long_columns
```

- [ ] **Step 3: Add a failing export-invariance test**

Use the common layout with CSV output and assert the complete normalized fields:

```bash
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
```

Register it with:

```bash
run_test adaptive_export test_adaptive_report_does_not_compact_exports
```

Update the pre-existing metadata-mode assertion from terminal label
`UNAVAILABLE` to compact label `unavail`; the metadata cardinality and export
semantics remain `N/A`/`UNAVAILABLE` as before.

- [ ] **Step 4: Run the new tests and verify RED**

Run:

```bash
TEST_FILTER=adaptive /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: all three tests fail because the current renderer truncates common
column names to 15 characters, uses a 10-character index field, renders
`source:source_index`, and has no new fake fixtures.

- [ ] **Step 5: Implement width measurement and allocation**

Add these functions after `refresh_terminal_width`:

```bash
calculate_report_widths() {
    local max_column=0 name name_length text_budget desired_column

    while IFS=$'\t' read -r name _; do
        name_length=${#name}
        [[ "$name_length" -gt "$max_column" ]] && max_column=$name_length
    done < "$RESULT_FILE"

    TYPE_WIDTH=12
    SOURCE_WIDTH=10
    desired_column=24
    if [[ "$max_column" -gt "$desired_column" ]]; then
        desired_column=$max_column
    fi
    [[ "$desired_column" -le 32 ]] || desired_column=32

    text_budget=$((TERM_WIDTH - 54))
    COLUMN_WIDTH=$desired_column
    INDEXES_WIDTH=$((text_budget - TYPE_WIDTH - SOURCE_WIDTH - COLUMN_WIDTH))
    if [[ "$INDEXES_WIDTH" -lt 12 ]]; then
        COLUMN_WIDTH=$((COLUMN_WIDTH - (12 - INDEXES_WIDTH)))
        INDEXES_WIDTH=12
    fi
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
```

`54` is the sum of the four numeric fields (`8 + 11 + 6 + 8`) and seven
three-character separators (`21`). For a 120-column terminal and a common
column name, the remaining text budget is exactly `66`, producing
`24 + 12 + 10 + 20`.

- [ ] **Step 6: Replace fixed renderer widths with the adaptive globals**

In `format_table_report`:

1. Remove `column_width`, `type_width`, `source_width`, `indexes_width`,
   `extra`, and `share`.
2. Call `refresh_terminal_width`, then `calculate_report_widths`.
3. Use the display headings `ELIGIBLE`, `CARDINALITY`, `RATIO`, and `SELECT.`.
4. Use widths `8`, `11`, `6`, and `8` for those numeric fields.
5. Use `COLUMN_WIDTH`, `TYPE_WIDTH`, `SOURCE_WIDTH`, and `INDEXES_WIDTH` in
   both header and row format strings.
6. Before truncating the source field, call `compact_source_label "$source"`
   and render `DISPLAY_SOURCE`; do not concatenate `source_index`.

The header format becomes:

```bash
line=$(printf "%-${COLUMN_WIDTH}s | %-${TYPE_WIDTH}s | %8s | %11s | %6s | %8s | %-${SOURCE_WIDTH}s | %-${INDEXES_WIDTH}s" \
    COLUMN TYPE ELIGIBLE CARDINALITY RATIO SELECT. SOURCE INDEXES)
```

The row format uses the identical widths:

```bash
line=$(printf "%-${COLUMN_WIDTH}s | %-${TYPE_WIDTH}s | %8s | %11s | %6s | %8s | %-${SOURCE_WIDTH}s | %-${INDEXES_WIDTH}s" \
    "$column" "$type" "$eligible" "$card" "$ratio" "$pct" "$source" "$indexes")
```

- [ ] **Step 7: Run focused and complete tests and verify GREEN**

Run:

```bash
TEST_FILTER=adaptive /bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: the three adaptive tests pass and the complete suite reports 20
passed, 0 failed. The pre-existing fallback-alignment test must remain green.

- [ ] **Step 8: Run portability and diff verification**

Run:

```bash
/bin/bash -n mysql/estimations/check_cardinality.sh
/bin/bash -n mysql/estimations/tests/fake_mysql.sh
/bin/bash -n mysql/estimations/tests/test_check_cardinality.sh
rg -n 'declare -A|mapfile|readarray|echo -e|sed -r|sed -E|mktemp --' \
  mysql/estimations/check_cardinality.sh mysql/estimations/tests
git diff --check
git status --short --branch
```

Expected: syntax passes; the compatibility search has no findings; the diff
has no whitespace errors; only the three intentional files are modified.

- [ ] **Step 9: Commit the implementation**

```bash
git add mysql/estimations/check_cardinality.sh \
  mysql/estimations/tests/fake_mysql.sh \
  mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): prioritize cardinality report identity fields"
```
