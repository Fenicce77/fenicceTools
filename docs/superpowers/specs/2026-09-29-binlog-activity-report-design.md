# Binlog Activity Report Design

## Objective

Replace the overlapping scripts in `mysql/binlogs/` with one supported,
portable reporting command. It must analyze local or remote MySQL and MariaDB
binary logs, report DML and DDL activity on screen, optionally produce CSV
artifacts, and preserve existing scripts as historical references until the new
implementation is verified.

## Supported command and archival scope

The supported command will be:

```text
mysql/binlogs/binlog_activity_report.sh
```

After verification, the following implementations move unchanged to
`mysql/binlogs/legacy/` without wrappers or symlinks:

```text
full_binlog_accounting_indexed.sh
summarize_DDLs_binlogs.sh
summarize_binlogs.sh
summarize_binlogs2.sh
summarize_binlogs2_range.sh
summarize_binlogs_notbinary.sh
summarize_binlogs_notbinary.top7.sh
summarize_binlogs_remote_DDLs.sh
```

## Input contract

### Source and server identity

`--source local|remote` is required.

| Source | Required arguments | Format resolution |
|---|---|---|
| `local` | `--file FILE [FILE ...]` or `--dir DIRECTORY`, plus `--server-version VERSION` | `--binlog-format statement|row|mixed` is required. |
| `remote` | `--login-path NAME` and `--binlog-file FILE [FILE ...]` | If omitted, `--server-version`, `--server-family`, and `--binlog-format` are obtained from `@@version`, `@@version_comment`, and `@@GLOBAL.binlog_format`. |

`--server-family mysql|mariadb` is optional in local mode. The default is
derived from `--server-version`: a string containing `MariaDB` selects
`mariadb`; otherwise it selects `mysql`, including Percona Server. Explicit
`--server-family` overrides derivation for non-standard version strings.

The server-version profile is one of `mysql-5.7`, `mysql-8.0+`, or
`mariadb-10+`. It selects compatible client options and auxiliary parsing
patterns. It does not suppress event-level detection.

### Analysis options

```text
--scope dml|ddl|all                 Default: all
--start DATETIME                    Inclusive mysqlbinlog start bound
--stop DATETIME                     Inclusive mysqlbinlog stop bound
--top-tables NUMBER                 Default: 10
--csv PATH                          Optional plain CSV report
--mysqlbinlog-bin PATH              Default: mysqlbinlog, with mariadb-binlog fallback
--no-color
--help
```

All input selection is deterministic, de-duplicated, and preserves paths with
spaces. Errors print the full color-aware help and exit with status `2`.

## Event normalization

The report runs the selected reader with verbose decoded row output. It does
not execute the result and it does not alter any source binlog.

1. Maintain context for event timestamp, binlog position, transaction boundary
   and latest `Table_map` mapping.
2. Classify row DML from decoded pseudo-SQL lines:
   `### INSERT INTO`, `### UPDATE`, and `### DELETE FROM`.
3. Associate row activity with the latest valid `Table_map` and retain the
   decoded table identifier as a fallback.
4. Parse normal statement/DDL `Query` content as multi-line SQL blocks, rather
   than treating `###` output as SQL.
5. Identify `CREATE`, `ALTER`, `DROP`, `TRUNCATE`, `RENAME`, and `CREATE INDEX`
   as DDL. DML statement classification covers `INSERT`, `UPDATE`, `DELETE`,
   and `REPLACE`.
6. End or flush transaction context at `COMMIT`, `Xid`, `ROLLBACK`, a new
   transaction boundary, or end of input.

`MIXED` is parsed event by event. It can contain statement and row events in
one file and, depending on server behavior, in the same transaction. The
configured `binlog_format` is recorded in metadata and validated, not used as
an exclusive parser branch.

MariaDB-specific `Annotate_rows`, `Partial_rows`, compressed row events and
`Table_map` variants are context events, not extra DML occurrences. MySQL and
MariaDB row images may omit columns; the report counts operations and table
activity without depending on a fixed number of row values.

## Presentation and artifacts

Screen output is always emitted. It uses an aligned table with stable colors:

| Operation | Color |
|---|---|
| INSERT / WRITE_ROWS | Green |
| UPDATE | Yellow |
| DELETE | Red |
| DDL | Cyan |

The screen includes source metadata, declared/detected server profile, input
files, event totals, and the top table summary. `--top-tables` defaults to 10.

`--csv PATH` writes a plain RFC-4180-compatible artifact without ANSI escapes.
The schema is:

```text
Timestamp,SourceFile,Position,ServerFamily,ServerVersion,BinlogFormat,EventClass,Operation,Schema,Table,TransactionId
```

## Compatibility and safety

- Bash 3.2+ on macOS and Linux; `set -euo pipefail`.
- Detect `mysqlbinlog` or `mariadb-binlog`; fail clearly if neither is usable.
- Remote reads use `--login-path` and `--read-from-remote-server`; no password
  is accepted on the command line.
- The command is read-only with respect to the source server and files.
- CSV output is created only when requested; parent-directory errors are
  reported before processing starts.
- No regex may rely on a field's fixed position in human-readable output.

## Regression matrix

Fixtures must cover the following cases, with a fake reader/client for remote
mode:

| Family/profile | Format | Required fixture behavior |
|---|---|---|
| MySQL 5.7 | STATEMENT | Multi-line DML and DDL query blocks. |
| MySQL 8.0/8.4 | ROW | `Table_map`, decoded INSERT/UPDATE/DELETE and Xid. |
| MySQL 8.0/8.4 | MIXED | Statement DDL plus row DML in the same input. |
| MariaDB 10.x/11.x | ROW | `Annotate_rows`, `Table_map`, row operations and partial/fragment context. |
| MariaDB 10.x/11.x | MIXED | Statement and row activity with default annotated rows. |

The suite also verifies local validation rules, remote auto-detection,
explicit family override, top-table default and override, stable operation
colors under a pseudo-TTY, `--no-color`, plain CSV output, time filtering,
source-file immutability, paths with spaces, and archive inventory after the
migration.

## Official compatibility references

- MySQL 8.4: [Mixed Binary Logging Format](https://dev.mysql.com/doc/refman/8.4/en/binary-log-mixed.html)
- MySQL 8.0: [mysqlbinlog](https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog.html)
- MySQL: [Row Event Display](https://dev.mysql.com/doc/refman/9.7/en/mysqlbinlog-row-events.html)
- MariaDB: [Binary Log Formats](https://mariadb.com/docs/server/server-management/server-monitoring-logs/binary-log/binary-log-formats)
- MariaDB: [Row Binlog Events](https://mariadb.com/docs/server/server-management/server-monitoring-logs/binary-log/row-binlog-events)
- MariaDB: [Annotate_rows_log_event](https://mariadb.com/docs/server/clients-and-utilities/logging-tools/mariadb-binlog/annotate_rows_log_event)
