#!/usr/bin/env bash
# Behavioral contract tests for the foreign key topology analyzer CLI.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../fk_analyzer.sh"
FAKE_MYSQL="$SCRIPT_DIR/fake_mysql_fk.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fk-analyzer-test.XXXXXX")
OUTPUT=""
STATUS=0
STRIPPED_OUTPUT=""
FIXTURE_FILE="$TMP/presentation-relations.tsv"
FIXTURE_RUNNER="$TMP/run-fk-presentation-fixture.sh"

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

strip_ansi() {
    STRIPPED_OUTPUT=$(printf '%s\n' "$1" | LC_ALL=C awk '
        {
            gsub(/\033\[[0-9;]*[a-zA-Z]/, "")
            sub(/\r$/, "")
            print
        }
    ')
}

assert_has_ansi() {
    [[ "$1" == *$'\033['* ]] || fail 'expected ANSI color sequences'
}

write_presentation_fixture() {
    printf '%s\n' \
        $'OUTBOUND\tPHYSICAL_FK\tsales\torders\t(tenant_identifier_component, extremely_long_order_identifier_component, regional_partition_identifier_component)\tsales\tcustomers_archive\t(tenant_identifier_component, customer_identifier_component, regional_partition_identifier_component)\tfk_orders_customer_archive_with_long_identifier\tidx_orders_customer_archive_covering_tuple\t\tON UPDATE RESTRICT; ON DELETE CASCADE' \
        $'OUTBOUND\tCOMPLETE_VIRTUAL_FK\tsales\taudit_orders\t(orders_tenant_identifier, orders_order_identifier, orders_regional_partition_identifier)\tsales\torders\t(tenant_identifier, order_identifier, regional_partition_identifier)\t\tidx_audit_orders_complete_virtual_tuple\t\tComplete ordered composite tuple and compatible index prefix' \
        $'OUTBOUND\tPARTIAL_VIRTUAL_FK\tsales\ttyped_orders\t(orders_tenant_identifier, orders_order_identifier, orders_regional_partition_identifier)\tsales\torders\t(tenant_identifier, order_identifier, regional_partition_identifier)\t\tidx_typed_orders_wrong_order\tMISSING_COMPONENTS,TYPE_MISMATCH,UNINDEXED,INDEX_ORDER_MISMATCH\tPartial composite relationship with all diagnostic tags visible' \
        $'OUTBOUND\tAMBIGUOUS_VIRTUAL_FK\tsales\tledger_entries\t(country_code_identifier_component)\t\t\t()\t\tidx_ledger_country_code\t\tCandidate targets: sales.countries(code), sales.currencies(code)' \
        $'INBOUND\tPHYSICAL_FK\tsales\tshipment_items_archive\t(tenant_identifier_component, order_identifier_component, regional_partition_identifier_component)\tsales\torders\t(tenant_identifier_component, order_identifier_component, regional_partition_identifier_component)\tfk_shipment_items_archive_orders\tidx_shipment_items_archive_orders_tuple\tUNINDEXED\tON UPDATE CASCADE; ON DELETE RESTRICT' \
        $'INBOUND\tCOMPLETE_VIRTUAL_FK\tsales\torder_events_archive\t(orders_tenant_identifier, orders_order_identifier, orders_regional_partition_identifier)\tsales\torders\t(tenant_identifier, order_identifier, regional_partition_identifier)\t\tidx_order_events_archive_tuple\t\tComplete inbound virtual composite relationship' \
        > "$FIXTURE_FILE"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'source "${FK_ANALYZER_SCRIPT:?}"' \
        'resolve_mysql_bin() { :; }' \
        'connection_preflight() { :; }' \
        'target_preflight() { TARGET_ENGINE=InnoDB; }' \
        'acquire_metadata() { :; }' \
        'build_physical_relations() { cp "${FK_FIXTURE_FILE:?}" "$WORK_DIR/relations.tsv"; }' \
        'build_virtual_relations() { :; }' \
        'main "$@"' \
        > "$FIXTURE_RUNNER"
    chmod +x "$FIXTURE_RUNNER"
}

write_tree_golden_fixture() {
    printf '%s\n' \
        $'OUTBOUND\tPHYSICAL_FK\tsales\torders\t(first_id)\tsales\tfirst_parent\t(id)\tfk_orders_first\tidx_orders_first\t\tON UPDATE RESTRICT; ON DELETE CASCADE' \
        $'INBOUND\tCOMPLETE_VIRTUAL_FK\tsales\taudit_orders\t(orders_id)\tsales\torders\t(id)\t\tidx_audit_orders\t\t' \
        $'OUTBOUND\tPHYSICAL_FK\tsales\torders\t(second_id)\tsales\tsecond_parent\t(id)\tfk_orders_second\tidx_orders_second\t\t' \
        $'OUTBOUND\tPARTIAL_VIRTUAL_FK\tsales\torders\t(third_id)\tsales\tthird_parent\t(id)\t\tidx_orders_third\tTYPE_MISMATCH\tType differs' \
        > "$FIXTURE_FILE"
}

write_terminal_probe_fixtures() {
    PROBE_BIN="$TMP/terminal-probe-bin"
    TERMINAL_PROBE_LOG="$TMP/terminal-probe.log"
    mkdir -p "$PROBE_BIN"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'if [[ -t 0 ]]; then input=tty; else input=redirected; fi' \
        'printf "stty:%s\\n" "$input" >> "${TERMINAL_PROBE_LOG:?}"' \
        '[[ "${1:-}" == size ]] || exit 64' \
        'printf "%s\\n" "${FAKE_STTY_RESULT:?}"' \
        > "$PROBE_BIN/stty"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf "tput:%s\\n" "${1:-}" >> "${TERMINAL_PROBE_LOG:?}"' \
        '[[ "${1:-}" == cols ]] || exit 64' \
        'printf "%s\\n" "${FAKE_TPUT_RESULT:?}"' \
        > "$PROBE_BIN/tput"
    chmod +x "$PROBE_BIN/stty" "$PROBE_BIN/tput"
    export PROBE_BIN TERMINAL_PROBE_LOG
}

assert_terminal_probe_log() {
    local expected=$1
    local actual=""

    [[ -f "$TERMINAL_PROBE_LOG" ]] && actual=$(<"$TERMINAL_PROBE_LOG")
    assert_equals "$actual" "$expected"
}

run_fixture_case() {
    local name=$1
    shift
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    OUTPUT=$(FK_ANALYZER_SCRIPT="$SCRIPT" FK_FIXTURE_FILE="$FIXTURE_FILE" \
        /bin/bash "$FIXTURE_RUNNER" "$@" 2>&1)
    STATUS=$?
    set -e
    OUTPUT=${OUTPUT//$'\r'/}
    printf 'ok: %s\n' "$name"
}

run_fixture_tty() {
    local name=$1 runner_command
    shift
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    case "$(uname -s)" in
        Darwin)
            OUTPUT=$(TERM=xterm script -q /dev/null env \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                /bin/bash "$FIXTURE_RUNNER" "$@" 2>&1)
            ;;
        Linux)
            printf -v runner_command '%q ' env TERM=xterm \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                /bin/bash "$FIXTURE_RUNNER" "$@"
            OUTPUT=$(script -q -e -c "$runner_command" /dev/null 2>&1)
            ;;
        *)
            set -e
            fail "unsupported pseudo-terminal platform: $(uname -s)"
            ;;
    esac
    STATUS=$?
    set -e
    OUTPUT=${OUTPUT//$'\r'/}
    printf 'ok: %s\n' "$name"
}

run_fixture_tty_width() {
    local width=$1 name=$2 runner_command
    shift 2
    [[ "$width" =~ ^[0-9]+$ ]] || fail "pseudo-TTY width must contain digits only: [$width]"
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    case "$(uname -s)" in
        Darwin)
            OUTPUT=$(TERM=xterm script -q /dev/null /bin/bash -c \
                'stty cols "$1"; shift; unset COLUMNS; exec "$@"' \
                width-runner "$width" env \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                "PATH=${PROBE_TEST_PATH_PREFIX:-}$PATH" \
                /bin/bash "$FIXTURE_RUNNER" "$@" 2>&1)
            ;;
        Linux)
            printf -v runner_command '%q ' env TERM=xterm \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                "PATH=${PROBE_TEST_PATH_PREFIX:-}$PATH" \
                /bin/bash "$FIXTURE_RUNNER" "$@"
            runner_command="stty cols $width; unset COLUMNS; exec $runner_command"
            OUTPUT=$(script -q -e -c "$runner_command" /dev/null 2>&1)
            ;;
        *)
            set -e
            fail "unsupported pseudo-terminal platform: $(uname -s)"
            ;;
    esac
    STATUS=$?
    set -e
    OUTPUT=${OUTPUT//$'\r'/}
    printf 'ok: %s\n' "$name"
}

