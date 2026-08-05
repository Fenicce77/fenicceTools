# Check Cardinality Standardization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `check_cardinality.sh` as a safe, tested MySQL 8 cardinality analyzer with backward-compatible options, guarded exact/ANALYZE operations, aligned terminal output, and clean CSV/TSV export.

**Architecture:** Keep one deployable Bash 3.2 script, split internally into CLI, MySQL transport, metadata, analysis, and reporting functions. Test the real executable through a deterministic fake MySQL client whose query log proves that safe modes never issue unintended user-table scans or writes.

**Tech Stack:** Bash 3.2, POSIX `awk`/`sort`/`sed`, MySQL 8.0/8.4 SQL, ANSI terminal output, shell-based integration tests.

## Global Constraints

- Preserve `-l`, `-d`, `-t`, `-f`, `-p`, `-r`, and `-h`.
- Support macOS default Bash 3.2 and Linux Bash.
- Use `set -euo pipefail`; explicitly guard expected nonzero commands.
- Do not use associative arrays, `mapfile`, `readarray`, GNU-only `sed`, or GNU-only `mktemp` syntax.
- Use `printf`, not `echo -e`; use portable `awk` instead of `bc`.
- Keep code, comments, help, diagnostics, and output labels in English.
- Default to `--mode auto`, threshold `500000`, drift `10`, and timeout `30000` ms.
- Never force an index for exact `COUNT(*)`.
- Never execute ANALYZE without `--analyze-table` plus an allowed explicit environment.
- Do not modify `analyze_prefix_index.sh` or `estimate_storage.sh`.

---

### Task 1: Test Harness and Backward-Compatible CLI Foundation

**Files:**
- Create: `mysql/estimations/tests/fake_mysql.sh`
- Create: `mysql/estimations/tests/test_check_cardinality.sh`
- Modify: `mysql/estimations/check_cardinality.sh:1-117`

**Interfaces:**
- Consumes: existing short options and `MYSQL_BIN` environment override.
- Produces: `initialize_defaults`, `initialize_colors`, `show_help`, `parse_arguments`, `validate_arguments`, `resolve_mysql_bin`, `build_table_list`, and a `main "$@"` entry point.
- Test contract: `FAKE_MYSQL_SCENARIO` selects fixtures and `FAKE_MYSQL_QUERY_LOG` records every SQL statement.

- [ ] **Step 1: Create the executable fake MySQL client**

Implement argument parsing that captures the value following `-e`, appends it to the required query log, and returns baseline responses:

```bash
#!/usr/bin/env bash
set -euo pipefail

query=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -e)
            [[ $# -ge 2 ]] || exit 90
            query=$2
            shift 2
            ;;
        *) shift ;;
    esac
done

printf '%s\n--QUERY-END--\n' "$query" >> "${FAKE_MYSQL_QUERY_LOG:?}"

case "$query" in
    *"cardinality:connection"*) printf '1\t8.4.6\tfake-db.example\n' ;;
    *"information_schema.tables"*"COUNT(*)"*) printf '1\n' ;;
    *"SELECT TABLE_ROWS"*) printf '100\n' ;;
    *"SELECT COUNT(*) FROM"*) printf '100\n' ;;
    *"SELECT COLUMN_NAME FROM information_schema.columns"*) printf 'id\n' ;;
    *"GROUP_CONCAT"*"information_schema.STATISTICS"*) printf 'PRIMARY(#1)\n' ;;
    *"SELECT CARDINALITY FROM information_schema.STATISTICS"*) printf '100\n' ;;
    *"COUNT(DISTINCT CASE"*) printf '100\t100\n' ;;
    *) printf 'fake_mysql: unhandled query: %s\n' "$query" >&2; exit 91 ;;
esac
```

Run `chmod +x mysql/estimations/tests/fake_mysql.sh` so client-resolution tests
exercise a real executable path.

- [ ] **Step 2: Create CLI-first integration tests**

The test runner must create a private directory, install cleanup traps, provide `run_case`, `assert_status`, `assert_contains`, and `assert_query_contains`, and support `TEST_FILTER`:

