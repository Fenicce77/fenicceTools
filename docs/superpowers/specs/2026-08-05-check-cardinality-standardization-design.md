# Check Cardinality Standardization Design

## Objective

Standardize and harden `mysql/estimations/check_cardinality.sh` while preserving
its existing purpose and every current short option. The redesign must provide a
consistent command-line interface, a server-safe cardinality algorithm, aligned
colored terminal output, optional clean CSV/TSV reports, and deterministic test
coverage on macOS and Linux.

This is phase one of a wider standardization effort for the three tools under
`mysql/estimations`. This phase changes only `check_cardinality.sh`; it documents
but does not alter `analyze_prefix_index.sh` or `estimate_storage.sh`.

## Existing Tool Context

The directory contains three tools with distinct purposes:

- `analyze_prefix_index.sh` evaluates prefix lengths for string index design.
- `check_cardinality.sh` compares InnoDB row estimates with live counts and
  reports per-column selectivity and index membership.
- `estimate_storage.sh` projects data, index, retention, and buffer-pool usage.

The scripts currently differ in CLI parsing, help layout, color initialization,
validation, MySQL client discovery, error handling, output conventions, and
file-report behavior. They also lack automated tests. A new
`mysql/estimations/README.md` will document this context, shared conventions,
and the phased migration roadmap.

## Current `check_cardinality.sh` Problems

The current performance threshold does not protect the server because the
script executes an exact `COUNT(*)` before choosing metadata or live analysis.
For InnoDB, exact counts traverse an index and can be costly on large or
uncached tables.

Other correctness and reliability problems include:

- `information_schema.STATISTICS.CARDINALITY` is treated as standalone column
  cardinality even when the column occurs after the first position of a
  composite index.
- An unindexed column is reported as cardinality zero even though metadata has
  no standalone estimate for it.
- The generic `CHAR_LENGTH(column) > 0` predicate applies string semantics to
  every data type.
- Empty-table drift calculation relies on an error fallback rather than an
  explicit zero-row rule.
- MySQL metadata is fetched with multiple client processes for every column.
- SQL literals and identifiers are interpolated without centralized escaping.
- Temporary files are not protected by an exit/signal cleanup trap.
- `--help` is unsupported and `-h` exits with failure.
- Numeric and option-value validation is incomplete.
- ANSI escapes are included inside padded format strings, making reliable
  column alignment difficult.

## Scope

### Included

- Preserve existing short options and behavior where it does not conflict with
  the new safety guarantees.
- Add long aliases and new safety/reporting options.
- Add `auto`, `metadata`, and `exact` analysis modes.
- Add explicit, environment-guarded `ANALYZE LOCAL TABLE` execution.
- Correct row-count, metadata-cardinality, and type-filtering semantics.
- Add deterministic aligned terminal output and CSV/TSV export.
- Refactor the standalone script into focused Bash functions.
- Add fake-MySQL regression and integration-style tests.
- Add directory-level documentation for all estimation tools.

### Excluded

- Behavior changes to `analyze_prefix_index.sh` or `estimate_storage.sh`.
- A shared sourced Bash library in this phase.
- Automatic `ANALYZE TABLE` execution based on drift.
- Approximate sampling algorithms that claim exact cardinality.
- Automatic index creation, statistics changes, or any data-changing SQL.
- PMM, Prometheus, or Grafana integration in this phase.

## Platform and Runtime Constraints

- Support Bash 3.2, including the default macOS Bash.
- Support macOS/BSD and Linux/GNU userlands.
- Use `set -euo pipefail`.
- Use no associative arrays, `mapfile`, `readarray`, GNU-only `sed`, or
  GNU-only `mktemp` syntax.
- Use portable `awk` for decimal calculations; remove the `bc` dependency.
- Use `printf`, not `echo -e`, for deterministic escape handling.
- Keep all code, comments, help, diagnostics, and report labels in English.
- Require a MySQL 8.0 or 8.4 compatible client/server interface.

## Internal Architecture

`check_cardinality.sh` remains one deployable file. It is divided into functions
with explicit responsibilities:

- `initialize_defaults`: define every global before strict mode can expose an
  unset-variable path.
