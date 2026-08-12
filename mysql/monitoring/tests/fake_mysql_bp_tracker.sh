#!/usr/bin/env bash
set -euo pipefail

sql=$(cat)
printf '%s\n' "$sql" >> "${FAKE_MYSQL_BP_LOG:?}"

case "$sql" in
    *'bp-tracker:global'*)
        if [[ "${FAKE_MYSQL_BP_MODE:-}" == global-failure ]]; then
            printf '%s\n' 'global metrics unavailable' >&2
            exit 1
        fi
        printf '20000\t4000\t15000\t500\t3.33\t6000\t1200\t2400\n'
        ;;
    *'bp-tracker:top-objects'*)
        if [[ "${FAKE_MYSQL_BP_MODE:-}" == top-failure ]]; then
            printf '%s\n' 'top objects unavailable' >&2
            exit 1
        fi
        printf 'app.orders\t800\t13107200\t9830400\t100\t3\t750\n'
        ;;
    *'bp-tracker:active-sessions'*)
        if [[ "${FAKE_MYSQL_BP_MODE:-}" == sessions-failure ]]; then
            printf '%s\n' 'sessions unavailable' >&2
            exit 1
        fi
        printf 'app\t61\texecuting\tSELECT confidential_statement FROM orders\n'
        ;;
esac