```bash
run_case() {
    local name=$1
    shift
    : > "$QUERY_LOG"
    set +e
    OUTPUT=$(FAKE_MYSQL_QUERY_LOG="$QUERY_LOG" \
        FAKE_MYSQL_SCENARIO=baseline \
        MYSQL_BIN="$FAKE_MYSQL" \
        "$SCRIPT" "$@" 2>&1)
    STATUS=$?
    set -e
    LAST_CASE=$name
}

run_test() {
    local name=$1
    local function_name=$2
    [[ -z "${TEST_FILTER:-}" || "$name" == *"$TEST_FILTER"* ]] || return 0
    "$function_name"
}
```

Add tests proving:

```bash
test_help_and_no_arguments_exit_zero() {
    run_case no_args
    assert_status 0
    assert_contains "$OUTPUT" 'MySQL Cardinality Analyzer'
    assert_contains "$OUTPUT" '--mode auto|metadata|exact'

    run_case long_help --help
    assert_status 0
    run_case short_help -h
    assert_status 0
}

test_short_and_long_options_remain_accepted() {
    run_case short -l test-login -d app -t users -p 500000 -r 10
    assert_status 0
    run_case long --login-path test-login --database app --tables users \
        --performance-threshold 500000 --drift-threshold 10 --mode=auto \
        --max-execution-time-ms=30000 --mysql-bin "$FAKE_MYSQL"
    assert_status 0
}

test_cli_validation_uses_exit_two() {
    run_case missing_value --login-path
    assert_status 2
    run_case bad_mode -l x -d app -t users --mode unsafe
    assert_status 2
    run_case format_without_output -l x -d app -t users --format csv
    assert_status 2
}
```

Also cover `--name=value`, table files, comma-list deduplication, comments/blank lines, `--no-color`, invalid numeric boundaries, invalid environment, and the MySQL binary precedence `--mysql-bin > MYSQL_BIN > PATH`.
Assert missing/nonexecutable clients and connection failures exit 3, while a
fake per-table SQL failure exits 4 after later tables are attempted.

- [ ] **Step 3: Run CLI tests and verify RED**

Run:

```bash
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because no long options exist, `-h` exits 1, values are not validated, and no fake-client override is available.

- [ ] **Step 4: Implement the CLI/runtime foundation**

Add strict mode and initialize every global, including:

```bash
initialize_defaults() {
    MYSQL_BIN_ENV=${MYSQL_BIN:-}
    LOGIN_PATH=""
    DATABASE=""
    TABLE_STRING=""
    TABLE_FILE=""
    PERF_THRESHOLD=500000
    DRIFT_THRESHOLD=10
    REQUESTED_MODE="auto"
    MAX_EXECUTION_TIME_MS=30000
    ANALYZE_TABLE=false
    ENVIRONMENT=""
    OUTPUT_FILE=""
    OUTPUT_FORMAT=""
    MYSQL_BIN_OPTION=""
    MYSQL_BIN=""
    NO_COLOR=false
    TABLE_ARRAY=()
    UNIQUE_TABLES=()
    WORK_DIR=""
    FINAL_STATUS=0
}
```

Use a `require_value "$option" "${2-}"` helper before every shift. Parse both long forms with a manual `while`/`case`, for example:

```bash
--login-path=*) LOGIN_PATH=${1#*=} ;;
--login-path|-l)
    require_value "$1" "${2-}"
    LOGIN_PATH=$2
    shift
    ;;
--mode=*) REQUESTED_MODE=${1#*=} ;;
--mode)
    require_value "$1" "${2-}"
    REQUESTED_MODE=$2
    shift
    ;;
--analyze-table) ANALYZE_TABLE=true ;;
--no-color) NO_COLOR=true ;;
-h|--help) show_help; exit 0 ;;
```

Validate integers with Bash regexes, enums with `case`, `--format` only with an output file, and at least one table input. Resolve the client exactly as:

```bash
if [[ -n "$MYSQL_BIN_OPTION" ]]; then
    MYSQL_BIN=$MYSQL_BIN_OPTION
elif [[ -n "$MYSQL_BIN_ENV" ]]; then
    MYSQL_BIN=$MYSQL_BIN_ENV
