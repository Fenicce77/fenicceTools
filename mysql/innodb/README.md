# InnoDB Tools

This directory contains the supported capture and post-mortem analysis tools
for `SHOW ENGINE INNODB STATUS`. The normal workflow is to capture samples with
the sampler and inspect the resulting files with the analyzer.

Both commands work on macOS and Linux. ANSI color is emitted only to an
interactive terminal and can always be disabled with `--no-color`.

## Capture: `innodb_engine_status.sampler.sh`

`innodb_engine_status_sampler/innodb_engine_status.sampler.sh` captures
`SHOW ENGINE INNODB STATUS` at a configurable interval, or prints one live
sample without writing files.

### Instance configuration

The required positional argument is `INSTANCE_NAME`. It resolves to the client
option file below; except for the documented special-instance contract, the
file must contain `host` and `port`.

```text
innodb_engine_status_sampler/.conf/<instance_name>.cnf
```

```ini
[client]
host=mysql-primary.example.net
port=3306
user=innodb_monitor
password=change-me
```

Authentication options are passed to the selected MySQL client through this
option file. The sampler never invokes `sudo`.

### Capture layout and operational guarantees

Default capture mode writes under:

```text
/data/innodb/<host>_<port>/YYYYMMDD/YYYYMMDD_HH.sample
```

`--sample-base-dir` replaces only `/data/innodb`. The hourly sample is
appended to, so it contains every collection from that hour. Before each
capture the sampler verifies connectivity, writes a temporary file, then
appends only a complete result. It creates an atomic, instance-specific lock;
a second live capture is rejected and stale locks are recovered automatically.

### Parameters

| Argument | Description |
|---|---|
| `INSTANCE_NAME` | Required configuration name; letters, numbers, `.`, `_`, and `-`. |
| `-i`, `--interval SECONDS` | Positive capture interval; default `5`. |
| `--display` | Print one live sample. No files or locks are created. |
| `--sample-base-dir PATH` | Capture base path; default `/data/innodb`. |
| `--mysql-bin PATH` | MySQL client executable or command name; default `mysql` from `PATH`. |
| `--no-color` | Disable ANSI colors. |
| `-h`, `--help` | Print complete help and exit. |

### Examples

Capture every five seconds using the default layout:

```bash
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh ke-primary
```

Capture every ten seconds into a monitoring volume:

```bash
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh \
  ke-primary --interval 10 --sample-base-dir /srv/innodb/samples
```

Inspect a configured remote instance without storing the result:

```bash
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh \
  ke-primary --display --no-color
```

## Analyze: `innodb_status_analyzer.sh`

`innodb_status_analyzer.sh` reads timestamped samples and extracts active
deadlocks and persistent lock waits. It aggregates query templates, event
frequency, users, threads, transaction IDs and observed lock duration. Source
samples are read-only.

Input filenames must strictly be `YYYYMMDD_HH.sample`. Inputs can be selected
by directory, explicit file, or shell pattern; invalid names are warned and
skipped. Repeated selections are deduplicated and processed in stable order.

The analyzer derives event bounds from the sample name and embedded status
timestamp. A `LATEST DETECTED DEADLOCK` older than 2.5 hours relative to its
containing sample is excluded as stale.

### Parameters

| Argument | Description |
|---|---|
| `-d`, `--dir DIRECTORY` | Analyze valid samples in a directory. |
| `-f`, `--file FILE [FILE ...]` | Analyze explicit files; repeatable. |
| `-p`, `--pattern PATTERN` | Analyze files matching a shell pattern; repeatable. |
| `-s`, `--start DATE` | Inclusive bound: `YYYY-MM-DD [HH[:MM[:SS]]]`. |
| `-e`, `--end DATE` | Inclusive bound: `YYYY-MM-DD [HH[:MM[:SS]]]`. |
| `-n`, `--top NUMBER` | Global-summary row limit; default `20`. |
| `-t`, `--table LIST` | Comma-separated table patterns; accepts `*` and `?`. |
| `-u`, `--user PATTERN` | User pattern; accepts `*` and `?`. |
| `-m`, `--mode MODE` | `all` (default), `deadlocks`, or `locks`. |
| `-r`, `--report-mode MODE` | `screen`, `file` (default), or `both`. |
| `-o`, `--output-dir DIRECTORY` | Destination for reports and CSV artifacts. |
| `--no-color` | Disable ANSI colors. |
| `-h`, `--help` | Print complete help and exit. |

### Reports and CSV artifacts

`--report-mode file` and `both` write `innodb_report_<MODE>.log`. ANSI escapes
are removed from all file artifacts. With `--output-dir`, per-sample details
are written as:

```text
<sample>.analysis_<MODE>_<filters>.csv
```

Multi-sample analysis, or any date-bounded analysis, also writes:

```text
full_recap_<MODE>_<date_range><filters>.csv
```

The recap schema is:

```text
Type,Hash,FirstSeen,LastSeen,TotalMetric,Occurrences,Users,Threads,TransactionIDs,QueryTemplate
```

### Examples

Review a day's samples and retain reports and CSV files:

```bash
./innodb_status_analyzer.sh \
  --dir /srv/innodb/samples/mysql-primary.example.net_3306/20260928 \
  --mode all --report-mode both --output-dir /tmp/innodb-review
```

Review deadlocks in one file without color:

```bash
./innodb_status_analyzer.sh \
  --file /srv/innodb/samples/mysql-primary.example.net_3306/20260928/20260928_13.sample \
  --mode deadlocks --report-mode screen --no-color
```

Investigate a table and user during a bounded interval:

```bash
./innodb_status_analyzer.sh \
  --dir /srv/innodb/samples/mysql-primary.example.net_3306/20260928 \
  --start '2026-09-28 10:00:00' --end '2026-09-28 14:00:00' \
  --table 'app.orders' --user 'application_*' --mode locks \
  --report-mode both --output-dir /tmp/innodb-orders-locks
```

## Historical tools

`legacy/innodb_engine_photographer.ptosc.sh` is the former
pt-online-schema-change-gated sampler. It is preserved unchanged for reference
and is not supported. The canonical sampler replaces its capture role.

Historical analyzer implementations are preserved byte-for-byte under
`innodb_analyzer/legacy/`. They are archival material, not supported commands.
