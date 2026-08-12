#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/check_opened_sessions_interactive.sh"
FAKE="$ROOT/tests/fake_mysql_open_sessions.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/open-sessions-cli-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export FAKE_MYSQL_SQL_LOG="$TMP/sql.log"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] || fail "expected exit status $expected, got $STATUS"
}

assert_contains() {
    local file=$1 expected=$2
    grep -F -- "$expected" "$file" >/dev/null || fail "missing '$expected' in $file"
}

assert_not_contains() {
    local file=$1 unexpected=$2
    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "unexpected '$unexpected' in $file"
    fi
}

assert_occurrences() {
    local file=$1 expected=$2 count=$3 actual
    actual=$(grep -F -c -- "$expected" "$file" || true)
    [[ "$actual" -eq "$count" ]] || fail "expected $count occurrences of '$expected' in $file, got $actual"
}

run_case() {
    local name=$1
    shift

    set +e
    "$SCRIPT" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
}

# A monitor without connection credentials must stop before terminal setup.
run_case no_args
assert_status 2
assert_contains "$TMP/no_args.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/no_args.err" 'Usage:'
assert_contains "$TMP/no_args.err" $'\033['

# Help must be available without a connection and document the interactive key contract.
run_case help --help
assert_status 0
assert_contains "$TMP/help.out" 'Runtime keys:'
assert_contains "$TMP/help.out" '[q] Quit'

run_case no_color_help --help --no-color
assert_status 0
assert_contains "$TMP/no_color_help.out" 'Runtime keys:'
if LC_ALL=C grep "$(printf '\033')" "$TMP/no_color_help.out" >/dev/null; then
    fail '--no-color help contains ANSI escape sequences'
fi

# Parser errors consistently print an error and the full help contract.
run_case unknown_option --unknown
assert_status 2
assert_contains "$TMP/unknown_option.err" 'ERROR: Unknown option: --unknown'
assert_contains "$TMP/unknown_option.err" 'Usage:'

run_case missing_value --login-path
assert_status 2
assert_contains "$TMP/missing_value.err" 'ERROR: Option --login-path requires a value.'
assert_contains "$TMP/missing_value.err" 'Usage:'

run_case missing_short_value -l -t 5
assert_status 2
assert_contains "$TMP/missing_short_value.err" 'ERROR: Option -l requires a value.'
assert_contains "$TMP/missing_short_value.err" 'Usage:'

run_case required_login_path --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/required_login_path.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/required_login_path.err" 'Usage:'

# Legacy getopts accepted attached values for every retained value-taking short option.
run_case attached_short_options -lreporting -t10 -uapp -dbilling -hhost -o --mysql-bin "$FAKE"
assert_status 0

run_case equals_options --login-path=reporting --refresh-time=10 --user=app \
    --database=billing --host=api --logging --diff --log-file="$TMP/new.log" \
    --mysql-bin="$FAKE" --no-color
assert_status 0

# Query filters must be escaped as SQL literals and collected in one client call.
: > "$TMP/sql.log"
run_case escaped_filters --login-path reporting --user "alice,o\\'connor" \
    --database "billing\\'archive" --host 'api%_west\\node' --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/sql.log" "USER IN (CONVERT(0x616c696365 USING utf8mb4), CONVERT(0x6f5c27636f6e6e6f72 USING utf8mb4))"
assert_contains "$TMP/sql.log" "DB = CONVERT(0x62696c6c696e675c2761726368697665 USING utf8mb4)"
assert_not_contains "$TMP/sql.log" "o\\'connor"
assert_not_contains "$TMP/sql.log" "billing\\'archive"
assert_contains "$TMP/sql.log" "HOST LIKE CONVERT(0x256170695c255c5f776573745c5c5c5c6e6f646525 USING utf8mb4) ESCAPE CONVERT(0x5c USING utf8mb4)"
assert_contains "$TMP/sql.log" 'UNION ALL'
assert_occurrences "$TMP/sql.log" 'UNION ALL' 1

run_case invalid_refresh --login-path reporting --refresh-time 0 --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/invalid_refresh.err" 'ERROR: --refresh-time must be a positive integer.'
assert_contains "$TMP/invalid_refresh.err" 'Usage:'

run_case invalid_mysql_bin --login-path reporting --mysql-bin "$TMP/missing-mysql"
assert_status 2
assert_contains "$TMP/invalid_mysql_bin.err" 'ERROR: --mysql-bin must reference an executable file.'
assert_contains "$TMP/invalid_mysql_bin.err" 'Usage:'

touch "$TMP/existing-validation.log"
run_case existing_log_validation --login-path reporting --log-file "$TMP/existing-validation.log" --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/existing_log_validation.err" 'ERROR: --log-file must not already exist.'
assert_contains "$TMP/existing_log_validation.err" 'Usage:'

# The fake must record the SQL bound to -e even when later client options follow it.
FAKE_MYSQL_SQL_LOG="$TMP/fake.sql" FAKE_MYSQL_OUTPUT=$'ROW\tapp\tbilling\thost\t3' \
    "$FAKE" --login-path reporting -e 'SELECT 1' --batch >"$TMP/fake.out"
assert_contains "$TMP/fake.sql" 'SELECT 1'
assert_contains "$TMP/fake.out" $'ROW\tapp\tbilling\thost\t3'

printf 'PASS: check_opened_sessions_interactive CLI contract\n'