else
    MYSQL_BIN=$(command -v mysql 2>/dev/null || true)
fi
[[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || cli_runtime_error 3 "MySQL client not found."
```

Implement whitespace trimming without `xargs`, deterministic deduplication through a temporary sorted list, portable colors with `printf`, and standardized help matching the approved option names and examples.

After resolving the client, perform the global connection/version check without
letting strict mode bypass the intended exit code:

```bash
if ! CONNECTION_OUTPUT=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" \
    --batch --raw --skip-column-names \
    -e "SELECT /* cardinality:connection */ 1, VERSION(), @@hostname;" 2>&1); then
    cli_runtime_error 3 "Unable to connect using login path '$LOGIN_PATH': $CONNECTION_OUTPUT"
fi
```

Create the private workspace and cleanup contract before table-list processing:

```bash
create_workspace() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/check-cardinality.XXXXXX") ||
        cli_runtime_error 3 "Unable to create temporary workspace."
}

cleanup() {
    case "${WORK_DIR:-}" in
        "${TMPDIR:-/tmp}"/check-cardinality.*) rm -rf "$WORK_DIR" ;;
    esac
}

trap cleanup EXIT
trap 'exit 130' INT TERM
```

Wrap the existing processing logic in `main` for this checkpoint; define all values it reads so `set -u` is safe. Replace `MYSQLBIN` references with `MYSQL_BIN`. Keep behavior otherwise unchanged until Task 2.

- [ ] **Step 5: Verify CLI GREEN and syntax compatibility**

Run:

```bash
bash -n mysql/estimations/check_cardinality.sh
TEST_FILTER=cli bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: all CLI tests pass with no warnings; baseline short invocation remains successful.

- [ ] **Step 6: Commit the CLI foundation**

```bash
git add mysql/estimations/check_cardinality.sh \
  mysql/estimations/tests/fake_mysql.sh \
  mysql/estimations/tests/test_check_cardinality.sh
git commit -m "refactor(mysql): standardize cardinality analyzer CLI"
```

### Task 2: Server-Safe Modes and Correct Metadata Semantics

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh`
- Modify: `mysql/estimations/tests/fake_mysql.sh`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`

**Interfaces:**
- Consumes: validated `REQUESTED_MODE`, `PERF_THRESHOLD`, `DATABASE`, `UNIQUE_TABLES`, and `mysql_query SQL`.
- Produces: `load_table_metadata TABLE`, `load_column_metadata TABLE`, `choose_effective_mode`, `analyze_metadata_columns`, `calculate_metrics CARD DENOMINATOR`, `TABLE_ENGINE`, `ESTIMATED_ROWS`, `EFFECTIVE_MODE`, and a normalized per-table TSV result file.
- Normalized column fields: `column`, `column_type`, `nullable`, `eligible_rows`, `cardinality`, `ratio`, `selectivity_pct`, `source`, `source_index`, `existing_indexes`, `status`, `error`.

- [ ] **Step 1: Add fake scenarios for large, missing-estimate, and composite-index tables**

Recognize stable SQL markers and return fixtures selected by `FAKE_MYSQL_SCENARIO`:

```text
/* cardinality:table_metadata */
/* cardinality:column_metadata */
```

Use these exact fixture shapes:

```bash
# table metadata: engine, estimated_rows
large) printf 'InnoDB\t900000\n' ;;
small) printf 'InnoDB\t100\n' ;;
missing_estimate) printf 'InnoDB\tNULL\n' ;;

# column metadata fields:
# column, column_type, data_type, nullable, metadata_cardinality,
# source_index, key_kind, index_columns, existing_indexes
printf 'id\tbigint unsigned\tbigint\tNO\t900000\tPRIMARY\tPRIMARY_SINGLE\t1\tPRIMARY(#1)\n'
printf 'tenant_id\tbigint unsigned\tbigint\tNO\tN/A\tN/A\tUNAVAILABLE\t2\tuk_tenant_email(#1), idx_email_tenant(#2)\n'
printf 'email\tvarchar(255)\tvarchar\tYES\t450000\tidx_email_tenant\tLEADING_COMPOSITE\t2\tidx_email_tenant(#1)\n'
```

