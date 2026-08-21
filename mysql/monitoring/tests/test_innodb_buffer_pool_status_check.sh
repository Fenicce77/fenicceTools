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
status_variables=$(grep -oE 'Innodb_buffer_pool_[[:alnum:]_]+' "$TMP/sql.log" | LC_ALL=C sort -u)
assert_equals "$status_variables" $'Innodb_buffer_pool_resize_status\nInnodb_buffer_pool_resize_status_code\nInnodb_buffer_pool_resize_status_progress' 'unexpected resize status variable inventory'

query_sources=$(grep -oE 'FROM[[:space:]]+[^[:space:];]+' "$TMP/sql.log" | LC_ALL=C sort -u)
assert_equals "$query_sources" 'FROM performance_schema.global_status' 'unexpected query source inventory'

target_expressions=$(grep -oF '@@GLOBAL.innodb_buffer_pool_size' "$TMP/sql.log" | wc -l | tr -d '[:space:]')
assert_equals "$target_expressions" '1' 'buffer pool target expression must occur exactly once'
assert_not_contains "$TMP/sql.log" 'SET ' 'query mutates server state'
assert_contains "$TMP/sample.out" $'Resizing\t0\t42\t1073741824' 'collector did not preserve the fake client response'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
