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
    *'/* trx-monitor:connection-check */'*)
        [[ "$mode" != connection-unavailable ]] || {
            printf 'access denied for login path\n' >&2
            exit 1
        }
        printf '1\n'
        ;;
    *'/* trx-monitor:connection-id */'*)
        printf '999\n'
        ;;
    *'/* trx-monitor:kill-target */'*)
        printf '12\tapp\thost1:3306\tsales\tQuery\t45\tWaiting for table metadata lock\tUPDATE orders SET status = 1\n'
        ;;
    *'/* trx-monitor:transactions-pfs */'*)
        case "$mode" in
            pfs-unavailable|transaction-unavailable)
                printf 'performance_schema access denied\n' >&2
                exit 1
                ;;
        esac
        if [[ "$mode" == pfs-stale ]]; then
            case "$sql" in
                *"et.STATE = 'ACTIVE'"*"CASE WHEN et.STATE = 'ACTIVE'"*) exit 0 ;;
                *) printf '88\tpool\thost3:3306\tsales\t900\tSleep\tSTALE TRANSACTION EVENT\n'; exit 0 ;;
            esac
        fi
        if [[ "$mode" == pfs-disabled ]]; then
            case "$sql" in
                *'information_schema.innodb_trx AS t'*'t.trx_id IS NOT NULL'*'TIMESTAMPDIFF(SECOND, t.trx_started, NOW())'*)
                    printf '77\tbatch\thost4:3306\tsales\t120\tSleep\tOPEN TRANSACTION WITHOUT PFS EVENT\n'
                    ;;
                *) exit 0 ;;
            esac
            exit 0
        fi
        if [[ "$mode" == age-colors ]]; then
            printf '%s\n' \
                $'101\tapp\thost1:3306\tsales\t59\tRunning\tSELECT age_59' \
                $'102\tapp\thost1:3306\tsales\t60\tRunning\tSELECT age_60' \
                $'103\tapp\thost1:3306\tsales\t120\tRunning\tSELECT age_120' \
                $'104\tapp\thost1:3306\tsales\t300\tRunning\tSELECT age_300'
            exit 0
        fi
        printf '12\tapp\thost1:3306\tsales\t30\tRunning\tSELECT 1\n'
        ;;
    *'/* trx-monitor:transactions-fallback */'*)
        [[ "$mode" != transaction-unavailable ]] || {
            printf 'information_schema transaction access denied\n' >&2
            exit 1
        }
        printf '13\treporting\thost2:3306\tsales\t60\tRunning\tSELECT 2\n'
        ;;
    *'/* trx-monitor:locks */'*)
        [[ "$mode" != sys-unavailable ]] || {
            printf '\033[31msys schema unavailable\033[0m\n' >&2
            exit 1
        }
        case "$sql" in
            *'       blocking_account,'*|*'       waiting_account,'*|*'       locked_table,'*)
                printf 'unknown sys.innodb_lock_waits column\n' >&2
                exit 1
                ;;
        esac
        case "$sql" in
            *'w.locked_table_schema'*'w.locked_table_name'*'performance_schema.threads AS blocking_thread'*'performance_schema.threads AS waiting_thread'*) : ;;
            *) printf 'incomplete lock-wait query\n' >&2; exit 1 ;;
        esac
        if [[ "$mode" == age-colors ]]; then
            printf '%s\n' \
                $'201\tapp@host1\t301\treport@host2\tsales.orders\t59\tUPDATE age_59\tINSERT age_59' \
                $'202\tapp@host1\t302\treport@host2\tsales.orders\t60\tUPDATE age_60\tINSERT age_60' \
                $'203\tapp@host1\t303\treport@host2\tsales.orders\t120\tUPDATE age_120\tINSERT age_120' \
                $'204\tapp@host1\t304\treport@host2\tsales.orders\t300\tUPDATE age_300\tINSERT age_300'
            exit 0
        fi
        printf '12\tapp@host1\t34\treport@host2\tsales.orders\t15\tUPDATE orders\tINSERT orders\n'
        ;;
    KILL\ CONNECTION\ *)
        printf 'killed\n'
        ;;
    *)
        printf '8.0.36\n'
        ;;
esac
