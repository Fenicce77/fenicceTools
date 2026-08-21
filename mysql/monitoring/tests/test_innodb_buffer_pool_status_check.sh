#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../../Innodb_buffer_pool_status.check.sh"
FAKE="$TEST_DIR/fake_mysql_bp_resize.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bp-resize-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
TEST_COUNT=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$3"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$3"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_no_ansi() { if LC_ALL=C grep -q $'\033' "$1"; then fail "$2"; fi; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_equals() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_occurrences() { local count; count=$(grep -F -c -- "$2" "$1" || true); [[ "$count" -eq "$3" ]] || fail "$4: expected $3, got $count"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_at_least_occurrences() { local count; count=$(grep -F -c -- "$2" "$1" || true); [[ "$count" -ge "$3" ]] || fail "$4: expected at least $3, got $count"; TEST_COUNT=$((TEST_COUNT + 1)); }

run_case() {
    local name=$1
    shift
    set +e
    "$SCRIPT" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
}

run_pseudo_tty() {
    local output_file=$1 input_command=$2 command='' argument
    shift 2

    for argument in "$SCRIPT" "$@"; do
        printf -v command '%s%q ' "$command" "$argument"
    done

    set +e
    case "$(uname -s)" in
        Darwin)
            /bin/bash -c "$input_command" | TERM=xterm script -q /dev/null /bin/bash -c "$command" \
                >"$output_file" 2>&1
            STATUS=${PIPESTATUS[1]}
            ;;
        Linux)
            /bin/bash -c "$input_command" | TERM=xterm script -q -e -c "$command" /dev/null \
                >"$output_file" 2>&1
            STATUS=${PIPESTATUS[1]}
            ;;
        *) fail "unsupported pseudo-terminal platform: $(uname -s)" ;;
    esac
    set -e
}

remove_refresh_sequences() {
    LC_ALL=C sed $'s/\033\\[H\033\\[2J//g' "$1"
}

remove_ansi_styles() {
    LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' "$1" | tr -d '\r'
}

run_case no_arguments
assert_status 2
assert_contains "$TMP/no_arguments.err" 'ERROR: --login-path is required.' 'missing login path error was not emitted'
assert_contains "$TMP/no_arguments.err" 'Usage:' 'missing login path did not show help'

run_case invalid_interval --login-path monitor --interval 0
assert_status 2
assert_contains "$TMP/invalid_interval.err" 'ERROR: --interval must be a positive integer.' 'zero interval was accepted'
assert_contains "$TMP/invalid_interval.err" 'Usage:' 'invalid interval did not show help'

run_case invalid_mysql_bin --login-path monitor --mysql-bin /not/a/mysql/client
assert_status 2
assert_contains "$TMP/invalid_mysql_bin.err" 'ERROR: --mysql-bin must reference a regular executable file.' 'invalid mysql binary was accepted'
assert_contains "$TMP/invalid_mysql_bin.err" 'Usage:' 'invalid mysql binary did not show help'

"$SCRIPT" --help --no-color >"$TMP/help.out"
assert_contains "$TMP/help.out" 'Usage:' 'help did not show usage'
assert_contains "$TMP/help.out" '--login-path NAME' 'help did not describe login path'
assert_contains "$TMP/help.out" '--interval SECONDS' 'help did not describe interval'
assert_contains "$TMP/help.out" '--mysql-bin PATH' 'help did not describe mysql binary'
assert_no_ansi "$TMP/help.out" 'no-color help contains ANSI sequences'

: > "$TMP/sql.log"
export FAKE_MYSQL_BP_RESIZE_LOG="$TMP/sql.log"
FAKE_MYSQL_BP_RESIZE_LOG="$TMP/sql.log" "$SCRIPT" --login-path monitor --no-color --mysql-bin "$FAKE" >"$TMP/sample.out"
status_variables=$(grep -oE 'Innodb_buffer_pool_[[:alnum:]_]+' "$TMP/sql.log" | LC_ALL=C sort -u)
assert_equals "$status_variables" $'Innodb_buffer_pool_resize_status\nInnodb_buffer_pool_resize_status_code\nInnodb_buffer_pool_resize_status_progress' 'unexpected resize status variable inventory'

