#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); SCRIPT="$ROOT/estimate_storage.sh"; FAKE="$ROOT/tests/fake_mysql_storage.sh"; TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FAKE_MYSQL_STORAGE_LOG="$TMP/sql.log"
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
help=$("$SCRIPT" --help); [[ "$help" == *'Required options'* && "$help" == *'Examples'* ]] || fail 'incomplete help'
"$SCRIPT" >/dev/null || fail 'no-argument help failed'
if "$SCRIPT" -l x -d app -t 'users%' -r 1 --environment test --mysql-bin "$FAKE" >/dev/null 2>&1; then fail 'percent accepted'; fi
if "$SCRIPT" -l x -d app -t users -r 1 --environment production --mysql-bin "$FAKE" >/dev/null 2>&1; then fail 'production accepted'; fi
"$SCRIPT" -l x -d app -t 'users_' -r 1 --environment test --mysql-bin "$FAKE" --no-color >"$TMP/out"
grep -Fq "TABLE_NAME LIKE 'users_%'" "$TMP/sql.log" || fail 'prefix pattern incorrect'
if grep -q $'\033' "$TMP/out"; then fail 'ANSI output present'; fi
printf 'PASS: estimate_storage\n'
