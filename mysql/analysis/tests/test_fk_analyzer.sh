#!/usr/bin/env bash
# Behavioral contract tests for the foreign key topology analyzer CLI.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../fk_analyzer.sh"
FAKE_MYSQL="$SCRIPT_DIR/fake_mysql_fk.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fk-analyzer-test.XXXXXX")
OUTPUT=""
STATUS=0

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] || fail "expected status $expected, got $STATUS; output: $OUTPUT"
}

run_case() {
    local name=$1
    shift
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    OUTPUT=$(/bin/bash "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
    printf 'ok: %s\n' "$name"
}

repeat_char() {
    local count=$1
    local character=$2
    local result=""
    local index=0
    while [[ "$index" -lt "$count" ]]; do
        result="${result}${character}"
        index=$((index + 1))
    done
    printf '%s' "$result"
}

export FAKE_MYSQL_FK_LOG="$TMP/fake-mysql.log"

run_case no_args
assert_status 0
assert_contains "$OUTPUT" 'MySQL Foreign Key Topology Analyzer'
assert_contains "$OUTPUT" 'Required options:'
assert_contains "$OUTPUT" 'Virtual relationship rules:'
assert_contains "$OUTPUT" 'Exit status:'
assert_contains "$OUTPUT" 'Examples:'

run_case help --help --no-color
assert_status 0
assert_not_contains "$OUTPUT" $'\033'

run_case missing_schema -l test -t orders --environment test
assert_status 2
assert_contains "$OUTPUT" '--schema is required.'

run_case bad_environment -l test -s sales -t orders --environment qa
assert_status 2

run_case exact_prod_guard -l test -s sales -t orders \
    --environment production --cardinality exact --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$OUTPUT" 'Exact cardinality in production requires --allow-production.'

run_case stray_allow -l test -s sales -t orders --environment test --allow-production
assert_status 2

run_case width_small -l test -s sales -t orders --environment test --terminal-width 119
assert_status 2

run_case missing_client -l test -s sales -t orders --environment test \
    --mysql-bin "$TMP/missing-mysql"
assert_status 3

run_case long_equals --login-path=test --schema=sales --table=orders --environment=test \
    --mysql-bin="$FAKE_MYSQL" --terminal-width=120 --format=tsv --output-file="$TMP/report.tsv"
assert_status 0
assert_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:connection'
assert_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:target'
assert_not_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:physical'

run_case long_space --login-path test --schema sales --table orders --environment test \
    --mysql-bin "$FAKE_MYSQL" --terminal-width 10000 --format csv --output-file "$TMP/report.csv"
assert_status 0

run_case legacy_cardinality -l test -s sales -t orders --environment production -c --mysql-bin "$FAKE_MYSQL"
assert_status 0

run_case unknown_option -l test -s sales -t orders --environment test --unknown
assert_status 2

run_case empty_schema -l test --schema= -t orders --environment test
assert_status 2
run_case empty_table -l test -s sales --table= --environment test
assert_status 2
run_case empty_login --login-path= -s sales -t orders --environment test
assert_status 2

schema_64=$(repeat_char 64 s)
table_64=$(repeat_char 64 t)
run_case identifiers_64 -l test -s "$schema_64" -t "$table_64" --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case schema_65 -l test -s "$(repeat_char 65 s)" -t orders --environment test
assert_status 2
run_case table_65 -l test -s sales -t "$(repeat_char 65 t)" --environment test
assert_status 2
run_case trailing_space -l test -s 'sales ' -t orders --environment test
assert_status 2
run_case control_character -l test -s $'sales\narchive' -t orders --environment test
assert_status 2

run_case width_minimum -l test -s sales -t orders --environment test --terminal-width 120 --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case width_maximum -l test -s sales -t orders --environment test --terminal-width 10000 --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case width_large -l test -s sales -t orders --environment test --terminal-width 10001
assert_status 2
run_case width_overflow -l test -s sales -t orders --environment test --terminal-width 999999999999999999999999999999
assert_status 2

MYSQL_BIN="$FAKE_MYSQL"
export MYSQL_BIN
run_case environment_client -l test -s sales -t orders --environment test
assert_status 0
run_case option_client_priority -l test -s sales -t orders --environment test --mysql-bin "$TMP/missing-mysql"
assert_status 3
unset MYSQL_BIN

mkdir "$TMP/path-bin"
ln -s "$FAKE_MYSQL" "$TMP/path-bin/mysql"
original_path=$PATH
PATH="$TMP/path-bin:$PATH"
export PATH
run_case path_client -l test -s sales -t orders --environment test
assert_status 0
PATH=$original_path
export PATH

FAKE_MYSQL_FK_MODE=connection-failure
export FAKE_MYSQL_FK_MODE
run_case connection_failure -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
assert_contains "$OUTPUT" 'access denied for configured login path'
unset FAKE_MYSQL_FK_MODE

FAKE_MYSQL_FK_MODE=connection-failure-ansi
export FAKE_MYSQL_FK_MODE
run_case connection_failure_ansi -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
assert_not_contains "$OUTPUT" $'\033'
assert_not_contains "$OUTPUT" $'\n'
unset FAKE_MYSQL_FK_MODE

FAKE_MYSQL_FK_MODE=target-missing
export FAKE_MYSQL_FK_MODE
run_case target_missing -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
unset FAKE_MYSQL_FK_MODE

printf 'PASS: fk_analyzer CLI contract\n'