- `initialize_colors`: select ANSI colors or empty strings for `--no-color`.
- `show_help`: render standardized usage, options, examples, and safety notes.
- `parse_arguments`: support short options plus both `--name value` and
  `--name=value` long forms.
- `validate_arguments`: validate required values, enums, numeric ranges,
  output settings, and the ANALYZE environment guard.
- `resolve_dependencies`: resolve the local MySQL client using the documented
  precedence.
- `create_workspace` and `cleanup`: manage a private portable temporary
  directory and signals.
- `mysql_query`: execute one query with consistent batch/raw settings and
  capture stdout, stderr, and status without breaking strict mode.
- SQL escaping helpers: quote identifiers and encode literal comparisons.
- Metadata loaders: fetch table, column, and index metadata in consolidated
  queries.
- Mode and analysis functions: choose the effective mode and run metadata or
  exact calculations.
- Formatter/export functions: produce terminal, CSV, and TSV representations
  from the same normalized row fields.
- Summary and exit functions: report aggregate status and select the final exit
  code.

The internal functions are intentionally structured so their conventions can
later guide the other estimation scripts. They remain embedded in this script
until at least two scripts need the same implementation, avoiding a premature
runtime library dependency.

## Command-Line Interface

### Preserved options

```text
-l LOGIN_PATH
-d DATABASE
-t TABLES
-f TABLE_FILE
-p PERFORMANCE_THRESHOLD
-r DRIFT_THRESHOLD
-h
```

### Added long aliases

```text
--login-path LOGIN_PATH
--database DATABASE
--tables TABLES
--table-file TABLE_FILE
--performance-threshold ROWS
--drift-threshold PERCENT
--help
```

### New options

```text
--mode auto|metadata|exact
--max-execution-time-ms MILLISECONDS
--analyze-table
--environment development|test|staging|production
-o, --output-file FILE
--format csv|tsv
--mysql-bin PATH
--no-color
```

Long options accept separated and equals forms. Existing short invocations stay
valid.

Defaults:

- `--mode auto`
- `--performance-threshold 500000`
- `--drift-threshold 10`
- `--max-execution-time-ms 30000`
- Color enabled when terminal capability is available.
- No output file unless `-o/--output-file` is supplied.
- Output format inferred from a `.csv` or `.tsv` extension; otherwise CSV.

The local client resolution order is:

1. `--mysql-bin PATH`
2. `MYSQL_BIN` environment variable
3. `command -v mysql`

This option changes only the local client executable. `--login-path` continues
to define the remote MySQL target.

No arguments and `-h/--help` print help and exit zero. CLI validation errors
print one concise error plus a help hint and exit with code 2.

## ANALYZE TABLE Safety Contract

`--analyze-table` is a deliberate opt-in and requires `--environment` to be
explicitly set to `development`, `test`, or `staging`.

The script refuses ANALYZE when:

- `--environment` is omitted;
- it is set to `production`; or
- it contains any unrecognized value.

For each requested table, ANALYZE runs before metadata collection:

```sql
ANALYZE LOCAL TABLE `database`.`table`;
```

`LOCAL` prevents binary logging and replication of the statement. The script
validates every returned `Msg_type` and `Msg_text` row. A failed analysis marks
that table failed and processing continues with the next table. The script does
not retry automatically and never initiates ANALYZE solely because drift is
high.

Help and runtime output state that ANALYZE updates optimizer statistics, can
take a read lock, requires suitable privileges, and may fail on read-only
targets.

## Analysis Modes

### Metadata mode

- Never execute `COUNT(*)`, `COUNT(column)`, or `COUNT(DISTINCT ...)` against
  user tables.
- Use table and index estimates from `information_schema`.
- Report exact rows and drift as `N/A`.

### Exact mode

- Execute exact analysis for every table, subject to the configured statement
  timeout.
- Run `EXPLAIN SELECT COUNT(*)` first and report the optimizer-selected access
  type and key.
- Execute `COUNT(*)` without forcing a primary, unique, or numeric index.

### Auto mode

- Load `information_schema.TABLES.TABLE_ROWS` first.
- If the estimate is less than or equal to the performance threshold, use exact
  mode.
- If it is greater than the threshold, use metadata mode and avoid all exact
  user-table scans.
- Treat a missing estimate conservatively as metadata mode unless the DBA
  explicitly requests exact mode.

