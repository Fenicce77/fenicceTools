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
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh myinstance 
```

Capture every ten seconds into a monitoring volume:

```bash
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh \
    myinstance --interval 10 --sample-base-dir /srv/innodb/samples
```

Inspect a configured remote instance without storing the result:

```bash
./innodb_engine_status_sampler/innodb_engine_status.sampler.sh \
  myinstance --display --no-color
```

### Automate capture on Linux

The sampler is a long-running foreground process. Use one service or one cron
entry per instance; do not schedule it every five minutes because its internal
loop already controls the capture interval and rejects concurrent execution.

#### Recommended: systemd service

`systemd` is suitable for Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux,
Amazon Linux, and SUSE. Install the script and its `.conf` directory in a
stable, readable location first. The service account must be able to read the
instance client option file and create the configured sample directory.

Create an environment file, for example
`/etc/innodb-engine-status-sampler/myinstance.env`:

```ini
INSTANCE_NAME=myinstance
SAMPLE_BASE_DIR=/srv/innodb/samples
INTERVAL=5
MYSQL_BIN=/usr/bin/mysql
```

Create `/etc/systemd/system/innodb-engine-status-sampler@.service`:

```ini
[Unit]
Description=InnoDB Engine Status Sampler for %i
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=innodb-monitor
Group=innodb-monitor
EnvironmentFile=/etc/innodb-engine-status-sampler/%i.env
ExecStart=/usr/local/sbin/innodb_engine_status.sampler.sh ${INSTANCE_NAME} --interval ${INTERVAL} --sample-base-dir ${SAMPLE_BASE_DIR} --mysql-bin ${MYSQL_BIN} --no-color
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

The example expects the sampler at
`/usr/local/sbin/innodb_engine_status.sampler.sh` and its instance configuration
at `/usr/local/sbin/.conf/myinstance.cnf`. Adjust the paths consistently if the
repository is installed elsewhere.

Create the service account and sample directory, then enable the instance:

```bash
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin innodb-monitor
sudo install -d -o innodb-monitor -g innodb-monitor /srv/innodb/samples
sudo install -d -m 0750 /etc/innodb-engine-status-sampler
sudo systemctl daemon-reload
sudo systemctl enable --now innodb-engine-status-sampler@myinstance.service
sudo systemctl status innodb-engine-status-sampler@myinstance.service
sudo journalctl -u innodb-engine-status-sampler@myinstance.service -f
```

On distributions where `useradd` is not available, create the equivalent
non-login system account using the local account-management tool. Keep client
option files restrictive because they can contain authentication material:

```bash
sudo chown innodb-monitor:innodb-monitor /usr/local/sbin/.conf/myinstance.cnf
sudo chmod 0600 /usr/local/sbin/.conf/myinstance.cnf
```

For another instance, add its `.env` file and matching `.conf` file, then
enable `innodb-engine-status-sampler@<instance>.service`.

#### Alternative: crond

Use `@reboot` with `crond` when a service unit cannot be installed. The cron
job remains attached to the sampler's foreground loop and starts it once per
boot. It does not provide `systemd` restart supervision.

Create `/etc/cron.d/innodb-engine-status-sampler`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

@reboot innodb-monitor /usr/local/sbin/innodb_engine_status.sampler.sh myinstance --interval 5 --sample-base-dir /srv/innodb/samples --mysql-bin /usr/bin/mysql --no-color >>/var/log/innodb-engine-status-sampler/myinstance.log 2>&1
```

Prepare the log path and reload or start the distribution's cron daemon:

```bash
sudo install -d -o innodb-monitor -g innodb-monitor /var/log/innodb-engine-status-sampler
sudo chmod 0644 /etc/cron.d/innodb-engine-status-sampler

# Debian and Ubuntu
sudo systemctl enable --now cron.service

# RHEL, Rocky Linux, AlmaLinux, Amazon Linux, and SUSE
sudo systemctl enable --now crond.service
```

For a user-owned schedule, use `crontab -u innodb-monitor -e` and omit the
username column from the `@reboot` line. Confirm the job after a restart with
`systemctl status cron.service` or `systemctl status crond.service` and inspect
the dedicated log file.

## Retain and compress: `compress.sample.files.sh`

`compress.sample.files.sh` manages completed daily sample directories produced
by the sampler. It is intentionally safe by default: it only prints its plan
unless `--apply` is supplied. Use the default mode to review every candidate
before allowing compression or deletion.

### Configuration

The configuration file is line-based and requires all three keys:

```ini
logdir=/srv/innodb/samples/mysql-primary.example.net_3306
dailytocompressret=2
toremovalretention=14
```

| Key | Meaning |
|---|---|
| `logdir` | Existing root that contains daily `YYYYMMDD` sample directories. `/` is rejected. |
| `dailytocompressret` | Age in full days after which an eligible daily directory can be archived. |
| `toremovalretention` | Age in full days after which a root-level `.tar.gz` archive can be removed. |

Only immediate child directories whose names match `YYYYMMDD` are considered
for compression. Only immediate root-level files ending in `.tar.gz` are
considered for archive retention. Other files and directories are excluded.

### Compression and deletion contract

For each eligible daily directory, the tool creates a temporary archive under
`logdir`, validates it with `tar -tzf`, atomically places it as
`YYYYMMDD.tar.gz`, and only then removes the source directory. If the target
archive already exists, the source is skipped; it is never overwritten.

When archive retention applies, only the matching archive file is removed. The
tool does not recursively delete arbitrary paths, does not accept `/` as the
root, and supports paths containing spaces.

### Parameters

| Argument | Description |
|---|---|
| `-c`, `--config FILE` | Required readable configuration file. |
| `--dry-run` | Print planned archive and removal actions without mutating the filesystem. This is the default. |
| `--apply` | Perform the planned compression and retention actions. |
| `--no-color` | Disable ANSI colors. |
| `-h`, `--help` | Print complete help and exit. |

### Operational examples

Review an instance's pending retention actions:

```bash
./compress.sample.files.sh \
  --config /etc/innodb/compress-mysql-primary.cnf
```

Apply exactly the reviewed plan:

```bash
./compress.sample.files.sh \
  --config /etc/innodb/compress-mysql-primary.cnf --apply --no-color
```

Automate it daily only after validating dry-run output in the target layout:

```cron
15 02 * * * innodb-monitor /usr/local/sbin/compress.sample.files.sh --config /etc/innodb/compress-mysql-primary.cnf --apply --no-color >>/var/log/innodb-sample-retention/mysql-primary.log 2>&1
```

The scheduled account needs write permission to `logdir` and its parent archive
location. Ensure the log directory exists and is writable before enabling the
cron entry. Treat `--apply` as a change-management action: keep dry-run output
in runbooks or deployment validation before changing retention values.

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
