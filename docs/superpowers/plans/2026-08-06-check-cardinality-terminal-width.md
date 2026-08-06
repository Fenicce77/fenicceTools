# Check Cardinality Terminal Width Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cardinality terminal table use the active macOS/Linux TTY width and provide a validated `--terminal-width N` override.

**Architecture:** Keep the renderer and width allocator unchanged. Add one explicit CLI width source and replace the single-source `tput` probe with a portable precedence chain: override, active `stty` geometry, exported `COLUMNS`, `tput`, then 120. Extend the existing fake-MySQL integration harness with deterministic non-TTY and pseudo-TTY geometry tests.

**Tech Stack:** macOS Bash 3.2, Linux Bash, portable `stty`/`tput`, BSD `script`, util-linux `script`, shell integration tests.

## Global Constraints

- Preserve `set -euo pipefail` and macOS Bash 3.2/Linux compatibility.
- Accept `--terminal-width N` only for integer values greater than or equal to 120; invalid explicit values exit 2.
- Width precedence is: explicit override, active `stty size`, exported `COLUMNS`, `tput cols`, fallback 120.
- Ignore invalid automatic candidates and continue to the next source.
- Do not cap valid widths; a 180-column terminal produces 180-character table lines.
- Preserve the 120-column minimum and `INDEXES_WIDTH >= 12`.
- Keep ANSI sequences outside padded values and retain the existing TTY-only color policy.
- Do not change SQL, cardinality calculations, status/error semantics, wrapping rules, ENUM normalization, or CSV/TSV output.
- Keep every table physical line exactly equal to the selected width with header-identical separator offsets.
- Expected terminal-probe failures must remain safe under strict mode.

---

### Task 1: Explicit Terminal Width CLI Override

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh:3-179,456-462`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh:132-190,470-530`

**Interfaces:**
- Consumes: `--terminal-width N` in either `--terminal-width=N` or `--terminal-width N` form.
- Produces: global `TERMINAL_WIDTH_OPTION`; `refresh_terminal_width` selects it before automatic sources.

- [ ] **Step 1: Add failing help and CLI validation tests**

Extend `test_cli_help_and_compatibility`:

```bash
strip_ansi "$OUTPUT"
assert_contains "$STRIPPED_OUTPUT" '--terminal-width'
assert_contains "$STRIPPED_OUTPUT" 'minimum: 120'
run_case width_long --login-path=test --database=app --tables=users \
    --terminal-width=160 --mysql-bin="$FAKE_MYSQL" --no-color
assert_status 0
```

Extend `test_cli_validation_and_client_failures`:

```bash
run_case width_missing -l x -d app -t users --terminal-width
assert_status 2
assert_contains "$OUTPUT" 'Option --terminal-width requires a value.'
run_case width_text -l x -d app -t users --terminal-width wide
assert_status 2
assert_contains "$OUTPUT" 'Terminal width must be an integer greater than or equal to 120.'
run_case width_small -l x -d app -t users --terminal-width 119
assert_status 2
assert_contains "$OUTPUT" 'Terminal width must be an integer greater than or equal to 120.'
run_case width_empty -l x -d app -t users --terminal-width=
assert_status 2
assert_contains "$OUTPUT" 'Option --terminal-width requires a value.'
```

- [ ] **Step 2: Add a failing override-geometry test**

Add and register:

```bash
test_terminal_width_override_controls_geometry() {
    COLUMNS=180 run_scenario layout_wrapped -l x -d app -t transactions \
        --mode metadata --no-color --terminal-width 160
    assert_status 0
    report_line 'COLUMN'
    header=$REPORT_LINE
    [[ ${#header} -eq 160 ]] || fail "override header is not 160 columns"
    pipe_offsets "$header"
    header_offsets=$PIPE_OFFSETS
    while IFS= read -r line; do
        case "$line" in
            *' | '*' | '*' | '*' | '*' | '*' | '*' | '*)
                [[ ${#line} -eq 160 ]] || fail "override physical line is not 160 columns"
                pipe_offsets "$line"
                [[ "$PIPE_OFFSETS" == "$header_offsets" ]] || fail 'override separator offsets differ'
                ;;
        esac
    done <<EOF
$OUTPUT
EOF
    report_row_fragments flags
    [[ "$RECONSTRUCTED_TYPE" == "set('audit','billing','security','reporting')" ]] ||
        fail "override reconstructed type [$RECONSTRUCTED_TYPE]"
    [[ "$RECONSTRUCTED_INDEXES" == 'idx_flags(#1), idx_flags_created_at(#1), uk_flags_external_reference(#1)' ]] ||
        fail "override reconstructed indexes [$RECONSTRUCTED_INDEXES]"
}

run_test terminal_width_override test_terminal_width_override_controls_geometry
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
TEST_FILTER=cli_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=terminal_width_override /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: CLI tests fail because the option is unknown; geometry test fails or
exits 2 for the same reason.

- [ ] **Step 4: Add the option default, help, parser, and validation**

In `initialize_defaults` add:

```bash
TERMINAL_WIDTH_OPTION=""
```

Under `Output and runtime` in `show_help`, add:

```bash
printf '  %s%-32s%s %s%-19s%s %s\n' "$help_option" '--terminal-width' "$help_reset" "$help_value" 'N' "$help_reset" 'Override terminal width (minimum: 120)'
```

Add an example before the blank line terminating `Examples`:

```bash
printf '  %s%s -l test-mysql -d app -t users --terminal-width 180%s\n' "$help_value" "$0" "$help_reset"
```

Add parser branches before `--no-color`:

```bash
--terminal-width=*)
    TERMINAL_WIDTH_OPTION=${1#*=}
    [[ -n "$TERMINAL_WIDTH_OPTION" ]] || cli_error "Option --terminal-width requires a value."
    ;;
--terminal-width)
    require_value "$1" "${2-}"
    TERMINAL_WIDTH_OPTION=$2
    shift
    ;;
