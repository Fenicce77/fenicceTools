# Changes

Changes to the original PBM physical-backup scripts (snapshot taken on
2026-10-02, before any edit). The full original code is preserved below as the
removed side of the diffs.

## Files

| Path | Status |
|---|---|
| `conf/pbm-agent.yaml`, `conf/pbm-conf.yaml` | Unchanged (template fixes planned for phase 6) |
| `systemd/services/*`, `systemd/timers/*` | Unchanged (still call `/etc/sysconfig/pbm-*`) |
| `sysconfig/pbm-agent`, `sysconfig/pbm-conf` | Unchanged |
| `sysconfig/pbm-physical-full-base` | Rewritten as a wrapper: `exec pbm-backup full` |
| `sysconfig/pbm-physical-incremental` | Rewritten as a wrapper: `exec pbm-backup incr` |
| `sysconfig/pbm-deletion` | Rewritten as a wrapper: `exec pbm-backup cleanup` |
| `bin/pbm-backup` | New: single entry point (`full`, `incr`, `cleanup`, `check`) |
| `lib/common.sh` | New: logging, config, dependencies, locking, portable dates |
| `lib/mongo.sh` | New: mongosh/mongo wrapper, URI parsing, local node identity |
| `lib/pbm.sh` | New: pbm CLI wrappers, busy detection, backup metadata (JSON) |
| `lib/compat.sh` | New: version/edition detection, PBM compatibility matrix, strategy |
| `lib/topology.sh` | New: per-node health probes and node election |
| `etc/pbm-backup.conf.example` | New: all tunables with defaults |
| `tests/` | New: smoke tests, pbm/mongosh mocks, PBM 2.12.0 fixtures |

## Where the original logic went

| Original | Now |
|---|---|
| `log_message` (copied in 3 scripts) | `log` in `lib/common.sh` |
| `` REPLSET=`echo $PBM_MONGODB_URI\|awk -F'&' ...` `` | `uri_param "$PBM_MONGODB_URI" replicaSet` (any position) |
| mongosh query on `admin.pbmBackups` + `grep`/`sed`/`tr` | `last_done_backup_json` in `lib/pbm.sh` (`pbm status -s backups` + `pbm describe-backup -o json`) |
| `grep -ci "${LOCALHOSTNAME}"` node guard | Node election in `lib/topology.sh` (`elect_nodes`, `is_local_node`) |
| `pbm backup --type incremental --base -w` | `run_physical full` in `bin/pbm-backup` |
| `pbm backup --type incremental -w` | `run_physical incr` in `bin/pbm-backup` |
| `pbm cleanup -y --older-than $(date -d ...) -w` | `cmd_cleanup` + `date_days_ago` (GNU and BSD `date`) |
| `${PBLOCALROOTMDIR}/${REPLSET}.lastbackup.index` | Still written (JSON line) by `full`/`incr` |
| Log files `incrbase.log`, `incr.log`, `deletion.log` | Same names, same `[PSMB][BACKUP]...` labels |

## Phase 1 - refactor and bug fixes

Bugs fixed:

1. Every log line of a run had the same timestamp: messages were built at
   script start. Production logs showed `END` at 15:15:10 for a backup that
   finished at 15:15:37. Timestamps are now taken when each line is written.
2. `pbm-physical-incremental` wrote the empty `PBMMSGBKPINFO` to the log
   instead of the finish message.
3. `pbm-physical-full-base` used `${REPLSET}` before defining it.
4. The full backup had no guard: with the timer on every node, all nodes
   launched a base at the same time. (Mitigated in phase 1, solved in phase 3.)
5. The node guard was a case-insensitive substring match (`node01` matched
   `node010`) on `hostname`.
6. Color variables were never defined.
7. Replica set name parsing depended on parameter order; port 27017 was
   hard-coded in `sed`.

Also: `set -euo pipefail`, `#!/usr/bin/env bash`, `--help` everywhere,
`--dry-run`, per-node lock (`flock` or `mkdir` fallback), errors to stderr,
exit codes 0/1/2 instead of `-1` (255), bash 3.2 compatible.

PBM metadata moved from the internal `admin.pbmBackups` collection to the
documented JSON output, verified against PBM 2.12.0:
`pbm status -s backups -o json` (base = `type: incremental`, `src: ""`) and
`pbm describe-backup <name> -o json` (`replsets[].node`). Busy detection:
`.running` is `{}` when idle; any non-empty object counts as busy.

## Phase 2 - detection and compatibility

- MongoDB version/edition from `buildInfo` (`psmdbVersion` or `-N` suffix ->
  PSMDB; `modules` contains `enterprise` -> Enterprise; else Community).
- PBM version from `pbm version`; pbm-agent version and health from
  `pbm status`.
- Compatibility matrix (`lib/compat.sh`): MongoDB 4.0 needs PBM 1.x;
  4.2/4.4 unsupported from PBM 2.6.0; 4.2 deprecated from PBM 2.3.0;
  package pinning advice on 4.x.
- Strategy: physical for PSMDB with physical incremental support, logical
  otherwise (`BACKUP_MODE` overrides).
- Physical scheme requires PITR disabled.

## Phase 3 - node election

- Every node probes every member (`directConnection=true`): pbm-agent,
  reachability, state, replication lag, `globalLock.currentQueue`,
  WiredTiger dirty cache.
- Order: chain owner (node of the last base), `PREFERRED_NODES`, name.
  The primary is never used unless `ALLOW_PRIMARY=true`.
- Only rank #0 runs; rank #N takes over after N x `FALLBACK_DELAY_SEC`
  if nobody started a backup.
