# Check Cardinality Wrapped Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render complete terminal `TYPE` and `INDEXES` information in aligned multiline rows, while displaying `ENUM(...)` only as `ENUM` and preserving complete machine-readable exports.

**Architecture:** Keep the normalized TSV result file as the source of truth and introduce display-only type normalization before width calculation. Add portable wrapping helpers that return newline-delimited fragments, then render each logical row as one primary line plus aligned continuation lines. CSV/TSV exports continue to read the original normalized fields and bypass every display transformation.

**Tech Stack:** macOS Bash 3.2, portable POSIX `awk`/`sed`, fake-MySQL shell integration tests, ANSI-safe `printf` rendering.

## Global Constraints

- Preserve `set -euo pipefail` and macOS Bash 3.2/Linux compatibility.
- Keep ANSI color sequences outside padded values and reset color after every physical line.
- Use 120 columns when `tput cols` is unavailable or reports fewer than 120; honor wider detected terminals.
- Preserve complete numeric counts; derived metrics may use the existing terminal-only scientific notation.
- Keep `INDEXES_WIDTH >= 12` and prevent every calculated width from becoming negative.
- Render case-insensitive `ENUM(...)` values as `ENUM` in the terminal only.
- Preserve complete original `column_type`, `source`, `source_index`, and `existing_indexes` values in normalized results and CSV/TSV exports.
- Wrap indexes at comma-plus-space entry boundaries when possible; hard-wrap only an individual entry that exceeds `INDEXES_WIDTH`.
- Keep every physical row within `TERM_WIDTH`, with separator offsets identical to the header.
- Print a row-level error exactly once after all physical lines belonging to that logical row.
- Do not change SQL, cardinality calculations, exit codes, CLI parameters, or report status semantics.

---

### Task 1: Display-Only ENUM Normalization and Dynamic TYPE Width

**Files:**
- Modify: `mysql/estimations/tests/fake_mysql.sh:45-76`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh:225-356`
- Modify: `mysql/estimations/check_cardinality.sh:378-468`

**Interfaces:**
- Consumes: normalized `RESULT_FILE` rows and `TERM_WIDTH`.
- Produces: `normalize_display_type RAW_TYPE`, setting global `DISPLAY_TYPE`; `calculate_report_widths`, setting `TYPE_WIDTH` from normalized display values while retaining `INDEXES_WIDTH >= 12`.

- [ ] **Step 1: Add a fake scenario containing ordinary and ENUM types**

Add this `cardinality:column_metadata` branch in
`mysql/estimations/tests/fake_mysql.sh`:

```bash
layout_types)
    printf 'unsigned_counter\tbigint unsigned\tbigint\tNO\t100\tidx_counter\tLEADING_SINGLE\t1\tidx_counter(#1)\n'
    printf "state\tenum('new','processing','complete')\tenum\tNO\t3\tidx_state\tLEADING_SINGLE\t1\tidx_state(#1)\n"
    ;;
```

The existing default table-metadata and exact-count branches are sufficient.

- [ ] **Step 2: Add a failing test for full ordinary types and compact ENUM output**

Add and register this test in
`mysql/estimations/tests/test_check_cardinality.sh`:

```bash
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

run_test wrapped_type_display test_report_displays_full_types_and_compacts_enum
```

- [ ] **Step 3: Run the focused test and verify it fails**

Run:

```bash
TEST_FILTER=wrapped_type_display /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because `bigint unsigned` is truncated by the fixed
12-character `TYPE_WIDTH`, and the full `ENUM(...)` definition is printed.

- [ ] **Step 4: Add terminal-only type normalization**

Add immediately after `truncate_text` in
`mysql/estimations/check_cardinality.sh`:

```bash
normalize_display_type() {
    local raw_type=$1 lower_type
    lower_type=$(printf '%s' "$raw_type" | tr '[:upper:]' '[:lower:]')
    case "$lower_type" in
        enum\(*) DISPLAY_TYPE=ENUM ;;
        *) DISPLAY_TYPE=$raw_type ;;
    esac
}
```

- [ ] **Step 5: Measure normalized TYPE values and allocate their width**

Change the `calculate_report_widths` scan to bind all normalized fields rather
than repeated `_` placeholders:

```bash
local max_column=0 max_type=4 name type nullable eligible card ratio pct
local source source_index indexes status_error name_length type_length

while IFS=$'\t' read -r name type nullable eligible card ratio pct source source_index indexes status_error; do
    normalize_display_type "$type"
    type_length=${#DISPLAY_TYPE}
    [[ "$type_length" -le "$max_type" ]] || max_type=$type_length
    # Retain the existing column and numeric measurements here.
done < "$RESULT_FILE"
```

