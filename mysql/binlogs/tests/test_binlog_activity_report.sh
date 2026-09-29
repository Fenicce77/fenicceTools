#!/usr/bin/env bash
# Behavioral contract tests for the binlog activity report CLI foundation.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../binlog_activity_report.sh"
FAKE_READER="$TEST_DIR/fake_binlog_reader.sh"
FIXTURE_ROOT="$TEST_DIR/fixtures/binlog_activity"
MYSQL57_FIXTURE="$FIXTURE_ROOT/mysql57_statement.sample"
MYSQL80_FIXTURE="$FIXTURE_ROOT/space dir/mysql80_row.sample"
MYSQL80_MIXED_FIXTURE="$FIXTURE_ROOT/mysql80_mixed.sample"
MARIADB10_ROW_FIXTURE="$FIXTURE_ROOT/mariadb10_row.sample"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/binlog-activity-test.XXXXXX")
OUTPUT=""
STATUS=0
TEST_COUNT=0

test_cleanup() {
    rm -rf "$TMP"
}
trap test_cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass_assertion() {
    TEST_COUNT=$((TEST_COUNT + 1))
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] \
        || fail "expected status $expected, got $STATUS; output: $OUTPUT"
    pass_assertion
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] \
        || fail "expected output to contain: $needle; output: $haystack"
    pass_assertion
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" != *"$needle"* ]] \
        || fail "expected output not to contain: $needle; output: $haystack"
    pass_assertion
}

assert_equals() {
    local actual=$1
    local expected=$2
    [[ "$actual" == "$expected" ]] \
        || fail "expected: $expected; got: $actual"
    pass_assertion
}

assert_file_empty() {
    local path=$1
    [[ ! -s "$path" ]] || fail "expected file to be empty: $path"
    pass_assertion
}

