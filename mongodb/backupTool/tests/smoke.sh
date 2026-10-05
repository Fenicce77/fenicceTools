#!/usr/bin/env bash
#
# smoke.sh - Scenario tests for pbm-backup using mocked pbm and mongosh CLIs
# and the PBM 2.12.0 JSON fixtures. No MongoDB or PBM needed.
#
# Usage: tests/smoke.sh [BASH_BINARY]
#   tests/smoke.sh                 # bash from PATH
#   tests/smoke.sh /bin/bash       # macOS bash 3.2 compatibility check
set -uo pipefail

BASH_BIN=${1:-bash}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FIX="${ROOT}/tests/fixtures/pbm-2.12.0-psmdb-8.0"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pbm-backup-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/env" <<EOT
PBM_MONGODB_URI="mongodb://u:p@mongocluster-node01:27017/?authSource=admin&replicaSet=gcssrs01"
EOT
cat >"$WORK/conf" <<EOT
PBM_LOCAL_ROOT="$WORK/root"
WAIT_POLL_SEC=1
WAIT_RUNNING_SEC=1
EOT

export PATH="${ROOT}/tests/mock:$PATH"
export MOCK_FIXTURES=$FIX MOCK_CALLS="$WORK/calls"
export PBM_BACKUP_CONF="$WORK/conf" PBM_ENV_FILE="$WORK/env" LOCK_DIR=$WORK
export PBM_BACKUP_COLOR=never FALLBACK_DELAY_SEC=0

# ---------------------------------------------------------------------------
# Node probe sets: $WORK/probes/<set>/<short-host>.json (missing = unreachable)
# ---------------------------------------------------------------------------
probe() { # state lag queue dirty primary [oplog_window_sec, default 86400]
    printf '{"reachable":true,"primary":%s,"state":"%s","lag":%s,"queue":%s,"dirty_pct":%s,"oplog_window_sec":%s}\n' \
        "$5" "$1" "$2" "$3" "$4" "${6:-86400}"
}
mkset() { # name node01-json node02-json node03-json
    local d="$WORK/probes/$1" i=1 j
    mkdir -p "$d"
    shift
    for j in "$@"; do
        if [[ -n $j ]]; then
            printf '%s\n' "$j" >"$d/mongocluster-node0${i}.json"
        fi
        i=$((i + 1))
    done
}
P1=$(probe PRIMARY 0 0 1.5 true)
S_OK=$(probe SECONDARY 0 0 1.2 false)
mkset healthy   "$P1" "$S_OK" "$S_OK"
mkset n03lag    "$P1" "$S_OK" "$(probe SECONDARY 300 0 1.2 false)"
mkset n03down   "$P1" "$S_OK" ""
mkset n03queue  "$P1" "$S_OK" "$(probe SECONDARY 0 80 1.2 false)"
mkset n02dirty  "$P1" "$(probe SECONDARY 0 0 35 false)" "$S_OK"
mkset onlyprim  "$P1" "" ""
mkset n03smalloplog "$P1" "$S_OK" "$(probe SECONDARY 0 0 1.2 false 400)"
export MOCK_PROBES="$WORK/probes/healthy"

# Status variants
NOW_ISO=$(jq -rn 'now | floor | todate')
jq --arg n "$NOW_ISO" '.backups.snapshot = [{name: $n, status: "done", type: "incremental", src: ""}] + .backups.snapshot' \
    "$FIX/status-backups.json" >"$WORK/backups-fresh-base.json"
jq '.backups.snapshot = []' "$FIX/status-backups.json" >"$WORK/backups-empty.json"
jq '.pitr.conf = true' "$FIX/status-all-agents-ok.json" >"$WORK/status-pitr-on.json"
jq '.cluster += [.cluster[0] | .rs = "rs2"]' "$FIX/status-all-agents-ok.json" >"$WORK/status-sharded.json"

