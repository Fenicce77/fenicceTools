# Binlog activity reporting

`binlog_activity_report.sh` is the supported MySQL/MariaDB binlog activity
reporter in this directory. It reads decoded binlog events and reports
recognized DML and table DDL operations, their timestamp, position, object,
transaction identifier, and a deterministic top-table summary.

## Requirements and command selection

The script is Bash 3.2 compatible and is supported on macOS and Linux. It
uses `mysqlbinlog` when available and otherwise uses `mariadb-binlog`; select
a specific reader with `--mysqlbinlog-bin PATH` when necessary. Use
`--no-color` for redirected output, automation, or terminals that do not
support ANSI color.

```bash
mysql/binlogs/binlog_activity_report.sh --help
```

### Local source

Local mode requires source identity because it cannot safely infer metadata
from an arbitrary binlog file. Supply one or more `--file` values, or a
`--dir` whose regular files are read in deterministic name order, together
with `--server-version` and `--binlog-format`. The server family defaults to
MySQL unless the version identifies MariaDB; use `--server-family` to state it
explicitly.

```bash
mysql/binlogs/binlog_activity_report.sh \
    --source local \
    --file /var/lib/mysql/mysql-bin.000123 /var/lib/mysql/mysql-bin.000124 \
    --server-version 8.4.6 \
    --binlog-format row \
    --scope dml \
    --top-tables 20 \
    --csv /tmp/mysql-binlog-activity.csv

mysql/binlogs/binlog_activity_report.sh \
    --source local \
    --dir "/var/lib/mysql/binlogs archive" \
    --server-version 10.11.8-MariaDB \
    --binlog-format mixed \
    --no-color
```

### Remote source

Remote mode requires `--login-path NAME` and one or more `--binlog-file`
values. The login path is passed as `--login-path=NAME` to both the `mysql`
client and the binlog reader, so credentials remain in the MySQL option-file
configuration rather than on the command line. Do not supply a password as a
command argument; the CLI intentionally does not accept it.

```bash
mysql/binlogs/binlog_activity_report.sh \
    --source remote \
    --login-path reporting \
    --binlog-file mysql-bin.000123 mysql-bin.000124 \
    --start '2026-09-29 00:00:00' \
    --stop '2026-09-29 06:00:00' \
    --scope all \
    --csv /tmp/remote-binlog-activity.csv
```

Unless all three identity inputs are overridden, remote mode discovers the
missing values with the read-only query:

```sql
SELECT @@version, @@version_comment, @@GLOBAL.binlog_format;
```

`--server-version`, `--server-family`, and `--binlog-format` independently
override the corresponding discovery result. The resolved family and version
select one of these parser profiles: `mysql-5.7`, `mysql-8.0+`, or
`mariadb-10+`. Unsupported version/family combinations fail before reading
the requested binlogs.

## Operation report and colors

The terminal report prints a summary, activity rows, and `Top tables by event
count`. `--scope dml`, `--scope ddl`, or `--scope all` controls both activity
rows and the summary. Recognized operations are INSERT, REPLACE, UPDATE,
DELETE, CREATE, ALTER, DROP, TRUNCATE, and RENAME.

When stdout is a terminal, `TERM` is not `dumb`, and `--no-color` is absent,
operation text is colorized as follows:

| Operation | Color |
| --- | --- |
| INSERT, REPLACE | green |
| UPDATE | yellow |
| DELETE | red |
| CREATE, ALTER, DROP, TRUNCATE, RENAME | cyan |

Non-terminal output and output requested with `--no-color` remain plain text.
Errors use red when stderr is a compatible terminal.

## CSV output schema

`--csv PATH` adds a plain RFC 4180-style CSV file with CRLF line endings and
CSV quoting for commas, quotes, and control characters. It never contains
ANSI color escapes. Its fixed header and field order are:

```text
Timestamp,SourceFile,Position,ServerFamily,ServerVersion,BinlogFormat,EventClass,Operation,Schema,Table,TransactionId
```

`EventClass` is `DML` or `DDL`; missing schema, table, or transaction values
are emitted as `-`. The CSV parent directory must already exist and be
writable. A CSV destination is rejected when it would overwrite an input
binlog.

## Safety and read-only behavior

This tool is reporting-only. It invokes the binlog reader with
`--base64-output=DECODE-ROWS --verbose` to decode events, but it never pipes
that decoded output to a MySQL server or replays it. Decoded output can expose
row values; treat the terminal and CSV report as potentially sensitive and do
not use the decoded stream as executable SQL.

For local sources the tool reads only readable regular files. For remote
sources it uses `--read-from-remote-server` and the identity query above; it
does not issue DML or DDL. The only persistent write performed by this CLI is
the optional `--csv` file. Temporary normalized event data is cleaned up on
both success and reader failure.

## Legacy scripts

The following historical variants are retained unchanged under `legacy/` for
reference only. They are not supported entry points and no compatibility
wrapper exists at their former active paths:

- `full_binlog_accounting_indexed.sh`
- `summarize_DDLs_binlogs.sh`
- `summarize_binlogs.sh`
- `summarize_binlogs2.sh`
- `summarize_binlogs2_range.sh`
- `summarize_binlogs_notbinary.sh`
- `summarize_binlogs_notbinary.top7.sh`
- `summarize_binlogs_remote_DDLs.sh`

Use `binlog_activity_report.sh` for all new reporting and automation.
