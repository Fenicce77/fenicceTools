#!/usr/bin/env bash
# Behavioral contract tests for the binlog activity report CLI foundation.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../binlog_activity_report.sh"
BINLOG_DIR=$(cd "$TEST_DIR/.." && pwd)
README="$BINLOG_DIR/README.md"
LEGACY_DIR="$BINLOG_DIR/legacy"
FAKE_READER="$TEST_DIR/fake_binlog_reader.sh"
FIXTURE_ROOT="$TEST_DIR/fixtures/binlog_activity"
MYSQL57_FIXTURE="$FIXTURE_ROOT/mysql57_statement.sample"
MYSQL80_FIXTURE="$FIXTURE_ROOT/space dir/mysql80_row.sample"
MYSQL80_MIXED_FIXTURE="$FIXTURE_ROOT/mysql80_mixed.sample"
MARIADB10_ROW_FIXTURE="$FIXTURE_ROOT/mariadb10_row.sample"
MARIADB11_MIXED_FIXTURE="$FIXTURE_ROOT/mariadb11_mixed.sample"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/binlog-activity-test.XXXXXX")
OUTPUT=""
STATUS=0
TEST_COUNT=0
FAKE_MYSQL_IDENTITY=$'11.4.2-custom\tMariaDB Server\tMIXED'

mkdir -p "$TMP/fake-bin"
ln -s "$FAKE_READER" "$TMP/fake-bin/mysql"

test_cleanup() {
    rm -rf "$TMP"
}
trap test_cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass_assertion() {
    TEST_COUNT=$((TEST_COUNT + 1))
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] \
        || fail "expected status $expected, got $STATUS; output: $OUTPUT"
    pass_assertion
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] \
        || fail "expected output to contain: $needle; output: $haystack"
    pass_assertion
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" != *"$needle"* ]] \
        || fail "expected output not to contain: $needle; output: $haystack"
    pass_assertion
}

assert_equals() {
    local actual=$1
    local expected=$2
    [[ "$actual" == "$expected" ]] \
        || fail "expected: $expected; got: $actual"
    pass_assertion
}

assert_file_empty() {
    local path=$1
    [[ ! -s "$path" ]] || fail "expected file to be empty: $path"
    pass_assertion
}

assert_directory_empty() {
    local path=$1
    local entry

    entry=$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z "$entry" ]] || fail "expected directory to be empty: $path; found: $entry"
    pass_assertion
}

assert_files_equal() {
    local actual=$1
    local expected=$2
    cmp -s "$actual" "$expected" \
        || fail "files differ: $actual and $expected"
    pass_assertion
}

assert_file_not_contains() {
    local path=$1
    local needle=$2
    if LC_ALL=C grep -q "$needle" "$path"; then
        fail "expected file not to contain: $needle; file: $path"
    fi
    pass_assertion
}

assert_file_exists() {
    local path=$1
    [[ -f "$path" ]] || fail "expected file to exist: $path"
    pass_assertion
}

assert_file_not_exists() {
    local path=$1
    [[ ! -e "$path" ]] || fail "expected file to be absent: $path"
    pass_assertion
}

assert_file_contains() {
    local path=$1
    local needle=$2
    LC_ALL=C grep -Fq -- "$needle" "$path" \
        || fail "expected file to contain: $needle; file: $path"
    pass_assertion
}