# ---------------------------------------------------------------------------
pass=0 fail=0
# check NAME EXPECTED_RC "pattern expected in pbm calls" "pattern NOT expected" -- ARGS...
# Optional: EXPECT_OUT="pattern" must appear in the command output,
#           EXPECT_NO_OUT="pattern" must not.
check() {
    local name=$1 want=$2 must=$3 mustnot=$4
    shift 5
    : >"$MOCK_CALLS"
    "$BASH_BIN" "${ROOT}/bin/pbm-backup" "$@" >"$WORK/out" 2>&1 </dev/null
    local rc=$? ok=1
    [[ $rc == "$want" ]] || ok=0
    if [[ -n $must ]] && ! grep -q -- "$must" "$MOCK_CALLS"; then ok=0; fi
    if [[ -n $mustnot ]] && grep -q -- "$mustnot" "$MOCK_CALLS"; then ok=0; fi
    if [[ -n ${EXPECT_OUT:-} ]] && ! grep -q -- "$EXPECT_OUT" "$WORK/out"; then ok=0; fi
    if [[ -n ${EXPECT_NO_OUT:-} ]] && grep -q -- "$EXPECT_NO_OUT" "$WORK/out"; then ok=0; fi
    if [[ $ok == 1 ]]; then
        pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$name"
    else
        fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s (rc=%s, want %s)\n' "$name" "$rc" "$want"
        sed 's/^/       | /' "$WORK/out"
        sed 's/^/       calls: /' "$MOCK_CALLS"
    fi
}
N1=mongocluster-node01 N2=mongocluster-node02 N3=mongocluster-node03
COMP="--compression=gzip --compression-level=5"
INCR="backup --type incremental $COMP --wait"
BASE="backup --type incremental --base $COMP --wait"
LOG="backup --type logical $COMP --wait"

printf 'pbm-backup smoke tests (%s)\n' "$("$BASH_BIN" -c 'echo $BASH_VERSION')"

printf '\n[incr: election, owner = node03 (fixture)]\n'
LOCAL_NODE_NAMES=$N3 check "owner node03 healthy -> incremental"            0 "$INCR" "--base" -- incr
LOCAL_NODE_NAMES=$N2 check "node02 is standby -> skip"                        0 "" "backup --type" -- incr
LOCAL_NODE_NAMES=$N1 EXPECT_OUT="not eligible (primary)" \
    check "node01 primary -> skip"                                            0 "" "backup --type" -- incr
LOCAL_NODE_NAMES=$N3 EXPECT_OUT="name=2026-10-02T16:15:05Z | opid=mock-opid-2026-10-02T16:15:05Z" \
    check "log shows the new incremental with its own opid"                   0 "$INCR" "" -- incr
MOCK_PROBES=$WORK/probes/n03lag   LOCAL_NODE_NAMES=$N2 EXPECT_OUT="replication lag 300s > 60s" \
    check "owner lagging -> node02 takes NEW base"                            0 "$BASE" "" -- incr
MOCK_PROBES=$WORK/probes/n03lag   LOCAL_NODE_NAMES=$N3 \
    check "owner lagging -> node03 itself skips"                              0 "" "backup --type" -- incr
MOCK_PROBES=$WORK/probes/n03down  LOCAL_NODE_NAMES=$N2 EXPECT_OUT="CHAIN\]\[RESTART" \
    check "owner unreachable -> node02 takes NEW base"                        0 "$BASE" "" -- incr
MOCK_PROBES=$WORK/probes/n03queue LOCAL_NODE_NAMES=$N2 EXPECT_OUT="queued operations 80 > 50" \
    check "owner with queued ops -> node02 takes NEW base"                    0 "$BASE" "" -- incr
MOCK_PROBES=$WORK/probes/n02dirty LOCAL_NODE_NAMES=$N3 \
    check "dirty cache on non-owner does not matter"                          0 "$INCR" "" -- incr
MOCK_STATUS=$FIX/status-node02-agent-down.json MOCK_PROBES=$WORK/probes/n03down LOCAL_NODE_NAMES=$N2 \
    EXPECT_OUT="No eligible node" \
    check "node02 agent down + node03 down -> error, no backup"               1 "" "backup --type" -- incr
