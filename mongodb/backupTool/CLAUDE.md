# Project: Generic PBM backup system for MongoDB

## Current state
Bash scripts performing PBM physical backups only, for Percona Server for MongoDB (PSMDB) v8 replica sets.

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

## Coding standards
- Bash with `set -euo pipefail`, portable across Linux and macOS (BSD vs GNU tools: date, sed, stat).
- Every script must have --help with description, parameters and usage examples.
- Colored, intuitive output. Comments, docs and messages in English.
- Reference user in examples: rmateos.
- Review existing code first, keep what works, explain changes as diffs.
