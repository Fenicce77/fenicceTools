#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/estimate_storage.sh"
FAKE="$ROOT/tests/fake_mysql_storage.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/estimate-storage-test.XXXXXX")
RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1 expected=$2 message=$3
    grep -F -- "$expected" "$file" >/dev/null || fail "$message"
}

assert_not_contains() {
    local file=$1 unexpected=$2 message=$3
    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "$message"
    fi
}

run_in_workspace() {
    (cd "$RUN_DIR" && "$@")
}

run_expect_status() {
    local expected=$1 output_file=$2 actual
    shift 2
    set +e
    "$@" >"$output_file" 2>&1
    actual=$?
    set -e
    [[ "$actual" -eq "$expected" ]] || fail "expected exit $expected, got $actual: $*"
}

new_sql_log() {
    FAKE_MYSQL_STORAGE_LOG=$1
    export FAKE_MYSQL_STORAGE_LOG
    : > "$FAKE_MYSQL_STORAGE_LOG"
}

new_sql_log "$TMP/help.sql"
run_in_workspace "$SCRIPT" >"$TMP/no-args.out"
run_in_workspace "$SCRIPT" --no-color --help >"$TMP/help.out"
for section in 'Usage:' 'Required options:' 'Projection options:' 'Safety:' 'Output and runtime:' 'Exit status:' 'Examples:'; do
    assert_contains "$TMP/no-args.out" "$section" "no-argument help missing $section"
    assert_contains "$TMP/help.out" "$section" "explicit help missing $section"
done
if LC_ALL=C grep "$(printf '\033')" "$TMP/help.out" >/dev/null; then
    fail '--no-color help contains ANSI escapes'
fi

new_sql_log "$TMP/validation.sql"
run_expect_status 2 "$TMP/unknown.out" run_in_workspace "$SCRIPT" --unknown
assert_contains "$TMP/unknown.out" 'Unknown option: --unknown' 'unknown-option diagnostic missing'
run_expect_status 2 "$TMP/missing-value.out" run_in_workspace "$SCRIPT" --login-path --database app
assert_contains "$TMP/missing-value.out" 'Option --login-path requires a value.' 'missing-value diagnostic missing'
run_expect_status 2 "$TMP/missing-required.out" run_in_workspace "$SCRIPT" --login-path x
assert_contains "$TMP/missing-required.out" '--database is required.' 'missing required-option diagnostic missing'
run_expect_status 2 "$TMP/invalid-environment.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 --environment qa --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/production-guard.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 --environment production --mysql-bin "$FAKE"
assert_contains "$TMP/production-guard.out" 'Production requires --allow-production.' 'production guard missing'
run_expect_status 2 "$TMP/non-production-allow.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 --environment test --allow-production --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/percent.out" run_in_workspace "$SCRIPT" -l x -d app -t 'users%' -r 1 --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/percent.out" '--table-prefix must not contain %.' 'percent wildcard was accepted'
run_expect_status 2 "$TMP/zero-rows.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 0 --environment test --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/zero-retention.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -k 0 --environment test --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/invalid-factor.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -i nope --environment test --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/factor-too-large.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -i 1001 --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/factor-too-large.out" '--index-factor must be between 0 and 1000' 'oversized index factor was accepted'
database_65='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
run_expect_status 2 "$TMP/database-too-long.out" run_in_workspace "$SCRIPT" -l x -d "$database_65" -t users -r 1 --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/database-too-long.out" '--database must contain 1 to 64 characters' 'oversized database identifier was accepted'
run_expect_status 2 "$TMP/database-trailing-space.out" run_in_workspace "$SCRIPT" -l x -d 'app ' -t users -r 1 --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/database-trailing-space.out" '--database must not end with a space' 'database identifier ending in a space was accepted'
run_expect_status 2 "$TMP/database-control.out" run_in_workspace "$SCRIPT" -l x -d $'app\narchive' -t users -r 1 --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/database-control.out" '--database must not contain control characters' 'database identifier containing a control character was accepted'
run_expect_status 2 "$TMP/invalid-unit.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -u week --environment test --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/format-without-output.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 --format csv --environment test --mysql-bin "$FAKE"
assert_contains "$TMP/format-without-output.out" '--format requires --output-file.' 'format without output was accepted'
run_expect_status 2 "$TMP/invalid-format.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -o "$TMP/report.json" --format json --environment test --mysql-bin "$FAKE"
run_expect_status 2 "$TMP/output-directory.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 -o "$TMP" --environment test --mysql-bin "$FAKE"
run_expect_status 3 "$TMP/client-missing.out" run_in_workspace "$SCRIPT" -l x -d app -t users -r 1 --environment test --mysql-bin "$TMP/missing-mysql"