MOCK_PROBES=$WORK/probes/onlyprim LOCAL_NODE_NAMES=$N1 \
    check "only primary alive -> error, no backup"                            1 "" "backup --type" -- incr
MOCK_PROBES=$WORK/probes/onlyprim LOCAL_NODE_NAMES=$N1 ALLOW_PRIMARY=true \
    check "only primary alive + ALLOW_PRIMARY=true -> base on primary"        0 "$BASE" "" -- incr
MOCK_BACKUPS=$WORK/backups-empty.json LOCAL_NODE_NAMES=$N2 EXPECT_OUT="starting a new chain" \
    check "no base yet -> #0 by name (node02) takes base"                     0 "$BASE" "" -- incr
MOCK_BACKUPS=$WORK/backups-empty.json LOCAL_NODE_NAMES=$N3 \
    check "no base yet -> node03 is standby"                                  0 "" "backup --type" -- incr
PREFERRED_NODES=$N3 MOCK_BACKUPS=$WORK/backups-empty.json LOCAL_NODE_NAMES=$N3 \
    check "no owner -> PREFERRED_NODES puts node03 first"                     0 "$BASE" "" -- incr
LOCAL_NODE_NAMES=nosuchhost EXPECT_OUT="not in the replica set member list" \
    check "host not a member -> error"                                        1 "" "backup --type" -- incr
LOCAL_NODE_NAMES=mongocluster-node0 \
    check "no substring match (node0 != node03)"                              1 "" "backup --type" -- incr
LOCAL_NODE_NAMES=$N2 check "--force on standby -> incremental"                0 "$INCR" "" -- incr --force
LOCAL_NODE_NAMES=$N3 check "--dry-run takes nothing"                          0 "" "backup --type" -- incr --dry-run
LOCAL_NODE_NAMES=$N3 MOCK_RC=1 check "pbm failure -> rc 1"                    1 "$INCR" "" -- incr

printf '\n[fallback / takeover]\n'
FALLBACK_DELAY_SEC=1 LOCAL_NODE_NAMES=$N2 EXPECT_OUT="TAKEOVER" \
    check "standby takes over when #0 did not start"                          0 "$BASE" "" -- incr
FALLBACK_DELAY_SEC=1 LOCAL_NODE_NAMES=$N2 MOCK_RUNNING='{"running":{"type":"backup","name":"x","opID":"y"}}' \
    EXPECT_OUT="higher-ranked node started" \
    check "standby stands down when #0 is running"                            0 "" "backup --type" -- incr

printf '\n[full]\n'
LOCAL_NODE_NAMES=$N3 check "owner runs base"                                  0 "$BASE" "" -- full
LOCAL_NODE_NAMES=$N2 check "standby skips base"                               0 "" "backup --type" -- full
MOCK_BACKUPS=$WORK/backups-fresh-base.json LOCAL_NODE_NAMES=$N3 \
    check "base already done -> dedup skip"                                   0 "" "backup --type" -- full
MOCK_BACKUPS=$WORK/backups-fresh-base.json LOCAL_NODE_NAMES=$N3 \
    check "--force ignores dedup"                                             0 "$BASE" "" -- full --force
MOCK_RC=1 LOCAL_NODE_NAMES=$N3 check "pbm failure -> rc 1"                    1 "$BASE" "" -- full
MOCK_RUNNING='{"running":{"type":"backup","name":"x","opID":"y"}}' LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="PBM is busy (backup x (opid y))" \
    check "waits when PBM busy"                                               0 "$BASE" "" -- full
MOCK_RUNNING='{"running":{"status":"running","startTS":1790957705}}' LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="PBM is busy (operation" \
    check "busy detected with unknown keys"                                   0 "" "" -- full
LOCAL_NODE_NAMES=$N3 EXPECT_NO_OUT="PBM is busy" check "idle {} is not busy"  0 "" "" -- full
MOCK_BACKUPS_AFTER=$WORK/backups-fresh-base.json MOCK_NODE=mongocluster-node02:27017 LOCAL_NODE_NAMES=$N3 EXPECT_OUT="PBM executed the backup on mongocluster-node02" \
    check "warns when PBM ran it on another node"                             0 "$BASE" "" -- full

