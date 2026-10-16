# ProxySQL Log Retention

`proxysql_eventslog_purge.sh` enforces retention on ProxySQL events log
(`mysql-eventslog_filename`) and audit log (`mysql-auditlog_filename`) files.

ProxySQL rotates both logs by size (`mysql-eventslog_filesize`,
`mysql-auditlog_filesize`) and appends an incremental numeric suffix
(`query.log.00000001`, `query.log.00000002`, ...), but it never purges rotated
files. On busy instances, especially with `mysql-eventslog_default_log=1` or a
catch-all query rule with `log=1`, the log directory grows without limit.

The same script installs and manages named systemd rotations (`--install`,
`--uninstall`, `--list`), one per ProxySQL instance and log type, each with its
own schedule and execution log.

## Behavior

- Files are selected by `<prefix>.<digits>` with an optional `.gz` suffix and
  sorted by their **numeric** suffix, not by mtime or lexical order.
- The file with the highest suffix is treated as the active file and is
  **never** deleted or compressed.
- Rotated files still held open by any process are skipped when `lsof` is
  available.
- Retention by count (`--keep`) and age (`--max-age`) can be combined. A file is
  deleted if it is outside the count window **or** older than the age limit.
- `--compress` gzips the rotated files that survive retention. Compressed files
  keep counting towards `--keep` on later runs.
- One prefix is processed per run. `query.log` never matches `audit.log` files.
- Runtime colors are emitted only when stdout is a TTY, so cron, journal and
  log output stay clean.
- `--help` is always colored, also when piped (use `less -R` to page it).
  Set `NO_COLOR=1` to get plain help text.

## Requirements

- Linux or macOS, Bash 3.2 or newer.
- `find`, `du`, `awk`, `sort`.
- `gzip` when `--compress` is used.
- `lsof` (optional, recommended): skips files still opened by a process.
- Write access to the log directory: run as the ProxySQL service user or root.
- Service management: Linux with systemd and root (`--root`/`--dry-run` work anywhere).

## Options

| Option | Default | Description |
|---|---|---|
| `-d`, `--dir DIR` | `/data/proxysql` | Directory that holds the log files. |
| `-p`, `--prefix NAME` | `query.log` | Log base name, as configured in `mysql-eventslog_filename` or `mysql-auditlog_filename`. |
| `-k`, `--keep N` | `10` | Rotated files to keep. The active file is not counted. |
| `-a`, `--max-age DAYS` | `0` (disabled) | Also delete rotated files older than `DAYS` days (mtime). |
| `-c`, `--compress` | off | gzip the rotated files that are kept. |
| `-n`, `--dry-run` | off | Print the actions without changing anything. |
| `-h`, `--help` | | Show help and exit. |
| `-V`, `--version` | | Show the version and exit. |

