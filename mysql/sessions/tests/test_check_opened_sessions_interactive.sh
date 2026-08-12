#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/check_opened_sessions_interactive.sh"
FAKE="$ROOT/tests/fake_mysql_open_sessions.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/open-sessions-cli-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

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

run_case required_login_path --mysql-bin /bin/true
assert_status 2
assert_contains "$TMP/required_login_path.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/required_login_path.err" 'Usage:'

# Legacy getopts accepted attached values for every retained value-taking short option.
run_case attached_short_options -lreporting -t10 -uapp -dbilling -hhost -o --mysql-bin /bin/true
assert_status 0

# The fake must record the SQL bound to -e even when later client options follow it.
FAKE_MYSQL_SQL_LOG="$TMP/fake.sql" FAKE_MYSQL_OUTPUT=$'ROW\tapp\tbilling\thost\t3' \
    "$FAKE" --login-path reporting -e 'SELECT 1' --batch >"$TMP/fake.out"
assert_contains "$TMP/fake.sql" 'SELECT 1'
assert_contains "$TMP/fake.out" $'ROW\tapp\tbilling\thost\t3'

printf 'PASS: check_opened_sessions_interactive CLI contract\n'
