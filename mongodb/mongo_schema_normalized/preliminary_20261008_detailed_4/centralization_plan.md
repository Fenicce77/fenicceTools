# MongoDB Centralization Plan

- Generated at: `2026-10-08T18:17:16Z` (bash implementation)
- Naming strategy: `auto` (separator `_`, mapping entries: 0)
- Target instance: _not defined_
- Findings: **0** errors, **1** warnings, **111** info

**Status: READY** - no blocking errors (review the warnings).

## 1. Capacity

| Instance | Documents | Data | Storage | Indexes |
|---|---:|---:|---:|---:|
| cd | 52611 | 30.33 GiB | 4.70 GiB | 1.47 MiB |
| gh | 1 | 52 B | 20.00 KiB | 20.00 KiB |
| ke | 130682 | 3.34 GiB | 543.88 MiB | 3.51 MiB |
| mw | 0 | 0 B | 0 B | 0 B |
| tz | 0 | 0 B | 0 B | 0 B |
| ug | 0 | 0 B | 0 B | 0 B |
| **Total** | **183294** | **33.67 GiB** | **5.23 GiB** | **5.00 MiB** |

## 2. Database mapping

| Instance | Source DB | Target DB | Reason | Collections | Views | Documents | Storage |
|---|---|---|---|---:|---:|---:|---:|
| cd | betika_cd | betika_cd | keep | 19 | 0 | 52611 | 4.70 GiB |
| gh | betika_gh | betika_gh | keep | 1 | 0 | 1 | 20.00 KiB |
| ke | betika_favorites | betika_favorites | keep | 1 | 0 | 3 | 32.00 KiB |
| ke | betika_help_center | betika_help_center | keep | 3 | 0 | 124835 | 6.98 MiB |
| ke | recon-engine | recon-engine | keep | 13 | 0 | 5844 | 536.87 MiB |

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

14 user(s) and 4 custom role(s) will be created by the `security` bootstrap phase (passwords are prompted, never exported).
- **[WARN] ROLE_CONFLICT** `explainRole@admin` (cd,gh,ke,mw,tz,ug): custom role differs across sources; bootstrap uses the definition from 'cd'

**Users to migrate (activity observed):** 2
- `cd` `reconciliation_app@betika_cd` - access: betika_cd; namespaces: betika_cd.recon.job.entries, betika_cd.recon.job.info
- `ke` `help_admin@betika_help_center` - access: betika_help_center; namespaces: betika_help_center.kb

**Users to review (access granted, no activity observed):** 31
- `cd` `admin@admin` - access: *; namespaces: -
- `cd` `mongodb_exporter@admin` - access: local; namespaces: -
- `cd` `pmm_monitor@admin` - access: *, local; namespaces: -
- `cd` `schema_auditor@admin` - access: *, config, local; namespaces: -
- `gh` `admin@admin` - access: *; namespaces: -
- `gh` `mongodb_exporter@admin` - access: local; namespaces: -
- `gh` `pmm_monitor@admin` - access: *, local; namespaces: -
- `gh` `recon_app@admin` - access: betika_gh; namespaces: -
- `gh` `schema_auditor@admin` - access: *, config, local; namespaces: -
- `ke` `admin@admin` - access: *; namespaces: -
- `ke` `mongodb_exporter@admin` - access: local; namespaces: -
- `ke` `pmm_monitor@admin` - access: *, local; namespaces: -
- `ke` `recon-engine_app@admin` - access: recon-engine; namespaces: -
- `ke` `recon-engine_app@recon-engine` - access: recon-engine; namespaces: -
- `ke` `root@admin` - access: *; namespaces: -
- `ke` `schema_auditor@admin` - access: *, config, local; namespaces: -
- `ke` `uxUser@admin` - access: betika_favorites; namespaces: -
- `ke` `uxUser@betika_favorites` - access: betika_favorites; namespaces: -
- `mw` `admin@admin` - access: *; namespaces: -
- `mw` `mongodb_exporter@admin` - access: local; namespaces: -
- `mw` `pbmuser@admin` - access: *, admin; namespaces: -
- `mw` `pmm_monitor@admin` - access: *, local; namespaces: -
- `mw` `schema_auditor@admin` - access: *, config, local; namespaces: -
- `tz` `admin@admin` - access: *; namespaces: -
- `tz` `betikaknowlegebase_app@admin` - access: *; namespaces: -
- `tz` `mongodb_exporter@admin` - access: local; namespaces: -
- `tz` `pmm_monitor@admin` - access: *, local; namespaces: -
- `tz` `schema_auditor@admin` - access: *, config, local; namespaces: -
- `ug` `admin@admin` - access: *; namespaces: -
- `ug` `pmm_monitor@admin` - access: *, local; namespaces: -
- `ug` `schema_auditor@admin` - access: *, config, local; namespaces: -

**Users without activity data (no oplog window or sampling):** 0

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