- [ ] **Step 2: Add RED tests for safe mode selection and metadata meaning**

Add assertions that:

```bash
test_auto_large_table_never_runs_exact_scan() {
    run_scenario large -l x -d app -t users --mode auto -p 500000
    assert_status 0
    assert_query_not_contains 'cardinality:exact_count'
    assert_query_not_contains 'COUNT(DISTINCT'
    assert_contains "$OUTPUT" 'metadata'
}

test_metadata_mode_never_scans_user_tables() {
    run_scenario small -l x -d app -t users --mode metadata
    assert_query_not_contains 'cardinality:exact_count'
    assert_query_not_contains 'cardinality:exact_column'
}

test_nonleading_index_is_not_standalone_cardinality() {
    run_scenario large -l x -d app -t users --mode metadata
    assert_contains "$OUTPUT" 'tenant_id'
    assert_contains "$OUTPUT" 'UNAVAILABLE'
    assert_contains "$OUTPUT" 'N/A'
}
```

Also test `auto` with a missing estimate selects metadata. The exact threshold
boundary moves to Task 3, where the complete exact engine exists.
Add query-log assertions for a database containing a single quote and a table
containing a backtick; the information-schema predicate must double the quote
and the identifier must double the backtick before exact SQL is generated.

- [ ] **Step 3: Run mode tests and verify RED**

Run:

```bash
TEST_FILTER=mode bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=metadata bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because the current script always executes `COUNT(*)` and treats any index position as standalone cardinality.

- [ ] **Step 4: Implement one guarded MySQL query wrapper**

Use a temporary stderr file and never invoke the client through `eval`:

```bash
mysql_query() {
    local sql=$1
    local stderr_file="$WORK_DIR/mysql.stderr"
    MYSQL_OUTPUT=""
    MYSQL_ERROR=""
    if MYSQL_OUTPUT=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" \
        --batch --raw --skip-column-names -e "$sql" 2>"$stderr_file"); then
        return 0
    fi
    MYSQL_ERROR=$(<"$stderr_file")
    return 1
}
```

The connection query must use `/* cardinality:connection */` and return `1`, `VERSION()`, and `@@hostname` in one call.

- [ ] **Step 5: Implement consolidated metadata queries and mode selection**

`load_table_metadata` queries one exact table match and returns engine plus nullable `TABLE_ROWS`.

`load_column_metadata` uses MySQL 8 CTEs/window functions to compute index-column counts and deterministic rank. The ranking expression must be:

```sql
CASE
    WHEN SEQ_IN_INDEX = 1 AND index_columns = 1 AND NON_UNIQUE = 0 THEN 1
    WHEN SEQ_IN_INDEX = 1 AND index_columns = 1 THEN 2
    WHEN SEQ_IN_INDEX = 1 THEN 3
    ELSE 4
END,
CASE WHEN INDEX_NAME = 'PRIMARY' THEN 0 ELSE 1 END,
INDEX_NAME
```

Return one row per column with complete `GROUP_CONCAT(INDEX_NAME,'(#',SEQ_IN_INDEX,')')`, selected leading cardinality/index, and one of:

```text
PRIMARY_SINGLE
UNIQUE_SINGLE
LEADING_SINGLE
LEADING_COMPOSITE
UNAVAILABLE
```

The selected metadata cardinality must be `N/A` when no `SEQ_IN_INDEX=1` candidate exists.

Implement mode choice exactly:

```bash
case "$REQUESTED_MODE" in
    exact|metadata) EFFECTIVE_MODE=$REQUESTED_MODE ;;
    auto)
        if [[ "$ESTIMATED_ROWS" =~ ^[0-9]+$ ]] && \
           [[ "$ESTIMATED_ROWS" -le "$PERF_THRESHOLD" ]]; then
            EFFECTIVE_MODE=exact
        else
            EFFECTIVE_MODE=metadata
        fi
        ;;
