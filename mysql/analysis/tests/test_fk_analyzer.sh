#!/usr/bin/env bash
# Behavioral contract tests for the foreign key topology analyzer CLI.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../fk_analyzer.sh"
FAKE_MYSQL="$SCRIPT_DIR/fake_mysql_fk.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fk-analyzer-test.XXXXXX")
OUTPUT=""
STATUS=0

test_cleanup() {
    rm -rf "$TMP"
}
trap test_cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] || fail "expected status $expected, got $STATUS; output: $OUTPUT"
}

assert_equals() {
    local actual=$1
    local expected=$2
    [[ "$actual" == "$expected" ]] || fail "expected: $expected; got: $actual"
}

assert_marker_once() {
    local marker=$1
    local count

    count=$(LC_ALL=C grep -c "$marker" "$FAKE_MYSQL_FK_LOG" || true)
    assert_equals "$count" 1
}

assert_tsv_fields() {
    local file=$1

    LC_ALL=C awk -F '\t' '
        NF != 12 { printf "line %d has %d fields\n", NR, NF > "/dev/stderr"; failed = 1 }
        index($0, sprintf("%c", 27)) { printf "line %d contains ANSI escape data\n", NR > "/dev/stderr"; failed = 1 }
        END { exit failed }
    ' "$file" || fail "expected ANSI-free 12-field rows in $file"
}