printf '\n[phase 2: preflight]\n'
MOCK_BUILDINFO='{"version":"7.0.14","modules":[]}' LOCAL_NODE_NAMES=$N2 EXPECT_OUT="strategy logical" \
    check "Community -> logical strategy"                                     0 "$LOG" "" -- full
MOCK_BUILDINFO='{"version":"7.0.14","modules":[]}' BACKUP_MODE=physical LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="Physical backups need Percona Server" \
    check "Community + BACKUP_MODE=physical -> rc 1"                          1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"7.0.14","modules":["enterprise"]}' LOCAL_NODE_NAMES=$N2 EXPECT_OUT="(enterprise," \
    check "Enterprise detected -> logical"                                    0 "$LOG" "" -- full
MOCK_BUILDINFO='{"version":"8.0.17-6","modules":[]}' LOCAL_NODE_NAMES=$N3 EXPECT_OUT="(psmdb," \
    check "PSMDB detected by -N suffix only"                                  0 "$BASE" "" -- full
MOCK_BUILDINFO='{"version":"4.4.29-28","psmdbVersion":"4.4.29-28","modules":[]}' LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="does not support MongoDB 4.4" \
    check "PSMDB 4.4 + PBM 2.12 -> incompatible"                              1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"4.4.29-28","psmdbVersion":"4.4.29-28","modules":[]}' MOCK_PBM_VERSION=2.5.0 \
    LOCAL_NODE_NAMES=$N3 EXPECT_OUT="versionlock" \
    check "PSMDB 4.4 + PBM 2.5 -> ok + pin advice"                            0 "$BASE" "" -- full
MOCK_BUILDINFO='{"version":"4.4.10-11","psmdbVersion":"4.4.10-11","modules":[]}' MOCK_PBM_VERSION=2.5.0 \
    LOCAL_NODE_NAMES=$N2 EXPECT_OUT="strategy logical" \
    check "PSMDB 4.4.10 too old for physical incr -> logical"                 0 "$LOG" "" -- full
MOCK_BUILDINFO='{"version":"4.0.28","modules":[]}' LOCAL_NODE_NAMES=$N3 EXPECT_OUT="needs PBM 1.x" \
    check "MongoDB 4.0 -> PBM 1.x needed"                                     1 "" "backup --type" -- full
MOCK_STATUS=$WORK/status-pitr-on.json LOCAL_NODE_NAMES=$N3 EXPECT_OUT="PITR is enabled" \
    check "PITR enabled -> rc 1"                                              1 "" "backup --type" -- full
MOCK_STATUS=$FIX/status-node02-agent-down.json LOCAL_NODE_NAMES=$N3 EXPECT_OUT="pbm-agent NOT ok" \
    check "agent down is reported"                                            0 "$BASE" "" -- full
MOCK_PBM_VERSION=2.11.0 LOCAL_NODE_NAMES=$N3 EXPECT_OUT="differs from CLI" \
    check "agent/CLI version mismatch is reported"                            0 "$BASE" "" -- full
MOCK_STATUS=$WORK/status-sharded.json LOCAL_NODE_NAMES=$N3 EXPECT_OUT="sharded" \
    check "sharded cluster -> rc 1"                                           1 "" "backup --type" -- full

# ---------------------------------------------------------------------------
# Phase 4: logical scheme (Community). Synthetic data relative to now:
#   logical full at now-6h taken on node03 (dump 300s, restoreTo = start+300)
# ---------------------------------------------------------------------------
NOW=$(date +%s)
LSTART=$(( NOW - 6 * 3600 ))
LNAME=$(jq -rn --argjson t "$LSTART" '$t | todate')
LRESTORE=$(( LSTART + 300 ))
jq --arg n "$LNAME" --argjson r "$LRESTORE" \
    '.backups.snapshot = [{name: $n, status: "done", type: "logical", src: "", restoreTo: $r, pbmVersion: "2.12.0"}]' \
    "$FIX/status-backups.json" >"$WORK/backups-logical.json"
