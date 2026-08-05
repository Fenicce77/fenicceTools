# MySQL Estimation Tools

These scripts are independent DBA tools. They intentionally remain separate because each one answers a different capacity or index-design question.

| Script | Purpose | Primary output |
|---|---|---|
| `check_cardinality.sh` | Compares InnoDB row estimates with exact counts when safe and reports per-column cardinality/selectivity | Aligned terminal table; optional CSV/TSV |
| `analyze_prefix_index.sh` | Evaluates prefix lengths for string-index design | Prefix selectivity analysis |
| `estimate_storage.sh` | Projects data, index, retention, and buffer-pool requirements | Storage/capacity estimate |

Only `check_cardinality.sh` has been standardized in this phase. Aligning the other two tools with the conventions below is future work; their current behavior is unchanged.

## Shared conventions

The target convention for this tool set is:

- Bash strict mode (`set -euo pipefail`) and Bash 3.2 compatibility.
- macOS/BSD and Linux/GNU userland compatibility.
- `-h` and `--help` with options, safety behavior, and examples.
- ANSI colors outside padded fields so visible columns remain aligned.
- Validated inputs, deterministic exit codes, and signal-safe temporary files.
- Optional local MySQL client override with `--mysql-bin`.
- Machine-readable reports without ANSI escapes or terminal truncation.

Exit codes for `check_cardinality.sh` are `0` for success, `2` for CLI validation, `3` for global dependency/connection failures, `4` for partial table/column failures, and `130` for interruption.

## Cardinality analyzer

```text
check_cardinality.sh -l LOGIN_PATH -d DATABASE (-t TABLES | -f FILE) [OPTIONS]
```

Preserved short options:

```text
-l LOGIN_PATH  -d DATABASE  -t TABLES  -f TABLE_FILE
-p ROWS        -r PERCENT   -o OUTPUT  -h
```

Long and safety/reporting options:

```text
--login-path PATH
--database NAME
--tables LIST
--table-file FILE
--performance-threshold ROWS
--drift-threshold PERCENT
--mode auto|metadata|exact
--max-execution-time-ms MILLISECONDS
--analyze-table
--environment development|test|staging|production
--output-file FILE
--format csv|tsv
--mysql-bin PATH
--no-color
--help
```

Long options accept both `--name value` and `--name=value` forms. The local client resolution order is `--mysql-bin`, the `MYSQL_BIN` environment variable, then `mysql` from `PATH`. This selects only the local client executable; the login path selects the remote server.

### Modes and semantics

`auto` first reads `information_schema.TABLES.TABLE_ROWS`. It performs exact analysis only when that estimate is less than or equal to `--performance-threshold` (default `500000`). Larger or missing estimates use metadata only. Therefore auto mode never performs a count before making its safety decision.

`metadata` never executes `COUNT(*)`, `COUNT(column)`, or `COUNT(DISTINCT ...)` against user tables. Index cardinality is meaningful only for a leading index column (`SEQ_IN_INDEX=1`). A column present only after the first position of composite indexes is reported as unavailable rather than zero.

`exact` runs an optimizer-timed `COUNT(*)`, preceded by `EXPLAIN`. It does not force an index; InnoDB may select its smallest suitable secondary index or the clustered index. Single-column primary and `UNIQUE NOT NULL` keys reuse the exact row count. Nullable single-column unique keys use `COUNT(column)`. Other columns use type-aware distinct and eligible-row counts.

The exact eligibility rules exclude NULL/zero-length character and binary values, exclude NULL/zero-date temporal values, and exclude only NULL for numeric and other scalar types. Numeric zero remains valid.

### Examples

Safe automatic selection:

```bash
mysql/estimations/check_cardinality.sh \
  --login-path=devel-mysql01 --database=app --tables=users,orders
```

Metadata-only inspection of a large production table:

```bash
mysql/estimations/check_cardinality.sh \
  -l production-mysql -d app -t event_history --mode metadata
```

Explicit exact analysis with a 15-second server-side hint:

```bash
mysql/estimations/check_cardinality.sh \
  -l test-mysql -d app -t users --mode exact --max-execution-time-ms 15000
```

Atomic CSV or TSV report:

```bash
mysql/estimations/check_cardinality.sh \
  -l staging-mysql -d app -f tables.txt --mode auto \
  --output-file cardinality.csv --format csv

mysql/estimations/check_cardinality.sh \
  -l staging-mysql -d app -t users -o cardinality.tsv --format tsv
```

Guarded optimizer-statistics refresh in a non-production environment:

```bash
mysql/estimations/check_cardinality.sh \
  -l test-mysql -d app -t users \
  --analyze-table --environment test --mode metadata
```

`ANALYZE LOCAL TABLE` updates optimizer statistics and avoids binary logging. It can still acquire a read lock, requires suitable privileges, and can fail on read-only or restricted Cloud SQL/RDS targets. The tool requires the explicit flag plus `development`, `test`, or `staging`; it refuses production and never runs ANALYZE automatically because drift is high.

macOS with a Homebrew client:

```bash
mysql/estimations/check_cardinality.sh \
  --mysql-bin /opt/homebrew/opt/mysql-client/bin/mysql \
  -l devel-mysql01 -d app -t users
```

Linux using the client from `PATH`:

```bash
mysql/estimations/check_cardinality.sh \
  -l devel-mysql01 -d app -t users
```

## Roadmap

- Phase 1: standardized cardinality analyzer, tests, and reports — implemented.
- Phase 2: align `analyze_prefix_index.sh` CLI, validation, and reporting — pending.
- Phase 3: align `estimate_storage.sh` CLI, validation, and reporting — pending.
