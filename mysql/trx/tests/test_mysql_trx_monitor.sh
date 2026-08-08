#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); SCRIPT="$ROOT/mysql_trx_monitor.sh"; FAKE="$ROOT/tests/fake_mysql_trx.sh"; TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FAKE_MYSQL_TRX_LOG="$TMP/sql.log"
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
"$SCRIPT" --help | grep -q -- '--view' || fail 'help missing view'
"$SCRIPT" --login-path x --view all --smoke-test --mysql-bin "$FAKE" --no-color >"$TMP/out"
grep -q 'TRANSACTIONS' "$TMP/out" || fail 'transactions missing'
grep -q 'LOCK WAITS' "$TMP/out" || fail 'locks missing'
grep -q '^KILL ' "$TMP/sql.log" && fail 'unexpected kill'
printf 'PASS: mysql_trx_monitor\n'