run_fixture_tty_width_with_redirected_stdin() {
    local width=$1 name=$2 runner_command
    shift 2
    [[ "$width" =~ ^[0-9]+$ ]] || fail "pseudo-TTY width must contain digits only: [$width]"
    : > "$FAKE_MYSQL_FK_LOG"
    set +e
    case "$(uname -s)" in
        Darwin)
            OUTPUT=$(TERM=xterm script -q /dev/null /bin/bash -c \
                'stty cols "$1"; shift; unset COLUMNS; exec "$@" </dev/null' \
                width-runner "$width" env \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                "PATH=${PROBE_TEST_PATH_PREFIX:-}$PATH" \
                /bin/bash "$FIXTURE_RUNNER" "$@" 2>&1)
            ;;
        Linux)
            printf -v runner_command '%q ' env TERM=xterm \
                "FK_ANALYZER_SCRIPT=$SCRIPT" "FK_FIXTURE_FILE=$FIXTURE_FILE" \
                "PATH=${PROBE_TEST_PATH_PREFIX:-}$PATH" \
                /bin/bash "$FIXTURE_RUNNER" "$@"
            runner_command="stty cols $width; unset COLUMNS; exec $runner_command </dev/null"
            OUTPUT=$(script -q -e -c "$runner_command" /dev/null 2>&1)
            ;;
        *)
            set -e
            fail "unsupported pseudo-terminal platform: $(uname -s)"
            ;;
    esac
    STATUS=$?
    set -e
    OUTPUT=${OUTPUT//$'\r'/}
    printf 'ok: %s\n' "$name"
}