The `-p/--performance-threshold` help text changes from an ambiguous row limit
to: "maximum estimated table rows eligible for exact analysis in auto mode."

## Exact Row Count

The row count query is:

```sql
SELECT /*+ MAX_EXECUTION_TIME(N) */ COUNT(*)
FROM `database`.`table`;
```

InnoDB is allowed to select its smallest suitable secondary index and falls
back to the clustered index when necessary. The script does not choose a key
based on `INT`/`BIGINT` type and does not force an index.

An `EXPLAIN` precedes the count. The terminal table-level summary displays the
selected key/access type or `N/A` when the server does not expose one.

## Exact Column Cardinality

Exact analysis uses these shortcuts:

- A single-column primary-key column reuses the exact table row count.
- A single-column `UNIQUE NOT NULL` key reuses the exact table row count.
- A single-column nullable unique key uses `COUNT(column)`; distinct processing
  is unnecessary because non-NULL values are unique.
- Composite primary and unique indexes provide no shortcut for an individual
  component.
- Other columns use an exact distinct count plus an eligible-row count.

Eligibility predicates are type-aware:

- Character and binary values exclude `NULL` and zero-length values.
- `DATE`, `DATETIME`, and `TIMESTAMP` values exclude `NULL` and zero-date
  representations.
- Numeric and other scalar values exclude only `NULL`; zero is valid.

Queries use `MAX_EXECUTION_TIME(N)`. A timeout or SQL error is stored on the
affected column, remaining columns/tables continue, and the final result is a
partial failure.

## Metadata Cardinality Semantics

`STATISTICS.CARDINALITY` is an optimizer estimate for an index prefix. It is a
standalone column estimate only when the column is the first key part.

For each column, metadata selection considers only `SEQ_IN_INDEX=1` entries and
uses this deterministic preference:

1. Single-column primary or unique index.
2. Dedicated single-column regular index.
3. Leading position of a composite index.

The selected index name is reported with the estimate. A column that appears
only at position 2 or later receives cardinality, ratio, and selectivity `N/A`,
with source `UNAVAILABLE`; complete index membership remains visible.

Metadata output never substitutes zero for an unavailable estimate.

## Drift Semantics

Drift is calculated only when an exact table row count exists:

```text
ABS(exact_rows - estimated_rows) / exact_rows * 100
```

For an empty exact table, drift is `0.00%`. Metadata-only analysis reports
`N/A`.

`-r/--drift-threshold` controls warning severity and an informational
recommendation to refresh optimizer statistics. It never triggers ANALYZE.

## Terminal Output

The terminal report uses this hierarchy:

```text
=============================================================================
 MySQL Cardinality Analyzer
=============================================================================
Server / version / database / requested tables
Requested mode / thresholds / timeout / export destination
-----------------------------------------------------------------------------

TABLE: database.table
Engine | Effective mode | Estimated rows | Exact rows | Drift | Count key

COLUMN | TYPE | ELIGIBLE ROWS | CARDINALITY | RATIO | SELECTIVITY | SOURCE | INDEXES
...
```

ANSI colors are always passed outside padded field content. Complete rows are
preformatted before color prefixes/suffixes are added. Escape sequences
therefore never contribute to width calculations.

Terminal width comes from `tput cols` when available. The script uses a
120-column fallback when geometry is unavailable or narrower than the minimum
layout. Long database, table, column, data-type, source-index, and index-list
values are deterministically truncated with `...` only in terminal output.

Colors:

- Green: successful exact result.
- Cyan: metadata/informational result.
- Yellow: drift, estimate, or partial warning.
- Red: failed table/column or rejected operation.

The final summary reports tables requested, completed, warned, failed, exact,
and metadata-only.

## CSV and TSV Export

`-o/--output-file` enables a machine-readable report. It never contains ANSI
sequences and never truncates values.

Fields, in order:

```text
database
table
engine
requested_mode
effective_mode
estimated_rows
exact_rows
drift_pct
column
data_type
nullable
eligible_rows
cardinality
ratio
selectivity_pct
source
source_index
existing_indexes
status
error
```