- `incr` on a node that does not own the chain takes a new base.
- After the backup, the node PBM actually used is checked and reported.
- New read-only `pbm-backup check` command.

Behavior changes vs. the original scripts:

| Situation | Before | Now |
|---|---|---|
| `incr` with no base backup | silently skipped (exit 0) | rank #0 takes a base |
| `incr` on the node that did not take the base | skipped | skipped (or takes over as new base if the owner is unavailable) |
| `full` launched on all nodes | concurrent bases, failures | one base, others skip |
| Host not found among members | substring match / skip | error, set `LOCAL_NODE_NAMES` |
| Failure exit code | 255 | 1 |
| mongosh | used for metadata | used for detection and health probes |

## Phase 4 - logical scheme (Community)

Selected automatically for MongoDB Community/Enterprise, for PSMDB versions
without physical incremental support, or with `BACKUP_MODE=logical`.
No hand-rolled mongodump/oplog tailing: PBM logical snapshots + PBM PITR.

- `full` -> `pbm backup --type logical --wait` on the elected node (same
  election as phase 3). Log: `logical-full.log`, labels `[MONGODB][BACKUP][LOGICAL][FULL]`.
  - Before: the oplog window of this node (`local.oplog.rs`, newest minus
    oldest `wall`) must be >= `OPLOG_WINDOW_FACTOR` (2) x the expected dump
    time (`EXPECTED_DUMP_SEC`, or the previous logical backup's duration).
  - After: `PITR_AUTOCONFIG=true` sets `pitr.enabled=true` and
    `pitr.oplogSpanMin=OPLOG_INCR_MIN` (360 = an oplog slice every 6h).
- `incr` -> oplog (PITR) check, no backup. Log: `oplog.log`, labels
  `[MONGODB][BACKUP][LOGICAL][OPLOG]`. Fails if PITR is disabled, if the saved
  oplog does not cover the last logical snapshot's `restoreTo`, if there is a
  gap after it, or if the newest saved oplog is older than
  `OPLOG_INCR_MIN` x 60 + `PITR_LAG_MARGIN_SEC`. Only the elected node runs it.
- `check` also reports PITR state, restorable window and gaps.
- The physical scheme still requires PITR disabled.

## Storage, compression and restore

- Backups always go to a bucket: preflight fails unless the PBM storage type
  (`pbm status` `.backups.type`) is in `REQUIRED_STORAGE_TYPES` (default `GCS`).
  PBM `filesystem` storage is rejected: it needs a path shared by every node.
- Backups are always compressed: every `pbm backup` gets
  `--compression=$BACKUP_COMPRESSION --compression-level=$BACKUP_COMPRESSION_LEVEL`
  (default gzip 5, same as `conf/pbm-conf.yaml`); `none` is rejected. Oplog
  slices: `pitr.compression`/`pitr.compressionLevel` are set with
  `PITR_AUTOCONFIG=true`, and the oplog check fails if `pitr.compression=none`.
- New `restore` command (log `restore.log`):
  - `restore BACKUP_NAME`: checks the backup exists and is `done`, then
    `pbm restore NAME` (`--wait` for logical; physical prints the post-restore
    steps).
  - `restore --to TIME`: picks the newest logical full with `restoreTo <= TIME`,
    checks the saved oplog covers `restoreTo..TIME` with no gap, then
    `pbm restore --time=TIME --wait`.
  - Disables PITR first when it is on (PBM requirement); reminds to take a
    new full afterwards. `--dry-run` prints the validated plan; without `--yes`
    the replica set name must be typed (refused when not on a TTY).

## Phase 5 - retention and metrics

Retention (`cleanup`):

- Runs only on the elected node (same election, no takeover); the original
  script ran on every node.
- The cutoff `today - RETENTION_DAYS` (00:00 UTC) is moved back to the start
  of the newest full backup (base or logical) that started at/before it, and
  `pbm cleanup -y --older-than <that time> --wait` runs. Chains are deleted
  whole, never split; the full that covers the cutoff and its oplog slices
  stay; the newest valid full is never deleted, even if backups stopped.
  Example with the PBM 2.12.0 fixture and a 2026-09-28 cutoff: the base of
  2026-09-28 starts at 00:00:45, so the 2026-09-27 chain (which covers
  00:00:00-00:00:45) is kept and only the 48 backups of 09-25 and 09-26 go.
- After the cleanup it verifies that the newest full is still listed.
- `--dry-run` prints the plan, including which backups would be deleted.

Metrics (optional, `METRICS_DIR`):

- `pbm_backup_run_<command>.prom` (full, incr, cleanup): last run timestamp,
  duration, success, skipped. Not written on `--dry-run`.
- `pbm_backup_state.prom`: restoreTo and size of the newest backup of each
  kind (base, incremental, logical), backups by status, PITR enabled/running,
  oplog coverage/gaps/lag (logical scheme), pbm-agent health, member
  eligibility, oplog window and replication lag per member.
- Atomic writes (temp file + mv); a metrics failure never fails a backup.
- New `metrics` command to refresh the state file from a frequent timer.

## Phase 6 - systemd, installer, templates, docs

- New units `pbm-backup-{full,incr,cleanup,metrics}.{service,timer}`
  (`AccuracySec=1s` so members start together). The incr timer follows the
  production schedule (01:15..23:15, `Persistent=false`); the Community
  scheme gets a drop-in with an every-`OPLOG_INCR_MIN` schedule. The old units
  moved to `systemd/legacy/` unchanged.
- `FULL_MIN_INTERVAL_SEC` (20h): `full` skips if the last full is more recent,
  so a `Persistent=true` catch-up after a reboot cannot take an extra full
  (including through the standby takeover path).
- `install.sh`: installs bin, libraries, docs, config (never overwritten) and
  units; `--scheme`, `--incr-every-min`, `--metrics`, `--enable`,
  `--legacy-wrappers`, `--disable-legacy`, `--dry-run`.
- Config files are looked up in `/etc/default` when `/etc/sysconfig` does
  not exist (Debian-like systems).
- Templates: `conf/pbm-agent.yaml` fixed (`log.level` indentation, host
  typo, placeholders instead of credentials, cluster settings removed);
  `conf/pbm-conf.yaml` documents what pbm-backup manages (PITR, priorities,
  compression) and that filesystem storage is not supported; generic host
  names.
- `README.md`.

## Fixes after checking the PBM 2.12.0 source

- `pbm config KEY` prints `[KEY=VALUE]` in text mode, so the value was never
  matched: on the logical scheme every run re-applied `pbm config --set`,
  reported false mismatches and could not detect `pitr.compression=none`.
  Now read with `-o json` (`{"key","value"}`). The test mock reproduces the
  real output, and the old parser fails three scenarios.
- Confirmed from the source: PITR range JSON (`pbm list`, `pbm status`) and
  the `YYYY-MM-DDTHH:MM:SS` UTC format of `--older-than` / `--time`.

## Packaging (0.6.0)

- `packaging/build-dist.sh`: runs the tests and builds
  `dist/pbm-backup-<version>.tar.gz` plus `.sha256` (explicit file list, no
  tests/fixtures, owner root, no macOS metadata).
- `install.sh`: records the installed version (`share/doc/pbm-backup/VERSION`),
  reports upgrades, `--uninstall` (keeps configuration and logs; warns about
  legacy wrappers), `--destdir` (staging root, no systemctl) and
  `--sysconfdir`; documented exit codes.
- `INSTALL.md`: installation and deployment guide.
- Version 0.6.0.

## PBM user script (0.6.1)

- `mongodb/pbmuser.create.js` (moved from `mongodb/js_scripts/`): creates
  or fixes the `pbmAnyAction` role and the PBM user with exactly the roles
  in the PBM documentation (`readWrite` admin, `backup`, `clusterMonitor`,
  `restore`, `pbmAnyAction`). The first version created `pbmAnyAction`
  without granting it, and granted `clusterAdmin`, `readWriteAnyDatabase`
  and `userAdminAnyDatabase`, which PBM does not need.
- Idempotent: an existing role/user is updated (extra roles removed and
  reported). Its password is kept unless `PBM_ROTATE_PASSWORD=1`.
- Password generated (32 alphanumeric) or typed twice
  (`PBM_PASSWORD_MODE=prompt`), shown in plain text and saved to
  `~/.pbm-backup/<user>.<rs>.<ts>.env` (0700/0600, never overwritten) with
  ready `PBM_MONGODB_URI` lines (URI-encoded).
- Requires the primary; writes with `w: majority`.
- `tests/pbmuser.test.sh`: 45 checks in mongosh with a fake admin database.
  Shipped in the package and installed in the doc directory.

## pbm-conf on install (0.6.2)

- `install.sh` now creates `/etc/sysconfig/pbm-conf` from the template when
  it does not exist (mode 0600) and warns that it must be filled in. It
  never overwrites an existing one (install, upgrade, uninstall). Until
  0.6.1 it only warned, so a fresh install had no connection file.
- Templates `sysconfig/pbm-conf` and `sysconfig/pbm-agent` use explicit
  placeholders (`<pbm_user>`, `<pbm_password>`, `<replica_set>`) instead of
  realistic-looking values, and `pbm-conf` lists the members (seed list).
- `pbm-backup` refuses to run (exit code 2) while `PBM_MONGODB_URI` still
  holds placeholders or the old template password, instead of failing to
  authenticate.

## PBM 2.5.0 / MongoDB 4.4 (0.6.3)

Review of every PBM interaction against the PBM 2.5.0 source, the last
release that supports MongoDB 4.4 (2.6.0 dropped it).

- All commands, options and JSON fields used exist with the same shape in
  2.5.0. Two gaps fixed:
  - Storage: PBM < 2.10 has no native GCS, so the bucket is configured as
    S3 with the `storage.googleapis.com` endpoint and `pbm status` reports
    `S3`. pbm-backup rejected it with the default `REQUIRED_STORAGE_TYPES=GCS`;
    it now treats S3 on `storage.googleapis.com` as GCS. Clearer rejection
    message (type, path, allowed types).
  - Compatibility matrix: PBM dropped MongoDB 4.2 in 2.4.0, not 2.6.0
    (PBM 2.4.x/2.5.x with 4.2 was accepted).
- `check`: before the first logical full, PITR disabled is a warning, not
  an error (the first full enables it).
- pbm-agent templates by PBM version: `sysconfig/pbm-agent` (environment,
  every PBM 2.x, the only option on 2.0 - 2.8), `conf/pbm-agent.yaml`
  (PBM >= 2.9, verified keys) and the new `conf/pbm-agent-config.conf`
  systemd drop-in that loads it. `conf/pbm-conf.yaml` gains the
  GCS-through-S3 block for PBM < 2.10.
- INSTALL.md: §4.3 agent configuration, §13 MongoDB 4.4 / PBM 2.5.0 with the
  downgrade procedure. Tests: 8 new scenarios (153 total).

## PBM 2.5.0 status format fix (0.6.4)

Found on the first real run on MongoDB 4.4 / PBM 2.5.0 (every member was
skipped, probes returned nothing).

- PBM 2.5.0 `pbm status -o json` reports members as `<replset>/<host>:<port>`
  and leaves the role of secondaries empty (`cmd/pbm/status.go`:
  `Host: c.RS + "/" + n.Host`, roles set only for P/A/D/H); PBM 2.12.0
  reports `<host>:<port>` and `S`. pbm-backup used the prefixed string as a
  host name: health probes failed, the local member could not be
  recognised and secondaries showed `role=?`. Members are now normalized
  (prefix stripped, empty role shown as `S`) in the election, the
  preflight agent warnings and the `pbm_agent_ok` metric.
- When a pbm-agent is not ok, the agent version (`NOT FOUND`, ...) and the
  errors reported by PBM are now shown in the preflight warning and in the
  election `SKIP(...)` reason.
- Tests use the real PBM 2.5.0 cluster format (8 new scenarios, 160 total);
  without the fix 7 scenarios fail.

## PBM install and GCS credentials docs, full compatibility matrix (0.6.5)

- INSTALL.md §1 reorganized:
  - §1.1 (new): PBM package by MongoDB version, from the version gate in
    the PBM source of every 2.x release. Covers a fresh install (EL and
    Debian/Ubuntu, pinned) and replacing a non-matching version in place
    (downgrade/upgrade, `.rpmsave` caveat, adjustments below 2.9/2.10).
  - §1.2 (new): GCS bucket credentials by PBM version. HMAC key (PBM < 2.10
    as `type: s3`, required; PBM >= 2.10 as `gcs` + `hmacAccessKey`/
    `hmacSecret`, optional) vs service account JSON key (`clientEmail`/
    `privateKey`, PBM >= 2.10 only). Service account, bucket IAM, prefix
    per replica set, organization policies, apply and verify.
  - §1.3: the PBM user (was §1.1). §13 now points to §1.1/§1.2.
- Compatibility matrix completed from the PBM source: MongoDB 5.0/6.0 were
  dropped in PBM 2.11.0 (2.10.0 is the last release for them), MongoDB 8.0
  needs PBM >= 2.7.0 and 7.0 PBM >= 2.4.0. These combinations were accepted
  before and PBM then refused the replica set. Pin advice for 5.0/6.0 too.
- `tools/gcs-hmac-test.py` (shipped and installed in the doc directory):
  tests a GCS HMAC key the way PBM < 2.10 uses it and prints the GCS error
  code behind a 403.
- `conf/pbm-conf.yaml`: S3 block region = bucket location.
- Tests: 6 new matrix scenarios (166 total).

## Installer: upgrade detection, plan, configuration backups (0.6.6)

- `install.sh` detects the installed version and runs as install, upgrade,
  reinstall or downgrade (downgrade refused without `--allow-downgrade`;
  `--upgrade` requires an installed version).
- Before changing anything it prints a plan: install options, files new /
  changed / removed / unchanged, configuration backups, new settings in the
  example config and the CHANGES.md sections newer than the installed
  version. `--dry-run` stops there.
- Install options (`--scheme`, `--incr-every-min`, `--metrics`,
  `--legacy-wrappers`) are kept from the previous install unless given
  again (`share/doc/pbm-backup/install.state`, inferred for older installs).
  Before, re-running without `--scheme logical` removed the logical drop-in.
- Upgrade/reinstall/downgrade copy the configuration files to
  `<file>.<mode>.<installed version>.<UTC time>` and keep them in place;
  `--fresh-config` renames them and installs the templates.
- `--uninstall` renames the configuration files (`<file>.uninstall.<version>.
  <UTC time>`), pbm-backup legacy wrappers included; `--keep-config` keeps
  the previous behaviour.
- Files no longer shipped are removed on upgrade.
- `tests/install.test.sh`: 71 lifecycle checks in a `--destdir` root (run by
  `build-dist.sh`).

## PBM storage templates (0.6.7)

- Two ready-to-use PBM configuration templates (`pbm config --file`), each
  with its section uncommented:
  - `conf/pbm-conf-gcp-hmac.yaml`: GCP bucket through the S3-compatible API
    with an HMAC key (`type: s3`). Every PBM 2.x; the only option below 2.10
    (MongoDB 4.2/4.4) and the only way to use HMAC from PBM 2.16.
  - `conf/pbm-conf-gcs.yaml`: native `gcs` with a service account JSON key,
    PBM >= 2.10 (Workload Identity >= 2.13 and HMAC 2.10 - 2.15 commented).
  Both explain that `pbm config --file` replaces the PITR section too
  (commented Community values to keep PITR on when re-applying).
- Correction (checked in the PBM source): HMAC credentials exist in the
  `gcs` type only in PBM 2.10 - 2.15; 2.16 removed them (`gcs` takes
  `clientEmail`/`privateKey` or `workloadIdentity`). INSTALL.md §1.2 said
  "PBM >= 2.10: optional HMAC"; with PBM >= 2.16 HMAC needs `type: s3`.
- `backup.numParallelCollections` exists from PBM 2.7 (not in 2.5): marked in
  the templates.

## Installer: configuration files with confirmation, log directories, .yml (0.6.8)

- The package copies are edited before running `install.sh`, which copies
  them: `sysconfig/pbm-conf` -> `pbm-conf` and the new editable
  `etc/pbm-backup.conf` -> `pbm-backup` always; with `--pbm-agent-env`,
  `--pbm-agent-yml` (refused on PBM < 2.9) and `--pbm-storage hmac|gcs`
  also the agent environment, the agent `.yml` + drop-in and
  `/etc/pbm-storage.conf`. A missing file is copied; an existing one is
  replaced only by an edited copy (saved first as `<file>.replaced.<ts>` or
  the upgrade copy); an unedited template never overwrites it.
- The copies are listed in the plan and need a confirmation. Templates
  still holding `<placeholders>` (or the default `pbm-backup`) show a
  WARNING and need a second one; after the run, every managed file still
  holding placeholders is listed with what to set. `--yes` answers both;
  no terminal and no `--yes` -> exit 2; declined -> exit 3, nothing changed.
  Before, `pbm-conf` and `pbm-backup` were only created when missing.
- `install.sh` creates `PBM_LOCAL_ROOT` and `LOG_DIR` (0750, from the
  configuration in effect) and the pbm-agent log directory (`log.path` of
  `/etc/pbm-agent.yml`, agent user) when missing, and writes
  `/etc/logrotate.d/pbm-backup` (and `pbm-agent`, copytruncate) with a
  "Managed by" marker; files without it are never touched.
  `--no-logrotate` / `--logrotate` (kept in `install.state`). Uninstall
  removes the pbm-backup rule only.
- PBM templates renamed `.yaml` -> `.yml`, as in the Percona packages:
  `conf/pbm-conf.yml`, `pbm-conf-gcp-hmac.yml`, `pbm-conf-gcs.yml`,
  `pbm-agent.yml`.
- INSTALL.md: section 4 starts with the table of configuration files
  (package file, destination, owner/mode, flag, what to edit, PBM
  versions) and the copy rules; new section 4.4 (log directories and
  rotation for pbm-backup and pbm-agent by PBM version).
- `build-dist.sh` refuses to package an edited `etc/pbm-backup.conf` or a
  `sysconfig/pbm-conf` without placeholders.
- `tests/install.test.sh`: 138 checks (confirmations, edited / unedited
  copies, replace with backup, agent and storage files, log dirs, logrotate).

## Diffs of the replaced scripts

<details>
<summary><code>sysconfig/pbm-physical-full-base</code></summary>

```diff
--- a/sysconfig/pbm-physical-full-base
+++ b/sysconfig/pbm-physical-full-base
@@ -1,92 +1,9 @@
-#!/usr/bin/bash
-
-. /etc/sysconfig/pbm-conf
-
-# Log message function
-function log_message(){
-
-        LABEL=$2
-        MESSAGE_HEAD_LINE="[`date +"%Y-%m-%d %H:%M:%S"`]${LABEL}"
-
-
-        case "$3" in
-                'OK' ) MESSAGE_TYPE="${grn}${MESSAGE_HEAD_LINE}[OK]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[OK]"
-                        ;;
-                'INFO' ) MESSAGE_TYPE="${blu}${MESSAGE_HEAD_LINE}[INFO]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[INFO]"
-                        ;;
-                'ERROR' ) MESSAGE_TYPE="${red}${MESSAGE_HEAD_LINE}[ERROR]"
-                                  MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[ERROR]"
-                        ;;
-                'WARNING' ) MESSAGE_TYPE="${yel}${MESSAGE_HEAD_LINE}[WARN]"
-                                        MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[WARN]"
-                        ;;
-
-        esac
-
-        case "$1" in
-                'STANDARD' ) MESSAGE_HEAD="${MESSAGE_TYPE}"
-                        ;;
-                'LOG' ) MESSAGE_HEAD="${MESSAGE_TYPE_LOG}"
-                        ;;
-        esac
-        MSG=$4
-
-        #MESSAGE_HEAD="${MESSAGE_TYPE}"
-        echo "${MESSAGE_HEAD} ${MSG} ${off}"
-}
-
-# Main Global Variables
-GREPBINPATH=`which grep`
-PBMBINPATH=`which pbm`
-MONGOSHBINPATH=`which mongosh`
-PBLOCALROOTMDIR="/data/backup/pbm"
-PBLOGROOTMDIR="/data/backup/pbm/logs"
-BASELOGFILE="${PBLOGROOTMDIR}/incrbase.log"     
-INCRLOGFILE="${PBLOGROOTMDIR}/incr.log"
-LASTBACKUPFNAME="${PBLOCALROOTMDIR}/${REPLSET}.lastbackup.index"
-LOCALHOSTNAME=`hostname`
-REPLSET=`echo $PBM_MONGODB_URI|awk -F'&' '{print $2}'|awk -F'=' '{print $2}'`
-EXITCODE=0
-
-# Main Output Messages
-SRVMSGINIT=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][INIT]" "INFO" "MongoDB Base Incremental Backup Service Initiating"`
-SRVMSGFINISH=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][END]" "INFO" "MongoDB Base Incremental Backup Service Ended"`
-
-PBMRUNSTARTINFO=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][PBM][RUN][START]" "INFO" "MongoDB Base Incremental Backup Starting!!"`
-RUNFINISHINFO=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][RUN][FINISH]" "INFO" "MongoDB Base Incremental Backup Finished!!"`
-
-PBMMSGOK=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][PBM][RUN][FINISH][OK]" "OK" "PBM - MongoDB Incremental Base Backup Successfully DONE!!"`
-PBMMSGKO=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][PBM][RUN][FINISH][ERROR]" "ERROR" "PBM - MongoDB Incremental Base Backup Failed!! Please check pbm-agent logs!! Exiting"`
-
-# MongoDB Queries in JS
-JSQRYLASTBASEBKPOK='db.getSiblingDB("admin").pbmBackups.find({status: "done",src_backup: { $exists: false }},{ opid: 1, name: 1, "replsets.node": 1 , "n.ack": 1 }).sort({start_ts: -1}).limit(1).forEach(printjson)'
-
-
-echo "${SRVMSGINIT}" && echo "${SRVMSGINIT}" >> ${BASELOGFILE}
-# Mongodb query to retrieve last backup successfully done
-
-# If Last Backup Ran in current host, next incremental will be ran, if not exit
-echo "${PBMRUNSTARTINFO}" && echo "${PBMRUNSTARTINFO}" >> ${BASELOGFILE}
-${PBMBINPATH} backup --type incremental --base -w
-if [[ $? -ne 0 ]]; then
-# pbm execution failed 
-        EXITCODE=-1
-else
-        LASTBKPINFO=`$MONGOSHBINPATH ${PBM_MONGODB_URI} --eval "${JSQRYLASTBASEBKPOK}" |grep 'opid\|status\|name\|node\|ack'|sed 's/\:27017//g'|tr -s '[:space:]'|tr -s ',' '|'|tr -d '\n'`
-        PBMMSGBKPINFO=`log_message "LOG" "[PSMB][BACKUP][BASE][INCREMENTAL][PBM][RUN][OK][INFO]" "INFO" "MongoDB Incremental Base Full Backup Info: [${LASTBKPINFO}]"`
-fi
-
-case $EXITCODE in
-        0) echo ${PBMMSGOK} && echo "${PBMMSGOK}" >> ${BASELOGFILE}
-           echo ${PBMMSGBKPINFO} && echo "${PBMMSGBKPINFO}" >> ${BASELOGFILE}
-           ;;
-        -1) echo ${PBMMSGKO} && echo "${PBMMSGKO}" >> ${BASELOGFILE}
-           ;;
-esac
-
-echo ${SRVMSGFINISH} && echo "${SRVMSGFINISH}" >> ${BASELOGFILE}
-
-
-exit ${EXITCODE}
+#!/usr/bin/env bash
+#
+# pbm-physical-full-base - compatibility wrapper kept so existing systemd units
+# (ExecStart=/etc/sysconfig/pbm-physical-full-base) keep working.
+# Daily physical incremental BASE backup.
+#
+# All logic lives in pbm-backup; run "pbm-backup full --help" for details.
+set -euo pipefail
+exec "${PBM_BACKUP_BIN:-/usr/local/bin/pbm-backup}" full "$@"
```

</details>

<details>
<summary><code>sysconfig/pbm-physical-incremental</code></summary>

```diff
--- a/sysconfig/pbm-physical-incremental
+++ b/sysconfig/pbm-physical-incremental
@@ -1,128 +1,9 @@
-#!/usr/bin/bash
-
-. /etc/sysconfig/pbm-conf
-
-# Log message function
-function log_message(){
-
-        LABEL=$2
-        MESSAGE_HEAD_LINE="[`date +"%Y-%m-%d %H:%M:%S"`]${LABEL}"
-
-
-        case "$3" in
-                'OK' ) MESSAGE_TYPE="${grn}${MESSAGE_HEAD_LINE}[OK]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[OK]"
-                        ;;
-                'INFO' ) MESSAGE_TYPE="${blu}${MESSAGE_HEAD_LINE}[INFO]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[INFO]"
-                        ;;
-                'ERROR' ) MESSAGE_TYPE="${red}${MESSAGE_HEAD_LINE}[ERROR]"
-                                  MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[ERROR]"
-                        ;;
-                'WARNING' ) MESSAGE_TYPE="${yel}${MESSAGE_HEAD_LINE}[WARN]"
-                                        MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[WARN]"
-                        ;;
-
-        esac
-
-        case "$1" in
-                'STANDARD' ) MESSAGE_HEAD="${MESSAGE_TYPE}"
-                        ;;
-                'LOG' ) MESSAGE_HEAD="${MESSAGE_TYPE_LOG}"
-                        ;;
-        esac
-        MSG=$4
-
-        #MESSAGE_HEAD="${MESSAGE_TYPE}"
-        echo "${MESSAGE_HEAD} ${MSG} ${off}"
-}
-
-# Main Global Variables
-GREPBINPATH=`which grep`
-PBMBINPATH=`which pbm`
-MONGOSHBINPATH=`which mongosh`
-PBLOCALROOTMDIR="/data/backup/pbm"
-PBLOGROOTMDIR="/data/backup/pbm/logs"
-BASELOGFILE="${PBLOGROOTMDIR}/incrbase.log"
-INCRLOGFILE="${PBLOGROOTMDIR}/incr.log"
-REPLSET=`echo $PBM_MONGODB_URI|awk -F'&' '{print $2}'|awk -F'=' '{print $2}'`
-LASTBACKUPFNAME="${PBLOCALROOTMDIR}/${REPLSET}.lastbackup.index"
-LOCALHOSTNAME=`hostname`
-
-EXITCODE=0
-
-# Main Output Messages
-SRVMSGINIT=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][INIT]" "INFO" "MongoDB Incremental Backup Service Initiating"`
-SRVMSGFINISH=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][END]" "INFO" "MongoDB Incremental Backup Service Ended"`
-MSGPRECHECK=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PRECHECK]" "INFO" "Checking Last Backup Ran Info"`
-PBMMSGPRECHECKOK=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][CHECKINFO]" "OK" "Last MongoDB Backup Ran in current Node. PBM Incremental Backup will be Run!!"`
-PBMMSGPRECHECKWRN=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][CHECKINFO][WARNING]" "WARNING" "Incremental MongoDB Backup Ran in other Node. Incremental Backup will not run. Exiting"`
-
-PBMRUNSTARTINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RUN][START]" "INFO" "PBM - RUN - MongoDB Incremental Backup Starting!!"`
-PBMRUNFINISHINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RUN][FINISH]" "INFO" "PBM - FINISH - MongoDB Incremental Backup Finished!!"`
-RUNFINISHINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][RUN][FINISH]" "INFO" "MongoDB Incremental Backup Finished!!"`
-
-PBMMSGRESYNCINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RESYNC_METADA][START]" "INFO" "PBM - Resyncing metadata Starting!!"`
-PBMMSGRESYNCOK=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RESYNC_METADA]" "OK" "PBM - Metadata SYNCED!!"`
-PBMMSGOK=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RUN][OK][FINISH]" "OK" "PBM - MongoDB Incremental Backup Successfully DONE!!"`
-PBMMSGKO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RUN][ERROR][FINISH]" "ERROR" "PBM - FINISH - MongoDB Incremental Backup Failed!! Please check pbm-agent logs!! Exiting"`
-
-# MongoDB Queries in JS
-JSQRYLASTBASEBKPKOK='db.getSiblingDB("admin").pbmBackups.find({status: "done",src_backup: { $exists: false }},{ opid: 1, name: 1, "replsets.node": 1 , "n.ack": 1 }).sort({start_ts: -1}).limit(1).forEach(printjson)'
-JSQRYLASTBACKUPOK='db.getSiblingDB("admin").pbmBackups.find({status: "done",src_backup: { $exists: true }},{ opid: 1, name: 1, "replsets.node": 1 , "n.ack": 1 }).sort({start_ts: -1}).limit(1).forEach(printjson)'
-
-echo "${SRVMSGINIT}" && echo "${SRVMSGINIT}" >> ${INCRLOGFILE}
-echo "${MSGPRECHECK}" && echo "${MSGPRECHECK}" >> ${INCRLOGFILE}
-# Mongodb query to retrieve last backup successfully done
-
-#LASTBKPINFO=`$MONGOSHBINPATH ${PBM_MONGODB_URI} --eval "${JSQRYLASTBACKUPOK}" | grep 'opid\|name\|node\|ack'|tr -s '[:space:]'|sed 's/\:27017//g'|sed 's/ ack/, ack/g'|sed 's/,/|/g'|tr -d '\n'`
-LASTBASEBKPINFO=`$MONGOSHBINPATH ${PBM_MONGODB_URI} --eval "${JSQRYLASTBASEBKPKOK}" |grep 'opid\|status\|name\|node\|ack'|sed 's/\:27017//g'|tr -s '[:space:]'|tr -s ',' '|'|tr -d '\n'`
-echo ${LASTBASEBKPINFO} > ${LASTBACKUPFNAME}
-#grep '${LOCALHOSTNAME}' ${LASTBACKUPFNAME}
-#BACKUPHOSTOK=$?
-
-# If Last Backup Ran in current host, next incremental will be ran, if not exit
-if [[ `${GREPBINPATH} -ci "${LOCALHOSTNAME}" ${LASTBACKUPFNAME}` -ne 0 ]]; then
-
-        # Run Incremental Backup
-        echo ${PBMMSGPRECHECKOK}  && echo "${PBMMSGPRECHECKOK}" >> ${INCRLOGFILE}
-        PBMLASTBASEBKPINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][PRECHECK][LASTBACKUP]" "INFO" "PBM - PRECHECK - Last MongoDB Incremental Backup Info: [${LASTBASEBKPINFO}]"`
-        echo "${PBMLASTBASEBKPINFO}" && echo "${PBMLASTBASEBKPINFO}" >> ${INCRLOGFILE}
-        echo "${PBMRUNSTARTINFO}" && echo "${PBMRUNSTARTINFO}" >> ${INCRLOGFILE}
-        ${PBMBINPATH} backup --type incremental -w
-        if [[ $? -ne 0 ]]; then
-        # pbm execution failed
-                EXITCODE=-1
-                
-        fi
-        echo ${PBMRUNFINISHINFO}  && echo "${PBMMSGBKPINFO}" >> ${INCRLOGFILE}
-#        echo "${PBMMSGRESYNCINFO}" && echo "${PBMMSGRESYNCINFO}" >> ${INCRLOGFILE}
-#	${PBMBINPATH} config --force-resync -w
-#        if [[ $? -eq 0 ]]; then
-#               	echo "${PBMMSGRESYNCOK}" && echo "${PBMMSGRESYNCOK}" >> ${INCRLOGFILE}
-#        fi
-        LASTBKPINFO=`$MONGOSHBINPATH ${PBM_MONGODB_URI} --eval "${JSQRYLASTBACKUPOK}" |grep 'opid\|status\|name\|node\|ack'|sed 's/\:27017//g'|tr -s '[:space:]'|tr -s ',' '|'|tr -d '\n'`
-        PBMMSGBKPINFO=`log_message "LOG" "[PSMB][BACKUP][INCREMENTAL][PBM][RUN][OK][FINISH]" "INFO" "MongoDB Incremental Backup Info: [${LASTBKPINFO}]"`
-#        fi
-
-else
-        # PBM Backup Precheck Not Successfull
-        EXITCODE=1
-fi
-
-# Exit messages management
-case $EXITCODE in
-        0) echo ${PBMMSGBKPINFO} && echo "${PBMMSGBKPINFO}" >> ${INCRLOGFILE}
-           echo ${PBMMSGOK} && echo "${PBMMSGOK}" >> ${INCRLOGFILE}
-           ;;
-        1) EXITCODE=0
-           echo ${PBMMSGPRECHECKWRN} && echo "${PBMMSGPRECHECKWRN}" >> ${INCRLOGFILE}
-           ;;
-        -1) echo ${PBMMSGKO} && echo "${PBMMSGKO}" >> ${INCRLOGFILE}
-            ;;
-esac
-
-echo ${SRVMSGFINISH} && echo "${SRVMSGFINISH}" >> ${INCRLOGFILE}
-
-
-exit ${EXITCODE}
+#!/usr/bin/env bash
+#
+# pbm-physical-incremental - compatibility wrapper kept so existing systemd units
+# (ExecStart=/etc/sysconfig/pbm-physical-incremental) keep working.
+# Hourly physical incremental backup (only on the base node).
+#
+# All logic lives in pbm-backup; run "pbm-backup incr --help" for details.
+set -euo pipefail
+exec "${PBM_BACKUP_BIN:-/usr/local/bin/pbm-backup}" incr "$@"
```

</details>

<details>
<summary><code>sysconfig/pbm-deletion</code></summary>

```diff
--- a/sysconfig/pbm-deletion
+++ b/sysconfig/pbm-deletion
@@ -1,82 +1,9 @@
-#!/usr/bin/bash
-
-. /etc/sysconfig/pbm-conf
-
-# Log message function
-function log_message(){
-
-        LABEL=$2
-        MESSAGE_HEAD_LINE="[`date +"%Y-%m-%d %H:%M:%S"`]${LABEL}"
-
-
-        case "$3" in
-                'OK' ) MESSAGE_TYPE="${grn}${MESSAGE_HEAD_LINE}[OK]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[OK]"
-                        ;;
-                'INFO' ) MESSAGE_TYPE="${blu}${MESSAGE_HEAD_LINE}[INFO]"
-                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[INFO]"
-                        ;;
-                'ERROR' ) MESSAGE_TYPE="${red}${MESSAGE_HEAD_LINE}[ERROR]"
-                                  MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[ERROR]"
-                        ;;
-                'WARNING' ) MESSAGE_TYPE="${yel}${MESSAGE_HEAD_LINE}[WARN]"
-                                        MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[WARN]"
-                        ;;
-
-        esac
-
-        case "$1" in
-                'STANDARD' ) MESSAGE_HEAD="${MESSAGE_TYPE}"
-                        ;;
-                'LOG' ) MESSAGE_HEAD="${MESSAGE_TYPE_LOG}"
-                        ;;
-        esac
-        MSG=$4
-
-        #MESSAGE_HEAD="${MESSAGE_TYPE}"
-        echo "${MESSAGE_HEAD} ${MSG} ${off}"
-}
-
-# Main Global Variables
-GREPBINPATH=`which grep`
-PBMBINPATH=`which pbm`
-MONGOSHBINPATH=`which mongosh`
-PBLOCALROOTMDIR="/data/backup/pbm"
-PBLOGROOTMDIR="/data/backup/pbm/logs"
-LOGFILE="${PBLOGROOTMDIR}/deletion.log"     
-LOCALHOSTNAME=`hostname`
-REPLSET=`echo $PBM_MONGODB_URI|awk -F'&' '{print $2}'|awk -F'=' '{print $2}'`
-EXITCODE=0
-RETENTIONDAYS=7
-DATEFROM=`date -d "-${RETENTIONDAYS} day" +\%Y-\%m-\%d`
-# Main Output Messages
-SRVMSGINIT=`log_message "LOG" "[PSMB][BACKUP][RETENTION][PURGE][INIT]" "INFO" "MongoDB Backups Deletion Service Initiating. RETENTION DAYS -> ${RETENTIONDAYS}"`
-SRVMSGFINISH=`log_message "LOG" "[PSMB][BACKUP][RETENTION][PURGE][END]" "INFO" "MongoDB Backups Deletion Service Ended"`
-
-PBMRUNSTARTINFO=`log_message "LOG" "[PSMB][BACKUP][RETENTION][PURGE][PBM][RUN][START]" "INFO" "PBM - MongoDB Backups Deletion Starting!! Deleting Backups stored Older than ${DATEFROM}"`
-
-PBMMSGOK=`log_message "LOG" "[PSMB][BACKUP][RETENTION][PURGE][PBM][RUN][FINISH][OK]" "OK" "PBM - MongoDB Backups Deletion Successfully DONE!!"`
-PBMMSGKO=`log_message "LOG" "[PSMB][BACKUP][RETENTION][PURGE][PBM][RUN][FINISH][ERROR]" "ERROR" "PBM - MongoDB Backups Deletion Failed!! Please check pbm-agent logs!! Exiting"`
-
-# MongoDB Queries in JS
-#JSQRYLASTBASEBKPOK=''
-
-
-echo "${SRVMSGINIT}" && echo "${SRVMSGINIT}" >> ${LOGFILE}
-echo "${PBMRUNSTARTINFO}" && echo "${PBMRUNSTARTINFO}" >> ${LOGFILE}
-
-
-#${PBMBINPATH} cleanup -y --older-than $(date -d '-8 day' +\%Y-\%m-\%d) -w
-${PBMBINPATH} cleanup -y --older-than $DATEFROM -w
-if [[ $? -ne 0 ]]; then
-# pbm execution failed 
-        EXITCODE=-1
-        echo ${PBMMSGKO} && echo "${PBMMSGKO}" >> ${LOGFILE}
-else
-        echo ${PBMMSGOK} && echo "${PBMMSGOK}" >> ${LOGFILE}              
-fi
-
-echo ${SRVMSGFINISH} && echo "${SRVMSGFINISH}" >> ${LOGFILE}
-
-
-exit ${EXITCODE}
+#!/usr/bin/env bash
+#
+# pbm-deletion - compatibility wrapper kept so existing systemd units
+# (ExecStart=/etc/sysconfig/pbm-deletion) keep working.
+# Retention purge (pbm cleanup --older-than).
+#
+# All logic lives in pbm-backup; run "pbm-backup cleanup --help" for details.
+set -euo pipefail
+exec "${PBM_BACKUP_BIN:-/usr/local/bin/pbm-backup}" cleanup "$@"
```

</details>

