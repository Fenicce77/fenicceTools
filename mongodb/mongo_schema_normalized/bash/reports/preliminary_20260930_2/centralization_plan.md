# MongoDB Centralization Plan

- Generated at: `2026-09-30T18:27:36Z` (bash implementation)
- Naming strategy: `auto` (separator `_`, mapping entries: 0)
- Target instance: _not defined_
- Findings: **0** errors, **4** warnings, **2** info

**Status: READY** - no blocking errors (review the warnings).

## 1. Capacity

| Instance | Documents | Data | Storage | Indexes |
|---|---:|---:|---:|---:|
| cd | 52302 | 30.13 GiB | 4.67 GiB | 1.41 MiB |
| gh | 1 | 52 B | 32.00 KiB | 32.00 KiB |
| ke | 130550 | 3.19 GiB | 521.68 MiB | 3.51 MiB |
| mw | 0 | 0 B | 0 B | 0 B |
| tz | 0 | 0 B | 0 B | 0 B |
| ug | 0 | 0 B | 0 B | 0 B |
| **Total** | **182853** | **33.32 GiB** | **5.18 GiB** | **4.95 MiB** |

## 2. Database mapping

| Instance | Source DB | Target DB | Reason | Collections | Views | Documents | Storage |
|---|---|---|---|---:|---:|---:|---:|
| cd | betika_cd | betika_cd | keep | 19 | 0 | 52302 | 4.67 GiB |
| gh | betika_gh | betika_gh | keep | 1 | 0 | 1 | 32.00 KiB |
| ke | betika_favorites | betika_favorites | keep | 1 | 0 | 3 | 32.00 KiB |
| ke | betika_help_center | betika_help_center | keep | 3 | 0 | 124835 | 6.98 MiB |
| ke | recon-engine | recon-engine | keep | 13 | 0 | 5712 | 514.67 MiB |

## 3. Required modifications

### 3.1 Blocking issues

_None._

### 3.2 Database renames (application impact)

_No database renames required._

### 3.3 Index harmonization

_No index drift between instances._

### 3.4 Data type normalization

_No scalar type normalization candidates._

### 3.5 Sharding

_No sharded source collections._

### 3.6 Security

_Security objects not collected (run the collection with --include-security)._

## 4. Execution runbook

1. Resolve every blocking issue and re-run the analysis until the status is READY.
2. Create the database-tools YAML files referenced by `migration_commands.sh` (chmod 600).
3. Freeze writes on the source databases: `mongodump` without `--oplog` is not point-in-time.
4. `BMN_PHASE=collections mongosh <target> --file target_bootstrap.js` (dry-run), then with `BMN_APPLY=1`.
5. `./migration_commands.sh --list`, then `./migration_commands.sh --apply`.
6. `BMN_PHASE=indexes`, then `BMN_PHASE=views`, then `BMN_PHASE=security` with `BMN_APPLY=1`.
7. Review and optionally apply `normalization_suggestions.js`.
8. `BMN_PHASE=verify` to compare document counts, then switch application connection strings.

## 5. Generated artifacts

- `analysis.json`: machine-readable analysis (mapping, drift, findings).
- `report.md`: inventory and cross-instance comparison.
- `target_bootstrap.js`: idempotent mongosh bootstrap for the target (phased).
- `migration_commands.sh`: mongodump/mongorestore jobs with namespace remapping.
- `normalization_suggestions.js`: type normalization candidates.
- `snapshots/`: raw per-instance schema snapshots (no document values).