jq '.backups.snapshot = []' "$FIX/status-backups.json" >"$WORK/backups-none.json"
jq '.pitr.conf = true | .pitr.run = true' "$FIX/status-all-agents-ok.json" >"$WORK/status-pitr-run.json"
mklist() { # name [[start,end],...]
    jq -n --argjson r "$2" '{snapshots: [], pitr: {on: true, ranges: [$r[] | {range: {start: .[0], end: .[1]}}]}}' >"$WORK/list-$1.json"
}
mklist ok      "[[$(( LRESTORE - 60 )),$(( NOW - 1200 ))]]"
mklist gap     "[[$(( LRESTORE - 60 )),$(( LRESTORE + 3600 ))],[$(( LRESTORE + 5400 )),$(( NOW - 1200 ))]]"
# older full (now-30h) whose slices stopped 7h ago
OSTART=$(( NOW - 30 * 3600 )); ORESTORE=$(( OSTART + 300 ))
jq --arg n "$(jq -rn --argjson t "$OSTART" '$t | todate')" --argjson r "$ORESTORE" \
    '.backups.snapshot = [{name: $n, status: "done", type: "logical", src: "", restoreTo: $r, pbmVersion: "2.12.0"}]' \
    "$FIX/status-backups.json" >"$WORK/backups-logical-old.json"
mklist stale   "[[$(( ORESTORE - 60 )),$(( NOW - 7 * 3600 ))]]"
mklist late    "[[$(( LRESTORE + 600 )),$(( NOW - 1200 ))]]"
CE='{"version":"7.0.14","modules":[]}'
lcfg() { # enabled span [compression, default gzip]
    printf 'pitr.enabled=%s\npitr.oplogSpanMin=%s\npitr.compression=%s\npitr.compressionLevel=5\n' \
        "$1" "$2" "${3:-gzip}" >"$WORK/pbmconf"
}

printf '\n[phase 4: logical full]\n'
printf 'pitr.enabled=false\npitr.oplogSpanMin=10\n' >"$WORK/pbmconf"
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="Oplog window 86400s >= 2 x expected dump 300s" \
    check "owner takes logical full"                                          0 "$LOG" "--base" -- full
for kv in pitr.oplogSpanMin=360 pitr.enabled=true pitr.compression=gzip pitr.compressionLevel=5; do
    if grep -q "pbm config --set $kv" "$MOCK_CALLS"; then
        pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "...and sets $kv"
    else
        fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "...and sets $kv"
    fi
done
lcfg true 360
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 \
    check "PITR already configured -> no config change"                      0 "$LOG" "config --set" -- full
lcfg false 10
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 PITR_AUTOCONFIG=false \
    check "PITR_AUTOCONFIG=false -> no config change"                        0 "$LOG" "config --set" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json LOCAL_NODE_NAMES=$N2 \
    check "standby skips logical full"                                        0 "" "backup --type" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_PROBES=$WORK/probes/n03smalloplog LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="Oplog window 400s < 2 x expected dump 300s" \
    check "oplog window too small -> rc 1, no backup"                         1 "" "backup --type" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_PROBES=$WORK/probes/n03smalloplog LOCAL_NODE_NAMES=$N3 \
    OPLOG_WINDOW_ENFORCE=false \
    check "oplog window too small + ENFORCE=false -> runs"                    0 "$LOG" "" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_PROBES=$WORK/probes/n03smalloplog LOCAL_NODE_NAMES=$N3 \
    EXPECTED_DUMP_SEC=100 \
    check "EXPECTED_DUMP_SEC overrides the estimate"                          0 "$LOG" "" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-none.json LOCAL_NODE_NAMES=$N2 EXPECT_OUT="cannot estimate the dump time" \
    check "first logical full -> no estimate, runs"                           0 "$LOG" "" -- full
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 \
    check "--dry-run takes nothing, changes nothing"                          0 "" "backup --type" -- full --dry-run