esac
```

In metadata analysis, use estimated rows as denominator, preserve `N/A`, and calculate numeric ratio/selectivity with one portable AWK program declared in a variable before invocation.

- [ ] **Step 6: Verify safe modes GREEN and remove `bc`**

Run:

```bash
TEST_FILTER=mode bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=metadata bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
rg -n '\bbc\b|BCBIN|COUNT\(\*\) FROM \$DATABASE' mysql/estimations/check_cardinality.sh
```

Expected: tests pass; `rg` finds no `bc` dependency or unmarked legacy live-count path.

- [ ] **Step 7: Commit safe metadata modes**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests
git commit -m "feat(mysql): add safe cardinality analysis modes"
```

### Task 3: Exact Count, Key Shortcuts, Type-Aware Predicates, and Drift

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh`
- Modify: `mysql/estimations/tests/fake_mysql.sh`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`

**Interfaces:**
- Consumes: normalized column metadata and `MAX_EXECUTION_TIME_MS`.
- Produces: `run_exact_count TABLE`, `build_eligibility_predicate QUOTED_COLUMN DATA_TYPE`, `run_exact_column TABLE ...`, `calculate_drift`, `EXACT_ROWS`, `COUNT_ACCESS`, `COUNT_INDEX`, and exact normalized result rows.

- [ ] **Step 1: Add exact-query fake responses and query-log fixtures**

Recognize:

```text
/* cardinality:count_explain */
/* cardinality:exact_count */
/* cardinality:exact_unique_nullable */
/* cardinality:exact_column */
```

Return `index\tidx_small` for the explain marker, `100` for exact count,
`95` for nullable unique count, and `40\t80` for ordinary cardinality/eligible rows. Add an `empty` scenario returning exact and estimated rows `0`.

- [ ] **Step 2: Add RED exact-analysis tests**

Verify:

```bash
test_exact_count_uses_optimizer_without_force_index() {
    run_scenario exact_keys -l x -d app -t users --mode exact \
        --max-execution-time-ms 12345
    assert_query_contains 'cardinality:count_explain'
    assert_query_contains 'cardinality:exact_count'
    assert_query_contains 'MAX_EXECUTION_TIME(12345)'
    assert_query_not_contains 'FORCE INDEX'
    assert_query_not_contains 'USE INDEX'
    assert_contains "$OUTPUT" 'idx_small'
}
```

Add fixture columns covering `PRIMARY_SINGLE`, `UNIQUE_SINGLE` nullable and nonnullable, a composite-primary component, `varchar`, `date`, and numeric zero. Assert:

- auto mode at an estimate exactly equal to `-p` selects exact analysis;
- single-column primary and unique-not-null reuse row count without exact-column queries;
- nullable unique uses `COUNT(column)` without `DISTINCT`;
- composite-primary component uses `COUNT(DISTINCT ...)`;
- string SQL uses `OCTET_LENGTH(column) > 0`;
- date SQL excludes `CAST(column AS CHAR) LIKE '0000-00-00%'`;
- numeric SQL contains only `column IS NOT NULL` and does not exclude zero;
- empty exact table reports `0.00%` drift;
- drift over `-r` produces a warning but never an ANALYZE query;
- a timed-out column continues later columns and exits 4.

- [ ] **Step 3: Run exact tests and verify RED**

```bash
TEST_FILTER=exact bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=drift bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because exact analysis, explain reporting, shortcuts, timeout hints, and correct drift do not exist.

- [ ] **Step 4: Implement exact table count without index forcing**

Build quoted identifiers using a helper that doubles backticks. Execute:

```sql
EXPLAIN
SELECT /*+ MAX_EXECUTION_TIME(N) */ /* cardinality:count_explain */ COUNT(*)
FROM `database`.`table`;

SELECT /*+ MAX_EXECUTION_TIME(N) */ /* cardinality:exact_count */ COUNT(*)
FROM `database`.`table`;
```

Request EXPLAIN with column headers and parse the `type` and `key` fields by header name in AWK rather than fixed position. Do not append any index hint.

- [ ] **Step 5: Implement exact column paths and eligibility**

Set `ELIGIBILITY_PREDICATE` as:

```bash
case "$data_type" in
    char|varchar|tinytext|text|mediumtext|longtext|binary|varbinary|tinyblob|blob|mediumblob|longblob)
        ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL AND OCTET_LENGTH($quoted_column) > 0"
        ;;
    date|datetime|timestamp)
        ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL AND CAST($quoted_column AS CHAR) NOT LIKE '0000-00-00%'"
        ;;
    *) ELIGIBILITY_PREDICATE="$quoted_column IS NOT NULL" ;;