assert_relation_row() {
    local file=$1
    local source_table=$2
    local classification=$3
    local source_columns=$4
    local target_table=$5
    local target_columns=$6
    local supporting_index=$7
    local status_tags=$8
    local count

    count=$(LC_ALL=C awk -F '\t' \
        -v source_table="$source_table" \
        -v classification="$classification" \
        -v source_columns="$source_columns" \
        -v target_table="$target_table" \
        -v target_columns="$target_columns" \
        -v supporting_index="$supporting_index" \
        -v status_tags="$status_tags" '
        $2 == classification && $4 == source_table && $5 == source_columns &&
        $7 == target_table && $8 == target_columns && $10 == supporting_index &&
        $11 == status_tags { count++ }
        END { print count + 0 }
    ' "$file")
    assert_equals "$count" 1
}

assert_no_modifying_sql() {
    if LC_ALL=C grep -Eiq '(^|[^[:alnum:]_])(INSERT|UPDATE|DELETE|ALTER|ANALYZE|KILL)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])SET[[:space:]]+GLOBAL([^[:alnum:]_]|$)' "$FAKE_MYSQL_FK_LOG"; then
        fail 'metadata query log contains a forbidden SQL keyword'
    fi
}

run_case() {
    local name=$1
    shift
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    OUTPUT=$(/bin/bash "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
    printf 'ok: %s\n' "$name"
}

repeat_char() {
    local count=$1
    local character=$2
    local result=""
    local index=0
    while [[ "$index" -lt "$count" ]]; do
        result="${result}${character}"
        index=$((index + 1))
    done
    printf '%s' "$result"
}

export FAKE_MYSQL_FK_LOG="$TMP/fake-mysql.log"

run_cli_tests() {
run_case no_args
assert_status 0
assert_contains "$OUTPUT" 'MySQL Foreign Key Topology Analyzer'
assert_contains "$OUTPUT" 'Required options:'
assert_contains "$OUTPUT" 'Virtual relationship rules:'
assert_contains "$OUTPUT" 'Exit status:'
assert_contains "$OUTPUT" 'Examples:'

run_case help --help --no-color
assert_status 0
assert_not_contains "$OUTPUT" $'\033'

run_case missing_schema -l test -t orders --environment test
assert_status 2
assert_contains "$OUTPUT" '--schema is required.'

run_case bad_environment -l test -s sales -t orders --environment qa
assert_status 2

run_case exact_prod_guard -l test -s sales -t orders \
    --environment production --cardinality exact --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$OUTPUT" 'Exact cardinality in production requires --allow-production.'

run_case stray_allow -l test -s sales -t orders --environment test --allow-production
assert_status 2

run_case width_small -l test -s sales -t orders --environment test --terminal-width 119
assert_status 2

run_case width_empty_equals -l test -s sales -t orders --environment test \
    --terminal-width= --mysql-bin "$FAKE_MYSQL"
assert_status 2
run_case width_empty_space -l test -s sales -t orders --environment test \
    --terminal-width "" --mysql-bin "$FAKE_MYSQL"
assert_status 2

run_case missing_client -l test -s sales -t orders --environment test \
    --mysql-bin "$TMP/missing-mysql"
assert_status 3

run_case long_equals --login-path=test --schema=sales --table=orders --environment=test \
    --mysql-bin="$FAKE_MYSQL" --terminal-width=120 --format=tsv --output-file="$TMP/report.tsv"
assert_status 0
assert_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:connection'
assert_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:target'
assert_contains "$(<"$FAKE_MYSQL_FK_LOG")" 'fk-analyzer:physical'

run_case long_space --login-path test --schema sales --table orders --environment test \
    --mysql-bin "$FAKE_MYSQL" --terminal-width 10000 --format csv --output-file "$TMP/report.csv"
assert_status 0

run_case legacy_cardinality -l test -s sales -t orders --environment production -c --mysql-bin "$FAKE_MYSQL"
assert_status 0

run_case unknown_option -l test -s sales -t orders --environment test --unknown
assert_status 2

run_case empty_schema -l test --schema= -t orders --environment test
assert_status 2
run_case empty_table -l test -s sales --table= --environment test
assert_status 2
run_case empty_login --login-path= -s sales -t orders --environment test
assert_status 2

schema_64=$(repeat_char 64 s)
table_64=$(repeat_char 64 t)
run_case identifiers_64 -l test -s "$schema_64" -t "$table_64" --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case schema_65 -l test -s "$(repeat_char 65 s)" -t orders --environment test
assert_status 2
run_case table_65 -l test -s sales -t "$(repeat_char 65 t)" --environment test
assert_status 2
run_case trailing_space -l test -s 'sales ' -t orders --environment test
assert_status 2
run_case control_character -l test -s $'sales\narchive' -t orders --environment test
assert_status 2

run_case width_minimum -l test -s sales -t orders --environment test --terminal-width 120 --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case width_maximum -l test -s sales -t orders --environment test --terminal-width 10000 --mysql-bin "$FAKE_MYSQL"
assert_status 0
run_case width_large -l test -s sales -t orders --environment test --terminal-width 10001
assert_status 2
run_case width_overflow -l test -s sales -t orders --environment test --terminal-width 999999999999999999999999999999
assert_status 2

MYSQL_BIN="$FAKE_MYSQL"
export MYSQL_BIN
run_case environment_client -l test -s sales -t orders --environment test
assert_status 0
run_case option_client_priority -l test -s sales -t orders --environment test --mysql-bin "$TMP/missing-mysql"
assert_status 3
unset MYSQL_BIN

mkdir "$TMP/path-bin"
ln -s "$FAKE_MYSQL" "$TMP/path-bin/mysql"
original_path=$PATH
PATH="$TMP/path-bin:$PATH"
export PATH
run_case path_client -l test -s sales -t orders --environment test
assert_status 0
PATH=$original_path
export PATH

FAKE_MYSQL_FK_MODE=connection-failure
export FAKE_MYSQL_FK_MODE
run_case connection_failure -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
assert_contains "$OUTPUT" 'access denied for configured login path'
unset FAKE_MYSQL_FK_MODE

FAKE_MYSQL_FK_MODE=connection-failure-ansi
export FAKE_MYSQL_FK_MODE
run_case connection_failure_ansi -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
assert_not_contains "$OUTPUT" $'\033'
assert_not_contains "$OUTPUT" $'\n'
unset FAKE_MYSQL_FK_MODE

FAKE_MYSQL_FK_MODE=target-missing
export FAKE_MYSQL_FK_MODE
run_case target_missing -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
unset FAKE_MYSQL_FK_MODE

FAKE_MYSQL_FK_MODE=metadata-failure
export FAKE_MYSQL_FK_MODE
run_case metadata_failure -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
assert_status 3
assert_contains "$OUTPUT" 'metadata access denied'
assert_not_contains "$OUTPUT" $'\033'
assert_not_contains "$OUTPUT" $'\n'
unset FAKE_MYSQL_FK_MODE

printf 'PASS: fk_analyzer CLI contract\n'
}

run_physical_tests() {
    local reducer_dir="$TMP/reducer"
    local relations

    mkdir "$reducer_dir"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    WORK_DIR=$reducer_dir
    SCHEMA_NAME=sales
    TABLE_NAME=orders

    printf '%s\n' \
        $'sales\torders\tid\t1\tbigint unsigned\t\t' \
        > "$WORK_DIR/columns.tsv"
    printf '%s\n' \
        $'sales\torders\tid\t1' \
        > "$WORK_DIR/pks.tsv"
    printf '%s\n' \
        $'fk_orders_customer\tsales\torders\tcustomer_id\tsales\tcustomers\tid\t1\tRESTRICT\tCASCADE' \
        $'fk_items_order\tsales\tshipment_items\ttenant_id\tsales\torders\ttenant_id\t1\tRESTRICT\tCASCADE' \
        $'fk_items_order\tsales\tshipment_items\torder_id\tsales\torders\torder_id\t2\tRESTRICT\tCASCADE' \
        $'fk_shipments_archive_orders\tsales\tshipments\tarchive_order_id\tarchive\torders\tid\t1\tRESTRICT\tCASCADE' \
        > "$WORK_DIR/physical-components.tsv"
    printf '%s\n' \
        $'sales\torders\tPRIMARY\t0\t1\tid\t1' \
        $'sales\torders\tidx_orders_customer\t1\t1\tcustomer_id\t42' \
        $'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t1\ttenant_id\t42' \
        $'sales\tshipment_items\tidx_shipment_items_tenant_order\t1\t2\torder_id\t42' \
        > "$WORK_DIR/indexes.tsv"
    printf '42\n' > "$WORK_DIR/stats.tsv"

    build_physical_relations
    relations=$(<"$WORK_DIR/relations.tsv")
    assert_contains "$relations" $'OUTBOUND\tPHYSICAL_FK\tsales\torders\t(customer_id)\tsales\tcustomers\t(id)\tfk_orders_customer\tidx_orders_customer\t\tON UPDATE RESTRICT; ON DELETE CASCADE'
    assert_contains "$relations" $'INBOUND\tPHYSICAL_FK\tsales\tshipment_items\t(tenant_id, order_id)\tsales\torders\t(tenant_id, order_id)\tfk_items_order\tidx_shipment_items_tenant_order\t\tON UPDATE RESTRICT; ON DELETE CASCADE'
    assert_equals "$(LC_ALL=C awk 'END { print NR }' "$WORK_DIR/relations.tsv")" 2
    assert_equals "$(LC_ALL=C awk -F '\t' '$9 == "fk_items_order" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_not_contains "$relations" 'fk_shipments_archive_orders'

    run_case physical_end_to_end -l test -s sales -t orders --environment test --mysql-bin "$FAKE_MYSQL"
    assert_status 0
    assert_marker_once 'fk-analyzer:columns'
    assert_marker_once 'fk-analyzer:pks'
    assert_marker_once 'fk-analyzer:physical'
    assert_marker_once 'fk-analyzer:indexes'
    assert_marker_once 'fk-analyzer:stats'
    assert_no_modifying_sql
    printf 'PASS: fk_analyzer physical relations\n'
}

load_virtual_fixture() {
    local mode=$1
    local fixture_dir=$2

    mkdir "$fixture_dir"
    WORK_DIR=$fixture_dir
    LOGIN_PATH=test
    MYSQL_BIN=$FAKE_MYSQL
    FAKE_MYSQL_FK_MODE=$mode
    export FAKE_MYSQL_FK_MODE
    acquire_metadata
    unset FAKE_MYSQL_FK_MODE
}

run_relation_reducers() {
    build_physical_relations
    if declare -F build_virtual_relations >/dev/null 2>&1; then
        build_virtual_relations
    fi
}

run_virtual_tests() {
    local composite_dir="$TMP/composite"
    local composite_direct_dir="$TMP/composite-direct"
    local gapped_dir="$TMP/gapped"
    local naming_dir="$TMP/naming"
    local ambiguity_dir="$TMP/ambiguity"
    local stable_copy="$TMP/relations.stable.tsv"
    local details

    # shellcheck source=/dev/null
    source "$SCRIPT"

    SCHEMA_NAME=sales
    TABLE_NAME=orders
    load_virtual_fixture composite "$composite_dir"
    PHYSICAL_ONLY=false
    run_relation_reducers
    assert_tsv_fields "$WORK_DIR/relations.tsv"
    assert_equals "$(LC_ALL=C awk 'END { print NR + 0 }' "$WORK_DIR/relations.tsv")" 4
    assert_relation_row "$WORK_DIR/relations.tsv" audit_orders COMPLETE_VIRTUAL_FK \
        '(orders_tenant_id, orders_order_id)' orders '(tenant_id, order_id)' \
        idx_audit_orders_fk ''
    assert_relation_row "$WORK_DIR/relations.tsv" legacy_orders PARTIAL_VIRTUAL_FK \
        '(orders_tenant_id)' orders '(tenant_id)' '' 'MISSING_COMPONENTS,UNINDEXED'
    assert_relation_row "$WORK_DIR/relations.tsv" shuffled_orders PARTIAL_VIRTUAL_FK \
        '(orders_tenant_id, orders_order_id)' orders '(tenant_id, order_id)' '' \
        'INDEX_ORDER_MISMATCH'
    assert_relation_row "$WORK_DIR/relations.tsv" typed_orders PARTIAL_VIRTUAL_FK \
        '(orders_tenant_id, orders_order_id)' orders '(tenant_id, order_id)' \
        idx_typed_orders_fk 'TYPE_MISMATCH'

    cp "$WORK_DIR/relations.tsv" "$stable_copy"
    run_relation_reducers
    cmp -s "$stable_copy" "$WORK_DIR/relations.tsv" || fail 'virtual relation ordering is not byte-stable'

    PHYSICAL_ONLY=true
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 ~ /VIRTUAL/ { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0
    PHYSICAL_ONLY=false

    SCHEMA_NAME=sales
    TABLE_NAME=event_log
    load_virtual_fixture composite-direct "$composite_direct_dir"
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0
    assert_relation_row "$WORK_DIR/relations.tsv" event_log COMPLETE_VIRTUAL_FK \
        '(tenant_id, entity_id)' orders_archive '(tenant_id, entity_id)' \
        idx_event_log_entity ''

    SCHEMA_NAME=sales
    TABLE_NAME=line_items
    load_virtual_fixture gapped "$gapped_dir"
    run_relation_reducers
    assert_relation_row "$WORK_DIR/relations.tsv" gapped_items PARTIAL_VIRTUAL_FK \
        '(line_items_tenant_id, line_items_line_id)' line_items '(tenant_id, line_id)' '' \
        'MISSING_COMPONENTS,INDEX_ORDER_MISMATCH'

    SCHEMA_NAME=sales
    TABLE_NAME=orders
    load_virtual_fixture naming "$naming_dir"
    TABLE_NAME=purchases
    run_relation_reducers
    assert_relation_row "$WORK_DIR/relations.tsv" purchases COMPLETE_VIRTUAL_FK \
        '(customers_id)' customers '(id)' idx_purchases_customer ''

    TABLE_NAME=addresses
    run_relation_reducers
    assert_relation_row "$WORK_DIR/relations.tsv" addresses COMPLETE_VIRTUAL_FK \
        '(code)' countries '(code)' idx_addresses_code ''
    assert_relation_row "$WORK_DIR/relations.tsv" addresses COMPLETE_VIRTUAL_FK \
        '(countries_code)' countries '(code)' idx_addresses_countries_code ''
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0

    TABLE_NAME=localized_addresses
    run_relation_reducers
    assert_relation_row "$WORK_DIR/relations.tsv" localized_addresses PARTIAL_VIRTUAL_FK \
        '(countries_code)' countries '(code)' idx_localized_country 'TYPE_MISMATCH'

    TABLE_NAME=source
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk 'END { print NR + 0 }' "$WORK_DIR/relations.tsv")" 0

    TABLE_NAME=settlements
    run_relation_reducers
    assert_tsv_fields "$WORK_DIR/relations.tsv"
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "PHYSICAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 ~ /VIRTUAL/ { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0

    TABLE_NAME=customers
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk 'END { print NR + 0 }' "$WORK_DIR/relations.tsv")" 2
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "PHYSICAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_relation_row "$WORK_DIR/relations.tsv" purchases COMPLETE_VIRTUAL_FK \
        '(customers_id)' customers '(id)' idx_purchases_customer ''
    cp "$WORK_DIR/relations.tsv" "$stable_copy"
    run_relation_reducers
    cmp -s "$stable_copy" "$WORK_DIR/relations.tsv" || fail 'mixed relation ordering is not byte-stable'

    PHYSICAL_ONLY=true
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "PHYSICAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 ~ /VIRTUAL/ { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0
    PHYSICAL_ONLY=false

    TABLE_NAME=orders
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk 'END { print NR + 0 }' "$WORK_DIR/relations.tsv")" 0

    SCHEMA_NAME=sales
    TABLE_NAME=ledger
    load_virtual_fixture ambiguity "$ambiguity_dir"
    run_relation_reducers
    assert_tsv_fields "$WORK_DIR/relations.tsv"
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { print $6 $7 }' "$WORK_DIR/relations.tsv")" ''
    details=$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { print $12 }' "$WORK_DIR/relations.tsv")
    assert_equals "$details" 'Candidate targets: sales.countries(code), sales.currencies(code)'

    printf '%s\n' \
        $'fk_ledger_country\tsales\tledger\tcode\tsales\tcountries\tcode\t1\tRESTRICT\tCASCADE' \
        > "$WORK_DIR/physical-components.tsv"
    run_relation_reducers
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "AMBIGUOUS_VIRTUAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 0
    assert_equals "$(LC_ALL=C awk -F '\t' '$2 == "PHYSICAL_FK" { count++ } END { print count + 0 }' "$WORK_DIR/relations.tsv")" 1
    assert_relation_row "$WORK_DIR/relations.tsv" ledger COMPLETE_VIRTUAL_FK \
        '(code)' currencies '(code)' idx_ledger_code ''
    assert_no_modifying_sql

    printf 'PASS: fk_analyzer virtual relations\n'
}

if [[ $# -eq 0 ]]; then
    run_cli_tests
    run_physical_tests
    run_virtual_tests
else
    for test_group in "$@"; do
        case "$test_group" in
            cli) run_cli_tests ;;
            physical) run_physical_tests ;;
            virtual) run_virtual_tests ;;
            *) fail "unknown test group: $test_group" ;;
        esac
    done
fi