normalized_sql=$(tr '\n\t' '  ' < "$TMP/sql.log" | tr -s ' ' | tr '[:lower:]' '[:upper:]')
assert_contains <(printf '%s\n' "$normalized_sql") 'FROM PERFORMANCE_SCHEMA.GLOBAL_STATUS WHERE' 'source must be followed immediately by WHERE'
from_keyword_count=$(printf '%s\n' "$normalized_sql" | grep -oF 'FROM ' | wc -l | tr -d '[:space:]')
assert_equals "$from_keyword_count" '1' 'query must contain exactly one FROM source keyword'
from_clause=${normalized_sql#* FROM }
from_clause=${from_clause%% WHERE *}
assert_equals "$from_clause" 'PERFORMANCE_SCHEMA.GLOBAL_STATUS' 'unexpected FROM clause inventory'
assert_not_contains <(printf '%s\n' "$normalized_sql") ' JOIN ' 'query must not join another source'
assert_not_contains <(printf '%s\n' "$from_clause") ',' 'FROM clause must not use comma sources'
assert_not_contains <(printf '%s\n' "$normalized_sql") ' UNION ' 'query must not combine another source'

target_expressions=$(grep -oF '@@GLOBAL.innodb_buffer_pool_size' "$TMP/sql.log" | wc -l | tr -d '[:space:]')
assert_equals "$target_expressions" '1' 'buffer pool target expression must occur exactly once'
assert_not_contains "$TMP/sql.log" 'SET ' 'query mutates server state'
assert_contains "$TMP/sample.out" 'Stage: No resize in progress (0)' 'completion stage was not rendered'
assert_contains "$TMP/sample.out" 'Stage progress: 42%' 'completion stage progress was not rendered'
assert_contains "$TMP/sample.out" '[######----------] 42%' 'progress bar did not use 16-cell floor arithmetic'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_case withdrawing -l monitor --no-color --mysql-bin "$FAKE"
assert_status 1
assert_contains "$TMP/withdrawing.out" 'Stage: Withdrawing blocks (3)' 'withdrawing stage was not rendered'
assert_contains "$TMP/withdrawing.out" 'Stage progress: 42%' 'withdrawing stage progress was not rendered'
assert_contains "$TMP/withdrawing.out" '[######----------] 42%' 'withdrawing bar did not use 16-cell floor arithmetic'
assert_contains "$TMP/withdrawing.out" 'Target buffer pool size: 8.00 GiB' 'target size was not formatted as GiB'

FAKE_MYSQL_BP_RESIZE_MODE=unavailable_numeric run_case unavailable -l monitor --no-color --mysql-bin "$FAKE"
assert_status 1
assert_contains "$TMP/unavailable.out" 'Stage progress: N/A' 'unavailable numeric progress was not rendered as N/A'
assert_contains "$TMP/unavailable.out" 'Numeric resize status is unavailable' 'unavailable numeric compatibility note was not rendered'

FAKE_MYSQL_BP_RESIZE_MODE=failed run_case failed -l monitor --no-color --mysql-bin "$FAKE"
assert_status 7
assert_contains "$TMP/failed.out" 'Stage: Resize failed (7)' 'failure stage was not rendered'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_case redirected_color -l monitor --mysql-bin "$FAKE"
assert_status 1
assert_no_ansi "$TMP/redirected_color.out" 'redirected active sample contains ANSI sequences'
assert_not_contains "$TMP/redirected_color.out" 'Interactive options:' 'redirected active sample contains interactive legend'
assert_occurrences "$TMP/redirected_color.out" 'InnoDB Buffer Pool Resize Monitor' 1 'redirected active state rendered more than once'

TERM=dumb FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_case dumb_terminal -l monitor --mysql-bin "$FAKE"
assert_status 1
assert_no_ansi "$TMP/dumb_terminal.out" 'TERM=dumb sample contains ANSI sequences'
assert_not_contains "$TMP/dumb_terminal.out" 'Interactive options:' 'TERM=dumb sample contains interactive legend'
assert_occurrences "$TMP/dumb_terminal.out" 'InnoDB Buffer Pool Resize Monitor' 1 'TERM=dumb active state rendered more than once'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_pseudo_tty "$TMP/tty.out" '{ sleep 2; printf q; }' \
    --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty.out" $'\033[H\033[2J' 'TTY output does not refresh the screen'
remove_ansi_styles "$TMP/tty.out" >"$TMP/tty.plain"
assert_contains "$TMP/tty.plain" 'Interactive options: [q] Quit' 'TTY output is missing the interactive legend'
assert_contains "$TMP/tty.out" $'\033[32mq' 'TTY legend does not color the quit key green'
assert_contains "$TMP/tty.out" $'\033[1;33mStage: Withdrawing blocks (3)' 'TTY active stage did not use yellow output'
assert_at_least_occurrences "$TMP/tty.out" 'InnoDB Buffer Pool Resize Monitor' 2 'TTY active resize did not poll'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_pseudo_tty "$TMP/tty-no-color.out" '{ sleep 1; printf q; }' \
    --login-path monitor --interval 1 --no-color --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty-no-color.out" $'\033[H\033[2J' 'no-color TTY output does not refresh the screen'
assert_contains "$TMP/tty-no-color.out" 'Interactive options: [q] Quit' 'no-color TTY output is missing the interactive legend'
remove_refresh_sequences "$TMP/tty-no-color.out" >"$TMP/tty-no-color.plain"
assert_no_ansi "$TMP/tty-no-color.plain" 'no-color TTY output contains ANSI styling'

FAKE_MYSQL_BP_RESIZE_MODE=complete run_pseudo_tty "$TMP/tty-complete.out" ':' \
    --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 0
assert_occurrences "$TMP/tty-complete.out" 'InnoDB Buffer Pool Resize Monitor' 1 'completed TTY state rendered more than once'
assert_not_contains "$TMP/tty-complete.out" 'Interactive options:' 'completed TTY state waited for interactive input'

FAKE_MYSQL_BP_RESIZE_MODE=failed run_pseudo_tty "$TMP/tty-failed.out" ':' \
    --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 7
assert_occurrences "$TMP/tty-failed.out" 'InnoDB Buffer Pool Resize Monitor' 1 'failed TTY state rendered more than once'
assert_not_contains "$TMP/tty-failed.out" 'Interactive options:' 'failed TTY state waited for interactive input'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
