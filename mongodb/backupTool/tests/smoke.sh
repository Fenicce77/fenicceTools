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
probe() { # state lag queue dirty primary
    printf '{"reachable":true,"primary":%s,"state":"%s","lag":%s,"queue":%s,"dirty_pct":%s}\n' "$5" "$1" "$2" "$3" "$4"
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
    "$BASH_BIN" "${ROOT}/bin/pbm-backup" "$@" >"$WORK/out" 2>&1
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
INCR="backup --type incremental --wait"
BASE="backup --type incremental --base --wait"

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
MOCK_BUILDINFO='{"version":"7.0.14","modules":[]}' LOCAL_NODE_NAMES=$N3 EXPECT_OUT="strategy logical" \
    check "Community -> logical strategy -> not yet, rc 1"                    1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"7.0.14","modules":[]}' BACKUP_MODE=physical LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="Physical backups need Percona Server" \
    check "Community + BACKUP_MODE=physical -> rc 1"                          1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"7.0.14","modules":["enterprise"]}' LOCAL_NODE_NAMES=$N3 EXPECT_OUT="(enterprise," \
    check "Enterprise detected"                                               1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"8.0.17-6","modules":[]}' LOCAL_NODE_NAMES=$N3 EXPECT_OUT="(psmdb," \
    check "PSMDB detected by -N suffix only"                                  0 "$BASE" "" -- full
MOCK_BUILDINFO='{"version":"4.4.29-28","psmdbVersion":"4.4.29-28","modules":[]}' LOCAL_NODE_NAMES=$N3 \
    EXPECT_OUT="does not support MongoDB 4.4" \
    check "PSMDB 4.4 + PBM 2.12 -> incompatible"                              1 "" "backup --type" -- full
MOCK_BUILDINFO='{"version":"4.4.29-28","psmdbVersion":"4.4.29-28","modules":[]}' MOCK_PBM_VERSION=2.5.0 \
    LOCAL_NODE_NAMES=$N3 EXPECT_OUT="versionlock" \
    check "PSMDB 4.4 + PBM 2.5 -> ok + pin advice"                            0 "$BASE" "" -- full
MOCK_BUILDINFO='{"version":"4.4.10-11","psmdbVersion":"4.4.10-11","modules":[]}' MOCK_PBM_VERSION=2.5.0 \
    LOCAL_NODE_NAMES=$N3 EXPECT_OUT="strategy logical" \
    check "PSMDB 4.4.10 too old for physical incr -> logical"                 1 "" "backup --type" -- full
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

printf '\n[check]\n'
LOCAL_NODE_NAMES=$N3 EXPECT_OUT="owns the chain" check "check on owner"       0 "" "backup --type" -- check
MOCK_PROBES=$WORK/probes/n03down LOCAL_NODE_NAMES=$N2 EXPECT_OUT="chain restart" \
    check "check on new #0"                                                   0 "" "backup --type" -- check
MOCK_PROBES=$WORK/probes/onlyprim LOCAL_NODE_NAMES=$N1 EXPECT_OUT="NO backup" \
    check "check with no eligible node"                                       1 "" "backup --type" -- check

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