run_cli() {
    set +e
    OUTPUT=$(PATH="$TMP/fake-bin:$PATH" \
        FAKE_BINLOG_READER_LOG="$TMP/reader.log" \
        FAKE_MYSQL_CLIENT_LOG="$TMP/mysql-client.log" \
        FAKE_MYSQL_IDENTITY="$FAKE_MYSQL_IDENTITY" \
        FAKE_REMOTE_FIXTURE="$MARIADB11_MIXED_FIXTURE" \
        "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
}

run_shell() {
    set +e
    OUTPUT=$(/bin/bash -c "$1" _ "$SCRIPT" "$TMP" 2>&1)
    STATUS=$?
    set -e
}

run_cli_pty() {
    local command_string=""
    local argument

    set +e
    if [[ "$(uname -s)" == Darwin ]]; then
        OUTPUT=$(PATH="$TMP/fake-bin:$PATH" TERM=xterm \
            FAKE_BINLOG_READER_LOG="$TMP/reader.log" \
            FAKE_MYSQL_CLIENT_LOG="$TMP/mysql-client.log" \
            FAKE_MYSQL_IDENTITY="$FAKE_MYSQL_IDENTITY" \
            FAKE_REMOTE_FIXTURE="$MARIADB11_MIXED_FIXTURE" \
            script -q /dev/null "$SCRIPT" "$@" 2>&1)
        STATUS=$?
    else
        printf -v command_string '%q ' "$SCRIPT" "$@"
        OUTPUT=$(PATH="$TMP/fake-bin:$PATH" TERM=xterm \
            FAKE_BINLOG_READER_LOG="$TMP/reader.log" \
            FAKE_MYSQL_CLIENT_LOG="$TMP/mysql-client.log" \
            FAKE_MYSQL_IDENTITY="$FAKE_MYSQL_IDENTITY" \
            FAKE_REMOTE_FIXTURE="$MARIADB11_MIXED_FIXTURE" \
            script -q -e -c "$command_string" /dev/null 2>&1)
        STATUS=$?
    fi
    set -e
}

if [[ ! -e "$SCRIPT" ]]; then
    fail "command does not exist: $SCRIPT"
fi

legacy_scripts=(
    full_binlog_accounting_indexed.sh
    summarize_DDLs_binlogs.sh
    summarize_binlogs.sh
    summarize_binlogs2.sh
    summarize_binlogs2_range.sh
    summarize_binlogs_notbinary.sh
    summarize_binlogs_notbinary.top7.sh
    summarize_binlogs_remote_DDLs.sh
)

assert_file_exists "$SCRIPT"
[[ -x "$SCRIPT" ]] || fail "expected canonical command to be executable: $SCRIPT"
pass_assertion
assert_file_exists "$README"
assert_equals "$(find "$LEGACY_DIR" -maxdepth 1 -type f -name '*.sh' -exec basename {} \; 2>/dev/null | LC_ALL=C sort)" \
    "$(printf '%s\n' "${legacy_scripts[@]}" | LC_ALL=C sort)"

for legacy_script in "${legacy_scripts[@]}"; do
    assert_file_exists "$LEGACY_DIR/$legacy_script"
    assert_file_not_exists "$BINLOG_DIR/$legacy_script"
done

assert_file_contains "$README" 'Local source'
assert_file_contains "$README" 'Remote source'
assert_file_contains "$README" '--login-path'
assert_file_contains "$README" 'color'
assert_file_contains "$README" 'Timestamp,SourceFile,Position,ServerFamily,ServerVersion,BinlogFormat,EventClass,Operation,Schema,Table,TransactionId'
assert_file_contains "$README" 'read-only'
assert_file_contains "$README" 'mysql-5.7`, `mysql-8.0+`, or'
assert_file_contains "$README" '`mariadb-10+`'
assert_file_contains "$README" 'Unsupported version/family combinations fail before reading'
assert_file_contains "$README" 'mysql/binlogs/binlog_activity_report.sh \'
assert_file_contains "$README" 'CRLF line endings'
assert_file_contains "$README" 'ANSI color escapes'
assert_file_contains "$README" 'must already exist and be'
assert_file_contains "$README" 'A CSV destination is rejected'
assert_file_contains "$README" 'overwrite an input'
assert_file_contains "$README" '--base64-output=DECODE-ROWS --verbose'
assert_file_contains "$README" 'but it never pipes'
assert_file_contains "$README" 'replays it.'
assert_file_contains "$README" 'Decoded output can expose'
assert_file_contains "$README" 'not use the decoded stream as executable SQL.'

# The checks below become reachable after the production command is added.
run_cli
assert_status 2
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" 'Local source:'
assert_contains "$OUTPUT" 'Remote source:'
assert_contains "$OUTPUT" 'Analysis and output:'
assert_contains "$OUTPUT" 'Examples:'

run_cli --unknown-option
assert_status 2
assert_contains "$OUTPUT" 'Unknown option: --unknown-option'
assert_contains "$OUTPUT" 'Usage:'

: > "$TMP/reader.log"
: > "$TMP/mysql-client.log"
run_cli --password command-line-secret
assert_status 2
assert_contains "$OUTPUT" 'Unknown option: --password'
assert_not_contains "$OUTPUT" 'command-line-secret'
assert_file_empty "$TMP/reader.log"
assert_file_empty "$TMP/mysql-client.log"

run_cli --source invalid
assert_status 2
assert_contains "$OUTPUT" 'Source must be local or remote.'
assert_contains "$OUTPUT" 'Usage:'

run_cli --source local --file "$MYSQL57_FIXTURE" \
    --binlog-format statement --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Local source requires --server-version.'
assert_contains "$OUTPUT" 'Usage:'

run_cli --source local --file "$MYSQL57_FIXTURE" \
    --server-version '5.7.44' --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Local source requires --binlog-format.'
assert_contains "$OUTPUT" 'Usage:'

: > "$TMP/reader.log"
run_cli --source local --file "$MYSQL57_FIXTURE" "$TMP/missing.binlog" \
    --server-version '5.7.44' --binlog-format statement \
    --mysqlbinlog-bin "$FAKE_READER"
assert_status 2
assert_contains "$OUTPUT" 'Binlog file is not readable:'
assert_file_empty "$TMP/reader.log"

mysql57_before=$(cksum "$MYSQL57_FIXTURE")
mysql80_before=$(cksum "$MYSQL80_FIXTURE")
: > "$TMP/reader.log"
run_cli --source local \
    --file "$MYSQL57_FIXTURE" "$MYSQL80_FIXTURE" \
    --file "$MYSQL57_FIXTURE" \
    --server-version '8.4.6' --binlog-format mixed \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server profile: mysql-8.0+'
assert_contains "$OUTPUT" 'Top tables: 10'
assert_contains "$OUTPUT" "$MYSQL57_FIXTURE"
assert_contains "$OUTPUT" "$MYSQL80_FIXTURE"
assert_equals "$(LC_ALL=C grep -Fxc $'READ\t'"$MYSQL57_FIXTURE" "$TMP/reader.log")" 1
assert_equals "$(LC_ALL=C grep -Fxc $'READ\t'"$MYSQL80_FIXTURE" "$TMP/reader.log")" 1
assert_equals "$(wc -l < "$TMP/reader.log" | tr -d ' ')" 2
assert_equals "$(cksum "$MYSQL57_FIXTURE")" "$mysql57_before"
assert_equals "$(cksum "$MYSQL80_FIXTURE")" "$mysql80_before"

run_cli --source local --file "$MYSQL80_FIXTURE" \
    --server-version '11.4.2-MariaDB' --binlog-format row \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mariadb'
assert_contains "$OUTPUT" 'Server profile: mariadb-10+'

run_cli --source local --file "$MYSQL80_FIXTURE" \
    --server-family mariadb --server-version '11.8.3-custom-build' \
    --binlog-format row --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mariadb'
assert_contains "$OUTPUT" 'Server profile: mariadb-10+'

mkdir -p "$TMP/input dir"
cp "$MYSQL80_FIXTURE" "$TMP/input dir/b.bin"
cp "$MYSQL57_FIXTURE" "$TMP/input dir/a.bin"
: > "$TMP/reader.log"
run_cli --source local --dir "$TMP/input dir" \
    --server-version '5.7.44' --binlog-format statement \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
expected_reads=$(printf 'READ\t%s\nREAD\t%s' \
    "$TMP/input dir/a.bin" "$TMP/input dir/b.bin")
assert_equals "$(< "$TMP/reader.log")" "$expected_reads"

run_shell 'source "$1"; resolve_profile mysql "5.7.44"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mysql-5.7'

run_shell 'source "$1"; resolve_profile mysql "8.4.6"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mysql-8.0+'

run_shell 'source "$1"; resolve_profile mariadb "10.11.8-MariaDB"; printf "%s\n" "$PROFILE"'
assert_status 0
assert_equals "$OUTPUT" 'mariadb-10+'

mkdir -p "$TMP/reader-bin"
ln -s "$FAKE_READER" "$TMP/reader-bin/mariadb-binlog"
run_shell 'source "$1"; PATH="$2/reader-bin"; MYSQLBINLOG_BIN=""; resolve_reader; printf "%s\n" "$READER"'
assert_status 0
assert_equals "$OUTPUT" "$TMP/reader-bin/mariadb-binlog"

ln -s "$FAKE_READER" "$TMP/reader-bin/mysqlbinlog"
run_shell 'source "$1"; PATH="$2/reader-bin"; MYSQLBINLOG_BIN=""; resolve_reader; printf "%s\n" "$READER"'
assert_status 0
assert_equals "$OUTPUT" "$TMP/reader-bin/mysqlbinlog"

run_shell 'source "$1"; normalize_events "'"$MYSQL57_FIXTURE"'" mysql mysql-5.7 statement'
assert_status 0
expected_mysql57=$(printf '%s\n%s' \
    $'2026-09-29 10:00:01\t123\tDML\tINSERT\tsales\torders\t-' \
    $'2026-09-29 10:00:02\t280\tDDL\tALTER\tsales\torders\t-')
assert_equals "$OUTPUT" "$expected_mysql57"

run_shell 'source "$1"; normalize_events "'"$MYSQL80_FIXTURE"'" mysql mysql-8.0+ row'
assert_status 0
expected_mysql80=$(printf '%s\n%s\n%s' \
    $'2026-09-29 11:00:00\t126\tDML\tINSERT\tsales\torders\tXID:9001' \
    $'2026-09-29 11:00:01\t240\tDML\tUPDATE\tsales\torders\tXID:9001' \
    $'2026-09-29 11:00:02\t360\tDML\tDELETE\tsales\torders\tXID:9001')
assert_equals "$OUTPUT" "$expected_mysql80"

run_shell 'source "$1"; normalize_events "'"$MYSQL80_MIXED_FIXTURE"'" mysql mysql-8.0+ mixed'
assert_status 0
expected_mysql80_mixed=$(printf '%s\n%s' \
    $'2026-09-29 12:00:00\t126\tDML\tINSERT\tsales\torders\t24bc7856-9a3b-11ef-9abc-0242ac120002:71' \
    $'2026-09-29 12:00:01\t260\tDDL\tCREATE\tsales\torder_archive\t-')
assert_equals "$OUTPUT" "$expected_mysql80_mixed"

run_shell 'source "$1"; normalize_events "'"$MARIADB10_ROW_FIXTURE"'" mariadb mariadb-10+ row'
assert_status 0
expected_mariadb10=$(printf '%s\n%s' \
    $'2026-09-29 13:00:00\t145\tDML\tUPDATE\tinventory\tstock\t0-1-991' \
    $'2026-09-29 13:00:01\t340\tDML\tDELETE\tinventory\tstock_history\t0-1-992')
assert_equals "$OUTPUT" "$expected_mariadb10"
assert_equals "$(printf '%s\n' "$OUTPUT" | wc -l | tr -d ' ')" 2
assert_not_contains "$OUTPUT" $'\tINSERT\tadversarial\tshadow\t'

printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TMP/failing-reader.sh"
chmod +x "$TMP/failing-reader.sh"
mkdir -p "$TMP/event-tmp"
set +e
OUTPUT=$(TMPDIR="$TMP/event-tmp" "$SCRIPT" \
    --source local --file "$MYSQL57_FIXTURE" \
    --server-version '5.7.44' --binlog-format statement \
    --mysqlbinlog-bin "$TMP/failing-reader.sh" --no-color 2>&1)
STATUS=$?
set -e
assert_status 1
assert_contains "$OUTPUT" 'Binlog reader failed for:'
assert_directory_empty "$TMP/event-tmp"

: > "$TMP/reader.log"
run_cli --source local \
    --file "$MYSQL80_FIXTURE" "$MYSQL80_MIXED_FIXTURE" \
    --server-version '8.4.6' --binlog-format mixed --top-tables 2 \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" '2026-09-29 11:00:00  126  DML  INSERT  sales.orders  XID:9001'
assert_contains "$OUTPUT" '2026-09-29 12:00:01  260  DDL  CREATE  sales.order_archive  -'
expected_top_tables=$(printf '%s\n%s' \
    '4  sales.orders' \
    '1  sales.order_archive')
actual_top_tables=$(printf '%s\n' "$OUTPUT" | awk '/^Top tables by event count:$/ { capture=1; next } capture && /^[0-9]+  / { print; count++; if (count == 2) exit }')
assert_equals "$actual_top_tables" "$expected_top_tables"
assert_not_contains "$OUTPUT" $'\033['

run_shell 'source "$1"; READER="/reader"; SOURCE=remote; REMOTE_LOGIN_PATH=reporting; START_DATETIME="2026-09-29 14:00:00"; STOP_DATETIME="2026-09-29 15:00:00"; build_reader_command; printf "<%s>\n" "${READER_COMMAND[@]}"'
assert_status 0
expected_reader_command=$(printf '%s\n' \
    '</reader>' \
    '<--login-path=reporting>' \
    '<--read-from-remote-server>' \
    '<--base64-output=DECODE-ROWS>' \
    '<--verbose>' \
    '<--start-datetime=2026-09-29 14:00:00>' \
    '<--stop-datetime=2026-09-29 15:00:00>')
assert_equals "$OUTPUT" "$expected_reader_command"

: > "$TMP/reader.log"
: > "$TMP/mysql-client.log"
run_cli --source remote --login-path remote-report \
    --binlog-file 'mariadb-bin,"west".000777' 'mariadb-bin,"west".000777' \
    --start '2026-09-29 14:00:00' --stop '2026-09-29 15:00:00' \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Source: remote'
assert_contains "$OUTPUT" 'Server family: mariadb'
assert_contains "$OUTPUT" 'Server version: 11.4.2-custom'
assert_contains "$OUTPUT" 'Server profile: mariadb-10+'
assert_contains "$OUTPUT" 'Binlog format: mixed'
assert_contains "$OUTPUT" '2026-09-29 14:00:00  145  DML  UPDATE  warehouse,west.quoted"items  0-1-1201'
assert_contains "$OUTPUT" '2026-09-29 14:00:01  250  DDL  CREATE  warehouse,west.archive,2026  -'
assert_contains "$(< "$TMP/mysql-client.log")" $'DISCOVERY_ARG\t--login-path=remote-report'
assert_contains "$(< "$TMP/mysql-client.log")" '@@GLOBAL.binlog_format'
assert_not_contains "$(< "$TMP/mysql-client.log")" '--password'
assert_contains "$(< "$TMP/reader.log")" $'REMOTE_ARG\t--login-path=remote-report'
assert_contains "$(< "$TMP/reader.log")" $'REMOTE_ARG\t--read-from-remote-server'
assert_contains "$(< "$TMP/reader.log")" $'REMOTE_ARG\t--start-datetime=2026-09-29 14:00:00'
assert_contains "$(< "$TMP/reader.log")" $'REMOTE_ARG\t--stop-datetime=2026-09-29 15:00:00'
assert_not_contains "$(< "$TMP/reader.log")" '--password'
assert_equals "$(LC_ALL=C grep -Fxc $'REMOTE_ARG\tmariadb-bin,"west".000777' "$TMP/reader.log")" 1

: > "$TMP/mysql-client.log"
run_cli --source remote --login-path override-report \
    --binlog-file mysql-bin.000888 \
    --server-family mysql --server-version 8.4.6 --binlog-format row \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mysql'
assert_contains "$OUTPUT" 'Server version: 8.4.6'
assert_contains "$OUTPUT" 'Server profile: mysql-8.0+'
assert_contains "$OUTPUT" 'Binlog format: row'
assert_file_empty "$TMP/mysql-client.log"

FAKE_MYSQL_IDENTITY=$'8.0.0\t\tROW'
: > "$TMP/mysql-client.log"
run_cli --source remote --login-path partial-override-report \
    --binlog-file mysql-bin.000889 \
    --server-family mysql --server-version 8.4.6 \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 0
assert_contains "$OUTPUT" 'Server family: mysql'
assert_contains "$OUTPUT" 'Server version: 8.4.6'
assert_contains "$OUTPUT" 'Binlog format: row'
assert_contains "$(< "$TMP/mysql-client.log")" '@@version'
assert_contains "$(< "$TMP/mysql-client.log")" '@@version_comment'
assert_contains "$(< "$TMP/mysql-client.log")" '@@GLOBAL.binlog_format'
assert_contains "$(< "$TMP/mysql-client.log")" \
    $'DISCOVERY_ARG\t--execute=SELECT @@version, @@version_comment, @@GLOBAL.binlog_format'
FAKE_MYSQL_IDENTITY=$'11.4.2-custom\tMariaDB Server\tMIXED'

: > "$TMP/reader.log"
: > "$TMP/mysql-client.log"
run_cli --source remote --login-path remote-report \
    --binlog-file mariadb-bin.000999 \
    --csv "$TMP/missing/output.csv" \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 2
assert_contains "$OUTPUT" 'CSV parent directory is not writable:'
assert_file_empty "$TMP/reader.log"
assert_file_empty "$TMP/mysql-client.log"

csv_path="$TMP/report.csv"
expected_csv="$TMP/expected.csv"
: > "$TMP/reader.log"
: > "$TMP/mysql-client.log"
run_cli --source remote --login-path remote-report \
    --binlog-file 'mariadb-bin,"west".000777' \
    --csv "$csv_path" --mysqlbinlog-bin "$FAKE_READER"
assert_status 0
assert_contains "$OUTPUT" 'Activity events:'
printf '%s\r\n' \
    'Timestamp,SourceFile,Position,ServerFamily,ServerVersion,BinlogFormat,EventClass,Operation,Schema,Table,TransactionId' \
    '2026-09-29 14:00:00,"mariadb-bin,""west"".000777",145,mariadb,11.4.2-custom,mixed,DML,UPDATE,"warehouse,west","quoted""items",0-1-1201' \
    '2026-09-29 14:00:01,"mariadb-bin,""west"".000777",250,mariadb,11.4.2-custom,mixed,DDL,CREATE,"warehouse,west","archive,2026",-' \
    > "$expected_csv"
assert_files_equal "$csv_path" "$expected_csv"
assert_file_not_contains "$csv_path" $'\033\['

pty_csv_path="$TMP/report-pty.csv"
run_cli_pty --source remote --login-path remote-report \
    --binlog-file 'mariadb-bin,"west".000777' \
    --csv "$pty_csv_path" --mysqlbinlog-bin "$FAKE_READER"
assert_status 0
assert_contains "$OUTPUT" $'\033['
assert_files_equal "$pty_csv_path" "$expected_csv"
assert_file_not_contains "$pty_csv_path" $'\033\['

cp "$MYSQL57_FIXTURE" "$TMP/binlog-csv-collision.bin"
collision_before=$(cksum "$TMP/binlog-csv-collision.bin")
: > "$TMP/reader.log"
run_cli --source local --file "$TMP/binlog-csv-collision.bin" \
    --server-version 5.7.44 --binlog-format statement \
    --csv "$TMP/binlog-csv-collision.bin" \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 2
assert_contains "$OUTPUT" 'CSV output must not overwrite an input binlog:'
assert_equals "$(cksum "$TMP/binlog-csv-collision.bin")" "$collision_before"
assert_file_empty "$TMP/reader.log"

newline_input="$TMP/"$'binlog\nactivity.bin'
cp "$MYSQL57_FIXTURE" "$newline_input"
newline_before=$(cksum "$newline_input")
: > "$TMP/reader.log"
run_cli --source local --file "$newline_input" \
    --server-version 5.7.44 --binlog-format statement \
    --csv "$TMP/newline-source.csv" \
    --mysqlbinlog-bin "$FAKE_READER" --no-color
assert_status 2
assert_contains "$OUTPUT" 'Input binlog name contains unsupported control characters.'
assert_equals "$(cksum "$newline_input")" "$newline_before"
assert_file_empty "$TMP/reader.log"

printf 'PASS: %s assertions\n' "$TEST_COUNT"