BACKUP_MODE=logical MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json LOCAL_NODE_NAMES=$N3 \
    check "PSMDB + BACKUP_MODE=logical -> logical, PITR allowed"              0 "$LOG" "" -- full

printf '\n[phase 4: oplog (PITR) check]\n'
lcfg true 360
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="Restorable to any point from $(jq -rn --argjson t "$LRESTORE" '$t | todate')" \
    check "continuous oplog -> ok"                                            0 "list -o json" "backup --type" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-gap.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="PITR\]\[GAP" \
    check "gap after the full -> rc 1"                                        1 "" "backup --type" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical-old.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-stale.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="s behind (max 22500s)" \
    check "slices stopped (6h+15m) -> rc 1"                                   1 "" "backup --type" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-late.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="no saved oplog covers the base snapshot" \
    check "oplog starts after the full -> rc 1"                               1 "" "backup --type" -- incr
lcfg false 360
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="enabling it (PITR_AUTOCONFIG=true)" \
    check "PITR disabled -> enabled by autoconfig"                            1 "config --set pitr.enabled=true" "backup --type" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 PITR_AUTOCONFIG=false \
    EXPECT_OUT="PITR is disabled" \
    check "PITR disabled + no autoconfig -> rc 1"                             1 "" "config --set" -- incr
lcfg true 360
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-none.json MOCK_STATUS=$WORK/status-pitr-run.json LOCAL_NODE_NAMES=$N2 \
    EXPECT_OUT="No logical full backup" \
    check "no logical full yet -> rc 1"                                       1 "" "backup --type" -- incr
lcfg true 360 none
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="UNCOMPRESSED" \
    check "oplog slices uncompressed -> rc 1"                                 1 "" "backup --type" -- incr
lcfg true 10
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 PITR_AUTOCONFIG=false EXPECT_OUT="pitr.oplogSpanMin=10, expected" \
    check "oplogSpanMin mismatch is reported"                                 0 "" "" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    FALLBACK_DELAY_SEC=60 LOCAL_NODE_NAMES=$N2 \
    check "standby skips the check immediately (no takeover wait)"            0 "" "list -o json" -- incr
MOCK_BUILDINFO=$CE MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-gap.json \
    MOCK_CONFIG=$WORK/pbmconf LOCAL_NODE_NAMES=$N3 EXPECT_OUT="PITR\]\[GAP" \
    check "check reports the gap"                                             1 "" "backup --type" -- check

printf '\n[storage / compression]\n'
jq '.backups.type = "FS" | .backups.path = "/data/backup/pbm"' "$FIX/status-all-agents-ok.json" >"$WORK/status-fs.json"
MOCK_STATUS=$WORK/status-fs.json LOCAL_NODE_NAMES=$N3 EXPECT_OUT="backups must go to a bucket" \
    check "filesystem storage -> rc 1"                                        1 "" "backup --type" -- full
MOCK_STATUS=$WORK/status-fs.json LOCAL_NODE_NAMES=$N3 REQUIRED_STORAGE_TYPES="GCS FS" \
    check "REQUIRED_STORAGE_TYPES can allow it"                               0 "$BASE" "" -- full
BACKUP_COMPRESSION=none check "BACKUP_COMPRESSION=none rejected"              2 "" "backup --type" -- full
BACKUP_COMPRESSION=zstd BACKUP_COMPRESSION_LEVEL= LOCAL_NODE_NAMES=$N3 \
    check "BACKUP_COMPRESSION=zstd without level"                             0 "backup --type incremental --base --compression=zstd --wait" "" -- full

printf '\n[check]\n'
LOCAL_NODE_NAMES=$N3 EXPECT_OUT="owns the chain" check "check on owner"       0 "" "backup --type" -- check
MOCK_PROBES=$WORK/probes/n03down LOCAL_NODE_NAMES=$N2 EXPECT_OUT="chain restart" \
    check "check on new #0"                                                   0 "" "backup --type" -- check
MOCK_PROBES=$WORK/probes/onlyprim LOCAL_NODE_NAMES=$N1 EXPECT_OUT="would do NOTHING" \
    check "check with no eligible node"                                       1 "" "backup --type" -- check

