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

## Layout

Repository (`mongodb/backupTool/`). `[pkg]` = shipped in the deployment
package (`packaging/build-dist.sh`), `[dev]` = repository only.

```
backupTool/
├── bin/
│   └── pbm-backup                    [pkg] entry point: full | incr | cleanup | restore | check | metrics
├── lib/                              [pkg] sourced by bin/pbm-backup
│   ├── common.sh                           logging, config, locking, portable dates
│   ├── mongo.sh                            mongosh wrapper, URI parsing, local node identity
│   ├── pbm.sh                              pbm CLI wrappers, backup metadata, PITR, retention
│   ├── compat.sh                           version/edition detection, PBM compatibility matrix
│   ├── topology.sh                         member health probes and node election
│   └── metrics.sh                          Prometheus textfile metrics
├── install.sh                        [pkg] install / upgrade (plan, config backups) / uninstall on a member
├── etc/
│   └── pbm-backup.conf.example       [pkg] tunables  -> /etc/sysconfig/pbm-backup
├── sysconfig/                        [pkg] environment files (templates) for /etc/sysconfig
│   ├── pbm-conf                            PBM_MONGODB_URI for pbm CLI + pbm-backup -> /etc/sysconfig/pbm-conf
│   ├── pbm-agent                           pbm-agent environment, every PBM 2.x     -> /etc/sysconfig/pbm-agent
│   └── pbm-physical-full-base              wrappers for the legacy units (install.sh --legacy-wrappers)
│       pbm-physical-incremental
│       pbm-deletion
├── conf/                             [pkg] PBM templates
│   ├── pbm-conf-gcp-hmac.yaml              PBM config: GCP bucket via S3 + HMAC key, any PBM 2.x -> pbm config --file
│   ├── pbm-conf-gcs.yaml                   PBM config: native gcs + service account key, PBM >= 2.10 -> pbm config --file
│   ├── pbm-conf.yaml                       PBM config reference with every option (storage, backup, PITR)
│   ├── pbm-agent.yaml                      pbm-agent config file, PBM >= 2.9         -> /etc/pbm-agent.yaml
│   └── pbm-agent-config.conf               systemd drop-in loading it, PBM >= 2.9   -> pbm-agent.service.d/
├── systemd/                          [pkg]
│   ├── services/pbm-backup-{full,incr,cleanup,metrics}.service
│   ├── timers/pbm-backup-{full,incr,cleanup,metrics}.timer
│   └── legacy/{services,timers}/           original pbm-physical-* / pbm-deletion units (reference, rollback)
├── mongodb/
│   └── pbmuser.create.js             [pkg] creates/fixes the PBM user and role (run by hand, once per replica set)
├── tools/
│   └── gcs-hmac-test.py              [pkg] checks a GCS HMAC key the way PBM < 2.10 uses it (INSTALL.md 1.2)
├── packaging/
│   └── build-dist.sh                 [dev] runs the tests, builds dist/pbm-backup-<version>.tar.gz + .sha256
├── tests/                            [dev]
│   ├── smoke.sh                            scenario tests (mocked pbm/mongosh)
│   ├── pbmuser.test.sh                     pbmuser.create.js in mongosh, fake admin DB
│   ├── install.test.sh                     install.sh lifecycle in a staging root (--destdir)
│   ├── mock/{pbm,mongosh}                  mocks reproducing real PBM output
│   └── fixtures/pbm-2.12.0-psmdb-8.0/      real (anonymized) pbm JSON output
├── README.md  INSTALL.md  CHANGES.md [pkg] docs (the package also adds VERSION)
└── CLAUDE.md  .gitignore             [dev]
```

What ends up on each member, and which files must be configured there
(pbm-backup and pbm-agent): [INSTALL.md §3](INSTALL.md#3-install-on-a-member).

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
- MongoDB >= 4.2 with a PBM release that supports it (INSTALL.md 1.1): 4.2 ->
  2.3.1, 4.4 -> 2.5.0, 5.0/6.0 -> 2.10.0, 7.0/8.0 -> current (8.0 needs >= 2.7.0);
  pin the package
  (`dnf versionlock add percona-backup-mongodb` / `apt-mark hold percona-backup-mongodb`).
- PBM storage: GCS bucket (filesystem storage needs NFS and is refused).
  PBM < 2.10 has no native GCS: use the S3-compatible endpoint
  (`storage.googleapis.com`), accepted as GCS (see INSTALL.md §13).
- The PBM user must have exactly the roles PBM documents; create or fix
  it with `mongodb/pbmuser.create.js` (see [INSTALL.md](INSTALL.md) 1.3).
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
tests/install.test.sh     # install.sh lifecycle (install, upgrade, downgrade, uninstall) in a staging root
```

Scenario tests with mocked `pbm` and `mongosh` and real PBM 2.12.0 JSON
output as fixtures. No MongoDB needed.

## Verified against PBM 2.5.0 (source)

- Every `pbm` command, option and JSON field used by pbm-backup exists with
  the same shape in v2.5.0 (`backup`, `cleanup`, `restore`, `status -s`,
  `describe-backup`, `list`, `config KEY -o json`, `config --set pitr.*`,
  `version`). Storage is reported as `S3` (no native GCS before 2.10).
- pbm-agent 2.5.0 reads only `PBM_MONGODB_URI` / `PBM_DUMP_PARALLEL_COLLECTIONS`
  (no config file before 2.9).
- `pbm status -o json` lists members as `<replset>/<host>:<port>` with an
  empty role for secondaries (2.12.0: `<host>:<port>`, `S`); pbm-backup
  normalizes both.

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
