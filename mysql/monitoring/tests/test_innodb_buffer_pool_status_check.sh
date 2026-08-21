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
assert_matches() { grep -E -- "$2" "$1" >/dev/null || fail "$3"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_full_help() {
    assert_contains "$1" 'Usage:' "$2 omitted help usage"
    assert_contains "$1" 'Required:' "$2 omitted the required-options section"
    assert_contains "$1" 'Options:' "$2 omitted the options section"
    assert_contains "$1" 'Examples:' "$2 omitted examples"
}

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
    local pseudo_tty_term=${PSEUDO_TTY_TERM:-xterm}
    shift 2

    for argument in "$SCRIPT" "$@"; do
        printf -v command '%s%q ' "$command" "$argument"
    done

    set +e
    case "$(uname -s)" in
        Darwin)
            /bin/bash -c "$input_command" | TERM="$pseudo_tty_term" script -q /dev/null /bin/bash -c "$command" \
                >"$output_file" 2>&1
            STATUS=${PIPESTATUS[1]}
            ;;
        Linux)
            /bin/bash -c "$input_command" | TERM="$pseudo_tty_term" script -q -e -c "$command" /dev/null \
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

run_case missing_login_value -l
assert_status 2
assert_contains "$TMP/missing_login_value.err" 'ERROR: --login-path requires a value.' 'absent login-path value was accepted'
assert_full_help "$TMP/missing_login_value.err" 'absent login-path value error'

run_case option_as_login_value -l --no-color
assert_status 2
assert_contains "$TMP/option_as_login_value.err" 'ERROR: --login-path requires a value.' 'option token was consumed as the login-path value'
assert_full_help "$TMP/option_as_login_value.err" 'option-as-login-path-value error'

run_case missing_interval_value -l monitor -i
assert_status 2
assert_contains "$TMP/missing_interval_value.err" 'ERROR: --interval requires a value.' 'absent interval value was accepted'
assert_full_help "$TMP/missing_interval_value.err" 'absent interval value error'

run_case option_as_interval_value -l monitor -i --no-color
assert_status 2
assert_contains "$TMP/option_as_interval_value.err" 'ERROR: --interval requires a value.' 'option token was consumed as the interval value'
assert_full_help "$TMP/option_as_interval_value.err" 'option-as-interval-value error'

run_case missing_mysql_bin_value -l monitor --mysql-bin
assert_status 2
assert_contains "$TMP/missing_mysql_bin_value.err" 'ERROR: --mysql-bin requires a value.' 'absent mysql-bin value was accepted'
assert_full_help "$TMP/missing_mysql_bin_value.err" 'absent mysql-bin value error'

run_case option_as_mysql_bin_value -l monitor --mysql-bin --no-color
assert_status 2
assert_contains "$TMP/option_as_mysql_bin_value.err" 'ERROR: --mysql-bin requires a value.' 'option token was consumed as the mysql-bin value'
assert_full_help "$TMP/option_as_mysql_bin_value.err" 'option-as-mysql-bin-value error'

run_pseudo_tty "$TMP/tty-option-as-value.out" ':' -l --no-color
assert_status 2
assert_contains "$TMP/tty-option-as-value.out" $'\033[1;31mERROR: --login-path requires a value.' 'option-as-value TTY error was not red'
assert_full_help "$TMP/tty-option-as-value.out" 'option-as-value TTY error'

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
assert_contains "$TMP/help.out" 'q, Q' 'help did not document the runtime quit key'
assert_contains "$TMP/help.out" 'Stage progress is for the current stage, not overall resize completion.' 'help did not define stage progress semantics'
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
assert_matches "$TMP/sample.out" '^Timestamp: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} .+$' 'normal frame omitted its timestamp'

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

FAKE_MYSQL_BP_RESIZE_MODE=query-failure-7 run_case query_failure -l monitor --mysql-bin "$FAKE"
assert_status 10
assert_no_ansi "$TMP/query_failure.out" 'redirected query failure frame contains ANSI sequences'
assert_occurrences "$TMP/query_failure.out" 'InnoDB Buffer Pool Resize Monitor' 1 'redirected query failure rendered more than one frame'
assert_contains "$TMP/query_failure.out" 'ERROR: Unable to collect resize status (mysql exit 7).' 'query failure frame omitted the client exit status'
assert_contains "$TMP/query_failure.out" 'resize status query failed with client status 7' 'query failure frame omitted the client diagnostic'
assert_matches "$TMP/query_failure.out" '^Timestamp: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} .+$' 'query failure frame omitted its timestamp'
assert_equals "$(wc -c < "$TMP/query_failure.err" | tr -d '[:space:]')" '0' 'query failure leaked the raw client diagnostic to stderr'

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