printf '\n[restore]\n'
ts() { jq -rn --argjson t "$1" '$t | todate | sub("Z$"; "")'; }
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    EXPECT_OUT="pbm restore --time=$(ts $(( LRESTORE + 3600 ))) --wait" \
    check "--to inside coverage -> plan (dry-run)"                            0 "" "pbm restore" -- restore --to "$(ts $(( LRESTORE + 3600 )))" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    EXPECT_OUT="Step 1: disable PITR" \
    check "--to plan disables PITR first"                                     0 "" "pbm restore" -- restore --to "$(ts $(( LRESTORE + 3600 )))" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    EXPECT_OUT="Saved oplog does not reach" \
    check "--to after the saved oplog -> rc 1"                                1 "" "pbm restore" -- restore --to "$(ts $(( NOW - 60 )))" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-gap.json \
    check "--to before the gap -> ok"                                         0 "" "pbm restore" -- restore --to "$(ts $(( LRESTORE + 1800 )))" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-gap.json \
    EXPECT_OUT="No saved oplog between" \
    check "--to inside the gap -> rc 1"                                       1 "" "pbm restore" -- restore --to "$(ts $(( LRESTORE + 4000 )))" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json \
    EXPECT_OUT="No logical full backup with restoreTo" \
    check "--to before any full -> rc 1"                                      1 "" "pbm restore" -- restore --to "$(ts $(( LSTART - 3600 )))" --dry-run
check "--to bad format -> rc 2"                                               2 "" "pbm restore" -- restore --to "yesterday" --dry-run
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    EXPECT_OUT="without --yes" \
    check "no --yes and no TTY -> refused"                                    2 "" "pbm restore" -- restore --to "$(ts $(( LRESTORE + 3600 )))"
MOCK_BACKUPS=$WORK/backups-logical.json MOCK_STATUS=$WORK/status-pitr-run.json MOCK_LIST=$WORK/list-ok.json \
    check "--yes: disables PITR, restores"                                    0 "pbm restore --time=$(ts $(( LRESTORE + 3600 ))) --wait" "" -- restore --to "$(ts $(( LRESTORE + 3600 )))" --yes
grep -q 'pbm config --set pitr.enabled=false' "$MOCK_CALLS" \
    && { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "...after pbm config --set pitr.enabled=false"; } \
    || { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "...after pbm config --set pitr.enabled=false"; }
EXPECT_OUT="Physical restore: PBM stops mongod" \
    check "physical incremental by name -> plan + warning"                    0 "" "pbm restore" -- restore 2026-10-02T16:15:05Z --dry-run
check "physical by name --yes"                                                0 "pbm restore 2026-10-02T16:15:05Z" "--wait" -- restore 2026-10-02T16:15:05Z --yes
check "unknown backup name -> rc 1"                                           1 "" "pbm restore" -- restore 2020-01-01T00:00:00Z --dry-run
check "name and --to together -> rc 2"                                        2 "" "pbm restore" -- restore 2026-10-02T16:15:05Z --to 2026-10-02T10:00:00
check "restore without target -> rc 2"                                        2 "" "pbm restore" -- restore
MOCK_RC=1 check "pbm restore fails -> rc 1"                                   1 "pbm restore" "" -- restore 2026-10-02T16:15:05Z --yes
check "restore --help"                                                        0 "" "" -- restore --help

printf '\n[cleanup / CLI]\n'
check "cleanup default retention"   0 "cleanup -y --older-than" "" -- cleanup
check "cleanup --dry-run"           0 "" "cleanup -y" -- cleanup --dry-run
check "cleanup invalid retention"   2 "" "cleanup -y" -- cleanup -r abc
BACKUP_MODE=bogus check "invalid BACKUP_MODE" 2 "" "" -- check
check "help"                        0 "" "" -- --help
check "check --help"                0 "" "" -- check --help
check "unknown argument"            2 "" "" -- bogus
check "no command"                  2 "" "" --

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