CSV values follow standard double-quote escaping. TSV values replace embedded
tabs, carriage returns, and newlines with spaces. The file is created only
after CLI validation. A temporary export file is created in the requested
output directory and renamed over the final destination only after report
generation succeeds. Keeping both paths on the same filesystem makes the
publication atomic and prevents a failed run from leaving a partial report.

## Validation and SQL Safety

Validation covers:

- required login path and database;
- at least one table from `-t` or `-f`;
- positive performance threshold and timeout;
- nonnegative drift percentage;
- valid mode, format, and environment enums;
- `--format` used only together with `-o/--output-file`;
- readable table-list file;
- executable MySQL client;
- writable output parent directory;
- ANALYZE environment contract.

Comma-separated and file-based table input is trimmed without `xargs`, ignores
empty/comment lines, deduplicates deterministically, and preserves valid names.

SQL helpers escape string literals and quote identifiers by doubling embedded
quote characters. Table existence is verified in `information_schema` before
the name is used as a quoted identifier. User values never enter SQL through an
unvalidated ad hoc interpolation path.

## Error Handling and Exit Codes

The script uses `set -euo pipefail`, but expected failures are captured in
conditionals or explicitly guarded.

Exit codes:

```text
0    Successful execution, including nonfatal warnings
2    CLI or validation error
3    Missing dependency, connection failure, or global initialization failure
4    One or more requested tables or columns failed
130  Interrupted
```

Global initialization failures stop immediately. Table and column analysis
failures are recorded and processing continues. The final summary and code 4
make partial results explicit.

A private directory is created using portable `mktemp -d` syntax under
`${TMPDIR:-/tmp}`. Cleanup traps remove only that validated directory on normal
exit and signals.

## Testing Strategy

Tests use a deterministic fake MySQL executable and fixture responses. They do
not require credentials or modify a real server.

Coverage includes:

- Bash syntax and Bash 3.2-compatible constructs.
- Existing short options and every long/equals alias.
- Help/no-argument success behavior.
- Missing option values, invalid enums, numeric boundaries, and missing files.
- MySQL client resolution precedence.
- Table input trimming, comments, deduplication, and ordering.
- Auto mode avoiding exact scans above the threshold.
- Auto mode choosing exact analysis at/below the threshold.
- Metadata mode never scanning user tables.
- Exact mode running `EXPLAIN` and optimizer-selected `COUNT(*)` without a
  forced index.
- Single-column primary, unique-not-null, unique-nullable, composite-key, and
  ordinary-column paths.
- Leading-index metadata selection and unavailable nonleading cardinality.
- Type-aware eligible-row predicates.
- Exact empty-table drift and metadata `N/A` drift.
- Timeout, SQL error, continuation, summary, and exit-code behavior.
- ANALYZE rejection for omitted/production environments.
- `ANALYZE LOCAL TABLE` execution for development, test, and staging.
- ANALYZE result validation and no automatic retry.
- CSV escaping, TSV sanitization, full-value preservation, and atomic output.
- ANSI-free exports and terminal visible-width alignment after stripping ANSI.
- Cleanup on success, error, and interruption.

Tests also assert the generated query log so a regression that reintroduces an
exact scan in large-table auto or metadata mode fails deterministically.

## Documentation

Create `mysql/estimations/README.md` containing:

- the distinct purpose and current invocation of all three scripts;
- the common direction for help, colors, validation, output, and safety;
- the fully standardized phase-one interface for `check_cardinality.sh`;
- exact versus estimated cardinality semantics;
- explicit production cautions for exact scans and ANALYZE;
- macOS and Linux examples using `mysql_config_editor` login paths;
- the future phased migration of prefix and storage tools without implying
  that they already implement the new interface.

## Acceptance Criteria

- Every existing short option remains accepted.
- Help, long aliases, output, and exit behavior match this specification.
- Large tables in default auto mode do not execute exact user-table scans.
- Metadata output never mislabels a nonleading index-prefix estimate as
  standalone column cardinality.
- Exact `COUNT(*)` does not force the clustered or a numeric index.
- ANALYZE cannot execute without an explicit allowed non-production
  environment.
- Terminal columns remain visibly aligned with color enabled.
- CSV/TSV files contain full clean values and are atomically published.
- Automated tests pass on macOS and Linux-compatible Bash environments.
- Neither `analyze_prefix_index.sh` nor `estimate_storage.sh` changes in this
  phase.
