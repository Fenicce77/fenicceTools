# ProxySQL Log Retention

`proxysql_eventslog_purge.sh` enforces retention on ProxySQL events log
(`mysql-eventslog_filename`) and audit log (`mysql-auditlog_filename`) files.

ProxySQL rotates both logs by size (`mysql-eventslog_filesize`,
`mysql-auditlog_filesize`) and appends an incremental numeric suffix
(`query.log.00000001`, `query.log.00000002`, ...), but it never purges rotated
files. On busy instances, especially with `mysql-eventslog_default_log=1` or a
catch-all query rule with `log=1`, the log directory grows without limit.

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

## Installation

`install.sh` installs the purge script and, optionally, the systemd service and
timer, a `tmpfiles.d` entry that keeps the execution log directory in place,
and a logrotate policy for the execution log. Run it from a terminal without
options and it asks for every setting, shows the plan, and asks for
confirmation before writing anything:

```bash
git clone https://github.com/Fenicce77/fenicceTools.git
cd fenicceTools/proxysql/log_retention
sudo ./install.sh
```

```text
==> Configuration
? Install proxysql_eventslog_purge.sh into [/usr/local/bin]:
? Install systemd service and timer [Y/n]:
? ProxySQL log directory (--data-dir) [/data/proxysql]:
? Execution log directory [/data/log/purge_proxysql_eventslog]:
? Run the service as user [root]:
? Schedule (systemd OnCalendar) [*-*-* 00:00:00]:
? Purge the events log [Y/n]:
?   Events log prefix [query.log]:
?   Rotated events log files to keep [200]:
?   Max age in days (0 = off) [3]:
? Purge the audit log [Y/n]:
...
==> Installation plan
  Schedule:              *-*-* 00:00:00
  Run as:                root:root
  Execution log:         /data/log/purge_proxysql_eventslog/purge_proxysql_eventslog.log
  Events log:            query.log (keep 200, max-age 3d)
  Audit log:             audit.log (keep 1000, max-age 30d)
  Output mode:           StandardOutput=append: (systemd 252)
? Apply this configuration [Y/n]:
```

Every prompt has an equivalent option, so the same installation can be scripted
(`-y` disables prompts, missing options take the defaults):

```bash
# Preview every generated file and command, change nothing
./install.sh --systemd -y --dry-run

# Daily at 00:00 as root, logs in /data/log/purge_proxysql_eventslog (defaults)
sudo ./install.sh --systemd -y

# Every 6 hours, events log only, 7 days retention, no compression
sudo ./install.sh --systemd -y --no-audit --events-max-age 7 --no-compress \
    --schedule '*-*-* 00/6:00:00'

# Install the units but enable the timer later
sudo ./install.sh --systemd -y --no-enable

# Script only (no systemd), into another directory
sudo ./install.sh --script-only -y --bin-dir /opt/dbre/bin

# Render the files into a staging root (packaging, configuration management)
./install.sh --systemd -y --root /tmp/stage --systemd-version 239

# Remove units, tmpfiles, logrotate and script (execution logs are kept)
sudo ./install.sh --uninstall -y
```

| Option | Default | Description |
|---|---|---|
| `--systemd` / `--script-only` | ask | Install the systemd components, or only the script. Non-interactive runs without either install only the script. |
| `--uninstall` | | Disable the timer and remove every installed file except the execution logs. |
| `-y`, `--yes` | | No prompts. |
| `-i`, `--interactive` | auto | Force prompts even when stdin is not a terminal. |
| `-n`, `--dry-run` | | Print the plan, the generated files and the commands. |
| `--bin-dir DIR` | `/usr/local/bin` | Script destination. |
| `--data-dir DIR` | `/data/proxysql` | ProxySQL log directory (`-d` of the purge script). |
| `--log-dir DIR` | `/data/log/purge_proxysql_eventslog` | Execution log directory; the file is `purge_proxysql_eventslog.log`. |
| `--user NAME` | `root` | Service user. Non-root adds `User=`/`Group=` and `su` to logrotate. |
| `--schedule SPEC` | `*-*-* 00:00:00` | `OnCalendar=` expression, validated with `systemd-analyze calendar`. |
| `--events-prefix`, `--events-keep`, `--events-max-age` | `query.log`, `200`, `3` | Events log retention. `--no-events` disables it. |
| `--audit-prefix`, `--audit-keep`, `--audit-max-age` | `audit.log`, `1000`, `30` | Audit log retention. `--no-audit` disables it. |
| `--no-compress` | | Do not pass `-c` to the purge script. |
| `--no-hardening` | | Omit `ProtectSystem=strict`, `ReadWritePaths=` and related sandboxing. |
| `--no-logrotate` | | Do not install `/etc/logrotate.d/purge_proxysql_eventslog`. |
| `--no-enable` | | Do not run `systemctl enable --now` on the timer. |
| `--systemd-version N` | detected | Selects `StandardOutput=append:` (>= 240) or `sh -c` redirection (older, e.g. RHEL 8). |
| `--root DIR` | | Write under an alternate root; no `systemctl` or `systemd-tmpfiles` calls. |

Installed files:

| File | Purpose |
|---|---|
| `/usr/local/bin/proxysql_eventslog_purge.sh` | Purge script. |
| `/etc/systemd/system/proxysql-log-retention.service` | Oneshot service, one `ExecStart=` per enabled log. |
| `/etc/systemd/system/proxysql-log-retention.timer` | Schedule (`Persistent=true`). |
| `/etc/tmpfiles.d/purge_proxysql_eventslog.conf` | Creates the execution log directory at boot. |
| `/etc/logrotate.d/purge_proxysql_eventslog` | Monthly rotation of the execution log, 12 copies. |

Re-run the installer to change the configuration. Files that do not change are
left untouched; files that change are backed up as `<file>.bak.<timestamp>`.
`--log-dir` must be a dedicated directory, different from `--data-dir`:
`tmpfiles.d` enforces its mode and owner, and logrotate rotates every `*.log`
in it, so system or shared directories such as `/var/log` are refused.
The installer requires root unless `--dry-run` or `--root` is used. On hosts
without systemd (for example macOS) use `--script-only`.

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

Exit status is `0` on success (including when no matching files exist) and `1`
on invalid arguments, a missing directory, or a missing `gzip` with
`--compress`.

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

`install.sh --systemd` generates and activates these units for you (see
[Installation](#installation)). The examples below document the manual setup.

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
bash proxysql/log_retention/tests/test_install.sh
```

The purge suite covers argument validation, colored help and `NO_COLOR`,
dry-run, retention by count and age, protection of the active file, compression and re-runs, numeric ordering of suffixes,
prefix isolation between `query.log` and `audit.log`, and color suppression on
non-TTY output.

The installer suite runs only with `--root` on a temporary directory or with
`--dry-run`. It covers option validation, script-only and systemd installs,
`append:` versus `sh -c` output for systemd 240+ and older, custom options,
idempotent reinstall with backups, interactive answers, re-prompting on
invalid values, aborting, and uninstall.