PSEUDO_TTY_TERM=dumb FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_pseudo_tty \
    "$TMP/tty-dumb.out" '{ sleep 1; printf q; }' -l monitor --interval 1 --mysql-bin "$FAKE"
assert_status 1
assert_no_ansi "$TMP/tty-dumb.out" 'TERM=dumb pseudo-TTY sample contains ANSI sequences'
assert_not_contains "$TMP/tty-dumb.out" 'Interactive options:' 'TERM=dumb pseudo-TTY sample contains interactive legend'
assert_occurrences "$TMP/tty-dumb.out" 'InnoDB Buffer Pool Resize Monitor' 1 'TERM=dumb pseudo-TTY active state rendered more than once'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_pseudo_tty "$TMP/tty.out" '{ sleep 2; printf q; }' \
    --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty.out" $'\033[H\033[2J' 'TTY output does not refresh the screen'
remove_ansi_styles "$TMP/tty.out" >"$TMP/tty.plain"
assert_contains "$TMP/tty.plain" 'Interactive options: [q] Quit' 'TTY output is missing the interactive legend'
assert_contains "$TMP/tty.out" $'\033[32mq' 'TTY legend does not color the quit key green'
assert_contains "$TMP/tty.out" $'\033[1;33mStage: Withdrawing blocks (3)' 'TTY active stage did not use yellow output'
assert_at_least_occurrences "$TMP/tty.out" 'InnoDB Buffer Pool Resize Monitor' 2 'TTY active resize did not poll'
tty_frame_count=$(grep -F -c -- 'InnoDB Buffer Pool Resize Monitor' "$TMP/tty.out")
tty_timestamp_count=$(grep -E -c -- 'Timestamp: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} .+' "$TMP/tty.out" || true)
assert_equals "$tty_timestamp_count" "$tty_frame_count" 'not every active TTY frame contained a timestamp'

FAKE_MYSQL_BP_RESIZE_MODE=withdrawing run_pseudo_tty "$TMP/tty-no-color.out" '{ sleep 1; printf q; }' \
    --login-path monitor --interval 1 --no-color --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty-no-color.out" $'\033[H\033[2J' 'no-color TTY output does not refresh the screen'
assert_contains "$TMP/tty-no-color.out" 'Interactive options: [q] Quit' 'no-color TTY output is missing the interactive legend'
remove_refresh_sequences "$TMP/tty-no-color.out" >"$TMP/tty-no-color.plain"
assert_no_ansi "$TMP/tty-no-color.plain" 'no-color TTY output contains ANSI styling'

FAKE_MYSQL_BP_RESIZE_MODE=unavailable_numeric run_pseudo_tty "$TMP/tty-unavailable.out" \
    '{ sleep 2; printf q; }' --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty-unavailable.out" $'\033[H\033[2J' 'unavailable numeric TTY output does not refresh the screen'
remove_ansi_styles "$TMP/tty-unavailable.out" >"$TMP/tty-unavailable.plain"
assert_contains "$TMP/tty-unavailable.plain" 'Interactive options: [q] Quit' 'unavailable numeric TTY output is missing the interactive legend'
assert_contains "$TMP/tty-unavailable.plain" 'Stage progress: N/A' 'unavailable numeric TTY output did not render N/A progress'
assert_at_least_occurrences "$TMP/tty-unavailable.out" 'InnoDB Buffer Pool Resize Monitor' 2 'unavailable numeric result-1 state did not poll'

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

: > "$TMP/query-failure-tty.sql.log"
FAKE_MYSQL_BP_RESIZE_LOG="$TMP/query-failure-tty.sql.log" \
    FAKE_MYSQL_BP_RESIZE_MODE=query-failure-7 run_pseudo_tty "$TMP/tty-query-failure.out" \
    '{ sleep 2; printf q; }' --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_status 10
assert_occurrences "$TMP/tty-query-failure.out" 'InnoDB Buffer Pool Resize Monitor' 1 'query failure TTY rendered more than one frame'
assert_occurrences "$TMP/tty-query-failure.out" 'ERROR: Unable to collect resize status (mysql exit 7).' 1 'query failure TTY did not render one ERROR diagnostic'
assert_contains "$TMP/tty-query-failure.out" $'\033[1;31mERROR:' 'query failure TTY ERROR was not red'
assert_not_contains "$TMP/tty-query-failure.out" 'Interactive options:' 'query failure TTY entered the polling loop'
assert_occurrences "$TMP/query-failure-tty.sql.log" 'SELECT' 1 'query failure TTY polled the collector'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
