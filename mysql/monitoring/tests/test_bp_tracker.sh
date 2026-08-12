#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../bp_tracker.sh"
FAKE="$TEST_DIR/fake_mysql_bp_tracker.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bp-tracker-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
TEST_COUNT=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$3"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$3"; TEST_COUNT=$((TEST_COUNT + 1)); }
assert_no_ansi() { if LC_ALL=C grep -q $'\033' "$1"; then fail "$2"; fi; TEST_COUNT=$((TEST_COUNT + 1)); }
run_failure() { if "$@" >"$TMP/failure.out" 2>&1; then fail "command unexpectedly succeeded: $*"; fi; }

if "$SCRIPT" >"$TMP/no-arguments.out" 2>&1; then :; else fail 'no-argument help did not succeed'; fi
assert_contains "$TMP/no-arguments.out" 'Usage:' 'no-argument invocation did not show help'
assert_contains "$TMP/no-arguments.out" 'Required:' 'no-argument help did not show required options'
assert_contains "$TMP/no-arguments.out" 'Monitoring:' 'no-argument help did not show monitoring options'
assert_contains "$TMP/no-arguments.out" 'Safety:' 'no-argument help did not show safety guidance'
assert_contains "$TMP/no-arguments.out" 'Examples:' 'no-argument help did not show examples'
run_failure "$SCRIPT" --login-path x --interval 0
assert_contains "$TMP/failure.out" 'interval must be a positive integer' 'zero interval was accepted'
assert_contains "$TMP/failure.out" 'Usage:' 'invalid invocation did not show help'
run_failure "$SCRIPT" --login-path x --top-objects 101
assert_contains "$TMP/failure.out" 'count must be between 1 and 100' 'large top object count was accepted'

"$SCRIPT" --help >"$TMP/help.out"
assert_contains "$TMP/help.out" '--no-color' 'help omits no-color'
assert_contains "$TMP/help.out" 'Runtime and output:' 'help does not use standard runtime section'
assert_contains "$TMP/help.out" 'Expensive optional views:' 'help does not document optional-view risk'
assert_no_ansi "$TMP/help.out" 'redirected help contains ANSI'

: > "$TMP/sql.log"
FAKE_MYSQL_BP_LOG="$TMP/sql.log" MYSQL_BIN="$FAKE" "$SCRIPT" --login-path monitor --no-color --output-file "$TMP/output.log" >"$TMP/default.out"
assert_contains "$TMP/default.out" 'BUFFER POOL ACTIVITY' 'default global section missing'
assert_contains "$TMP/default.out" 'Read I/O: 6000 pages/s' 'global read I/O missing'
assert_contains "$TMP/default.out" 'Young promotions/s: N/A' 'first delta was not unavailable'
assert_not_contains "$TMP/sql.log" 'innodb_buffer_stats_by_table' 'default executed costly top-objects query'
assert_not_contains "$TMP/sql.log" 'FROM sys.session' 'default executed session query'
assert_no_ansi "$TMP/default.out" 'no-color default output contains ANSI'
assert_no_ansi "$TMP/output.log" 'output log contains ANSI'
assert_not_contains "$TMP/default.out" 'Interactive options:' 'redirected output contains interactive legend'
assert_not_contains "$TMP/output.log" 'Interactive options:' 'output log contains interactive legend'

run_pseudo_tty() {
    local term=$1 output_file=$2
    shift 2

    case "$(uname -s)" in
        Darwin)
            { sleep 1; printf q; } | TERM="$term" script -q /dev/null "$@" >"$output_file" 2>&1
            ;;
        Linux)
            local runner_command
            printf -v runner_command '%q ' env "TERM=$term" "$@"
            { sleep 1; printf q; } | script -q -e -c "$runner_command" /dev/null >"$output_file" 2>&1
            ;;
        *) fail "unsupported pseudo-terminal platform: $(uname -s)" ;;
    esac
}

FAKE_MYSQL_BP_LOG="$TMP/tty.sql" run_pseudo_tty xterm "$TMP/tty.out" \
    env "MYSQL_BIN=$FAKE" "$SCRIPT" --login-path monitor --interval 1
sed $'s/\033\\[[0-9;]*[[:alpha:]]//g; s/\033([[:alpha:]]//g' "$TMP/tty.out" >"$TMP/tty-plain.out"
assert_contains "$TMP/tty-plain.out" 'Interactive options: [q] Quit' 'TTY frame is missing the reduced interactive legend'
assert_contains "$TMP/tty.out" $'\033[32mq' 'TTY legend does not color the quit key'
assert_contains "$TMP/tty.out" $'\033[31mQuit' 'TTY legend does not color the quit action'

FAKE_MYSQL_BP_LOG="$TMP/tty-no-color.sql" run_pseudo_tty xterm "$TMP/tty-no-color.out" \
    env "MYSQL_BIN=$FAKE" "$SCRIPT" --login-path monitor --interval 1 --no-color
assert_contains "$TMP/tty-no-color.out" 'Interactive options: [q] Quit' 'no-color TTY frame is missing the reduced interactive legend'
tty_no_color_output=$(< "$TMP/tty-no-color.out")
tty_no_color_without_refresh=${tty_no_color_output//$'\033[H\033[2J'/}
case "$tty_no_color_without_refresh" in
    *$'\033'*) fail 'no-color interactive legend emitted ANSI styles' ;;
esac

: > "$TMP/optional.sql"
FAKE_MYSQL_BP_LOG="$TMP/optional.sql" MYSQL_BIN="$FAKE" "$SCRIPT" --login-path monitor --no-color --top-objects 7 --object-filter 'a%_\\b' --active-sessions 3 --user-filter 'u%_\\v' --output-file "$TMP/optional.log" >"$TMP/optional.out"
assert_contains "$TMP/optional.sql" 'bp-tracker:top-objects' 'top objects query missing'
assert_contains "$TMP/optional.sql" 'LIMIT 7' 'top objects limit missing'
assert_contains "$TMP/optional.sql" 'CONVERT(X' 'top object filter is not encoded'
assert_contains "$TMP/optional.sql" 'ESCAPE' 'top object filter is not LIKE escaped'
assert_contains "$TMP/optional.sql" 'bp-tracker:active-sessions' 'session query missing'
assert_contains "$TMP/optional.sql" 'LIMIT 3' 'session limit missing'
assert_contains "$TMP/optional.out" 'SELECT confidential_statement' 'session statement missing on screen'
assert_not_contains "$TMP/optional.log" 'confidential_statement' 'session statement leaked to log'

FAKE_MYSQL_BP_MODE=top-failure FAKE_MYSQL_BP_LOG="$TMP/top-failure.sql" MYSQL_BIN="$FAKE" "$SCRIPT" --login-path monitor --no-color --top-objects >"$TMP/top-failure.out"
assert_contains "$TMP/top-failure.out" 'TOP OBJECTS UNAVAILABLE' 'top objects failure was not degraded'
assert_contains "$TMP/top-failure.out" 'BUFFER POOL ACTIVITY' 'top objects failure stopped global metrics'

FAKE_MYSQL_BP_MODE=sessions-failure FAKE_MYSQL_BP_LOG="$TMP/sessions-failure.sql" MYSQL_BIN="$FAKE" "$SCRIPT" --login-path monitor --no-color --active-sessions >"$TMP/sessions-failure.out"
assert_contains "$TMP/sessions-failure.out" 'ACTIVE USER SESSIONS UNAVAILABLE' 'sessions failure was not degraded'
assert_contains "$TMP/sessions-failure.out" 'BUFFER POOL ACTIVITY' 'sessions failure stopped global metrics'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
