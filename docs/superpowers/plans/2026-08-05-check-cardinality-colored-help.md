# Check Cardinality Colored Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `check_cardinality.sh` help invocation render the same friendly, structured, always-colored ANSI output.

**Architecture:** Keep help rendering self-contained inside `show_help`, with a dedicated local ANSI palette that does not depend on TTY detection or runtime color initialization. Exercise the real executable through the existing shell integration suite so the tests cover early argument parsing and all help entry paths.

**Tech Stack:** Bash 3.2, ANSI CSI color sequences, existing shell integration test harness.

## Global Constraints

- Preserve macOS Bash 3.2 and Linux Bash compatibility.
- Preserve `set -euo pipefail`.
- Help colors are unconditional, including redirected output and `--no-color --help`.
- Runtime `--no-color` behavior remains unchanged.
- Preserve all current help content, options, examples, safety statements, and exit code 0.
- Use `printf` for ANSI construction; do not use `echo -e` or GNU-only tools.

---

### Task 1: Always-Colored Friendly Help Renderer

**Files:**
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`
- Modify: `mysql/estimations/check_cardinality.sh:37-87`

**Interfaces:**
- Consumes: `show_help`, early `main` no-argument handling, and `parse_arguments` handling of `-h`, `--help`, and `--no-color`.
- Produces: one status-0 ANSI help screen with title, `Usage`, `Required`, `Analysis`, `Output and runtime`, `Examples`, and `Safety` sections.

- [ ] **Step 1: Add a test helper and failing help-color behavior test**

Add byte-level ANSI assertions to the existing test runner:

```bash
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
```

Add a focused test that exercises the real script:

```bash
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
```

Register it with:

```bash
run_test help_color test_help_is_always_colored_and_runtime_no_color_is_preserved
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
TEST_FILTER=help_color /bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL at `assert_has_ansi` because `show_help` currently emits plain text when the test captures stdout.

- [ ] **Step 3: Implement the dedicated help palette and structured renderer**

At the beginning of `show_help`, define only local variables so strict mode and early parsing remain safe:

```bash
show_help() {
    local help_title help_section help_option help_value help_warning help_error help_reset
    help_title=$(printf '\033[1;36m')
    help_section=$(printf '\033[1;33m')
    help_option=$(printf '\033[0;32m')
    help_value=$(printf '\033[0;36m')
    help_warning=$(printf '\033[0;33m')
    help_error=$(printf '\033[0;31m')
    help_reset=$(printf '\033[0m')
```

Render the existing content using ANSI values around semantic tokens. Use the following layout contract:

```bash
    printf '%s%s%s\n\n' "$help_title" 'MySQL Cardinality Analyzer' "$help_reset"
    printf '%sUsage:%s\n' "$help_section" "$help_reset"
    printf '  %s%s%s %s-l LOGIN_PATH -d DATABASE (-t TABLES | -f FILE) [OPTIONS]%s\n\n' \
        "$help_value" "$0" "$help_reset" "$help_value" "$help_reset"

    printf '%sRequired:%s\n' "$help_section" "$help_reset"
    printf '  %s%-35s%s %s\n' "$help_option" '-l, --login-path PATH' "$help_reset" 'MySQL login-path for the remote server'
```

Continue the same pattern for every existing option without changing wording or defaults. Color each section heading with `help_section`, each option signature with `help_option`, example command lines with `help_value`, the general safety statement with `help_warning`, and the production refusal phrase with `help_error`. Finish every colored segment with `help_reset`, including the final line.

Do not call `initialize_colors` from `show_help`; the help palette must remain independent of `NO_COLOR`, stdout TTY state, and `TERM`.

- [ ] **Step 4: Run focused and complete tests and verify GREEN**

Run:

```bash
TEST_FILTER=help_color /bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: the focused test passes and the complete suite reports 17 passed, 0 failed.

- [ ] **Step 5: Run portability and output verification**

Run:

```bash
/bin/bash -n mysql/estimations/check_cardinality.sh
/bin/bash -n mysql/estimations/tests/test_check_cardinality.sh
TERM=dumb mysql/estimations/check_cardinality.sh --help > /tmp/check-cardinality-help.out
LC_ALL=C grep -F $'\033[' /tmp/check-cardinality-help.out
rg -n 'echo -e|declare -A|mapfile|readarray|sed -r|sed -E' \
  mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git diff --check
```

Expected: syntax passes; redirected help contains ANSI; the compatibility search has no findings; the diff has no whitespace errors.

- [ ] **Step 6: Commit the implementation**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): color cardinality analyzer help"
```