esac
```

For ordinary/composite paths execute one statement returning:

```sql
SELECT /*+ MAX_EXECUTION_TIME(N) */ /* cardinality:exact_column */
       COUNT(DISTINCT CASE WHEN predicate THEN column END),
       COUNT(CASE WHEN predicate THEN 1 END)
FROM `database`.`table`;
```

For `PRIMARY_SINGLE` and nonnullable `UNIQUE_SINGLE`, use `EXACT_ROWS` directly. For nullable `UNIQUE_SINGLE`, execute `COUNT(column)` and use the result for both eligible rows and cardinality.

The nullable unique query is:

```sql
SELECT /*+ MAX_EXECUTION_TIME(N) */ /* cardinality:exact_unique_nullable */
       COUNT(`column`)
FROM `database`.`table`;
```

- [ ] **Step 6: Implement AWK drift and metric functions**

Use explicit zero handling:

```awk
BEGIN {
    if (exact == 0) { printf "0.00"; exit }
    diff = exact - estimate
    if (diff < 0) diff = -diff
    printf "%.2f", (diff / exact) * 100
}
```

Compare drift to the threshold in AWK. Warning changes status/color only and prints an advisory to consider guarded ANALYZE; it must not mutate `ANALYZE_TABLE`.

- [ ] **Step 7: Verify exact analysis GREEN**

```bash
TEST_FILTER=exact bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=drift bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: all exact, predicate, timeout, continuation, and drift tests pass.

- [ ] **Step 8: Commit exact analysis**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests
git commit -m "feat(mysql): add guarded exact cardinality analysis"
```

### Task 4: Non-Production ANALYZE TABLE Guard

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh`
- Modify: `mysql/estimations/tests/fake_mysql.sh`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`

**Interfaces:**
- Consumes: `ANALYZE_TABLE`, `ENVIRONMENT`, validated table identifiers, and `mysql_query`.
- Produces: `run_analyze_table TABLE`, validated `ANALYZE LOCAL TABLE` result processing, and per-table failure continuation.

- [ ] **Step 1: Add RED environment-guard tests**

Add exact assertions:

```bash
test_analyze_requires_explicit_nonproduction_environment() {
    run_scenario small -l x -d app -t users --analyze-table
    assert_status 2
    assert_query_not_contains 'ANALYZE'

    run_scenario small -l x -d app -t users --analyze-table --environment production
    assert_status 2
    assert_query_not_contains 'ANALYZE'
}

test_analyze_uses_local_and_precedes_metadata() {
    for environment in development test staging; do
        run_scenario analyze_ok -l x -d app -t users --analyze-table \
            --environment "$environment"
        assert_status 0
        assert_query_order 'ANALYZE LOCAL TABLE' 'cardinality:table_metadata'
    done
}
```

Add this real query-log ordering helper before the tests:

```bash
assert_query_order() {
    local first=$1
    local second=$2
    local first_line=""
    local second_line=""
    first_line=$(grep -n "$first" "$QUERY_LOG" | head -n 1 | cut -d: -f1 || true)
    second_line=$(grep -n "$second" "$QUERY_LOG" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] ||
        fail "query order is wrong: $first must precede $second"
}
```

Add `analyze_error_then_next_table`: fake an error result for the first table, success for the second, assert both are attempted, no retry occurs, and final exit is 4.

- [ ] **Step 2: Run ANALYZE tests and verify RED**

```bash
TEST_FILTER=analyze bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because `--analyze-table` is parsed but not guarded/executed.

- [ ] **Step 3: Enforce the double opt-in during CLI validation**

Implement:

```bash
if [[ "$ANALYZE_TABLE" == true ]]; then
    case "$ENVIRONMENT" in
        development|test|staging) : ;;
        production) cli_error "--analyze-table is forbidden for production." ;;
        "") cli_error "--analyze-table requires --environment development|test|staging." ;;
        *) cli_error "Invalid --environment value: $ENVIRONMENT" ;;
    esac
fi
```

