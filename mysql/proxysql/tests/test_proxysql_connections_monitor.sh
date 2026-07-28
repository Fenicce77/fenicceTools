#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_connections_monitor.sh"
TEST_COUNT=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3

    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$actual" == "$expected" ]] ||
        fail "$message: expected [$expected], got [$actual]"
}

PROXYSQL_MONITOR_TESTING=1
# shellcheck source=../proxysql_connections_monitor.sh
source "$SCRIPT_PATH"

assert_eq "CONN" "$VIEW_MODE" "sourcing initializes the default view"

initialize_defaults
parse_arguments \
    --login-path=proxysql_admin \
    --refresh-time=0.5 \
    --user-filter=app \
    --threshold=12

assert_eq "proxysql_admin" "$LOGIN_PATH" "login path parsing"
assert_eq "0.5" "$REFRESH_TIME" "floating refresh parsing"
assert_eq "app" "$USER_FILTER" "user filter parsing"
assert_eq "12" "$THRESHOLD" "threshold parsing"

printf 'PASS: %s assertions\n' "$TEST_COUNT"