fixture_arguments() {
    FIXTURE_ARGUMENTS=(-l test -s sales -t orders --environment test)
}

extract_table() {
    TABLE_OUTPUT=$(printf '%s\n' "$1" | LC_ALL=C awk '
        /^RELATION TOPOLOGY$/ { active = 1 }
        active && /^DEPENDENCY TREE$/ { exit }
        active { print }
    ')
}

extract_tree() {
    TREE_OUTPUT=$(printf '%s\n' "$1" | LC_ALL=C awk '
        /^DEPENDENCY TREE$/ { active = 1 }
        active { print }
    ')
}

assert_table_geometry() {
    local output=$1 expected_width=$2

    printf '%s\n' "$output" | LC_ALL=C awk -v width="$expected_width" '
        /^DIRECTION[ ]*[|]/ { active = 1; seen = 1 }
        active && NF == 0 { exit }
        active {
            separator_count = gsub(/[|]/, "|")
            plus_count = gsub(/[+]/, "+")
            if (separator_count == 5 || plus_count == 5) {
                if (length($0) != width) {
                    printf "line width %d, expected %d: [%s]\n", length($0), width, $0 > "/dev/stderr"
                    failed = 1
                }
            }
        }
        END { exit(failed || !seen) }
    ' || fail "table geometry does not use exactly $expected_width visible columns"
}

assert_continuations_and_values() {
    local output=$1

    printf '%s\n' "$output" | LC_ALL=C awk -F '[|]' '
        function trim(value) {
            sub(/^[ ]+/, "", value)
            sub(/[ ]+$/, "", value)
            return value
        }
        /^OUTBOUND[ ]*[|][ ]*PHYSICAL_FK/ { active = 1 }
        active && $0 ~ /^[ ]*[|]/ {
            direction = trim($1)
            classification = trim($2)
            status = trim($5)
            if (direction != "" || classification != "" || status != "") failed = 1
            continuation_count++
        }
        active && $0 !~ /^OUTBOUND[ ]*[|][ ]*PHYSICAL_FK/ && $0 !~ /^[ ]*[|]/ { active = 0 }
        END { exit !(continuation_count > 0 && !failed) }
    ' || fail 'continuation rows must blank direction, classification, and status'

    reconstructed=$(printf '%s\n' "$output" | LC_ALL=C awk -F '[|]' '
        function compact(value) {
            gsub(/[ ]/, "", value)
            return value
        }
        /^OUTBOUND[ ]*[|][ ]*PHYSICAL_FK/ { active = 1 }
        active && ($0 ~ /^OUTBOUND[ ]*[|][ ]*PHYSICAL_FK/ || $0 ~ /^[ ]*[|]/) {
            source = source compact($3)
            target = target compact($4)
            details = details compact($6)
            next
        }
        active { exit }
        END { print source "\t" target "\t" details }
    ')
    assert_contains "$reconstructed" 'tenant_identifier_component'
    assert_contains "$reconstructed" 'extremely_long_order_identifier_component'
    assert_contains "$reconstructed" 'regional_partition_identifier_component'
    assert_contains "$reconstructed" 'customer_identifier_component'
    assert_contains "$reconstructed" 'fk_orders_customer_archive_with_long_identifier'
    assert_contains "$reconstructed" 'idx_orders_customer_archive_covering_tuple'
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

run_presentation_tests() {
    local width width_case width_input width_expected
    local colored_table no_color_table fixture_snapshot

    write_presentation_fixture
    fixture_arguments

    for width in 120 160 220; do
        run_fixture_case "presentation_width_$width" "${FIXTURE_ARGUMENTS[@]}" \
            --terminal-width "$width" --no-color
        assert_status 0
        strip_ansi "$OUTPUT"
        extract_table "$STRIPPED_OUTPUT"
        assert_table_geometry "$TABLE_OUTPUT" "$width"
        assert_continuations_and_values "$TABLE_OUTPUT"
    done

    for width_case in '0120:120' '0190:190' '010000:10000'; do
        width_input=${width_case%%:*}
        width_expected=${width_case#*:}
        run_fixture_case "presentation_decimal_width_$width_input" \
            "${FIXTURE_ARGUMENTS[@]}" --terminal-width "$width_input" --no-color
        assert_status 0
        strip_ansi "$OUTPUT"
        extract_table "$STRIPPED_OUTPUT"
        assert_table_geometry "$TABLE_OUTPUT" "$width_expected"
    done

    COLUMNS=220 run_fixture_case presentation_explicit_precedence \
        "${FIXTURE_ARGUMENTS[@]}" --terminal-width 160 --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 160

    COLUMNS=160 run_fixture_case presentation_columns "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 160

    COLUMNS=invalid run_fixture_case presentation_invalid_columns_fallback \
        "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 120

    write_terminal_probe_fixtures
    : > "$TERMINAL_PROBE_LOG"
    FAKE_STTY_RESULT='24 171'
    FAKE_TPUT_RESULT=163
    PROBE_TEST_PATH_PREFIX="$PROBE_BIN:"
    export FAKE_STTY_RESULT FAKE_TPUT_RESULT PROBE_TEST_PATH_PREFIX
    run_fixture_tty_width 180 presentation_active_stty "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 171
    assert_terminal_probe_log 'stty:tty'

    : > "$TERMINAL_PROBE_LOG"
    FAKE_STTY_RESULT='24 invalid'
    FAKE_TPUT_RESULT=163
    export FAKE_STTY_RESULT FAKE_TPUT_RESULT
    run_fixture_tty_width 180 presentation_invalid_stty_uses_tput \
        "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 163
    assert_terminal_probe_log $'stty:tty\ntput:cols'

    : > "$TERMINAL_PROBE_LOG"
    FAKE_STTY_RESULT='24 173'
    FAKE_TPUT_RESULT=163
    export FAKE_STTY_RESULT FAKE_TPUT_RESULT
    run_fixture_tty_width_with_redirected_stdin 180 presentation_redirected_stdin \
        "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    assert_table_geometry "$TABLE_OUTPUT" 173
    assert_terminal_probe_log 'stty:tty'
    unset FAKE_STTY_RESULT FAKE_TPUT_RESULT PROBE_TEST_PATH_PREFIX

    run_fixture_tty_width 160 presentation_colored "${FIXTURE_ARGUMENTS[@]}"
    assert_status 0
    assert_has_ansi "$OUTPUT"
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    colored_table=$TABLE_OUTPUT

    run_fixture_tty_width 160 presentation_no_color "${FIXTURE_ARGUMENTS[@]}" --no-color
    assert_status 0
    strip_ansi "$OUTPUT"
    extract_table "$STRIPPED_OUTPUT"
    no_color_table=$TABLE_OUTPUT
    assert_equals "$colored_table" "$no_color_table"

    fixture_snapshot="$TMP/presentation-relations.snapshot.tsv"
    cp "$FIXTURE_FILE" "$fixture_snapshot"
    (
        # shellcheck source=/dev/null
        source "$SCRIPT"
        TERMINAL_WIDTH_OPTION=120
        TERMINAL_WIDTH_OPTION_SET=true
        NO_COLOR=true
        detect_terminal_width
        render_relation_tables "$FIXTURE_FILE" >/dev/null
    )
    cmp -s "$fixture_snapshot" "$FIXTURE_FILE" || fail 'presentation modified the normalized relation stream'

    printf 'PASS: fk_analyzer terminal presentation\n'
}

run_tree_tests() {
    local colored_tree no_color_tree branch_order golden_tree

    write_presentation_fixture
    fixture_arguments

    run_fixture_case tree_plain "${FIXTURE_ARGUMENTS[@]}" --tree --terminal-width 160 --no-color
    assert_status 0
    extract_tree "$OUTPUT"
    no_color_tree=$TREE_OUTPUT
    branch_order=$(printf '%s\n' "$no_color_tree" | LC_ALL=C awk '
        /OUTBOUND PHYSICAL$/ { print "OUTBOUND PHYSICAL" }
        /OUTBOUND VIRTUAL$/ { print "OUTBOUND VIRTUAL" }
        /INBOUND PHYSICAL$/ { print "INBOUND PHYSICAL" }
        /INBOUND VIRTUAL$/ { print "INBOUND VIRTUAL" }
    ')
    assert_equals "$branch_order" $'OUTBOUND PHYSICAL\nOUTBOUND VIRTUAL\nINBOUND PHYSICAL\nINBOUND VIRTUAL'
    assert_contains "$no_color_tree" '(tenant_identifier_component, extremely_long_order_identifier_component, regional_partition_identifier_component)'
    assert_contains "$no_color_tree" '(tenant_identifier, order_identifier, regional_partition_identifier)'
    assert_contains "$no_color_tree" '[MISSING_COMPONENTS]'
    assert_contains "$no_color_tree" '[TYPE_MISMATCH]'
    assert_contains "$no_color_tree" '[UNINDEXED]'
    assert_contains "$no_color_tree" '[INDEX_ORDER_MISMATCH]'
    assert_contains "$no_color_tree" 'Candidate targets: sales.countries(code), sales.currencies(code)'

    run_fixture_tty_width 160 tree_colored "${FIXTURE_ARGUMENTS[@]}" --tree
    assert_status 0
    assert_contains "$OUTPUT" $'\033[1;33msales.orders\033[0m'
    assert_contains "$OUTPUT" $'\033[2;36m├──\033[0m'
    assert_contains "$OUTPUT" $'\033[0;36mPHYSICAL_FK\033[0m'
    assert_contains "$OUTPUT" $'\033[0;32mCOMPLETE_VIRTUAL_FK\033[0m'
    assert_contains "$OUTPUT" $'\033[0;33mPARTIAL_VIRTUAL_FK\033[0m'
    assert_contains "$OUTPUT" $'\033[0;35mAMBIGUOUS_VIRTUAL_FK\033[0m'
    assert_contains "$OUTPUT" $'\033[0;31m[TYPE_MISMATCH]\033[0m'
    assert_contains "$OUTPUT" $'\033[0;34mfk_orders_customer_archive_with_long_identifier\033[0m'
    assert_contains "$OUTPUT" $'\033[0;34midx_orders_customer_archive_covering_tuple\033[0m'
    strip_ansi "$OUTPUT"
    extract_tree "$STRIPPED_OUTPUT"
    colored_tree=$TREE_OUTPUT
    assert_equals "$colored_tree" "$no_color_tree"

    write_tree_golden_fixture
    run_fixture_case tree_golden_connectors "${FIXTURE_ARGUMENTS[@]}" \
        --tree --terminal-width 160 --no-color
    assert_status 0
    extract_tree "$OUTPUT"
    golden_tree=$'DEPENDENCY TREE\nsales.orders\n├── OUTBOUND PHYSICAL\n│   ├── PHYSICAL_FK sales.orders(first_id) -> sales.first_parent(id) constraint=fk_orders_first index=idx_orders_first ON UPDATE RESTRICT; ON DELETE CASCADE\n│   └── PHYSICAL_FK sales.orders(second_id) -> sales.second_parent(id) constraint=fk_orders_second index=idx_orders_second\n├── OUTBOUND VIRTUAL\n│   └── PARTIAL_VIRTUAL_FK sales.orders(third_id) -> sales.third_parent(id) index=idx_orders_third [TYPE_MISMATCH] Type differs\n├── INBOUND PHYSICAL\n│   └── None\n└── INBOUND VIRTUAL\n    └── COMPLETE_VIRTUAL_FK sales.audit_orders(orders_id) -> sales.orders(id) index=idx_audit_orders'
    assert_equals "$TREE_OUTPUT" "$golden_tree"

    printf 'PASS: fk_analyzer semantic tree\n'
}

if [[ $# -eq 0 ]]; then
    run_cli_tests
    run_physical_tests
    run_virtual_tests
    run_presentation_tests
    run_tree_tests
else
    for test_group in "$@"; do
        case "$test_group" in
            cli) run_cli_tests ;;
            physical) run_physical_tests ;;
            virtual) run_virtual_tests ;;
            presentation) run_presentation_tests ;;
            tree) run_tree_tests ;;
            *) fail "unknown test group: $test_group" ;;
        esac
    done
fi