- [ ] **Step 4: Execute and validate ANALYZE results**

Run before `load_table_metadata`:

```sql
ANALYZE LOCAL TABLE `database`.`table`;
```

Use normal tabular output with four fields (`Table`, `Op`, `Msg_type`, `Msg_text`). Accept only rows whose `Msg_type` is `status` and whose message is `OK`, case-insensitively. Print all server messages. Any error/warning result marks the table failed, skips its metadata/cardinality work, and continues to the next table without retry.

- [ ] **Step 5: Verify ANALYZE GREEN and read-only defaults**

```bash
TEST_FILTER=analyze bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: guards, ordering, LOCAL syntax, result validation, continuation, and no-retry assertions pass; scenarios without `--analyze-table` contain no ANALYZE query.

- [ ] **Step 6: Commit ANALYZE support**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests
git commit -m "feat(mysql): guard nonproduction table analysis"
```

### Task 5: Aligned Terminal Rendering and Atomic CSV/TSV Reports

**Files:**
- Modify: `mysql/estimations/check_cardinality.sh`
- Modify: `mysql/estimations/tests/test_check_cardinality.sh`

**Interfaces:**
- Consumes: normalized table/column result TSV files.
- Produces: `refresh_terminal_width`, `truncate_text TEXT WIDTH`, `format_table_report`, `csv_escape`, `tsv_sanitize`, `initialize_export`, `append_export_row`, `publish_export`, and final summary output.

- [ ] **Step 1: Add RED alignment and export tests**

Run the formatter with `TERM=xterm-256color`, assert that real ANSI is present,
and strip it with the portable CSI regex before measuring. Assert:

- every rendered data row has separators at the same visible character offsets as the header;
- a 120-column fallback is used when `tput cols` fails or returns less than 120;
- a 160-column terminal retains more of long names than the fallback;
- terminal values end in `...` when truncated;
- CSV and TSV keep the complete long values;
- CSV doubles embedded quotes and quotes every field;
- TSV replaces tab/CR/LF with spaces;
- exports contain the exact 20-field header order from the spec;
- exports contain no escape byte;
- failed report generation leaves an existing destination unchanged;
- successful generation atomically replaces the destination;
- the summary counts requested/completed/warned/failed/exact/metadata tables.

- [ ] **Step 2: Run reporting tests and verify RED**

```bash
TEST_FILTER=alignment bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=export bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=summary bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: FAIL because output is still the legacy fixed table and no export exists.

- [ ] **Step 3: Implement geometry and ANSI-safe row formatting**

Set `TERM_WIDTH=120`; if `tput cols` yields an integer greater than 120, use it. Calculate fixed numeric widths first, then distribute remaining width between column/type/index text fields with documented minimums.

Build a clean line before coloring:

```bash
line=$(printf "%-*s | %-*s | %*s | %*s | %*s | %*s | %-*s | %-*s" \
    "$column_width" "$column_text" \
    "$type_width" "$type_text" \
    13 "$eligible_rows" 11 "$cardinality" 8 "$ratio" 11 "$selectivity" \
    "$source_width" "$source" "$indexes_width" "$indexes_text")
printf '%s%s%s\n' "$row_color" "$line" "$COLOR_RESET"
```

Never place ANSI variables inside a padded `%s`. Implement truncation as full value when it fits, `...` when width is 3, or `substr(value,1,width-3) "..."` otherwise.

- [ ] **Step 4: Implement clean atomic exports**

Resolve the output directory and create the temporary export beside the destination:

```bash
EXPORT_TEMP=$(mktemp "$output_dir/.check-cardinality.XXXXXX")
```

Register it for cleanup. Quote CSV values by replacing `"` with `""` and emitting `"value"`. Sanitize TSV controls using a portable AWK function. Write the exact 20-field header, append full untruncated normalized values, and call `mv "$EXPORT_TEMP" "$OUTPUT_FILE"` only after all report generation completes without a global or partial failure. On exit 4, remove the temporary export and preserve any existing destination.

