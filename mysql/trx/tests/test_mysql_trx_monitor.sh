#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/mysql_trx_monitor.sh"
FAKE="$ROOT/tests/fake_mysql_trx.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mysql-trx-monitor-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1 expected=$2 message=$3
    grep -F -- "$expected" "$file" >/dev/null || fail "$message"
}

assert_not_contains() {
    local file=$1 unexpected=$2 message=$3
    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "$message"
    fi
}

run_expect_failure() {
    local output_file=$1
    shift
    if "$@" >"$output_file" 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

new_sql_log() {
    FAKE_MYSQL_TRX_LOG=$1
    export FAKE_MYSQL_TRX_LOG
    : > "$FAKE_MYSQL_TRX_LOG"
}

new_sql_log "$TMP/help.sql"
"$SCRIPT" >"$TMP/no-args.out"
"$SCRIPT" --help >"$TMP/help.out"
for section in 'Usage:' 'Filters:' 'Logging:' 'Interactive controls:' 'Examples:'; do
    assert_contains "$TMP/no-args.out" "$section" "no-argument help missing $section"
    assert_contains "$TMP/help.out" "$section" "explicit help missing $section"
done

run_expect_failure "$TMP/empty-item.out" \
    "$SCRIPT" --login-path x --user-filter 'app,,reporting' --smoke-test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/empty-item.out" 'Invalid --user-filter' 'empty filter item was not rejected'

run_expect_failure "$TMP/empty-filter.out" \
    "$SCRIPT" --login-path x --database-filter '' --smoke-test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/empty-filter.out" 'Option --database-filter requires a value.' 'empty filter was not rejected'

run_expect_failure "$TMP/empty-equals-filter.out" \
    "$SCRIPT" --login-path x --host-filter= --smoke-test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/empty-equals-filter.out" 'Option --host-filter requires a value.' 'empty equals-form filter was not rejected'

run_expect_failure "$TMP/missing-filter-value.out" \
    "$SCRIPT" --login-path x --user-filter --view all --smoke-test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/missing-filter-value.out" 'Option --user-filter requires a value.' 'next option was consumed as a filter value'

run_expect_failure "$TMP/positional-after-double-dash.out" \
    "$SCRIPT" --login-path x --smoke-test --mysql-bin "$FAKE" --no-color -- unexpected
assert_contains "$TMP/positional-after-double-dash.out" 'Unexpected argument: unexpected' 'positional argument after -- was silently ignored'

new_sql_log "$TMP/filter.sql"
snapshot_log="$TMP/snapshot.log"
"$SCRIPT" --login-path x --view all --smoke-test --mysql-bin "$FAKE" --no-color \
    --user-filter 'app,reporting' --database-filter sales --host-filter 'host1:3306' \
    --output-file "$snapshot_log" >"$TMP/filter.out"
assert_contains "$TMP/filter.sql" "p.USER IN (CONVERT(X'617070' USING utf8mb4),CONVERT(X'7265706f7274696e67' USING utf8mb4))" 'user filter is not an exact mode-independent IN predicate'
assert_contains "$TMP/filter.sql" "p.DB IN (CONVERT(X'73616c6573' USING utf8mb4))" 'database filter is not an exact mode-independent IN predicate'
assert_contains "$TMP/filter.sql" "p.HOST IN (CONVERT(X'686f7374313a33333036' USING utf8mb4))" 'host filter is not an exact mode-independent IN predicate'
assert_contains "$snapshot_log" 'Snapshot:' 'snapshot timestamp missing from log'
assert_contains "$snapshot_log" 'TRANSACTIONS' 'transaction section missing from log'
if LC_ALL=C grep "$(printf '\033')" "$snapshot_log" >/dev/null; then
    fail 'snapshot log contains ANSI escape sequences'
fi

new_sql_log "$TMP/escaped-filter.sql"
"$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color \
    --user-filter "o'reilly,back\\slash" >"$TMP/escaped-filter.out"
assert_contains "$TMP/escaped-filter.sql" "p.USER IN (CONVERT(X'6f277265696c6c79' USING utf8mb4),CONVERT(X'6261636b5c736c617368' USING utf8mb4))" 'filter literals were not encoded independently of sql_mode'

new_sql_log "$TMP/pfs-fallback.sql"
FAKE_MYSQL_TRX_MODE=pfs-unavailable \
    "$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color \
    >"$TMP/pfs-fallback.out"
assert_contains "$TMP/pfs-fallback.out" $'13\treporting\thost2:3306' 'transaction fallback row missing'
assert_contains "$TMP/pfs-fallback.sql" '/* trx-monitor:transactions-fallback */' 'fallback query was not executed'

new_sql_log "$TMP/connection-unavailable.sql"
run_expect_failure "$TMP/connection-unavailable.out" env FAKE_MYSQL_TRX_MODE=connection-unavailable \
    "$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/connection-unavailable.out" "Unable to connect using login path 'x': access denied for login path" 'connection failure was reported as a degraded view'

new_sql_log "$TMP/transaction-unavailable.sql"
FAKE_MYSQL_TRX_MODE=transaction-unavailable \
    "$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color \
    >"$TMP/transaction-unavailable.out"
assert_contains "$TMP/transaction-unavailable.out" 'TRANSACTIONS UNAVAILABLE' 'missing transaction-unavailable message'
assert_contains "$TMP/transaction-unavailable.out" 'information_schema transaction access denied' 'transaction diagnostic was discarded'

new_sql_log "$TMP/pfs-stale.sql"
FAKE_MYSQL_TRX_MODE=pfs-stale \
    "$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color \
    >"$TMP/pfs-stale.out"
assert_not_contains "$TMP/pfs-stale.out" 'STALE TRANSACTION EVENT' 'committed or rolled-back PFS event was rendered as active'

new_sql_log "$TMP/pfs-disabled.sql"
FAKE_MYSQL_TRX_MODE=pfs-disabled \
    "$SCRIPT" --login-path x --view transactions --smoke-test --mysql-bin "$FAKE" --no-color \
    >"$TMP/pfs-disabled.out"
assert_contains "$TMP/pfs-disabled.out" 'OPEN TRANSACTION WITHOUT PFS EVENT' 'disabled PFS instrumentation hid an open InnoDB transaction'

new_sql_log "$TMP/sys-unavailable.sql"
degraded_log="$TMP/degraded.log"
FAKE_MYSQL_TRX_MODE=sys-unavailable \
    "$SCRIPT" --login-path x --view all --smoke-test --mysql-bin "$FAKE" --no-color \
    --output-file "$degraded_log" >"$TMP/sys-unavailable.out"
assert_contains "$TMP/sys-unavailable.out" 'TRANSACTIONS' 'transactions disappeared when lock view degraded'
assert_contains "$TMP/sys-unavailable.out" 'LOCK WAITS UNAVAILABLE' 'missing degraded lock-view message'
assert_contains "$TMP/sys-unavailable.out" 'sys schema unavailable' 'lock-view diagnostic was discarded'
if LC_ALL=C grep "$(printf '\033')" "$degraded_log" >/dev/null; then
    fail 'degraded snapshot log contains ANSI escape sequences from MySQL stderr'
fi

new_sql_log "$TMP/smoke.sql"
"$SCRIPT" --login-path x --view all --smoke-test --mysql-bin "$FAKE" --no-color >"$TMP/smoke.out"
assert_not_contains "$TMP/smoke.sql" 'KILL CONNECTION' 'smoke mode issued an automatic kill'
assert_contains "$TMP/smoke.sql" 'w.locked_table_schema' 'lock query does not use the documented table schema column'
assert_contains "$TMP/smoke.sql" 'w.locked_table_name' 'lock query does not use the documented table name column'
assert_contains "$TMP/smoke.sql" 'performance_schema.threads AS blocking_thread' 'blocking account is not derived from performance_schema threads'
assert_contains "$TMP/smoke.sql" 'performance_schema.threads AS waiting_thread' 'waiting account is not derived from performance_schema threads'
assert_not_contains "$TMP/smoke.sql" '       blocking_account,' 'lock query uses the nonexistent blocking_account view column'
assert_not_contains "$TMP/smoke.sql" '       waiting_account,' 'lock query uses the nonexistent waiting_account view column'
assert_contains "$TMP/smoke.out" $'12\tapp@host1\t34\treport@host2\tsales.orders' 'normal lock-wait row was not rendered'

new_sql_log "$TMP/invalid-kill.sql"
printf 'kabc\nq' | "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/invalid-kill.out"
assert_not_contains "$TMP/invalid-kill.sql" 'KILL CONNECTION' 'invalid connection ID issued a kill'

new_sql_log "$TMP/unconfirmed-kill.sql"
printf 'k12\nno\nq' | "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/unconfirmed-kill.out"
assert_contains "$TMP/unconfirmed-kill.sql" '/* trx-monitor:kill-target */' 'kill target was not inspected'
assert_not_contains "$TMP/unconfirmed-kill.sql" 'KILL CONNECTION' 'unconfirmed kill was executed'

new_sql_log "$TMP/confirmed-kill.sql"
printf 'k12\nkill 12\nq' | "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/confirmed-kill.out"
assert_contains "$TMP/confirmed-kill.sql" 'KILL CONNECTION 12' 'confirmed kill was not executed'
assert_not_contains "$TMP/confirmed-kill.sql" '/* trx-monitor:connection-id */' 'kill path queried an ephemeral connection ID as a self-connection guard'
kill_count=$(grep -Fc 'KILL CONNECTION 12' "$TMP/confirmed-kill.sql" || true)
[[ "$kill_count" -eq 1 ]] || fail "expected one confirmed kill, found $kill_count"

new_sql_log "$TMP/pause.sql"
printf 'pq' | "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/pause.out"
assert_contains "$TMP/pause.out" '[PAUSED]' 'pause state was not displayed'

new_sql_log "$TMP/interactive-filter.sql"
printf 'fapp,reporting\nsales\nhost1:3306\nq' | \
    "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/interactive-filter.out"
assert_contains "$TMP/interactive-filter.out" 'Filters updated.' 'interactive filter update was not acknowledged'
assert_contains "$TMP/interactive-filter.sql" "p.USER IN (CONVERT(X'617070' USING utf8mb4),CONVERT(X'7265706f7274696e67' USING utf8mb4))" 'interactive user filter was not applied'
assert_contains "$TMP/interactive-filter.sql" "p.DB IN (CONVERT(X'73616c6573' USING utf8mb4))" 'interactive database filter was not applied'
assert_contains "$TMP/interactive-filter.sql" "p.HOST IN (CONVERT(X'686f7374313a33333036' USING utf8mb4))" 'interactive host filter was not applied'

new_sql_log "$TMP/invalid-interactive-filter.sql"
printf 'fapp,,reporting\nsales\nhost1:3306\nq' | \
    "$SCRIPT" --login-path x --view transactions --user-filter app --mysql-bin "$FAKE" --no-color \
    >"$TMP/invalid-interactive-filter.out"
assert_contains "$TMP/invalid-interactive-filter.out" 'Invalid filters; existing filters retained.' 'invalid interactive filter did not retain state'
assert_not_contains "$TMP/invalid-interactive-filter.sql" "p.USER IN ('app','','reporting')" 'invalid interactive filter reached SQL'

new_sql_log "$TMP/log-toggle.sql"
toggle_log="$TMP/toggle.log"
printf 'lq' | "$SCRIPT" --login-path x --view transactions --output-file "$toggle_log" \
    --mysql-bin "$FAKE" --no-color >"$TMP/log-toggle.out"
assert_contains "$TMP/log-toggle.out" 'Snapshot logging paused.' 'logging toggle did not pause logging'
snapshot_count=$(grep -Fc 'Snapshot:' "$toggle_log" || true)
[[ "$snapshot_count" -eq 1 ]] || fail "expected one snapshot before logging pause, found $snapshot_count"

new_sql_log "$TMP/log-without-file.sql"
printf 'lq' | "$SCRIPT" --login-path x --view transactions --mysql-bin "$FAKE" --no-color >"$TMP/log-without-file.out"
assert_contains "$TMP/log-without-file.out" 'Logging requires --output-file.' 'missing output-file logging message'

new_sql_log "$TMP/stdin-eof.sql"
"$SCRIPT" --login-path x --view transactions --refresh-time 5 --mysql-bin "$FAKE" --no-color \
    </dev/null >"$TMP/stdin-eof.out" &
eof_pid=$!
sleep 0.2
if kill -0 "$eof_pid" 2>/dev/null; then
    kill "$eof_pid" 2>/dev/null || true
    wait "$eof_pid" 2>/dev/null || true
    fail 'closed stdin caused an unthrottled monitor loop'
fi
wait "$eof_pid"

printf 'PASS: mysql_trx_monitor\n'