new_sql_log "$TMP/zero-padded.sql"
run_in_workspace "$SCRIPT" -l x -d app -t users -r 0009 -k 003 -u hour \
    --environment test --mysql-bin "$FAKE" --no-color >"$TMP/zero-padded.out"
assert_contains "$TMP/zero-padded.sql" '216 AS daily_rows' 'zero-padded hourly rows were not normalized as decimal'
assert_contains "$TMP/zero-padded.sql" 'SUM(daily_rows) * 3' 'zero-padded retention was not normalized as decimal'

new_sql_log "$TMP/human.sql"
run_in_workspace "$SCRIPT" -l x -d app -t 'users_' -r 100 --environment test --mysql-bin "$FAKE" --no-color >"$TMP/human.out"
assert_contains "$TMP/human.out" 'MySQL Version: 8.0.36' 'human summary missing server version'
assert_contains "$TMP/human.out" '| users' 'human projection table missing'
assert_contains "$TMP/human.out" 'Done.' 'human completion message missing'
if find "$RUN_DIR" -maxdepth 1 -name 'storage_estimate_*.csv' -print | grep . >/dev/null; then
    fail 'default execution created an implicit CSV report'
fi
assert_contains "$TMP/human.sql" "TABLE_NAME LIKE CONVERT(X'75736572735f25' USING utf8mb4)" 'underscore prefix or appended percent changed'
assert_contains "$TMP/human.sql" 'CAST(SUM(daily_rows) * 30 AS DECIMAL(65,0))' 'total-row projection does not use overflow-safe decimal arithmetic'
assert_not_contains "$TMP/human.sql" 'INSERT ' 'estimator issued a write statement'
assert_not_contains "$TMP/human.sql" 'UPDATE ' 'estimator issued a write statement'
assert_not_contains "$TMP/human.sql" 'DELETE ' 'estimator issued a write statement'

new_sql_log "$TMP/connection.sql"
run_expect_status 3 "$TMP/connection.out" env FAKE_MYSQL_STORAGE_MODE=connection-failure \
    FAKE_MYSQL_STORAGE_LOG="$TMP/connection.sql" "$SCRIPT" -l x -d app -t users -r 1 \
    --environment test --mysql-bin "$FAKE" --no-color
assert_contains "$TMP/connection.out" "Unable to connect using login path 'x'" 'connection failure diagnostic missing'

mkdir -p "$TMP/export"
new_sql_log "$TMP/csv.sql"
csv_report="$TMP/export/storage.csv"
run_in_workspace "$SCRIPT" -l x -d app -t users -r 100 --environment test --mysql-bin "$FAKE" \
    --output-file "$csv_report" --format csv --no-color >"$TMP/csv.out"
[[ -f "$csv_report" ]] || fail 'CSV report was not created'
assert_contains "$csv_report" '"Table_Name","Rows_Day","Total_Rows"' 'CSV header is not correctly quoted'
assert_contains "$csv_report" '"users","100","3000"' 'CSV data row is not correctly quoted'
if LC_ALL=C grep "$(printf '\033')" "$csv_report" >/dev/null; then fail 'CSV contains ANSI escapes'; fi
assert_contains "$TMP/csv.out" "Report written: $csv_report" 'CSV completion path missing'

