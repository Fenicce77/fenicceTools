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

if [[ "${FAKE_MYSQL_FK_MODE:-physical}" == "metadata-failure" && "$query" == *"fk-analyzer:physical"* ]]; then
    printf '\033]0;unsafe title\007\033[31mmetadata access denied\033[0m\n' >&2
    exit 1
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
        case "${FAKE_MYSQL_FK_MODE:-physical}" in
            composite)
                printf 'sales\taudit_orders\torders_tenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\taudit_orders\torders_order_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\taudit_orders\trecorded_at\t3\ttimestamp\t\t\n'
                printf 'sales\tlegacy_orders\torders_tenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders\ttenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders\torder_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\tshuffled_orders\torders_tenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tshuffled_orders\torders_order_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\ttyped_orders\torders_tenant_id\t1\tbigint\t\t\n'
                printf 'sales\ttyped_orders\torders_order_id\t2\tbigint unsigned\t\t\n'
                ;;
            composite-direct)
                printf 'sales\tevent_log\ttenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tevent_log\tentity_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\torders_archive\ttenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders_archive\tentity_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\torders_live\ttenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders_live\tentity_id\t2\tbigint\t\t\n'
                ;;
            gapped)
                printf 'sales\tgapped_items\tline_items_tenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tgapped_items\tline_items_line_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\tline_items\ttenant_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tline_items\torder_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\tline_items\tline_id\t3\tbigint unsigned\t\t\n'
                ;;
            naming)
                printf 'sales\taddresses\tcode\t1\tvarchar(2)\tutf8mb4\tutf8mb4_unicode_ci\n'
                printf 'sales\taddresses\tcountries_code\t2\tvarchar(2)\tutf8mb4\tutf8mb4_unicode_ci\n'
                printf 'sales\tcountries\tcode\t1\tvarchar(2)\tutf8mb4\tutf8mb4_unicode_ci\n'
                printf 'sales\tcurrencies\tcode\t1\tvarchar(2)\tutf8mb4\tutf8mb4_0900_ai_ci\n'
                printf 'sales\tcustomers\tid\t1\tbigint unsigned\t\t\n'
                printf 'sales\tlocalized_addresses\tcountries_code\t1\tvarchar(2)\tutf8mb4\tutf8mb4_0900_ai_ci\n'
                printf 'sales\tpurchases\tcustomers_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tsettlements\tcustomers_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\tsource\tid\t1\tbigint unsigned\t\t\n'
                ;;
            ambiguity)
                printf 'sales\tcurrencies\tcode\t1\tvarchar(3)\tutf8mb4\tutf8mb4_unicode_ci\n'
                printf 'sales\tcountries\tcode\t1\tvarchar(3)\tutf8mb4\tutf8mb4_unicode_ci\n'
                printf 'sales\tledger\tcode\t1\tvarchar(3)\tutf8mb4\tutf8mb4_unicode_ci\n'
                ;;
            *)
                printf 'sales\torders\tid\t1\tbigint unsigned\t\t\n'
                ;;
        esac
        ;;
    *"fk-analyzer:pks"*)
        case "${FAKE_MYSQL_FK_MODE:-physical}" in
            composite)
                printf 'sales\torders\ttenant_id\t1\n'
                printf 'sales\torders\torder_id\t2\n'
                ;;
            composite-direct)
                printf 'sales\torders_archive\ttenant_id\t1\n'
                printf 'sales\torders_archive\tentity_id\t2\n'
                printf 'sales\torders_live\ttenant_id\t1\n'
                printf 'sales\torders_live\tentity_id\t2\n'
                ;;
            gapped)
                printf 'sales\tline_items\ttenant_id\t1\n'
                printf 'sales\tline_items\torder_id\t2\n'
                printf 'sales\tline_items\tline_id\t3\n'
                ;;
            naming)
                printf 'sales\tcountries\tcode\t1\n'
                printf 'sales\tcurrencies\tcode\t1\n'
                printf 'sales\tcustomers\tid\t1\n'
                ;;
            ambiguity)
                printf 'sales\tcurrencies\tcode\t1\n'
                printf 'sales\tcountries\tcode\t1\n'
                ;;
            *)
                printf 'sales\torders\tid\t1\n'
                ;;
        esac
        ;;
    *"fk-analyzer:physical"*)
        case "${FAKE_MYSQL_FK_MODE:-physical}" in
            naming)
                printf 'fk_settlements_customer\tsales\tsettlements\tcustomers_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n'
                ;;
            composite|composite-direct|gapped|ambiguity)
                ;;
            *)
                printf 'fk_orders_customer\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n'
                printf 'fk_items_order\tsales\tshipment_items\ttenant_id\tsales\torders\ttenant_id\t1\tRESTRICT\tCASCADE\n'
                printf 'fk_items_order\tsales\tshipment_items\torder_id\tsales\torders\torder_id\t2\tRESTRICT\tCASCADE\n'
                ;;
        esac
        ;;
    *"fk-analyzer:indexes"*)
        case "${FAKE_MYSQL_FK_MODE:-physical}" in
            composite)
                printf 'sales\taudit_orders\tidx_audit_orders_fk\t1\t1\torders_tenant_id\t42\n'
                printf 'sales\taudit_orders\tidx_audit_orders_fk\t1\t2\torders_order_id\t42\n'
                printf 'sales\taudit_orders\tidx_audit_orders_fk\t1\t3\trecorded_at\t42\n'
                printf 'sales\torders\tPRIMARY\t0\t1\ttenant_id\t42\n'
                printf 'sales\torders\tPRIMARY\t0\t2\torder_id\t42\n'
                printf 'sales\tshuffled_orders\tidx_shuffled_orders_fk\t1\t1\torders_order_id\t42\n'
                printf 'sales\tshuffled_orders\tidx_shuffled_orders_fk\t1\t2\torders_tenant_id\t42\n'
                printf 'sales\ttyped_orders\tidx_typed_orders_fk\t1\t1\torders_tenant_id\t42\n'
                printf 'sales\ttyped_orders\tidx_typed_orders_fk\t1\t2\torders_order_id\t42\n'
                ;;
            composite-direct)
                printf 'sales\tevent_log\tidx_event_log_entity\t1\t1\ttenant_id\t42\n'
                printf 'sales\tevent_log\tidx_event_log_entity\t1\t2\tentity_id\t42\n'
                printf 'sales\torders_archive\tPRIMARY\t0\t1\ttenant_id\t42\n'
                printf 'sales\torders_archive\tPRIMARY\t0\t2\tentity_id\t42\n'
                printf 'sales\torders_live\tPRIMARY\t0\t1\ttenant_id\t42\n'
                printf 'sales\torders_live\tPRIMARY\t0\t2\tentity_id\t42\n'
                ;;
            gapped)
                printf 'sales\tgapped_items\tidx_gapped_items_reversed\t1\t1\tline_items_line_id\t42\n'
                printf 'sales\tgapped_items\tidx_gapped_items_reversed\t1\t2\tline_items_tenant_id\t42\n'
                printf 'sales\tline_items\tPRIMARY\t0\t1\ttenant_id\t42\n'
                printf 'sales\tline_items\tPRIMARY\t0\t2\torder_id\t42\n'
                printf 'sales\tline_items\tPRIMARY\t0\t3\tline_id\t42\n'
                ;;
            naming)
                printf 'sales\taddresses\tidx_addresses_code\t1\t1\tcode\t42\n'
                printf 'sales\taddresses\tidx_addresses_countries_code\t1\t1\tcountries_code\t42\n'
                printf 'sales\tcountries\tPRIMARY\t0\t1\tcode\t42\n'
                printf 'sales\tcurrencies\tPRIMARY\t0\t1\tcode\t42\n'
                printf 'sales\tcustomers\tPRIMARY\t0\t1\tid\t42\n'
                printf 'sales\tlocalized_addresses\tidx_localized_country\t1\t1\tcountries_code\t42\n'
                printf 'sales\tpurchases\tidx_purchases_customer\t1\t1\tcustomers_id\t42\n'
                printf 'sales\tsettlements\tidx_settlements_customer\t1\t1\tcustomers_id\t42\n'
                ;;
            ambiguity)
                printf 'sales\tcurrencies\tPRIMARY\t0\t1\tcode\t42\n'
                printf 'sales\tcountries\tPRIMARY\t0\t1\tcode\t42\n'
                printf 'sales\tledger\tidx_ledger_code\t1\t1\tcode\t42\n'
                ;;
            *)
                printf 'sales\torders\tPRIMARY\t0\t1\tid\t1\n'
                printf 'sales\torders\tidx_orders_customer\t1\t1\tcustomer_id\t42\n'
                printf 'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t1\ttenant_id\t42\n'
                printf 'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t2\torder_id\t42\n'
                ;;
        esac
        ;;
    *"fk-analyzer:stats"*)
        printf '42\n'
        ;;
    *"fk-analyzer:exact"*)
        printf '42\n'
        ;;
esac
