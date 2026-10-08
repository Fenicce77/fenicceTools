# MongoDB Schema Analysis Report

- Generated at: `2026-10-08T18:17:16Z` (bash implementation)
- Naming strategy: `auto` (separator `_`, mapping entries: 0)
- Target instance: _not defined_
- Findings: **0** errors, **1** warnings, **111** info

## 1. Instances

| Instance | Alias | Role | Status | Version | FCV | Topology | DBs | Collections | Views | Documents | Data | Storage | Indexes |
|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| cd | cd | source | ok | 4.4.15 | 4.4 | replicaset | 1 | 19 | 0 | 52611 | 30.33 GiB | 4.70 GiB | 1.47 MiB |
| gh | gh | source | ok | 4.4.29 | 4.4 | replicaset | 1 | 1 | 0 | 1 | 52 B | 20.00 KiB | 20.00 KiB |
| ke | ke | source | ok | 4.4.3 | 4.4 | replicaset | 3 | 17 | 0 | 130682 | 3.34 GiB | 543.88 MiB | 3.51 MiB |
| mw | mw | source | ok | 4.4.13 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| tz | tz | source | ok | 4.4.22 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| ug | ug | source | ok | 4.4.25 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |

## 2. Findings summary

| Severity | Code | Count |
|---|---|---:|
| WARN | ROLE_CONFLICT | 1 |
| INFO | ARRAY_TYPES_POLYMORPHIC | 4 |
| INFO | NO_RECENT_ACTIVITY | 34 |
| INFO | NO_TARGET | 1 |
| INFO | NO_USER_DATABASES | 3 |
| INFO | ROLE_DUPLICATE | 2 |
| INFO | SCHEMA_TRUNCATED | 1 |
| INFO | STALE_COLLECTION | 31 |
| INFO | USER_DUPLICATE | 4 |
| INFO | USER_NO_ACTIVITY | 31 |

## 3. Errors

_None._

## 4. Warnings

- **[WARN] ROLE_CONFLICT** `explainRole@admin` (cd,gh,ke,mw,tz,ug): custom role differs across sources; bootstrap uses the definition from 'cd'

## 5. Informational

- **[INFO] ARRAY_TYPES_POLYMORPHIC** `betika_cd.recon.config.filter` (cd): 1 array field(s) mix BSON types inside the same document (polymorphic / key-value pattern, usually by design; not a normalization candidate)
  - `columns[].functions[].parameters[]: string=12, double=1 (in 12 doc(s))`
- **[INFO] ARRAY_TYPES_POLYMORPHIC** `betika_cd.recon.job.info` (cd): 1 array field(s) mix BSON types inside the same document (polymorphic / key-value pattern, usually by design; not a normalization candidate)
  - `steps[].attachments[].value: int=100, string=100 (in 100 doc(s))`
- **[INFO] ARRAY_TYPES_POLYMORPHIC** `recon-engine.recon.config.filter` (ke): 1 array field(s) mix BSON types inside the same document (polymorphic / key-value pattern, usually by design; not a normalization candidate)
  - `columns[].functions[].parameters[]: string=6, int=1 (in 6 doc(s))`
