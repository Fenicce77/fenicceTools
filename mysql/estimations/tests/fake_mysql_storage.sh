#!/usr/bin/env bash
set -euo pipefail

sql=""
batch=false
table=false
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
        --batch|-B|-s) batch=true ;;
        --table|-t) table=true ;;
    esac
done

printf '%s\n' "$sql" >> "${FAKE_MYSQL_STORAGE_LOG:?}"
mode=${FAKE_MYSQL_STORAGE_MODE:-normal}

case "$sql" in
    *'/* estimate-storage:connection */'*)
        [[ "$mode" != connection-failure ]] || {
            printf 'access denied for login path\n' >&2
            exit 1
        }
        printf '8.0.36\t8589934592\n'
        ;;
    *'/* estimate-storage:projection */'*)
        [[ "$mode" != projection-failure ]] || {
            printf 'projection query failed\n' >&2
            exit 1
        }
        if [[ "$mode" == report-failure && "$batch" == true ]]; then
            printf 'report query failed\n' >&2
            exit 1
        fi
        if [[ "$mode" == slow-report && "$batch" == true ]]; then
            sleep 2
        fi
        if [[ "$table" == true ]]; then
            printf '+------------+----------+------------+-------------+------------+--------------+----------------+--------------+--------------+\n'
            printf '| Table_Name | Rows_Day | Total_Rows | Data_MB_Day | Idx_MB_Day | Total_MB_Day | Total_GB_Month | Retention_GB | BP_Pct_Total |\n'
            printf '| users      | 100      | 3000       | 1.0000      | 0.3000     | 1.3000       | 0.04           | 0.04         | 0.01%%        |\n'
            printf '| TOTAL      | 100      | 3000       | 1.0000      | 0.3000     | 1.3000       | 0.04           | 0.04         | 0.01%%        |\n'
            printf '+------------+----------+------------+-------------+------------+--------------+----------------+--------------+--------------+\n'
        elif [[ "$batch" == true ]]; then
            printf 'Table_Name\tRows_Day\tTotal_Rows\tData_MB_Day\tIdx_MB_Day\tTotal_MB_Day\tTotal_GB_Month\tRetention_GB\tBP_Pct_Total\n'
            if [[ "$mode" == escaped-identifiers ]]; then
                printf '%s\t100\t3000\t1.0000\t0.3000\t1.3000\t0.04\t0.04\t0.01%%\n' 'users\\archive'
                printf '%s\t100\t3000\t1.0000\t0.3000\t1.3000\t0.04\t0.04\t0.01%%\n' 'line\nbreak'
                printf '%s\t100\t3000\t1.0000\t0.3000\t1.3000\t0.04\t0.04\t0.01%%\n' 'tab\tname'
            else
                printf 'users\t100\t3000\t1.0000\t0.3000\t1.3000\t0.04\t0.04\t0.01%%\n'
            fi
            printf 'TOTAL\t100\t3000\t1.0000\t0.3000\t1.3000\t0.04\t0.04\t0.01%%\n'
        else
            printf 'unexpected projection output mode\n' >&2
            exit 1
        fi
        ;;
    *)
        printf 'unexpected SQL\n' >&2
        exit 1
        ;;
esac
