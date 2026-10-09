# Project: Generic PBM backup system for MongoDB

## Current state
`pbm-backup` (version in `bin/pbm-backup`, `VERSION=`): a PBM 2.x backup runner for MongoDB
>= 4.2 replica sets, PSMDB and Community. Phases 1-6 of the original plan are done; see
README.md (what it does), INSTALL.md (deployment) and CHANGES.md (history against the
original scripts, which are kept as diffs there and as units in `systemd/legacy/`).
- Detects version/edition (buildInfo), checks the PBM compatibility matrix, picks the scheme.
- PSMDB -> physical: daily `--base` + hourly incrementals, PITR off.
- Community -> logical: daily logical full + PBM PITR oplog slices every OPLOG_INCR_MIN
  (default 360), oplog window check before the full, chain continuity check every 6h.
- Node election on every member: stay on the owner of the last full, fail over to a
  healthy secondary, never the primary.
- Chain-aligned safe retention, `restore` with coverage validation, optional Prometheus
  textfile metrics, systemd units, `install.sh`, tarball packaging, PBM user script.
- Verified against PBM 2.12.0 output and source, and the PBM 2.5.0 source (last release for
  MongoDB 4.4; no native GCS before 2.10, no agent config file before 2.9); not yet run on a
  live cluster (see the "Not yet verified" list in README.md).

## Goal
Extend the system to support MongoDB >= 4.x, both PSMDB and MongoDB Community:
- PSMDB: physical / incremental physical backups (requires $backupCursor).
- Community: logical backups (no physical backup available on-prem).
- Daily full backup + incrementals based on oplog timestamps between consecutive backups.
  Preferred approach: PBM native logical snapshot + PITR oplog slicing (pitr.enabled=true,
  pitr.oplogSpanMin), validating oplog chain continuity (no gaps) since the last full via
  `pbm status -o json` / `pbm list -o json`. Do NOT hand-roll mongodump-based oplog tailing
  unless explicitly requested.

## Requirements
- Auto-detect server version (db.version()) and edition (buildInfo / $backupCursor availability)
  and select backup type accordingly.
- Validate installed PBM version against MongoDB version (PBM 2.3.0 deprecated 4.2,
  PBM 2.6.0 dropped 4.4; 4.0 needs PBM 1.x). Recommend pinning the package on 4.x nodes.
- Check oplog window vs. expected logical dump duration before running a full.
- Retention (pbm cleanup --older-than) must keep the last valid base snapshot for PITR.
- Optional Prometheus textfile-collector metrics (last backup ts, PITR lag, backup status);
  keep PMM2/PMM3 compatibility.

## Agreed design decisions
- PBM 2.x only. Backups always go to the GCS bucket and are always compressed
  (`--compression` on every `pbm backup`, `pitr.compression` for oplog slices).
- No NFS: PBM filesystem storage and any local/per-node storage mode are out of scope.
- Never back up on the primary; keep backing up on the member that owns the chain.
- PBM user: exactly the roles in the PBM documentation (`mongodb/pbmuser.create.js`, run by
  hand once per replica set; passwords shown and saved to a 0600 file; existing users keep
  their password unless rotation is requested).

## Layout
- `bin/pbm-backup`, `lib/*.sh` (common, mongo, pbm, compat, topology, metrics).
- `systemd/` (new units; `legacy/` = original ones), `sysconfig/` (env templates and wrappers
  for the legacy units), `conf/` (PBM templates), `etc/pbm-backup.conf.example` (tunables).
- `install.sh`, `packaging/build-dist.sh`, `mongodb/pbmuser.create.js`,
  `tools/gcs-hmac-test.py` (GCS HMAC key check, Python stdlib).
- `tests/` (smoke.sh, pbmuser.test.sh, mocks, PBM 2.12.0 fixtures).

## Testing and release
- `tests/smoke.sh` (bash from PATH) and `tests/smoke.sh /bin/bash` (macOS bash 3.2);
  `tests/pbmuser.test.sh` (real mongosh, fake admin DB). Mocks must reproduce real PBM
  output exactly (fixtures come from real `pbm` output; check the PBM source when unsure).
- Release: bump `VERSION=` in `bin/pbm-backup`, update CHANGES.md, run
  `packaging/build-dist.sh` (runs both suites, writes `dist/pbm-backup-<version>.tar.gz`
  + `.sha256`). Fixtures and examples must stay anonymized (public repository).

## Coding standards
- Bash with `set -euo pipefail`, portable across Linux and macOS (BSD vs GNU tools: date, sed, stat).
- Every script must have --help with description, parameters and usage examples.
- Colored, intuitive output. Comments, docs and messages in English.
- Reference user in examples: rmateos.
- Review existing code first, keep what works, explain changes as diffs.