After computing `text_budget`, begin with these priorities:

```bash
TYPE_WIDTH=12
[[ "$max_type" -le "$TYPE_WIDTH" ]] || TYPE_WIDTH=$max_type
SOURCE_WIDTH=10
COLUMN_WIDTH=$desired_column
INDEXES_WIDTH=$((text_budget - TYPE_WIDTH - SOURCE_WIDTH - COLUMN_WIDTH))
```

If `INDEXES_WIDTH < 12`, reclaim only the shortage from `TYPE_WIDTH` down to a
minimum of 8 before applying the existing fallback reductions. This preserves
ordinary type values when budget permits and causes exceptional types to wrap
rather than forcing the row past `TERM_WIDTH`.

- [ ] **Step 6: Normalize TYPE before terminal rendering**

In `format_table_report`, replace terminal truncation of the original type with:

```bash
normalize_display_type "$type"
type=$DISPLAY_TYPE
truncate_text "$column" "$COLUMN_WIDTH"
column=$TRUNCATED
```

Do not call `truncate_text` for `type`; Task 2 will wrap it. Do not modify
`append_result` or `export_table_results`.

- [ ] **Step 7: Run focused and existing adaptive tests**

Run:

```bash
TEST_FILTER=wrapped_type_display /bin/bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=adaptive_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash -n mysql/estimations/check_cardinality.sh
```

Expected: the new test and all existing adaptive tests PASS; syntax check exits
0.

- [ ] **Step 8: Commit Task 1**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/fake_mysql.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): normalize cardinality type display"
```

---

### Task 2: Boundary-Aware Wrapping and Aligned Multiline Rows

**Files:**
- Modify: `mysql/estimations/tests/fake_mysql.sh:45-80`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh:225-370`
- Modify: `mysql/estimations/check_cardinality.sh:378-525`

**Interfaces:**
- Consumes: `DISPLAY_TYPE`, `TYPE_WIDTH`, `INDEXES_WIDTH`, and one normalized logical result row.
- Produces: `wrap_type TEXT WIDTH` and `wrap_indexes TEXT WIDTH`, each setting newline-delimited global `WRAPPED_TEXT`; `format_table_report` emits aligned physical lines.

- [ ] **Step 1: Add deterministic wrapping fixtures**

Extend the fake `cardinality:column_metadata` case:

```bash
layout_wrapped)
    printf "flags\tset('audit','billing','security','reporting')\tset\tYES\t8\tidx_flags\tLEADING_SINGLE\t1\tidx_flags(#1), idx_flags_created_at(#1), uk_flags_external_reference(#1)\n"
    ;;
layout_oversized_index)
    printf 'external_reference\tvarchar(128)\tvarchar\tNO\t100\tidx_external\tLEADING_SINGLE\t1\tidx_external_reference_identifier_exceeding_the_terminal_cell_width(#1)\n'
    ;;
```

- [ ] **Step 2: Add helpers for inspecting physical table lines**

Add these portable test helpers:

```bash
pipe_offsets() {
    PIPE_OFFSETS=$(printf '%s' "$1" | awk '{s=""; for(i=1;i<=length($0);i++) if(substr($0,i,1)=="|") s=s i ","; print s}')
}

assert_table_lines_aligned() {
    local header_offsets line offsets
    report_line 'COLUMN'
    pipe_offsets "$REPORT_LINE"
    header_offsets=$PIPE_OFFSETS
    while IFS= read -r line; do
        case "$line" in
            *' | '*' | '*' | '*' | '*' | '*' | '*' | '*)
                pipe_offsets "$line"
                offsets=$PIPE_OFFSETS
                [[ "$offsets" == "$header_offsets" ]] || fail "$LAST_CASE: misaligned line [$line]"
                [[ ${#line} -le 120 ]] || fail "$LAST_CASE: line exceeds 120 columns"
                ;;
        esac
    done <<EOF
$OUTPUT
EOF
}
```

- [ ] **Step 3: Add failing multiline and oversized-index tests**

Add and register:

