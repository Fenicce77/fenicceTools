#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_connections_monitor.sh"
BENCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pxmon-bench.XXXXXX")

export FAKE_MYSQL_STATE_DIR="$BENCH_DIR/state"
mkdir "$FAKE_MYSQL_STATE_DIR"

PROXYSQL_MONITOR_TESTING=1
# shellcheck source=../proxysql_connections_monitor.sh
source "$SCRIPT_PATH"

cleanup_benchmark() {
    stop_mysql_session
    rm -rf "$BENCH_DIR"
}
trap cleanup_benchmark EXIT INT TERM

initialize_defaults
initialize_colors
LOGIN_PATH="benchmark"
MYSQL_BIN="$TEST_DIR/fake_mysql.sh"
QUERY_TIMEOUT=2
start_mysql_session

samples=20
i=0
while [[ "$i" -lt "$samples" ]]; do
    execute_query "SELECT 'TEST_CONNECTIONS';"
    i=$((i + 1))
done
stop_mysql_session

launches=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches")
launches=${launches// /}

printf 'Samples: %s\n' "$samples"
printf 'MySQL client launches: %s\n' "$launches"
printf 'Launches per sample: %s/%s\n' "$launches" "$samples"

[[ "$launches" == "1" ]]