- **[INFO] ARRAY_TYPES_POLYMORPHIC** `recon-engine.recon.job.info` (ke): 1 array field(s) mix BSON types inside the same document (polymorphic / key-value pattern, usually by design; not a normalization candidate)
  - `steps[].attachments[].value: int=100, string=100 (in 100 doc(s))`
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.doc.extension` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.doc.type` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.field` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.filter` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.job` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.provider` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.settlement` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.transaction.type` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.config.transfer.expiry` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.history` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.job` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.notification` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.progress` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.provider` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.provider.query` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.stage` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_cd.recon.transfer` (cd): no writes since 2026-10-07T18:12:17Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_gh.user` (gh): no writes since 2026-10-07T18:10:48Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_favorites.favorites` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_help_center.users` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `betika_help_center.votes` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.doc.extension` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.doc.type` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.field` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.filter` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.job` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.provider` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.settlement` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.transaction.type` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.config.transfer.expiry` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.history` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.job.entries` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.recon.job.info` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_RECENT_ACTIVITY** `recon-engine.test` (ke): no writes since 2026-10-07T18:11:50Z (oplog) and no reads/writes since -: candidate for archiving instead of migrating
- **[INFO] NO_TARGET**: no target instance defined; the central instance should run MongoDB >= 4.4
- **[INFO] NO_USER_DATABASES** (mw): the instance has no user databases (listed: admin, config, local): nothing to migrate
- **[INFO] NO_USER_DATABASES** (tz): the instance has no user databases (listed: admin, config, local): nothing to migrate
- **[INFO] NO_USER_DATABASES** (ug): the instance has no user databases (listed: admin, config, local): nothing to migrate
- **[INFO] ROLE_DUPLICATE** `bmnSchemaAuditor@admin` (cd,gh,ke,mw,tz,ug): same custom role defined in several sources
- **[INFO] ROLE_DUPLICATE** `oplogReader@admin` (cd,gh,ke,mw,tz,ug): same custom role defined in several sources
- **[INFO] SCHEMA_TRUNCATED** `betika_cd.recon.job.info` (cd): field path limit reached while sampling (dynamic keys?); schema is partial
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.doc.extension` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:01:05Z (1073 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.doc.type` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:00:03Z (1073 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.field` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:03:41Z (1073 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.filter` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:10:52Z (394 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.job` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:59:59Z (394 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.provider` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T08:35:45Z (394 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.settlement` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:26:34Z (394 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.transaction.type` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T06:59:34Z (1073 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.transfer.expiry` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-30T14:38:25Z (1074 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.history` (cd): no inserts (no *modified* date field: updates are not visible) since 2024-07-11T11:22:02Z (819 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.job` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T07:12:46Z (1158 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.notification` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-07-24T09:38:22Z (1172 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.progress` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T08:33:58Z (1158 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.provider` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-07-12T07:11:07Z (1184 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.provider.query` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-03T10:09:06Z (1162 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.stage` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T07:13:58Z (1158 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.transfer` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-04T10:16:01Z (1161 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_gh.user` (gh): no inserts (no *modified* date field: updates are not visible) since 2024-10-14T14:49:25Z (724 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.kb` (ke): no inserts (no *modified* date field: updates are not visible) since 2021-08-12T20:48:48Z (1882 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.users` (ke): no inserts (no *modified* date field: updates are not visible) since 2018-11-14T09:34:56Z (2885 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.votes` (ke): no inserts (no *modified* date field: updates are not visible) since 2024-11-27T22:10:36Z (679 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.doc.extension` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:23:46Z (1024 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.doc.type` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:22:45Z (1024 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.field` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:30:36Z (1024 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.filter` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:36:49Z (217 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.job` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-05-07T07:29:25Z (154 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.provider` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:30:42Z (217 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.settlement` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:31:48Z (217 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.transaction.type` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:22:23Z (1024 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.transfer.expiry` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:16:50Z (1024 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.history` (ke): no inserts (no *modified* date field: updates are not visible) since 2024-03-04T07:36:59Z (948 days before the collection date)
- **[INFO] USER_DUPLICATE** `mongodb_exporter@admin` (cd,gh,ke,mw,tz): same user and roles defined in several sources
- **[INFO] USER_DUPLICATE** `admin@admin` (cd,gh,ke,mw,tz,ug): same user and roles defined in several sources
- **[INFO] USER_DUPLICATE** `pmm_monitor@admin` (cd,gh,ke,mw,tz,ug): same user and roles defined in several sources
- **[INFO] USER_DUPLICATE** `schema_auditor@admin` (cd,gh,ke,mw,tz,ug): same user and roles defined in several sources
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (cd): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `mongodb_exporter@admin` (cd): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (cd): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (cd): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (gh): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `mongodb_exporter@admin` (gh): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (gh): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `recon_app@admin` (gh): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (gh): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `mongodb_exporter@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `recon-engine_app@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `recon-engine_app@recon-engine` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `root@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `uxUser@admin` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `uxUser@betika_favorites` (ke): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (mw): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `mongodb_exporter@admin` (mw): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pbmuser@admin` (mw): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (mw): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (mw): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (tz): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `betikaknowlegebase_app@admin` (tz): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `mongodb_exporter@admin` (tz): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (tz): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (tz): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `admin@admin` (ug): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `pmm_monitor@admin` (ug): user has access but no activity was observed (oplog/sampling)
- **[INFO] USER_NO_ACTIVITY** `schema_auditor@admin` (ug): user has access but no activity was observed (oplog/sampling)

## 6. Inventory

### Instance `cd`

| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |
|---|---|---|---:|---:|---:|---:|---:|---|---|---:|
| betika_cd | recon.config.doc.extension | collection | 2 | 460 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.config.doc.type | collection | 2 | 146 B | 20.00 KiB | 1 | 20.00 KiB | no | - | 0 |
| betika_cd | recon.config.field | collection | 5 | 461 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.config.filter | collection | 18 | 6.21 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 1 |
| betika_cd | recon.config.job | collection | 22 | 18.77 KiB | 44.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.config.provider | collection | 17 | 2.21 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.config.settlement | collection | 25 | 8.87 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.config.transaction.type | collection | 2 | 222 B | 20.00 KiB | 1 | 20.00 KiB | no | - | 0 |
| betika_cd | recon.config.transfer.expiry | collection | 1 | 67 B | 20.00 KiB | 1 | 20.00 KiB | no | - | 0 |
| betika_cd | recon.history | collection | 16766 | 2.88 MiB | 780.00 KiB | 1 | 296.00 KiB | no | - | 0 |
| betika_cd | recon.job | collection | 39 | 26.05 KiB | 44.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.job.entries | collection | 23340 | 29.33 GiB | 4.50 GiB | 1 | 404.00 KiB | no | - | 0 |
| betika_cd | recon.job.info | collection | 12193 | 1.00 GiB | 201.10 MiB | 1 | 276.00 KiB | no | - | 1 |
| betika_cd | recon.notification | collection | 13 | 6.54 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.progress | collection | 66 | 77.17 KiB | 56.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.provider | collection | 4 | 514 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.provider.query | collection | 8 | 2.45 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.stage | collection | 82 | 31.84 KiB | 44.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.transfer | collection | 6 | 2.22 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |

### Instance `gh`

| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |
|---|---|---|---:|---:|---:|---:|---:|---|---|---:|
| betika_gh | user | collection | 1 | 52 B | 20.00 KiB | 1 | 20.00 KiB | no | - | 0 |

### Instance `ke`

| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |
|---|---|---|---:|---:|---:|---:|---:|---|---|---:|
| betika_favorites | favorites | collection | 3 | 1.28 KiB | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| betika_help_center | kb | collection | 29 | 76.56 KiB | 92.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_help_center | users | collection | 4 | 774 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| betika_help_center | votes | collection | 124802 | 12.85 MiB | 6.86 MiB | 1 | 2.90 MiB | no | - | 0 |
| recon-engine | recon.config.doc.extension | collection | 2 | 409 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.doc.type | collection | 2 | 146 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.field | collection | 5 | 461 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.filter | collection | 7 | 2.86 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 1 |
| recon-engine | recon.config.job | collection | 8 | 6.80 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.provider | collection | 7 | 979 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.settlement | collection | 7 | 2.27 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.transaction.type | collection | 2 | 222 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.transfer.expiry | collection | 1 | 67 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.history | collection | 632 | 112.08 KiB | 52.00 KiB | 1 | 40.00 KiB | no | - | 0 |
| recon-engine | recon.job.entries | collection | 3435 | 3.32 GiB | 535.86 MiB | 1 | 92.00 KiB | no | - | 0 |
| recon-engine | recon.job.info | collection | 1736 | 3.09 MiB | 664.00 KiB | 1 | 76.00 KiB | no | - | 1 |
| recon-engine | test | collection | 0 | 0 B | 12.00 KiB | 1 | 12.00 KiB | no | - | 0 |

### Instance `mw`

_No user databases._

### Instance `tz`

_No user databases._

### Instance `ug`

_No user databases._

## 7. Cross-instance comparison

### 7.1 Database name overlap

_No overlapping database names._

### 7.2 Shared namespaces (drift)

_No namespaces shared across instances._
## 8. Activity

`~` dates come from ObjectId `_id` values (inserts only, client clock). *Last modified* comes from date fields matching the modified pattern: exact through an index or `--modified-scan`; `≥` is a lower bound taken from the sampled documents.

### Instance `cd`

- Members: cd-mongodbcluster01-node01.betika.private:27017 (PRIMARY), cd-mongodbcluster01-node02.betika.private:27017 (SECONDARY), cd-mongodbcluster01-node03.betika.private:27017 (SECONDARY)
- Oplog: 24 h requested on cd-mongodbcluster01-node02.betika.private:27017; analyzed from 2026-10-07T18:12:17Z to 2026-10-08T18:12:08Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:12:18Z - 2026-10-08T18:17:15Z

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field | Created (oplog) | Last write (oplog) | Oplog i/u/d/c | Sampled ops | Users |
|---|---|---|---|---|---|---|---|---|---:|---|
| betika_cd.recon.config.doc.extension | objectId | 2023-10-31T07:00:29Z | 2023-10-31T07:01:05Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.doc.type | objectId | 2023-10-31T06:59:58Z | 2023-10-31T07:00:03Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.field | objectId | 2023-10-31T07:03:01Z | 2023-10-31T07:03:41Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.filter | objectId | 2023-12-05T10:27:43Z | 2025-09-09T09:10:52Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.job | objectId | 2023-12-05T10:24:49Z | 2025-09-09T09:59:59Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.provider | objectId | 2023-10-31T06:27:48Z | 2025-09-09T08:35:45Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.settlement | objectId | 2023-11-29T09:26:58Z | 2025-09-09T09:26:34Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.transaction.type | objectId | 2023-10-31T06:59:15Z | 2023-10-31T06:59:34Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.config.transfer.expiry | objectId | 2023-10-30T14:38:25Z | 2023-10-30T14:38:25Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.history | objectId | 2023-07-18T11:09:22Z | 2024-07-11T11:22:02Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.job | objectId | 2023-07-18T11:09:22Z | 2023-08-07T07:12:46Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.job.entries | objectId | 2023-12-05T10:40:42Z | 2026-10-08T17:14:25Z | - | - | - | 2026-10-08T17:15:57Z | 22/22/0/0 | 0 | reconciliation_app@betika_cd (44) |
| betika_cd.recon.job.info | objectId | 2023-12-05T10:40:07Z | 2026-10-08T17:12:45Z | - | - | - | 2026-10-08T17:16:00Z | 12/11/0/0 | 0 | reconciliation_app@betika_cd (23) |
| betika_cd.recon.notification | objectId | 2023-07-19T08:01:13Z | 2023-07-24T09:38:22Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.progress | objectId | 2023-07-20T11:47:33Z | 2023-08-07T08:33:58Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.provider | objectId | 2023-07-11T12:25:56Z | 2023-07-12T07:11:07Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.provider.query | objectId | 2023-08-03T10:07:26Z | 2023-08-03T10:09:06Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.stage | objectId | 2023-07-19T08:00:49Z | 2023-08-07T07:13:58Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_cd.recon.transfer | objectId | 2023-07-19T08:01:13Z | 2023-08-04T10:16:01Z | - | - | - | - | 0/0/0/0 | 0 | - |

### Instance `gh`

- Members: gh-mongodbcluster01.betika.private:27017 (SECONDARY), gh-mongodbcluster02.betika.private:27017 (PRIMARY), gh-mongodbcluster03.betika.private:27017 (SECONDARY)
- Oplog: 24 h requested on gh-mongodbcluster01.betika.private:27017; analyzed from 2026-10-07T18:10:48Z to 2026-10-08T18:10:43Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:10:48Z - 2026-10-08T18:15:46Z

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field | Created (oplog) | Last write (oplog) | Oplog i/u/d/c | Sampled ops | Users |
|---|---|---|---|---|---|---|---|---|---:|---|
| betika_gh.user | objectId | 2024-10-14T14:49:25Z | 2024-10-14T14:49:25Z | - | - | - | - | 0/0/0/0 | 0 | - |

### Instance `ke`

- Members: ke-mongodbcluster01.betika.private:27017 (SECONDARY), ke-mongodbcluster03.betika.private:27017 (SECONDARY), ke-mongodbcluster02.betika.private:27017 (PRIMARY)
- Oplog: 24 h requested on ke-mongodbcluster01.betika.private:27017; analyzed from 2026-10-07T18:11:50Z to 2026-10-08T18:11:45Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:11:50Z - 2026-10-08T18:16:48Z

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field | Created (oplog) | Last write (oplog) | Oplog i/u/d/c | Sampled ops | Users |
|---|---|---|---|---|---|---|---|---|---:|---|
| betika_favorites.favorites | other | - | - | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_help_center.kb | objectId | 2018-12-03T15:11:27Z | 2021-08-12T20:48:48Z | - | - | - | 2026-10-08T17:35:04Z | 0/32/0/0 | 0 | help_admin@betika_help_center (32) |
| betika_help_center.users | objectId | 2018-11-12T09:35:39Z | 2018-11-14T09:34:56Z | - | - | - | - | 0/0/0/0 | 0 | - |
| betika_help_center.votes | objectId | 2018-11-12T09:58:19Z | 2024-11-27T22:10:36Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.doc.extension | objectId | 2023-12-19T12:23:19Z | 2023-12-19T12:23:46Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.doc.type | objectId | 2023-12-19T12:22:40Z | 2023-12-19T12:22:45Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.field | objectId | 2023-12-19T12:29:45Z | 2023-12-19T12:30:36Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.filter | objectId | 2023-12-20T13:51:34Z | 2026-03-05T10:36:49Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.job | objectId | 2023-12-20T13:21:51Z | 2026-05-07T07:29:25Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.provider | objectId | 2023-12-20T13:19:08Z | 2026-03-05T10:30:42Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.settlement | objectId | 2023-12-20T13:19:47Z | 2026-03-05T10:31:48Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.transaction.type | objectId | 2023-12-19T12:22:16Z | 2023-12-19T12:22:23Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.config.transfer.expiry | objectId | 2023-12-19T12:16:50Z | 2023-12-19T12:16:50Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.history | objectId | 2023-12-19T12:39:06Z | 2024-03-04T07:36:59Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.job.entries | objectId | 2023-12-19T12:45:41Z | 2026-10-07T12:05:54Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.recon.job.info | objectId | 2023-12-19T12:45:11Z | 2026-10-07T12:05:09Z | - | - | - | - | 0/0/0/0 | 0 | - |
| recon-engine.test | empty | - | - | - | - | - | - | 0/0/0/0 | 0 | - |

### Instance `mw`

- Members: mw-mongodbcluster01.betika.private:27017 (PRIMARY), mw-mongodbcluster02.betika.private:27017 (SECONDARY), mw-mongodbcluster03.betika.private:27017 (SECONDARY)
- Oplog: 24 h requested on mw-mongodbcluster02.betika.private:27017; analyzed from 2026-10-07T18:10:47Z to 2026-10-08T18:10:43Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:10:48Z - 2026-10-08T18:15:45Z

_No collections._

### Instance `tz`

- Members: tz-mongodbcluster01-node01.betika.private:27017 (SECONDARY), tz-mongodbcluster01-node02.betika.private:27017 (PRIMARY), tz-mongodbcluster01-node03.betika.private:27017 (SECONDARY)
- Oplog: 24 h requested on tz-mongodbcluster01-node01.betika.private:27017; analyzed from 2026-10-07T18:10:47Z to 2026-10-08T18:10:39Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:10:47Z - 2026-10-08T18:15:45Z

_No collections._

### Instance `ug`

- Members: ug-mongodbcluster01-node01.betika.private:27017 (SECONDARY), ug-mongodbcluster01-node02.betika.private:27017 (PRIMARY), ug-mongodbcluster01-node03.betika.private:27017 (SECONDARY)
- Oplog: 24 h requested on ug-mongodbcluster01-node01.betika.private:27017; analyzed from 2026-10-07T18:10:47Z to 2026-10-08T18:10:47Z
- Live sampling: 30 round(s) every 10 s on 3 member(s), 2026-10-08T18:10:47Z - 2026-10-08T18:15:45Z

_No collections._

## 9. Users

| Instance | User | Defined | Access (source DBs) | Observed via | Oplog writes | Sampled ops | Namespaces | Applications | Clients | Recommendation |
|---|---|---|---|---|---:|---:|---|---|---|---|
| cd | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| cd | mongodb_exporter@admin | yes | local | - | 0 | 0 | - | - | - | **review** |
| cd | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| cd | reconciliation_app@betika_cd | yes | betika_cd | oplog | 67 | 0 | betika_cd.recon.job.entries, betika_cd.recon.job.info | - | - | **migrate** |
| cd | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
| gh | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| gh | mongodb_exporter@admin | yes | local | - | 0 | 0 | - | - | - | **review** |
| gh | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| gh | recon_app@admin | yes | betika_gh | - | 0 | 0 | - | - | - | **review** |
| gh | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
| ke | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| ke | help_admin@betika_help_center | yes | betika_help_center | oplog | 32 | 0 | betika_help_center.kb | - | - | **migrate** |
| ke | mongodb_exporter@admin | yes | local | - | 0 | 0 | - | - | - | **review** |
| ke | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| ke | recon-engine_app@admin | yes | recon-engine | - | 0 | 0 | - | - | - | **review** |
| ke | recon-engine_app@recon-engine | yes | recon-engine | - | 0 | 0 | - | - | - | **review** |
| ke | root@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| ke | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
| ke | uxUser@admin | yes | betika_favorites | - | 0 | 0 | - | - | - | **review** |
| ke | uxUser@betika_favorites | yes | betika_favorites | - | 0 | 0 | - | - | - | **review** |
| mw | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| mw | mongodb_exporter@admin | yes | local | - | 0 | 0 | - | - | - | **review** |
| mw | pbmuser@admin | yes | *, admin | - | 0 | 0 | - | - | - | **review** |
| mw | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| mw | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
| tz | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| tz | betikaknowlegebase_app@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| tz | mongodb_exporter@admin | yes | local | - | 0 | 0 | - | - | - | **review** |
| tz | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| tz | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
| ug | admin@admin | yes | * | - | 0 | 0 | - | - | - | **review** |
| ug | pmm_monitor@admin | yes | *, local | - | 0 | 0 | - | - | - | **review** |
| ug | schema_auditor@admin | yes | *, config, local | - | 0 | 0 | - | - | - | **review** |
