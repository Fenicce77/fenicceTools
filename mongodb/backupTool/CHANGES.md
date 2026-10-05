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

