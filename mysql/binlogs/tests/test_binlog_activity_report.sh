#!/usr/bin/env bash
# Behavioral contract tests for the binlog activity report CLI foundation.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../binlog_activity_report.sh"
FAKE_READER="$TEST_DIR/fake_binlog_reader.sh"
FIXTURE_ROOT="$TEST_DIR/fixtures/binlog_activity"
MYSQL57_FIXTURE="$FIXTURE_ROOT/mysql57_statement.sample"
MYSQL80_FIXTURE="$FIXTURE_ROOT/space dir/mysql80_row.sample"
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

printf 'PASS: %s assertions\n' "$TEST_COUNT"