run_cli() {
    set +e
    OUTPUT=$(FAKE_BINLOG_READER_LOG="$TMP/reader.log" "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
}

run_shell() {
    set +e
    OUTPUT=$(/bin/bash -c "$1" _ "$SCRIPT" "$TMP" 2>&1)
    STATUS=$?
    set -e
}

if [[ ! -e "$SCRIPT" ]]; then
    fail "command does not exist: $SCRIPT"
fi

# The checks below become reachable after the production command is added.
run_cli
assert_status 2
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" 'Local source:'
assert_contains "$OUTPUT" 'Remote source:'
assert_contains "$OUTPUT" 'Analysis and output:'
assert_contains "$OUTPUT" 'Examples:'

run_cli --unknown-option
assert_status 2
assert_contains "$OUTPUT" 'Unknown option: --unknown-option'
assert_contains "$OUTPUT" 'Usage:'

run_cli --source invalid
assert_status 2
assert_contains "$OUTPUT" 'Source must be local or remote.'
assert_contains "$OUTPUT" 'Usage:'

run_cli --source local --file "$MYSQL57_FIXTURE" \
    --binlog-format statement --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Local source requires --server-version.'
assert_contains "$OUTPUT" 'Usage:'

run_cli --source local --file "$MYSQL57_FIXTURE" \
    --server-version '5.7.44' --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Local source requires --binlog-format.'
assert_contains "$OUTPUT" 'Usage:'

: > "$TMP/reader.log"
run_cli --source local --file "$MYSQL57_FIXTURE" "$TMP/missing.binlog" \
    --server-version '5.7.44' --binlog-format statement \
    --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Binlog file is not readable:'
assert_file_empty "$TMP/reader.log"

mysql57_before=$(cksum "$MYSQL57_FIXTURE")
mysql80_before=$(cksum "$MYSQL80_FIXTURE")
: > "$TMP/reader.log"
run_cli --source local \
    --file "$MYSQL57_FIXTURE" "$MYSQL80_FIXTURE" \
    --file "$MYSQL57_FIXTURE" \
    --server-version '8.4.6' --binlog-format mixed \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server profile: mysql-8.0+'
assert_contains "$OUTPUT" 'Top tables: 10'
assert_contains "$OUTPUT" "$MYSQL57_FIXTURE"
assert_contains "$OUTPUT" "$MYSQL80_FIXTURE"
assert_equals "$(LC_ALL=C grep -Fxc $'READ\t'"$MYSQL57_FIXTURE" "$TMP/reader.log")" 1
assert_equals "$(LC_ALL=C grep -Fxc $'READ\t'"$MYSQL80_FIXTURE" "$TMP/reader.log")" 1
assert_equals "$(wc -l < "$TMP/reader.log" | tr -d ' ')" 2
assert_equals "$(cksum "$MYSQL57_FIXTURE")" "$mysql57_before"
assert_equals "$(cksum "$MYSQL80_FIXTURE")" "$mysql80_before"

run_cli --source local --file "$MYSQL80_FIXTURE" \
    --server-version '11.4.2-MariaDB' --binlog-format row \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mariadb'
assert_contains "$OUTPUT" 'Server profile: mariadb-10+'

run_cli --source local --file "$MYSQL80_FIXTURE" \
    --server-family mariadb --server-version '11.8.3-custom-build' \
    --binlog-format row --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mariadb'
assert_contains "$OUTPUT" 'Server profile: mariadb-10+'

mkdir -p "$TMP/input dir"
cp "$MYSQL80_FIXTURE" "$TMP/input dir/b.bin"
cp "$MYSQL57_FIXTURE" "$TMP/input dir/a.bin"
: > "$TMP/reader.log"
run_cli --source local --dir "$TMP/input dir" \
    --server-version '5.7.44' --binlog-format statement \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
expected_reads=$(printf 'READ\t%s\nREAD\t%s' \
    "$TMP/input dir/a.bin" "$TMP/input dir/b.bin")
assert_equals "$(< "$TMP/reader.log")" "$expected_reads"

run_shell 'source "$1"; resolve_profile mysql "5.7.44"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mysql-5.7'

run_shell 'source "$1"; resolve_profile mysql "8.4.6"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mysql-8.0+'

run_shell 'source "$1"; resolve_profile mariadb "10.11.8-MariaDB"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mariadb-10+'

mkdir -p "$TMP/reader-bin"
ln -s "$FAKE_READER" "$TMP/reader-bin/mariadb-binlog"
run_shell 'source "$1"; PATH="$2/reader-bin"; MYSQLBINLOG_BIN=""; resolve_reader; printf "%s\n" "$READER"'
assert_status 0
assert_equals "$OUTPUT" "$TMP/reader-bin/mariadb-binlog"

ln -s "$FAKE_READER" "$TMP/reader-bin/mysqlbinlog"
run_shell 'source "$1"; PATH="$2/reader-bin"; MYSQLBINLOG_BIN=""; resolve_reader; printf "%s\n" "$READER"'
assert_status 0
assert_equals "$OUTPUT" "$TMP/reader-bin/mysqlbinlog"

run_shell 'source "$1"; normalize_events "'"$MYSQL57_FIXTURE"'" mysql mysql-5.7 statement'
assert_status 0
expected_mysql57=$(printf '%s\n%s' \
    $'2026-09-29 10:00:01\t123\tDML\tINSERT\tsales\torders\t-' \
    $'2026-09-29 10:00:02\t280\tDDL\tALTER\tsales\torders\t-')
assert_equals "$OUTPUT" "$expected_mysql57"

run_shell 'source "$1"; normalize_events "'"$MYSQL80_FIXTURE"'" mysql mysql-8.0+ row'
assert_status 0
expected_mysql80=$(printf '%s\n%s\n%s' \
    $'2026-09-29 11:00:00\t126\tDML\tINSERT\tsales\torders\tXID:9001' \
    $'2026-09-29 11:00:01\t240\tDML\tUPDATE\tsales\torders\tXID:9001' \
    $'2026-09-29 11:00:02\t360\tDML\tDELETE\tsales\torders\tXID:9001')
assert_equals "$OUTPUT" "$expected_mysql80"

run_shell 'source "$1"; normalize_events "'"$MYSQL80_MIXED_FIXTURE"'" mysql mysql-8.0+ mixed'
assert_status 0
expected_mysql80_mixed=$(printf '%s\n%s' \
    $'2026-09-29 12:00:00\t126\tDML\tINSERT\tsales\torders\t24bc7856-9a3b-11ef-9abc-0242ac120002:71' \
    $'2026-09-29 12:00:01\t260\tDDL\tCREATE\tsales\torder_archive\t-')
assert_equals "$OUTPUT" "$expected_mysql80_mixed"

run_shell 'source "$1"; normalize_events "'"$MARIADB10_ROW_FIXTURE"'" mariadb mariadb-10+ row'
assert_status 0
expected_mariadb10=$(printf '%s\n%s' \
    $'2026-09-29 13:00:00\t145\tDML\tUPDATE\tinventory\tstock\t0-1-991' \
    $'2026-09-29 13:00:01\t340\tDML\tDELETE\tinventory\tstock_history\t0-1-992')
assert_equals "$OUTPUT" "$expected_mariadb10"

: > "$TMP/reader.log"
run_cli --source local \
    --file "$MYSQL80_FIXTURE" "$MYSQL80_MIXED_FIXTURE" \
    --server-version '8.4.6' --binlog-format mixed --top-tables 2 \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" '2026-09-29 11:00:00  126  DML  INSERT  sales.orders  XID:9001'
assert_contains "$OUTPUT" '2026-09-29 12:00:01  260  DDL  CREATE  sales.order_archive  -'
expected_top_tables=$(printf '%s\n%s' \
    '4  sales.orders' \
    '1  sales.order_archive')
actual_top_tables=$(printf '%s\n' "$OUTPUT" | awk '/^Top tables by event count:$/ { capture=1; next } capture && /^[0-9]+  / { print; count++; if (count == 2) exit }')
assert_equals "$actual_top_tables" "$expected_top_tables"
assert_not_contains "$OUTPUT" $'\033['

printf 'PASS: %s assertions\n' "$TEST_COUNT"
