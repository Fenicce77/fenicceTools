#!/usr/bin/env bash
# Deterministic MySQL client fixture for fk_analyzer.sh tests.
set -euo pipefail

query=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--execute)
            [[ $# -ge 2 ]] || exit 64
            query=$2
            shift 2
            ;;
        --execute=*)
            query=${1#--execute=}
            shift
            ;;
        -e?*)
            query=${1#-e}
            shift
            ;;
        --batch|--table)
            shift
            ;;
        --database)
            [[ $# -ge 2 ]] || exit 64
            shift 2
            ;;
        --database=*)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

printf '%s\n' "$query" >> "${FAKE_MYSQL_FK_LOG:?}"

if [[ "$query" == *"fk-analyzer:connection"* ]]; then
    case "${FAKE_MYSQL_FK_MODE:-physical}" in
        connection-failure)
            printf '%s\n' 'access denied for configured login path' >&2
            exit 1
            ;;
        connection-failure-ansi)
            printf '\033]0;unsafe title\007\033[31maccess denied for configured login path\033[0m\n' >&2
            exit 1
            ;;
    esac
fi

case "$query" in
    *"fk-analyzer:connection"*)
        printf '8.4.2\t8589934592\n'
        ;;
    *"fk-analyzer:target"*)
        if [[ "${FAKE_MYSQL_FK_MODE:-physical}" != "target-missing" ]]; then
            printf 'orders\tInnoDB\n'
        fi
        ;;
    *"fk-analyzer:ddl"*)
        printf 'orders\tCREATE TABLE `orders` (`id` bigint unsigned NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB\n'
        ;;
    *"fk-analyzer:columns"*)
        printf 'sales\torders\tid\t1\tbigint unsigned\t\t\n'
        ;;
    *"fk-analyzer:pks"*)
        printf 'sales\torders\tid\t1\n'
        ;;
    *"fk-analyzer:physical"*)
        printf 'fk_orders_customer\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n'
        printf 'fk_items_order\tsales\tshipment_items\ttenant_id\tsales\torders\ttenant_id\t1\tRESTRICT\tCASCADE\n'
        printf 'fk_items_order\tsales\tshipment_items\torder_id\tsales\torders\torder_id\t2\tRESTRICT\tCASCADE\n'
        ;;
    *"fk-analyzer:indexes"*)
        printf 'sales\torders\tPRIMARY\t0\t1\tid\t1\n'
        printf 'sales\torders\tidx_orders_customer\t1\t1\tcustomer_id\t42\n'
        printf 'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t1\ttenant_id\t42\n'
        printf 'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t2\torder_id\t42\n'
        ;;
    *"fk-analyzer:stats"*)
        printf '42\n'
        ;;
    *"fk-analyzer:exact"*)
        printf '42\n'
        ;;
esac
