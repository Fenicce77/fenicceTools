# pbm-backup

Backup runner for MongoDB replica sets built on
[Percona Backup for MongoDB](https://docs.percona.com/percona-backup-mongodb/) (PBM 2.x).
It picks the backup scheme from the server it finds, decides which member does
the work, and keeps an always-restorable, compressed backup set in a GCS bucket.

| Server | Scheme | `full` (daily) | `incr` |
|---|---|---|---|
| Percona Server for MongoDB with physical incremental support | physical | `pbm backup --type incremental --base` | hourly `pbm backup --type incremental` |
| MongoDB Community / Enterprise, older PSMDB | logical | `pbm backup --type logical` | every `OPLOG_INCR_MIN` (6h): check the PBM PITR oplog slices |

In the logical scheme PBM saves a compressed oplog slice every
`OPLOG_INCR_MIN` minutes (`pitr.oplogSpanMin`), chained from the last logical
full, so any point in time between fulls can be restored.

Change history against the original scripts: [CHANGES.md](CHANGES.md).

## How it works

Every member runs the same systemd timers. On each run, every member:

1. **Preflight**: detects the MongoDB version/edition (`buildInfo`) and the
   PBM version, checks the compatibility matrix, the storage type (bucket
   only) and the scheme rules (physical: PITR off).
2. **Election**: probes every member directly (pbm-agent, reachability,
   state, replication lag, queued operations, WiredTiger dirty cache, oplog
   window) and builds the same ordered list:
   1. the **owner**: member that took the last full;
   2. `PREFERRED_NODES`, in order;
   3. the rest by name.

   The **primary is never used** (unless `ALLOW_PRIMARY=true`). Only rank #0
   acts. Rank #N takes over after N x `FALLBACK_DELAY_SEC` if nobody started.
3. If the owner is down, has no healthy pbm-agent or is overloaded, the next
   member takes over. In the physical scheme it starts a **new base**, because
   an incremental chain cannot move between members.

PBM itself chooses the member that executes a backup by `backup.priority`;
pbm-backup checks afterwards and warns if it differs. Keep the primary lowest.

## Requirements

- Linux with systemd on every member; bash >= 3.2.
- `pbm` (PBM 2.x, same version as the pbm-agents), `jq`, `mongosh` (or the
  legacy `mongo` shell).
- MongoDB >= 4.2. 4.2/4.4 need PBM < 2.6.0; pin the package
  (`dnf versionlock add percona-backup-mongodb` / `apt-mark hold percona-backup-mongodb`).
- PBM storage: GCS bucket (filesystem storage needs NFS and is refused).
- The PBM user must have exactly the roles PBM documents; create or fix
  it with `mongodb/pbmuser.create.js` (see [INSTALL.md](INSTALL.md) 1.1).
  They cover the health probes (`clusterMonitor`) and the oplog window
  (read on `local.oplog.rs`).

## Install

Full deployment guide (package build, configuration, validation, switch-over
from the old units, upgrade, rollback, automation): [INSTALL.md](INSTALL.md).
Build the deployable package with `packaging/build-dist.sh`.

Quick version, on **every** member:

```bash
sudo ./install.sh --dry-run                    # see what it does
sudo ./install.sh --enable --disable-legacy    # PSMDB, replacing the old units
sudo ./install.sh --scheme logical --incr-every-min 360 --metrics --enable   # Community
```

Then put the connection string in `/etc/sysconfig/pbm-conf` (template:
[sysconfig/pbm-conf](sysconfig/pbm-conf)) and review
`/etc/sysconfig/pbm-backup` (all tunables, see
[etc/pbm-backup.conf.example](etc/pbm-backup.conf.example)). Debian-like
systems use `/etc/default` instead of `/etc/sysconfig`.

Validate before enabling the timers:

```bash
sudo pbm-backup check
```

`check` is read-only: versions, compatibility, storage, election table and
what `full`/`incr` would do on this member (plus PITR coverage in the
logical scheme).

## Commands

| Command | What it does | Log file |
|---|---|---|
| `full` | Daily full on the elected member | `incrbase.log` / `logical-full.log` |
| `incr` | Physical incremental, or oplog (PITR) check | `incr.log` / `oplog.log` |
| `cleanup` | Safe retention purge on the elected member | `deletion.log` |
| `restore` | Validated `pbm restore` by name or `--to TIME` | `restore.log` |
| `check` | Read-only diagnostics | none |
| `metrics` | Refresh Prometheus state metrics | none |

Common options: `--dry-run`, `--force` (skip election and duplicate guards),
`--config FILE`, `--env-file FILE`, `--no-color`. Every command has `--help`.

Exit codes: `0` success or skipped on purpose, `1` failure, `2` usage or
configuration error.

## Schedule (systemd)

| Timer | When | Notes |
|---|---|---|
| `pbm-backup-full.timer` | 00:00 | `Persistent=true`; `FULL_MIN_INTERVAL_SEC` (20h) prevents a second full after a reboot catch-up |
| `pbm-backup-incr.timer` | physical: 01:15..23:15 hourly; logical: drop-in every `OPLOG_INCR_MIN` | `Persistent=false` |
| `pbm-backup-cleanup.timer` | 00:40 | waits for a running backup |
| `pbm-backup-metrics.timer` | every 5 min | only with `--metrics` |

The old `pbm-physical-*` / `pbm-deletion` units are kept in
[systemd/legacy](systemd/legacy); with `install.sh --legacy-wrappers` the old
`/etc/sysconfig/pbm-*` scripts become wrappers around `pbm-backup`.

## Retention

`cleanup` computes `today - RETENTION_DAYS` (00:00 UTC) and moves the cutoff
back to the start of the newest full that started at/before it. Then it runs
`pbm cleanup --older-than <cutoff>`. Whole chains are deleted, never split,
and the newest valid full is never deleted, even if backups stopped. Use
`pbm-backup cleanup --dry-run` to see the list.

## Restore

```bash
pbm-backup restore --to 2026-10-05T11:30:00 --dry-run   # logical, point in time (UTC)
pbm-backup restore 2026-10-05T00:00:45Z                   # by backup name
```

`--to` picks the newest logical full before that time and checks that the
saved oplog covers it with no gap. PITR is disabled before the restore (PBM
requires it). Without `--yes` the replica set name must be typed. After a
restore take a new full: `pbm-backup full --force`. Physical restores also
need the PBM post-restore steps (restart mongod and pbm-agents,
`pbm config --force-resync`).

## Metrics

Set `METRICS_DIR` to a textfile-collector directory:

- node_exporter: `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`
- PMM2: `/usr/local/percona/pmm2/collectors/textfile-collector/low-resolution`
- PMM3: `/usr/local/percona/pmm/collectors/textfile-collector/low-resolution`

| Metric | Meaning |
|---|---|
| `pbm_backup_run_success{command}` / `_skipped` / `_duration_seconds` / `_last_timestamp_seconds` | last run of full, incr, cleanup on this member |
| `pbm_backup_last_restore_timestamp_seconds{kind}` | consistency point of the newest base / incremental / logical backup |
| `pbm_backup_last_size_bytes{kind}`, `pbm_backup_snapshots{status}` | sizes and counts |
| `pbm_pitr_enabled`, `pbm_pitr_running`, `pbm_pitr_coverage_ok`, `pbm_pitr_gaps`, `pbm_pitr_lag_seconds` | oplog slices (logical scheme) |
| `pbm_agent_ok{member}`, `pbm_backup_member_eligible{member}`, `pbm_oplog_window_seconds{member}`, `pbm_replication_lag_seconds{member}` | members |

Alert examples:

```promql
# No successful backup of the expected kind in 26h (physical: kind="base")
time() - max by (rs) (pbm_backup_last_restore_timestamp_seconds{kind="logical"}) > 26 * 3600
# Oplog slices not covering the chain (logical scheme)
min by (rs) (pbm_pitr_coverage_ok) == 0
# A run failed on any member
min by (rs, command) (pbm_backup_run_success) == 0
```

## Tests

```bash
tests/smoke.sh            # bash from PATH
tests/smoke.sh /bin/bash  # macOS bash 3.2
tests/pbmuser.test.sh     # pbmuser.create.js in mongosh, fake admin DB
```

Scenario tests with mocked `pbm` and `mongosh` and real PBM 2.12.0 JSON
output as fixtures. No MongoDB needed.

## Verified against PBM 2.12.0

- `pbm status [-s backups|-s running] -o json`, `pbm describe-backup -o json`
  (fixtures in `tests/fixtures/pbm-2.12.0-psmdb-8.0`).
- From the PBM 2.12.0 source (`cmd/pbm`, `pbm/oplog`): PITR ranges in
  `pbm list -o json` (`.pitr.ranges[].range.{start,end}`) and
  `pbm status -o json` (`.backups.pitrChunks.pitrChunks[].range`);
  `pbm config KEY -o json` (`{"key","value"}`; text mode prints `[KEY=VALUE]`);
  `pbm cleanup --older-than` / `pbm restore --time` accept
  `YYYY-MM-DDTHH:MM:SS` and `YYYY-MM-DD`, parsed as UTC.
- `pbm backup` accepts `--compression` (none/gzip/snappy/lz4/s2/pgzip/zstd)
  and `--compression-level` for every backup type; existing physical
  backups are already compressed (`size` < `size_uncompressed`).

## Not yet verified against a live cluster

- A real Community run with PITR enabled (formats checked in the source only).
- `buildInfo.psmdbVersion` (the `-N` version suffix is used as fallback).
- `globalLock.currentQueue` as an overload signal on MongoDB 8.0.
- Dynamic `backup.priority` to force the executing member is not
  automated (`pbm config --file` replaces the whole configuration).
