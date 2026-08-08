#!/usr/bin/env bash
set -euo pipefail

sql=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) sql=$2; shift 2 ;;
        *) shift ;;
    esac
done

printf '%s\n' "$sql" >> "${FAKE_MYSQL_PREFIX_LOG:?}"
if [[ "$sql" == *'COLUMN_NAME FROM information_schema.COLUMNS'* ]]; then
    printf 'name\nnotes\n'
elif [[ "$sql" == *'CHAR_LENGTH'* ]]; then
    printf '1,3\n'
elif [[ "$sql" == *'COUNT(DISTINCT LEFT'* ]]; then
    if [[ "$sql" == *'`notes`'* && "${FAKE_MYSQL_PREFIX_FAIL_NOTES:-0}" = 1 ]]; then
        printf 'simulated query error\n' >&2
        exit 1
    fi
    printf '0.5000,0.9000,1.0000\n'
fi
