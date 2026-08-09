#!/usr/bin/env bash
set -euo pipefail

sql=""
expect_sql=false
for argument in "$@"; do
    if [[ "$expect_sql" == true ]]; then
        sql=$argument
        expect_sql=false
        continue
    fi
    case "$argument" in
        -e|--execute) expect_sql=true ;;
        --execute=*) sql=${argument#*=} ;;
    esac
done

printf '%s\n' "$sql" >> "${FAKE_MYSQL_TRX_LOG:?}"

mode=${FAKE_MYSQL_TRX_MODE:-normal}
case "$sql" in
    *'/* trx-monitor:connection-id */'*)
        printf '999\n'
        ;;
    *'/* trx-monitor:kill-target */'*)
        printf '12\tapp\thost1:3306\tsales\tQuery\t45\tWaiting for table metadata lock\tUPDATE orders SET status = 1\n'
        ;;
    *'/* trx-monitor:transactions-pfs */'*)
        [[ "$mode" != pfs-unavailable ]] || {
            printf 'performance_schema access denied\n' >&2
            exit 1
        }
        printf '12\tapp\thost1:3306\tsales\t30\tRunning\tSELECT 1\n'
        ;;
    *'/* trx-monitor:transactions-fallback */'*)
        printf '13\treporting\thost2:3306\tsales\t60\tRunning\tSELECT 2\n'
        ;;
    *'/* trx-monitor:locks */'*)
        [[ "$mode" != sys-unavailable ]] || {
            printf 'sys schema unavailable\n' >&2
            exit 1
        }
        printf '12\tapp@host1\t34\treport@host2\tsales.orders\t15\tUPDATE orders\tINSERT orders\n'
        ;;
    KILL\ CONNECTION\ *)
        printf 'killed\n'
        ;;
    *)
        printf '8.0.36\n'
        ;;
esac