```

Add validation after execution-time validation:

```bash
if [[ -n "$TERMINAL_WIDTH_OPTION" ]]; then
    [[ "$TERMINAL_WIDTH_OPTION" =~ ^[0-9]+$ ]] ||
        cli_error "Terminal width must be an integer greater than or equal to 120."
    [[ "$TERMINAL_WIDTH_OPTION" -ge 120 ]] ||
        cli_error "Terminal width must be an integer greater than or equal to 120."
fi
```

- [ ] **Step 5: Give the explicit override first precedence**

At the beginning of `refresh_terminal_width`, after setting the fallback:

```bash
if [[ -n "$TERMINAL_WIDTH_OPTION" ]]; then
    TERM_WIDTH=$TERMINAL_WIDTH_OPTION
    return 0
fi
```

Leave the existing `tput` probe in place for this task; Task 2 replaces the
automatic path.

- [ ] **Step 6: Run focused and full verification**

Run:

```bash
TEST_FILTER=cli_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=terminal_width_override /bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash -n mysql/estimations/check_cardinality.sh
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
git diff --check
```

Expected: focused tests pass, the complete suite reports 30 passed and 0
failed, syntax exits 0, and `git diff --check` is silent.

- [ ] **Step 7: Commit Task 1**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): add terminal width override"
```

---

### Task 2: Active TTY Detection and Fallback Precedence

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh:456-470`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh:42-90,470-550`

**Interfaces:**
- Consumes: validated `TERMINAL_WIDTH_OPTION`, active stdin/stdout TTYs, `${COLUMNS:-}`, and `tput cols`.
- Produces: `read_stty_columns`, setting global `DETECTED_COLUMNS`; `valid_automatic_width VALUE`; `refresh_terminal_width`, setting `TERM_WIDTH` according to the approved precedence.

- [ ] **Step 1: Add a deterministic pseudo-TTY width runner**

Add beside `run_scenario_tty`:

```bash
run_scenario_tty_width() {
    local width=$1 scenario=$2 runner_command
    shift 2
    LAST_CASE=$scenario
    : > "$QUERY_LOG"
    set +e
    case "$(uname -s)" in
        Darwin)
            OUTPUT=$(TERM=xterm script -q /dev/null /bin/bash -c \
                'stty cols "$1"; shift; unset COLUMNS; exec "$@"' \
                width-runner "$width" env \
                "FAKE_MYSQL_QUERY_LOG=$QUERY_LOG" "FAKE_MYSQL_SCENARIO=$scenario" \
                "MYSQL_BIN=$FAKE_MYSQL" "$SCRIPT" "$@" 2>&1)
            ;;
        Linux)
            printf -v runner_command '%q ' env TERM=xterm \
                "FAKE_MYSQL_QUERY_LOG=$QUERY_LOG" "FAKE_MYSQL_SCENARIO=$scenario" \
                "MYSQL_BIN=$FAKE_MYSQL" "$SCRIPT" "$@"
            runner_command="stty cols $width; unset COLUMNS; exec $runner_command"
            OUTPUT=$(script -q -e -c "$runner_command" /dev/null 2>&1)
            ;;
        *)
            set -e
            fail "unsupported pseudo-terminal platform: $(uname -s)"
            ;;
    esac
    STATUS=$?
    set -e
    OUTPUT=${OUTPUT//$'\r'/}
}
```

The test-only helper controls the PTY width before starting the production
script and removes only carriage returns inserted by `script` capture.

- [ ] **Step 2: Add failing active-TTY and fallback tests**

Add a reusable exact-width assertion:

```bash
assert_table_width_and_alignment() {
    local expected=$1 header header_offsets line
    report_line 'COLUMN'
    header=$REPORT_LINE
    [[ ${#header} -eq "$expected" ]] || fail "$LAST_CASE: header width ${#header}, expected $expected"
    pipe_offsets "$header"
    header_offsets=$PIPE_OFFSETS
    while IFS= read -r line; do
        case "$line" in
            *' | '*' | '*' | '*' | '*' | '*' | '*' | '*)
                [[ ${#line} -eq "$expected" ]] || fail "$LAST_CASE: physical width ${#line}, expected $expected"
                pipe_offsets "$line"
                [[ "$PIPE_OFFSETS" == "$header_offsets" ]] || fail "$LAST_CASE: separator offsets differ"
                ;;
        esac
    done <<EOF
$OUTPUT
EOF
}
```

Add and register:

```bash
test_terminal_width_uses_active_stty_geometry() {
    run_scenario_tty_width 180 layout_wrapped -l x -d app -t transactions \
        --mode metadata --no-color
    assert_status 0
    assert_table_width_and_alignment 180
    report_row_fragments flags
    [[ "$RECONSTRUCTED_INDEXES" == 'idx_flags(#1), idx_flags_created_at(#1), uk_flags_external_reference(#1)' ]] ||
        fail "stty reconstructed indexes [$RECONSTRUCTED_INDEXES]"
}

test_terminal_width_override_precedes_active_tty() {
    run_scenario_tty_width 180 layout_wrapped -l x -d app -t transactions \
        --mode metadata --no-color --terminal-width 160
    assert_status 0
    assert_table_width_and_alignment 160
}

test_terminal_width_uses_columns_then_fallback() {
    COLUMNS=170 run_scenario layout_common -l x -d app -t transactions \
        --mode metadata --no-color
    assert_status 0
    assert_table_width_and_alignment 170

    COLUMNS=invalid run_scenario layout_common -l x -d app -t transactions \
        --mode metadata --no-color
    assert_status 0
    assert_table_width_and_alignment 120
}

run_test terminal_width_stty test_terminal_width_uses_active_stty_geometry
run_test terminal_width_precedence test_terminal_width_override_precedes_active_tty
run_test terminal_width_fallback test_terminal_width_uses_columns_then_fallback
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
TEST_FILTER=terminal_width_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: the override test from Task 1 passes; the active-TTY test reports 120
instead of 180 because captured `tput` returns its static value. The `COLUMNS`
test documents current platform behavior but does not replace the required
`stty` RED.

- [ ] **Step 4: Implement portable width validation and `stty` acquisition**

Replace the current automatic probe with:

```bash
valid_automatic_width() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -ge 120 ]]
}

read_stty_columns() {
    local size="" stty_rows=""
    DETECTED_COLUMNS=""
    if [[ -t 0 ]]; then
        size=$(stty size 2>/dev/null || true)
    elif [[ -t 1 ]]; then
        size=$(stty size </dev/tty 2>/dev/null || true)
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
        TERM_WIDTH=$DETECTED_COLUMNS
        return 0
    fi

    cols=${COLUMNS:-}
    if valid_automatic_width "$cols"; then
        TERM_WIDTH=$cols
        return 0
    fi

    cols=$(tput cols 2>/dev/null || true)
    if valid_automatic_width "$cols"; then TERM_WIDTH=$cols; fi
    return 0
}
```

- [ ] **Step 5: Run focused width tests**

Run:

```bash
TEST_FILTER=terminal_width_ /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: 4 width tests pass, including exact 180-character pseudo-TTY lines,
160-character explicit override lines, 170-character exported-`COLUMNS` lines,
and the 120-character invalid-candidate fallback.

- [ ] **Step 6: Run the complete verification matrix**

Run:

```bash
/bin/bash -n mysql/estimations/check_cardinality.sh
/bin/bash -n mysql/estimations/tests/fake_mysql.sh
/bin/bash -n mysql/estimations/tests/test_check_cardinality.sh
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
git diff --check
```

Expected: all syntax checks exit 0, the full suite reports 33 passed and 0
failed, and `git diff --check` is silent.

- [ ] **Step 7: Manually reproduce the original macOS symptom and corrected result**

Run:

```bash
TERM=xterm script -q /dev/null /bin/bash -c 'stty cols 180; detected=$(tput cols 2>/dev/null || true); printf "tput=%s stty=" "$detected"; stty size'
TEST_FILTER=terminal_width_stty /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Record that the first command demonstrates divergent `tput`/`stty` values on
macOS and the second proves the script selects the 180-column active geometry.

- [ ] **Step 8: Commit Task 2**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "fix(mysql): detect active terminal width"
```

- [ ] **Step 9: Record final branch state**

Run:

```bash
git status --short --branch
git log --oneline -5
```

Expected: a clean `codex/cardinality-terminal-width` branch containing the
design, plan, CLI override, and automatic-detection commits.
