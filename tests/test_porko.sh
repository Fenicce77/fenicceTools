#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
BIN="$TEMP_DIR/porko"

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

cc -std=c11 -Wall -Wextra -Werror "$ROOT_DIR/porko.c" -o "$BIN"

assert_eq() { [[ "$1" == "$2" ]] || { printf 'Assertion failed: %s\n' "$3" >&2; exit 1; }; }
assert_fails() { "$@" >/dev/null 2>"$TEMP_DIR/error" && { printf 'Expected failure: %s\n' "$*" >&2; exit 1; }; [[ -s "$TEMP_DIR/error" ]]; }

expected_two=$'START TRANSACTION;\none;\ntwo;\nCOMMIT;\nSELECT SLEEP(0.3);\nSTART TRANSACTION;\nthree;\nCOMMIT;'
actual_two=$(printf 'one;\ntwo;\nthree;\n' | "$BIN" -b 2)
assert_eq "$actual_two" "$expected_two" 'short batch output'

actual_long=$(printf 'one;\ntwo;\nthree;\n' | "$BIN" --batch-size 3)
assert_eq "$actual_long" $'START TRANSACTION;\none;\ntwo;\nthree;\nCOMMIT;\nSELECT SLEEP(0.3);\nSTART TRANSACTION;\nCOMMIT;' 'long batch output'

default_output=$(awk 'BEGIN { for (i = 1; i <= 2001; i++) print "row" i ";" }' | "$BIN")
[[ "$default_output" == *$'row2000;\nCOMMIT;\nSELECT SLEEP(0.3);\nSTART TRANSACTION;\nrow2001;'* ]]
[[ "$default_output" != *'BEGIN;'* ]]

help_output=$("$BIN" --help)
[[ "$help_output" == *'--batch-size'* && "$help_output" == *'-b'* ]]

assert_fails "$BIN" -b
assert_fails "$BIN" -b 0
assert_fails "$BIN" --batch-size nope
assert_fails "$BIN" -b 2 --batch-size 3
assert_fails "$BIN" 2

printf 'PASS: porko CLI and transaction output\n'