Service management (see [Service management](#service-management-systemd)):

| Option | Default | Description |
|---|---|---|
| `--install NAME` | | Install or update rotation `NAME` with the purge options of the same command line. `NAME` is `[A-Za-z0-9_-]`, max 64. |
| `--uninstall NAME` | | Disable and remove rotation `NAME`. The execution log and the script are kept. |
| `--list` | | List installed rotations with directory, prefix, retention, schedule, timer state and next run. |
| `--schedule SPEC` | `*-*-* 00:00:00` | `OnCalendar=` expression, validated with `systemd-analyze calendar`. |
| `--log-dir DIR` | `/data/log/purge_proxysql_eventslog` | Execution log directory. The log file is `DIR/NAME.log`. |
| `--bin-dir DIR` | `/usr/local/bin` | Where the script is copied for the units to run. |
| `--user NAME` | `root` | Service user. A non-root user adds `User=`/`Group=` and `su` to logrotate. |
| `--no-hardening` | | Omit `ProtectSystem=strict`, `ReadWritePaths=` and related sandboxing. |
| `--no-logrotate` | | Do not install a logrotate policy for the execution log. |
| `--no-enable` | | Install the timer without enabling or starting it. |
| `-y`, `--yes` | | Apply without the confirmation prompt. |
| `--root DIR` | | Write under an alternate root (staging, packaging, tests). No `systemctl` calls. |
| `--systemd-version N` | detected | `StandardOutput=append:` for 240 or newer, `sh -c` redirection for older (RHEL 8). |

Exit status is `0` on success (including when no matching files exist) and `1`
on invalid arguments, a missing directory or privileges, a missing `gzip` with
`--compress`, a conflicting rotation, or a declined confirmation.

## Usage

Check the configured file names and rotation sizes first, from the ProxySQL
admin interface:

```sql
SELECT variable_name, variable_value
FROM global_variables
WHERE variable_name IN (
    'mysql-eventslog_filename',
    'mysql-eventslog_filesize',
    'mysql-eventslog_format',
    'mysql-eventslog_default_log',
    'mysql-auditlog_filename',
    'mysql-auditlog_filesize'
);
```

Preview the actions before any change:

```bash
./proxysql_eventslog_purge.sh -d /data/proxysql -k 20 --dry-run
```

Keep the last 20 rotated events log files, drop anything older than 3 days, and
compress the survivors:

```bash
./proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 20 -a 3 -c
```

Age-only retention (keep 7 days of audit logs, whatever the file count):

```bash
./proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 100000 -a 7 -c
```

Emergency cleanup: keep only the active file:

```bash
./proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 0
```

Sample output:

```text
[INFO]  Directory: /data/proxysql | prefix: query.log | keep: 2 | max-age: 30d | compress: 1
[INFO]  Found 5 file(s). Active (protected): query.log.00000005
[OK]    Deleted query.log.00000001 (100.02 MB)
[OK]    Deleted query.log.00000002 (100.01 MB)
[OK]    Compressed query.log.00000003
[OK]    Compressed query.log.00000004

Summary: deleted=2 compressed=2 skipped=0 freed=371.40 MB
```

## Service management (systemd)

The script installs itself as named **rotations**. Each rotation is one
directory + prefix with its own retention, schedule and execution log, so a
host with several ProxySQL instances gets one rotation per instance and log
type:

| File | Purpose |
|---|---|
| `/usr/local/bin/proxysql_eventslog_purge.sh` | Copy of the script used by every rotation (updated when it differs). |
| `/etc/systemd/system/proxysql-log-retention-NAME.service` | Oneshot service running the purge with the given options. |
| `/etc/systemd/system/proxysql-log-retention-NAME.timer` | Schedule (`Persistent=true`). |
| `/etc/logrotate.d/proxysql-log-retention-NAME` | Monthly rotation of `LOG_DIR/NAME.log` only, 12 copies. |

Install the rotations for two instances, each with events and audit logs:

```bash
cd fenicceTools/proxysql/log_retention

sudo ./proxysql_eventslog_purge.sh --install proxysql1-events \
    -d /data/proxysql1 -p query.log -k 200 -a 3 -c

sudo ./proxysql_eventslog_purge.sh --install proxysql1-audit \
    -d /data/proxysql1 -p audit.log -k 1000 -a 30 -c

sudo ./proxysql_eventslog_purge.sh --install proxysql2-events \
    -d /data/proxysql2 -p query.log -k 100 -a 2 -c \
    --schedule '*-*-* 00/6:00:00' --log-dir /data/log/proxysql2
```

Before changing anything, `--install` shows the plan and the exact content of
the service, timer and logrotate files, then asks for confirmation:

```text
==> Install rotation 'proxysql1-events' (new)
  Log files:         /data/proxysql1/query.log.NNNNNNNN
  Retention:         keep 200, max-age 3d, compress yes
  Schedule:          *-*-* 00:00:00
  Run as:            root:root
  Execution log:     /data/log/purge_proxysql_eventslog/proxysql1-events.log
  Script:            /usr/local/bin/proxysql_eventslog_purge.sh (install)
  Service:           /etc/systemd/system/proxysql-log-retention-proxysql1-events.service
  Timer:             /etc/systemd/system/proxysql-log-retention-proxysql1-events.timer
  Logrotate:         /etc/logrotate.d/proxysql-log-retention-proxysql1-events
  Hardening:         yes
  Output mode:       StandardOutput=append: (systemd 252)
  Enable timer:      yes

----- /etc/systemd/system/proxysql-log-retention-proxysql1-events.service -----
...
ExecStartPre=/bin/date '+=== %%Y-%%m-%%d %%H:%%M:%%S run start ==='
ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql1 -p query.log -k 200 -a 3 -c
...

? Install rotation 'proxysql1-events' [y/N]:
```

`-y` skips the prompt (required when stdin is not a terminal) and `--dry-run`
prints the plan and files without writing anything.

List, inspect and remove rotations:

```bash
./proxysql_eventslog_purge.sh --list
```

```text
NAME                 DIR                      PREFIX        KEEP    AGE GZ   SCHEDULE           TIMER     NEXT RUN
proxysql1-audit      /data/proxysql1          audit.log     1000    30d yes  *-*-* 00:00:00     active    Sat 2026-10-17 00:00:00 WEST
proxysql1-events     /data/proxysql1          query.log      200     3d yes  *-*-* 00:00:00     active    Sat 2026-10-17 00:00:00 WEST
proxysql2-events     /data/proxysql2          query.log      100     2d yes  *-*-* 00/6:00:00   active    Fri 2026-10-16 18:00:00 WEST
```

```bash
systemctl start proxysql-log-retention-proxysql1-events.service    # run now
tail -n 50 /data/log/purge_proxysql_eventslog/proxysql1-events.log
sudo ./proxysql_eventslog_purge.sh --uninstall proxysql2-events
```

Rules:

- Re-running `--install NAME` with different options updates the rotation.
  Files that do not change are left untouched; files that change are backed up
  as `<file>.bak.<timestamp>`, and the timer is restarted to pick up a new
  schedule.
- Two rotations cannot manage the same directory + prefix; the second install
  is refused and names the existing rotation.
- The execution log directory is created if missing (mode `0750`); an existing
  directory is never modified. logrotate only targets `LOG_DIR/NAME.log`, so
  any directory can hold the execution logs.
- The rotation settings are stored as `# plr.*` comments in the service file,
  which is what `--list` and the conflict check read.
- `--install` and `--uninstall` require root and systemd. On other hosts, use
  `--root DIR` to render the files, or cron.

## Scheduling

Install the script, then schedule it as the user that owns the log directory:

```bash
sudo install -m 0755 proxysql_eventslog_purge.sh /usr/local/bin/
```

Choose the frequency from the rotation rate. With a daily run, rotated files
accumulate for up to 24 hours, so the disk must hold a full day of logs and
`--keep` must be large enough not to drop files you still need within that
day. Estimate it from `mysql-eventslog_filesize` and the number of rotations
per day:

```bash
# Rotations over the last 24 hours
find /data/proxysql -maxdepth 1 -name 'query.log.[0-9]*' -mtime -1 | wc -l
```

Schedule times use the server time zone (`timedatectl` on Linux).

### Cron

Every 30 minutes:

```cron
# /etc/cron.d/proxysql-logs
*/30 * * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 20   -a 3  -c >/dev/null 2>&1
*/30 * * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 1000 -a 30 -c >/dev/null 2>&1
```

Once a day at 00:00, keeping the output in a log file:

```cron
# /etc/cron.d/proxysql-logs
0 0 * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 200  -a 3  -c >>/var/log/proxysql/log_retention.log 2>&1
0 0 * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 1000 -a 30 -c >>/var/log/proxysql/log_retention.log 2>&1
```

Files in `/etc/cron.d/` must be owned by root, mode `0644`, include the user
field, and end with a newline. For a user crontab (`crontab -e -u proxysql`),
omit the user field:

```cron
0 0 * * * /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 200 -a 3 -c >>/var/log/proxysql/log_retention.log 2>&1
```

Make sure the log directory exists and is writable by the cron user:

```bash
sudo install -d -o proxysql -g proxysql -m 0750 /var/log/proxysql
```

### systemd service and timer

`--install` generates and activates these units for you (see
[Service management](#service-management-systemd)). The examples below
document the manual setup.

A single `oneshot` service runs both prefixes in sequence. Output goes to the
journal without ANSI colors, because stdout is not a TTY.

```ini
# /etc/systemd/system/proxysql-log-retention.service
[Unit]
Description=ProxySQL events and audit log retention
After=proxysql.service

[Service]
Type=oneshot
User=proxysql
Group=proxysql
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 200 -a 3 -c
ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 1000 -a 30 -c
```

Once a day at 00:00:

```ini
# /etc/systemd/system/proxysql-log-retention.timer
[Unit]
Description=Run ProxySQL log retention daily at 00:00

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

`Persistent=true` runs a missed execution at the next boot if the server was
down at 00:00. To pin the schedule to a specific time zone regardless of the
server setting, use `OnCalendar=*-*-* 00:00:00 Atlantic/Canary` (systemd 235 or
newer).

Every 30 minutes instead, replace the `[Timer]` section with:

```ini
[Timer]
OnCalendar=*:0/30
Persistent=true
```

Enable and verify:

```bash
# Validate the expression and show the next trigger
systemd-analyze calendar '*-*-* 00:00:00'

sudo systemctl daemon-reload
sudo systemctl enable --now proxysql-log-retention.timer

# Next and last executions
systemctl list-timers proxysql-log-retention.timer

# Run once now, outside the schedule, and review the output
sudo systemctl start proxysql-log-retention.service
journalctl -u proxysql-log-retention.service --since today --no-pager
```

## Operational notes

- **Reduce the volume at the source.** Retention only treats the symptom. Check
  `mysql-eventslog_default_log` and the rules with `log = 1` in
  `mysql_query_rules`; a catch-all rule left over from troubleshooting is the
  usual cause. Binary format (`mysql-eventslog_format = 1`) is far more compact
  than JSON (`2`).
- **Deleted but still open files.** Removing the active file by hand does not
  free space because ProxySQL keeps the descriptor open. Detect it with
  `lsof +L1 | grep -i proxysql` and run `PROXYSQL FLUSH LOGS;` from the admin
  interface to reopen the log; the previous file then becomes a rotated file.
- **Audit log compliance.** Audit logs are often subject to retention policies.
  Prefer `--compress` with a policy-aligned `--max-age`, or archive rotated files
  to external storage (GCS, S3) before purging.
- **Age is based on mtime.** A rotated file's mtime is its last write, which is
  close to its rotation time.

## Local verification

Both suites use temporary directories only and never touch real ProxySQL or
system files:

```bash
bash proxysql/log_retention/tests/test_proxysql_eventslog_purge.sh
bash proxysql/log_retention/tests/test_service_management.sh
```

The purge suite covers argument validation, colored help and `NO_COLOR`,
dry-run, retention by count and age, protection of the active file, compression and re-runs, numeric ordering of suffixes,
prefix isolation between `query.log` and `audit.log`, and color suppression on
non-TTY output.

The service management suite runs only with `--root` on a temporary directory
or with `--dry-run`. It covers option validation, the generated service, timer
and logrotate files, several rotations on one host, the dir + prefix conflict
check, idempotent reinstall with backups, `append:` versus `sh -c` output,
custom options, the confirmation prompt (declined, accepted, and refused
without a terminal), `--list`, and `--uninstall`.
