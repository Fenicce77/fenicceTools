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

TRANSPORT_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pxmon-test.XXXXXX")
FAKE_MYSQL_STATE_DIR="$TRANSPORT_TEST_DIR/state"
mkdir "$FAKE_MYSQL_STATE_DIR"
export FAKE_MYSQL_STATE_DIR
MYSQL_BIN="$TEST_DIR/fake_mysql.sh"
LOGIN_PATH="proxysql_admin"
QUERY_TIMEOUT=2

start_mysql_session
execute_query "SELECT 'TEST_CONNECTIONS';"
first_result=$QUERY_RESULT
execute_query "SELECT 'TEST_SECOND_SAMPLE';"
second_result=$QUERY_RESULT

assert_eq $'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t4' \
    "$first_result" "first framed result"
assert_eq $'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t6' \
    "$second_result" "second framed result"
launches=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches")
launches=${launches// /}
assert_eq "1" "$launches" "one persistent client launch"

failed_session_dir=$MYSQL_SESSION_DIR
kill "$MYSQL_PID"
wait "$MYSQL_PID" 2>/dev/null || true
execute_query_with_retry "SELECT 'TEST_CONNECTIONS';"
reconnected_result=$QUERY_RESULT
active_session_dir=$MYSQL_SESSION_DIR

assert_eq $'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t4' \
    "$reconnected_result" "retry returns data after reconnect"
launches=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches")
launches=${launches// /}
assert_eq "2" "$launches" "dead client is replaced exactly once"
[[ ! -e "$failed_session_dir" ]] || fail "failed transport directory was not removed"

stop_mysql_session
[[ ! -e "$active_session_dir" ]] || fail "active transport directory was not removed"

PREV_DATA=$'app\tclient\tbackend:3306\tappdb\t4'
CURR_DATA=$'app\tclient\tbackend:3306\tappdb\t6'
USER_FILTER=""
THRESHOLD=0
format_conn_data "$PREV_DATA" "$CURR_DATA"
case "$FORMATTED_OUTPUT" in
    *"+2"*) : ;;
    *) fail "CONN formatter did not preserve delta semantics" ;;
esac

format_query_data $'11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n*\\tFROM t'
case "$FORMATTED_OUTPUT" in
    *"SELECT * FROM t"*) : ;;
    *) fail "QUERY formatter did not sanitize escaped controls" ;;
esac

TERM_WIDTH=130
format_digest_data $'0x123\t8\t12000\t100\t4000\tSELECT\\tcol FROM very_long_table'
case "$FORMATTED_OUTPUT" in
    *"SELECT col FROM very_long_table"*) : ;;
    *) fail "DIGEST formatter did not sanitize escaped controls" ;;
esac

backend_payload=$'__PXMON_POOL__\n10\tbackend:3306\tONLINE\t2\t3\t50\t1\n__PXMON_PING__\nbackend\t2026-07-28 12:00:00\t500\t'
format_backend_data "$backend_payload"
case "${F_POOL}:${F_PING}" in
    *"ONLINE"*"500us"*) : ;;
    *) fail "BACKEND formatter did not split both sections" ;;
esac

launches_before_backend=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches")
launches_before_backend=${launches_before_backend// /}
VIEW_MODE="BACKEND"
LAST_SAMPLE_STALE=false
start_mysql_session
sample_current_view
sample_current_view
backend_session_dir=$MYSQL_SESSION_DIR

case "${F_POOL}:${F_PING}" in
    *"ONLINE"*"500us"*) : ;;
    *) fail "BACKEND sampling did not format both persistent-query sections" ;;
esac
launches_after_backend=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches")
launches_after_backend=${launches_after_backend// /}
assert_eq "$((launches_before_backend + 1))" "$launches_after_backend" \
    "two BACKEND samples reuse one client"
stop_mysql_session
[[ ! -e "$backend_session_dir" ]] || fail "BACKEND transport directory was not removed"

TERM_WIDTH=120
TERM_GEOMETRY_DIRTY=true
refresh_terminal_geometry
assert_eq "120" "${#SEP_LINE}" "wide separator length"
assert_eq "120" "${#SEP_THIN}" "thin separator length"

(
    date_calls="$TRANSPORT_TEST_DIR/date-calls"
    date() {
        printf 'called\n' >> "$date_calls"
        printf '2026-07-28 12:00:00\n'
    }
    TIMESTAMP=""
    TIMESTAMP_SECOND=-1
    SECONDS=10
    refresh_timestamp
    refresh_timestamp
    assert_eq "2026-07-28 12:00:00" "$TIMESTAMP" \
        "timestamp refresh stores local time"
    calls=$(wc -l < "$date_calls")
    calls=${calls// /}
    assert_eq "1" "$calls" "timestamp is cached within the same second"
)

VIEW_MODE="CONN"
PAUSED=false
handle_key "v"
assert_eq "QUERY" "$VIEW_MODE" "view toggle"
handle_key "p"
assert_eq "true" "$PAUSED" "pause toggle"
handle_key "p"
assert_eq "false" "$PAUSED" "resume toggle"

if ! is_positive_refresh "0.5"; then
    fail "positive fractional refresh was rejected"
fi
if is_positive_refresh "0"; then
    fail "zero refresh was accepted"
fi

(
    FORMATTED_OUTPUT="last valid row"
    LAST_SAMPLE_STALE=false
    LAST_DB_ERROR=""
    execute_query_with_retry() {
        LAST_DB_ERROR="ProxySQL unavailable"
        return 1
    }
    VIEW_MODE="QUERY"
    sample_current_view || true
    assert_eq "last valid row" "$FORMATTED_OUTPUT" \
        "failed sample preserves last data"
    assert_eq "true" "$LAST_SAMPLE_STALE" \
        "failed sample marks output stale"
)

rm -rf "$TRANSPORT_TEST_DIR"

printf 'PASS: %s assertions\n' "$TEST_COUNT"
