#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_MYSQL_LOG:?FAKE_MYSQL_LOG is required}"

printf '%s\n' "$*" >> "$FAKE_MYSQL_LOG"

if [[ "$*" == *"SELECT 1"* ]] && [[ "${FAKE_MYSQL_FAIL_CONNECTION:-0}" == '1' ]]; then
    printf '%s\n' 'connection failed' >&2
    exit 1
fi

if [[ "$*" == *"SELECT 1"* ]]; then
    printf '1\n'
    exit 0
fi

printf '%s\n' '====================================='
printf '%s\n' '2026-09-11 10:00:00 INNODB MONITOR OUTPUT'
printf '%s\n' 'Per second averages calculated from the last 1 seconds'