```bash
test_report_wraps_type_and_all_index_entries() {
    run_scenario layout_wrapped -l x -d app -t transactions --mode metadata --no-color
    assert_status 0
    assert_contains "$OUTPUT" "set('audit',"
    assert_contains "$OUTPUT" "'reporting')"
    assert_contains "$OUTPUT" 'idx_flags(#1),'
    assert_contains "$OUTPUT" 'idx_flags_created_at(#1),'
    assert_contains "$OUTPUT" 'uk_flags_external_reference(#1)'
    assert_not_contains "$OUTPUT" '...'
    assert_table_lines_aligned
}

test_report_hard_wraps_one_oversized_index() {
    run_scenario layout_oversized_index -l x -d app -t transactions --mode metadata --no-color
    assert_status 0
    assert_contains "$OUTPUT" 'idx_external_'
    assert_contains "$OUTPUT" 'reference_'
    assert_contains "$OUTPUT" 'width(#1)'
    assert_not_contains "$OUTPUT" '...'
    assert_table_lines_aligned
}

run_test wrapped_multiline test_report_wraps_type_and_all_index_entries
run_test wrapped_oversized_index test_report_hard_wraps_one_oversized_index
```

- [ ] **Step 4: Run the new tests and verify they fail**

Run:

```bash
TEST_FILTER=wrapped_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: the Task 1 test passes; multiline tests FAIL because indexes and long
types still use ellipsis truncation.

- [ ] **Step 5: Implement a portable TYPE wrapper**

Declare the `awk` program in a shell string before invoking it, matching the
project's macOS workaround:

```bash
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
```

This retains every character, including comma-adjacent spaces, and hard-wraps
when no comma occurs within the cell.

- [ ] **Step 6: Implement an index-entry-aware wrapper**

Implement `wrap_indexes TEXT WIDTH` using a predeclared portable `awk` program.
It must:

1. Split only on the literal delimiter `, `.
2. Reattach `,` to every non-final entry.
3. Pack complete entries while `length(line) + 1 + length(entry) <= width`.
4. Move a complete entry to the next line when it does not fit the remaining
   space.
5. Emit `substr(entry, 1, width)` chunks only when `length(entry) > width`.
6. Set `WRAPPED_TEXT` to newline-delimited fragments and emit `---` unchanged.

Use this concrete program shape:

```bash
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
```

- [ ] **Step 7: Render one logical row as multiple aligned physical lines**

In `format_table_report`, normalize and wrap before rendering:

```bash
normalize_display_type "$type"
wrap_type "$DISPLAY_TYPE" "$TYPE_WIDTH"
type_lines=$WRAPPED_TEXT
wrap_indexes "$indexes" "$INDEXES_WIDTH"
index_lines=$WRAPPED_TEXT
```

Use newline-delimited queues compatible with Bash 3.2. On the first iteration,
render the real values. On later iterations, pass empty strings for every field
except the next type/index fragments. Continue until both queues are exhausted.
The `printf` format string must remain exactly the same as the header format.

Add this queue helper:

```bash
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
```

Use a helper with this interface to avoid duplicating width geometry:

```bash
render_report_line() {
    RENDERED_LINE=$(printf "%-${COLUMN_WIDTH}s | %-${TYPE_WIDTH}s | %${ELIGIBLE_WIDTH}s | %${CARDINALITY_WIDTH}s | %${RATIO_WIDTH}s | %${SELECTIVITY_WIDTH}s | %-${SOURCE_WIDTH}s | %-${INDEXES_WIDTH}s" \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")
}
```

Extract the first queue item with `${queue%%$'\n'*}` and remove it with a
`case` that distinguishes single-line from multiline values. Do not use
`mapfile`, associative arrays, negative substring indexes, or GNU-only tools.

Print each physical line as:

```bash
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
```

After the physical-line loop, retain the existing single error print.

- [ ] **Step 8: Run focused wrapping and alignment tests**

Run:

```bash
TEST_FILTER=wrapped_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=alignment_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash -n mysql/estimations/check_cardinality.sh
```

Expected: all focused tests PASS and syntax check exits 0.

- [ ] **Step 9: Commit Task 2**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/fake_mysql.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): wrap cardinality report columns"
```

---

### Task 3: Color, Error Ordering, Wide-Terminal, and Export Regression Coverage

**Files:**
- Modify: `mysql/estimations/tests/fake_mysql.sh:12-76`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh:225-380`
- Modify if tests expose a defect: `mysql/estimations/check_cardinality.sh:378-560`

**Interfaces:**
- Consumes: multiline renderer from Task 2 and unchanged normalized result/export paths.
- Produces: regression proof for ANSI coloring, error placement, 160-column geometry, and original CSV/TSV values.

- [ ] **Step 1: Add a wrapped error fixture**

Add an early fake-query failure:

```bash
layout_wrapped_error:*cardinality:exact_column*wrapped_failure*)
    printf '%s\n' 'forced wrapped-column failure' >&2
    exit 1
    ;;
```

Add column metadata:

```bash
layout_wrapped_error)
    printf "wrapped_failure\tset('audit','billing','security','reporting')\tset\tYES\t8\tN/A\tUNAVAILABLE\t0\tidx_wrapped_failure_reference(#1), idx_wrapped_failure_created_at(#1)\n"
    ;;
