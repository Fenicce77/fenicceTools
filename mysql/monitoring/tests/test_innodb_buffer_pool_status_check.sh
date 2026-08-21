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

run_case() {
    local name=$1
    shift
    set +e
    "$SCRIPT" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
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
FAKE_MYSQL_BP_RESIZE_LOG="$TMP/sql.log" "$SCRIPT" --login-path monitor --no-color --mysql-bin "$FAKE" >"$TMP/sample.out"
assert_contains "$TMP/sql.log" 'Innodb_buffer_pool_resize_status' 'resize status was not queried'
assert_contains "$TMP/sql.log" 'Innodb_buffer_pool_resize_status_progress' 'resize progress was not queried'
assert_contains "$TMP/sql.log" '@@GLOBAL.innodb_buffer_pool_size' 'buffer pool target size was not queried'
assert_not_contains "$TMP/sql.log" 'SET ' 'query mutates server state'
assert_contains "$TMP/sample.out" $'Resizing\t0\t42\t1073741824' 'collector did not preserve the fake client response'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
