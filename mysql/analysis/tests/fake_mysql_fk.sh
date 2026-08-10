#!/usr/bin/env bash
# Deterministic MySQL client fixture for fk_analyzer.sh tests.
set -euo pipefail

query=""
mode=${FAKE_MYSQL_FK_MODE:-physical}
raw_output=false

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
        --raw)
            raw_output=true
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
if [[ -n "${FAKE_MYSQL_FK_OPTIONS_LOG:-}" ]]; then
    printf '%s\t%s\n' "$raw_output" "$query" >> "$FAKE_MYSQL_FK_OPTIONS_LOG"
fi

if [[ "$query" == *"fk-analyzer:connection"* ]]; then
    case "$mode" in
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

case "$mode:$query" in
    ddl-failure:*fk-analyzer:ddl*)
        printf '\033]0;unsafe title\007\033[31mDDL access denied\033[0m\ninjected line\n' >&2
        exit 1
        ;;
    metadata-failure:*fk-analyzer:physical*|physical-failure:*fk-analyzer:physical*|report-failure:*fk-analyzer:physical*)
        printf '\033]0;unsafe title\007\033[31mphysical metadata access denied\033[0m\ninjected line\n' >&2
        exit 1
        ;;
    virtual-metadata-failure:*fk-analyzer:columns*)
        printf '\033]0;unsafe title\007\033[31mvirtual metadata access denied\033[0m\ninjected line\n' >&2
        exit 1
        ;;
    stats-failure:*fk-analyzer:stats*)
        printf '\033]0;unsafe title\007\033[31mstatistics access denied\033[0m\ninjected line\n' >&2
        exit 1
        ;;
esac

case "$query" in
    *"fk-analyzer:connection"*)
        printf '8.4.2\t8589934592\n'
        ;;
    *"fk-analyzer:target"*)
        if [[ "$mode" != "target-missing" ]]; then
            printf 'orders\tInnoDB\n'
        fi
        ;;
    *"fk-analyzer:ddl"*)
        if [[ "$mode" == escaped-report && "$raw_output" == true ]]; then
            printf 'orders\tCREATE TABLE `orders` (\n  `id` bigint unsigned NOT NULL,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB\n'
        else
            printf 'orders\tCREATE TABLE `orders` (`id` bigint unsigned NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB\n'
        fi
        ;;
    *"fk-analyzer:columns"*)
        case "$mode" in
            report|slow-report|escaped-report)
                printf 'sales\taudit_orders\torders_id\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders\tid\t1\tbigint unsigned\t\t\n'
                printf 'sales\torders\tcustomer_id\t2\tbigint unsigned\t\t\n'
                printf 'sales\tshipment_items\torder_id\t1\tbigint unsigned\t\t\n'
                ;;
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
        case "$mode" in
            report|slow-report|escaped-report)
                printf 'sales\torders\tid\t1\n'
                ;;
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
        case "$mode" in
            report|slow-report)
                printf 'fk_orders_"customer"\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n'
                printf 'fk_items_order\tsales\tshipment_items\torder_id\tsales\torders\tid\t1\tRESTRICT\tCASCADE\n'
                ;;
            escaped-report)
                if [[ "$raw_output" == true ]]; then
                    printf 'fk_orders_\ttab\nline\\slash\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n'
                else
                    printf '%s\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE\n' 'fk_orders_\ttab\nline\\slash'
                fi
                printf 'fk_items_order\tsales\tshipment_items\torder_id\tsales\torders\tid\t1\tRESTRICT\tCASCADE\n'
                ;;
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
        case "$mode" in
            report|slow-report|escaped-report)
                printf 'sales\taudit_orders\tidx_audit_orders_fk\t1\t1\torders_id\t42\n'
                printf 'sales\torders\tPRIMARY\t0\t1\tid\t42\n'
                printf 'sales\torders\tidx_orders_customer\t1\t1\tcustomer_id\t42\n'
                printf 'sales\tshipment_items\tidx_shipment_items_order\t1\t1\torder_id\t42\n'
                ;;
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
        case "$mode" in
            cardinality|report|slow-report|escaped-report) printf '40\n' ;;
            exact-zero) printf '5\n' ;;
            *) printf '42\n' ;;
        esac
        ;;
    *"fk-analyzer:exact"*)
        case "$mode" in
            exact-zero) printf '0\n' ;;
            *) printf '42\n' ;;
        esac
        ;;
esac
