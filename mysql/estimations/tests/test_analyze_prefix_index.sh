#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/analyze_prefix_index.sh"
FAKE="$ROOT/tests/fake_mysql_prefix.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FAKE_MYSQL_PREFIX_LOG="$TMP/sql.log"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

"$SCRIPT" --help | grep -q -- '--environment' || fail 'help lacks environment'
if "$SCRIPT" -l x -d app -t users --mysql-bin "$FAKE" >/dev/null 2>&1; then fail 'missing environment accepted'; fi
if "$SCRIPT" -l x -d app -t users --environment production --mysql-bin "$FAKE" >/dev/null 2>&1; then fail 'production accepted'; fi
if "$SCRIPT" -l x -d 'bad-name' -t users --environment test --mysql-bin "$FAKE" >/dev/null 2>&1; then fail 'unsafe identifier accepted'; fi
"$SCRIPT" -l x -d app -t users -c name,notes --environment test --mysql-bin "$FAKE" --query-timeout 500 --no-color >"$TMP/out"
grep -q 'MAX_EXECUTION_TIME(500)' "$TMP/sql.log" || fail 'timeout hint absent'
if grep -q $'\033' "$TMP/out"; then fail 'ANSI output present'; fi
printf 'PASS: analyze_prefix_index\n'