new_sql_log "$TMP/escaped-identifiers.sql"
escaped_report="$TMP/export/escaped.csv"
env FAKE_MYSQL_STORAGE_MODE=escaped-identifiers FAKE_MYSQL_STORAGE_LOG="$TMP/escaped-identifiers.sql" \
    "$SCRIPT" -l x -d app -t users -r 100 --environment test --mysql-bin "$FAKE" \
    --output-file "$escaped_report" --format csv --no-color >"$TMP/escaped-identifiers.out"
assert_contains "$escaped_report" '"users\\archive","100","3000"' 'CSV changed MySQL batch escaping for a backslash'
assert_contains "$escaped_report" '"line\nbreak","100","3000"' 'CSV changed MySQL batch escaping for a newline'
assert_contains "$escaped_report" '"tab\tname","100","3000"' 'CSV changed MySQL batch escaping for a tab'

new_sql_log "$TMP/tsv.sql"
tsv_report="$TMP/export/storage.tsv"
run_in_workspace "$SCRIPT" -l x -d app -t users -r 100 --environment test --mysql-bin "$FAKE" \
    --output-file "$tsv_report" --no-color >"$TMP/tsv.out"
[[ -f "$tsv_report" ]] || fail 'TSV report was not created'
assert_contains "$tsv_report" $'Table_Name\tRows_Day\tTotal_Rows' 'TSV format was not inferred from extension'
assert_contains "$tsv_report" $'TOTAL\t100\t3000' 'TSV total row missing'

printf 'ORIGINAL\n' > "$TMP/export/preserved.csv"
new_sql_log "$TMP/report-failure.sql"
run_expect_status 3 "$TMP/report-failure.out" env FAKE_MYSQL_STORAGE_MODE=report-failure \
    FAKE_MYSQL_STORAGE_LOG="$TMP/report-failure.sql" "$SCRIPT" -l x -d app -t users -r 100 \
    --environment test --mysql-bin "$FAKE" --output-file "$TMP/export/preserved.csv" --format csv --no-color
[[ "$(<"$TMP/export/preserved.csv")" == ORIGINAL ]] || fail 'failed export replaced the existing report'
if find "$TMP/export" -maxdepth 1 -name '.estimate-storage.*' -print | grep . >/dev/null; then
    fail 'failed export left a temporary file'
fi

printf 'ORIGINAL\n' > "$TMP/export/interrupted.csv"
new_sql_log "$TMP/interrupted.sql"
env FAKE_MYSQL_STORAGE_MODE=slow-report FAKE_MYSQL_STORAGE_LOG="$TMP/interrupted.sql" \
    "$SCRIPT" -l x -d app -t users -r 100 --environment test --mysql-bin "$FAKE" \
    --output-file "$TMP/export/interrupted.csv" --format csv --no-color \
    >"$TMP/interrupted.out" 2>&1 &
interrupted_pid=$!
temporary_seen=false
attempt=0
while [[ "$attempt" -lt 100 ]]; do
    if find "$TMP/export" -maxdepth 1 -name '.estimate-storage.*' -print | grep . >/dev/null; then
        temporary_seen=true
        break
    fi
    sleep 0.02
    attempt=$((attempt + 1))
done
if [[ "$temporary_seen" != true ]]; then
    kill -TERM "$interrupted_pid" 2>/dev/null || true
    wait "$interrupted_pid" 2>/dev/null || true
    fail 'signal test never observed the atomic temporary report'
fi
kill -TERM "$interrupted_pid"
set +e
wait "$interrupted_pid"
interrupted_status=$?
set -e
[[ "$interrupted_status" -eq 130 ]] || fail "TERM returned $interrupted_status instead of 130"
[[ "$(<"$TMP/export/interrupted.csv")" == ORIGINAL ]] || fail 'TERM replaced the existing report'
if find "$TMP/export" -maxdepth 1 -name '.estimate-storage.*' -print | grep . >/dev/null; then
    fail 'TERM left a temporary report'
fi

printf 'PASS: estimate_storage\n'
