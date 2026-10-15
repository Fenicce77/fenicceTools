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
- Colors are emitted only when stdout is a TTY, so cron and log output stay
  clean.

## Requirements

- Linux or macOS, Bash 3.2 or newer.
- `find`, `du`, `awk`, `sort`.
- `gzip` when `--compress` is used.
- `lsof` (optional, recommended): skips files still opened by a process.
- Write access to the log directory: run as the ProxySQL service user or root.

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

Install the script and run it from cron as the user that owns the log
directory:

```bash
sudo install -m 0755 proxysql_eventslog_purge.sh /usr/local/bin/
```

```cron
# /etc/cron.d/proxysql-logs
*/30 * * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 20  -a 3  -c >/dev/null 2>&1
*/30 * * * * proxysql /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 1000 -a 30 -c >/dev/null 2>&1
```

Equivalent systemd timer:

```ini
# /etc/systemd/system/proxysql-eventslog-purge.service
[Unit]
Description=ProxySQL events log retention

[Service]
Type=oneshot
User=proxysql
ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 20 -a 3 -c
```

```ini
# /etc/systemd/system/proxysql-eventslog-purge.timer
[Unit]
Description=Run ProxySQL events log retention every 30 minutes

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now proxysql-eventslog-purge.timer
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

The test suite builds temporary fixture directories only and never touches real
ProxySQL files:

```bash
bash mysql/proxysql/log_retention/tests/test_proxysql_eventslog_purge.sh
```

It covers argument validation, dry-run, retention by count and age, protection
of the active file, compression and re-runs, numeric ordering of suffixes,
prefix isolation between `query.log` and `audit.log`, and color suppression on
non-TTY output.