- [ ] **Step 5: Verify reporting GREEN**

```bash
TEST_FILTER=alignment bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=export bash mysql/estimations/tests/test_check_cardinality.sh
TEST_FILTER=summary bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
```

Expected: all output, alignment, truncation, export-cleanliness, atomicity, and summary tests pass.

- [ ] **Step 6: Commit reporting**

```bash
git add mysql/estimations/check_cardinality.sh mysql/estimations/tests/test_check_cardinality.sh
git commit -m "feat(mysql): add aligned cardinality reports"
```

### Task 6: Estimation Tools Context, Full Verification, and Portability Audit

**Files:**
- Create: `mysql/estimations/README.md`
- Verify: `mysql/estimations/check_cardinality.sh`
- Verify: `mysql/estimations/tests/fake_mysql.sh`
- Verify: `mysql/estimations/tests/test_check_cardinality.sh`
- Verify unchanged: `mysql/estimations/analyze_prefix_index.sh`
- Verify unchanged: `mysql/estimations/estimate_storage.sh`

**Interfaces:**
- Consumes: completed analyzer and approved design.
- Produces: operator documentation and final macOS/Linux-compatible evidence.

- [ ] **Step 1: Write the estimation-tools context README**

Document:

- a purpose/interface matrix for all three scripts;
- shared future conventions for strict mode, help, colors, validation, MySQL client resolution, reports, and exit codes;
- full `check_cardinality.sh` option reference and examples for auto, metadata, exact, CSV, TSV, and guarded ANALYZE;
- exact versus estimated/index-prefix semantics;
- the default safe-mode decision flow;
- the fact that `ANALYZE LOCAL TABLE` updates optimizer statistics, is non-production-only in this tool, can take a read lock, and may require privileges unavailable on read-only/cloud targets;
- macOS example using `/opt/homebrew/opt/mysql-client/bin/mysql` and Linux example using PATH;
- a roadmap marking prefix/storage standardization as future phases, not implemented behavior.

Use `rmateos` only if an OS user is required in an example.

- [ ] **Step 2: Commit operator documentation**

```bash
git add mysql/estimations/README.md
git commit -m "docs(mysql): document estimation tool conventions"
```

- [ ] **Step 3: Run syntax, complete tests, and static compatibility searches**

```bash
bash -n mysql/estimations/check_cardinality.sh
bash -n mysql/estimations/tests/fake_mysql.sh
bash -n mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_check_cardinality.sh
rg -n 'declare -A|mapfile|readarray|echo -e|sed -r|sed -E|mktemp --|\bbc\b|\bxargs\b' \
  mysql/estimations/check_cardinality.sh mysql/estimations/tests
```

Expected: syntax passes, complete tests pass, and compatibility search produces no findings.

- [ ] **Step 4: Verify help and representative fake executions**

```bash
mysql/estimations/check_cardinality.sh --help
FAKE_MYSQL_QUERY_LOG=/private/tmp/cardinality-auto.log \
FAKE_MYSQL_SCENARIO=large \
mysql/estimations/check_cardinality.sh \
  --mysql-bin mysql/estimations/tests/fake_mysql.sh \
  --login-path=test --database=app --tables=users --mode=auto
FAKE_MYSQL_QUERY_LOG=/private/tmp/cardinality-exact.log \
FAKE_MYSQL_SCENARIO=exact_keys \
mysql/estimations/check_cardinality.sh \
  --mysql-bin mysql/estimations/tests/fake_mysql.sh \
  -l test -d app -t users --mode exact -o /private/tmp/cardinality.csv
```

Expected: help exits zero; auto large output is metadata-only; exact output reports the selected count key; CSV is clean and complete.

- [ ] **Step 5: Prove unrelated estimation scripts did not change**

```bash
git diff main...HEAD -- mysql/estimations/analyze_prefix_index.sh \
  mysql/estimations/estimate_storage.sh
```

Expected: no diff.

- [ ] **Step 6: Run final repository checks**

```bash
git diff main...HEAD --check
git status --short --branch
```

Expected: no whitespace errors and only intentional committed changes.
