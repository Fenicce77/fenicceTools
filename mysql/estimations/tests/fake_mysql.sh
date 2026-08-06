#!/usr/bin/env bash
set -euo pipefail

query=""
include_headers=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -e)
            [[ $# -ge 2 ]] || exit 90
            query=$2
            shift 2
            ;;
        --column-names) include_headers=true; shift ;;
        *) shift ;;
    esac
done

printf '%s\n--QUERY-END--\n' "$query" >> "${FAKE_MYSQL_QUERY_LOG:?}"
scenario=${FAKE_MYSQL_SCENARIO:-baseline}

case "$scenario:$query" in
    connection_error:*cardinality:connection*) printf '%s\n' 'access denied' >&2; exit 1 ;;
    partial:*cardinality:table_metadata*"X'626164'"*) printf '%s\n' 'metadata failed' >&2; exit 1 ;;
    analyze_error:*ANALYZE\ LOCAL\ TABLE*bad*) printf '%s\n' 'app.bad\tanalyze\terror\tforced failure'; exit 0 ;;
    timeout:*cardinality:exact_column*slow_col*) printf '%s\n' 'maximum statement execution time exceeded' >&2; exit 1 ;;
esac

case "$query" in
    *cardinality:connection*) printf '1\t8.4.6\tfake-db.example\n' ;;
    *ANALYZE\ LOCAL\ TABLE*)
        [[ "$scenario" == analyze_empty ]] || printf 'app.table\tanalyze\tstatus\tOK\n'
        ;;
    *cardinality:table_metadata*)
        case "$scenario" in
            large) printf 'InnoDB\t900000\n' ;;
            missing_estimate) printf 'InnoDB\tNULL\n' ;;
            empty) printf 'InnoDB\t0\n' ;;
            threshold) printf 'InnoDB\t500000\n' ;;
            drift) printf 'InnoDB\t50\n' ;;
            layout_divergent) printf 'InnoDB\t1\n' ;;
            *) printf 'InnoDB\t100\n' ;;
        esac
        ;;
    *cardinality:column_metadata*)
        case "$scenario" in
            large|missing_estimate)
                printf 'id\tbigint unsigned\tbigint\tNO\t900000\tPRIMARY\tPRIMARY_SINGLE\t1\tPRIMARY(#1)\n'
                printf 'tenant_id\tbigint unsigned\tbigint\tNO\tN/A\tN/A\tUNAVAILABLE\t2\tuk_tenant_email(#1), idx_email_tenant(#2)\n'
                printf 'email\tvarchar(255)\tvarchar\tYES\t450000\tidx_email_tenant\tLEADING_COMPOSITE\t2\tidx_email_tenant(#1)\n'
                ;;
            exact_keys|timeout)
                printf 'id\tbigint\tbigint\tNO\t100\tPRIMARY\tPRIMARY_SINGLE\t1\tPRIMARY(#1)\n'
                printf 'code\tvarchar(32)\tvarchar\tNO\t100\tuk_code\tUNIQUE_SINGLE\t1\tuk_code(#1)\n'
                printf 'external_id\tbigint\tbigint\tYES\t95\tuk_external\tUNIQUE_SINGLE\t1\tuk_external(#1)\n'
                printf 'tenant_id\tbigint\tbigint\tNO\t40\tPRIMARY\tLEADING_COMPOSITE\t2\tPRIMARY(#1)\n'
                printf 'name\tvarchar(255)\tvarchar\tYES\t40\tidx_name\tLEADING_SINGLE\t1\tidx_name(#1)\n'
                printf 'created_on\tdate\tdate\tYES\t40\tN/A\tUNAVAILABLE\t0\t---\n'
                printf 'zero_value\tint\tint\tYES\t40\tN/A\tUNAVAILABLE\t0\t---\n'
                [[ "$scenario" != timeout ]] || printf 'slow_col\tvarchar(20)\tvarchar\tYES\t20\tN/A\tUNAVAILABLE\t0\t---\n'
                [[ "$scenario" != timeout ]] || printf 'after_slow\tint\tint\tYES\t10\tN/A\tUNAVAILABLE\t0\t---\n'
                ;;
            layout_common)
                printf 'vendor_transaction_id\tvarchar(128)\tvarchar\tNO\t100\tuk_vendor_transaction\tUNIQUE_SINGLE\t1\tidx_aviator_vendor_transaction(#1), uk_vendor_transaction(#1)\n'
                printf 'processing_status\ttinyint unsigned\ttinyint\tYES\t20\tidx_aviator_status_created\tLEADING_SINGLE\t1\tidx_aviator_status_created(#1)\n'
                printf 'wallet_reference\tvarchar(128)\tvarchar\tYES\t95\tuk_wallet_reference\tUNIQUE_SINGLE\t1\tuk_wallet_reference(#1)\n'
                ;;
            layout_borrow)
                printf 'applied_multiplier_reference_key\tvarchar(128)\tvarchar\tNO\t100\tuk_applied_multiplier_reference\tUNIQUE_SINGLE\t1\tidx_aviator_applied_multiplier_reference(#1)\n'
                ;;
            layout_numeric)
                printf 'vendor_transaction_id\tvarchar(128)\tvarchar\tNO\t123456789\tuk_vendor_transaction\tUNIQUE_SINGLE\t1\tidx_aviator_vendor_transaction(#1)\n'
                ;;
            layout_divergent)
                printf 'vendor_transaction_id\tvarchar(128)\tvarchar\tNO\t18446744073709551615\tidx_divergent_cardinality\tLEADING_SINGLE\t1\tidx_divergent_cardinality(#1)\n'
                ;;
            layout_types)
                printf 'unsigned_counter\tbigint unsigned\tbigint\tNO\t100\tidx_counter\tLEADING_SINGLE\t1\tidx_counter(#1)\n'
                printf "state\tenum('new','processing','complete')\tenum\tNO\t3\tidx_state\tLEADING_SINGLE\t1\tidx_state(#1)\n"
                ;;
            layout_wrapped)
                printf "flags\tset('audit','billing','security','reporting')\tset\tYES\t8\tidx_flags\tLEADING_SINGLE\t1\tidx_flags(#1), idx_flags_created_at(#1), uk_flags_external_reference(#1)\n"
                ;;
            layout_oversized_index)
                printf 'external_reference\tvarchar(128)\tvarchar\tNO\t100\tidx_external\tLEADING_SINGLE\t1\tidx_external_reference_identifier_exceeding_the_terminal_cell_width(#1)\n'
                ;;
            *) printf 'id\tbigint\tbigint\tNO\t100\tPRIMARY\tPRIMARY_SINGLE\t1\tPRIMARY(#1)\n' ;;
        esac
        ;;
    *cardinality:count_explain*)
        if [[ "$include_headers" == true ]]; then
            printf 'id\tselect_type\ttable\tpartitions\ttype\tpossible_keys\tkey\tkey_len\tref\trows\tfiltered\tExtra\n'
        fi
        printf '1\tSIMPLE\tusers\tNULL\tindex\tNULL\tidx_small\t8\tNULL\t100\t100.00\tUsing index\n'
        ;;
    *cardinality:exact_count*)
        case "$scenario" in
            empty) printf '0\n' ;;
            layout_numeric) printf '123456789\n' ;;
            *) printf '100\n' ;;
        esac
        ;;
    *cardinality:exact_unique_nullable*) printf '95\n' ;;
    *cardinality:exact_column*) printf '40\t80\n' ;;
    *) printf 'fake_mysql: unhandled query: %s\n' "$query" >&2; exit 91 ;;
esac