```

- [ ] **Step 2: Add failing or regression tests for color and error ordering**

Add and register:

```bash
test_wrapped_rows_preserve_color_and_error_order() {
    run_scenario layout_wrapped_error -l x -d app -t transactions --mode exact
    assert_status 4
    assert_has_ansi "$OUTPUT"
    error_count=$(printf '%s\n' "$OUTPUT" | awk '/Error: forced wrapped-column failure/ {count++} END {print count+0}')
    [[ "$error_count" -eq 1 ]] || fail "wrapped error printed $error_count times"
    last_index_line=$(printf '%s\n' "$OUTPUT" | awk '/idx_wrapped_failure_created_at/ {line=NR} END {print line+0}')
    error_line=$(printf '%s\n' "$OUTPUT" | awk '/Error: forced wrapped-column failure/ {print NR; exit}')
    [[ "$error_line" -gt "$last_index_line" ]] || fail 'wrapped error printed before continuation lines'
    error_color_count=$(printf '%s\n' "$OUTPUT" | LC_ALL=C awk 'index($0, "\033[0;31m") == 1 {count++} END {print count+0}')
    [[ "$error_color_count" -ge 2 ]] || fail 'ERROR color is not applied to every wrapped physical line'
}

run_test wrapped_color_error test_wrapped_rows_preserve_color_and_error_order
```

- [ ] **Step 3: Add a 160-column multiline geometry test**

```bash
test_wrapped_report_honors_wide_terminal() {
    TERM=xterm COLUMNS=160 run_scenario layout_wrapped -l x -d app -t transactions --mode metadata --no-color
    assert_status 0
    report_line 'COLUMN'
    [[ ${#REPORT_LINE} -eq 160 ]] || fail "wide header is not 160 columns"
    while IFS= read -r line; do
        case "$line" in
            *' | '*' | '*' | '*' | '*' | '*' | '*' | '*)
                [[ ${#line} -le 160 ]] || fail "wide physical line exceeds 160 columns"
                ;;
        esac
    done <<EOF
$OUTPUT
EOF
}

run_test wrapped_wide test_wrapped_report_honors_wide_terminal
```

- [ ] **Step 4: Extend export regression coverage for ENUM and wrapped fields**

Run `layout_types` with CSV output and assert the original ENUM definition is
present:

```bash
test_wrapped_display_does_not_change_exports() {
    out="$TMP_ROOT/wrapped.csv"
    run_scenario layout_types -l x -d app -t transactions --mode metadata \
        --no-color -o "$out" --format csv
    assert_status 0
    assert_contains "$(sed -n '3p' "$out")" "enum('new','processing','complete')"

    out="$TMP_ROOT/wrapped.tsv"
    run_scenario layout_wrapped -l x -d app -t transactions --mode metadata \
        --no-color -o "$out" --format tsv
    assert_status 0
    assert_contains "$(sed -n '2p' "$out")" "set('audit','billing','security','reporting')"
    assert_contains "$(sed -n '2p' "$out")" 'idx_flags(#1), idx_flags_created_at(#1), uk_flags_external_reference(#1)'
}

run_test wrapped_export test_wrapped_display_does_not_change_exports
```

- [ ] **Step 5: Run the complete verification matrix**

Run:

```bash
/bin/bash -n mysql/estimations/check_cardinality.sh
/bin/bash -n mysql/estimations/tests/fake_mysql.sh
/bin/bash -n mysql/estimations/tests/test_check_cardinality.sh
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
git diff --check
```

Expected: every syntax check exits 0, the complete test suite reports zero
failures, and `git diff --check` prints nothing.

- [ ] **Step 6: Manually inspect deterministic 120- and 160-column output**

Run the two fake scenarios directly through the test harness by temporarily
setting `TEST_FILTER=wrapped_multiline` and `TEST_FILTER=wrapped_wide`. Confirm
from captured output that:

- ordinary `bigint unsigned` is visible without ellipsis;
- `ENUM(...)` members are absent from terminal output;
- every index entry is present;
- continuation cells are blank except for `TYPE` and `INDEXES`;
- ANSI-free separators occupy the same offsets on all physical lines.

Do not modify the harness to print captured production output permanently.

- [ ] **Step 7: Commit Task 3**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/fake_mysql.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "test(mysql): harden wrapped cardinality output"
```

- [ ] **Step 8: Record final branch state**

Run:

```bash
git status --short --branch
git log --oneline -5
```

Expected: a clean `codex/cardinality-wrapped-columns` branch containing the
design commits and the three implementation commits.
