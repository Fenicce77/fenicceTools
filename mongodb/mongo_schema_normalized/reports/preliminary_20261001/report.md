# MongoDB Schema Analysis Report

- Generated at: `2026-10-01T16:48:52Z` (bash implementation)
- Naming strategy: `auto` (separator `_`, mapping entries: 0)
- Target instance: _not defined_
- Findings: **0** errors, **4** warnings, **33** info

## 1. Instances

| Instance | Alias | Role | Status | Version | FCV | Topology | DBs | Collections | Views | Documents | Data | Storage | Indexes |
|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| cd | cd | source | ok | 4.4.15 | 4.4 | replicaset | 1 | 19 | 0 | 52352 | 30.21 GiB | 4.68 GiB | 1.41 MiB |
| gh | gh | source | ok | 4.4.29 | 4.4 | replicaset | 1 | 1 | 0 | 1 | 52 B | 20.00 KiB | 20.00 KiB |
| ke | ke | source | ok | 4.4.3 | 4.4 | replicaset | 3 | 17 | 0 | 130616 | 3.26 GiB | 533.12 MiB | 3.50 MiB |
| mw | mw | source | ok | 4.4.13 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| tz | tz | source | ok | 4.4.22 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| ug | ug | source | ok | 4.4.25 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |

## 2. Findings summary

| Severity | Code | Count |
|---|---|---:|
| WARN | FIELD_TYPE_MIXED | 4 |
| INFO | NO_TARGET | 1 |
| INFO | SCHEMA_TRUNCATED | 1 |
| INFO | STALE_COLLECTION | 31 |

## 3. Errors

_None._

## 4. Warnings

- **[WARN] FIELD_TYPE_MIXED** `betika_cd.recon.config.filter` (cd): 1 field(s) with inconsistent BSON types in a sample of 18 document(s)
  - `columns[].functions[].parameters[]: string=12, double=1`
- **[WARN] FIELD_TYPE_MIXED** `betika_cd.recon.job.info` (cd): 1 field(s) with inconsistent BSON types in a sample of 100 document(s)
  - `steps[].attachments[].value: int=100, string=100`
- **[WARN] FIELD_TYPE_MIXED** `recon-engine.recon.config.filter` (ke): 1 field(s) with inconsistent BSON types in a sample of 7 document(s)
  - `columns[].functions[].parameters[]: string=6, int=1`
- **[WARN] FIELD_TYPE_MIXED** `recon-engine.recon.job.info` (ke): 1 field(s) with inconsistent BSON types in a sample of 100 document(s)
  - `steps[].attachments[].value: int=100, string=100`

## 5. Informational

- **[INFO] NO_TARGET**: no target instance defined; the central instance should run MongoDB >= 4.4
- **[INFO] SCHEMA_TRUNCATED** `betika_cd.recon.job.info` (cd): field path limit reached while sampling (dynamic keys?); schema is partial
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.doc.extension` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:01:05Z (1066 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.doc.type` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:00:03Z (1066 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.field` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T07:03:41Z (1066 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.filter` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:10:52Z (387 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.job` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:59:59Z (387 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.provider` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T08:35:45Z (387 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.settlement` (cd): no inserts (no *modified* date field: updates are not visible) since 2025-09-09T09:26:34Z (387 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.transaction.type` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-31T06:59:34Z (1066 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.config.transfer.expiry` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-10-30T14:38:25Z (1067 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.history` (cd): no inserts (no *modified* date field: updates are not visible) since 2024-07-11T11:22:02Z (812 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.job` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T07:12:46Z (1151 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.notification` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-07-24T09:38:22Z (1165 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.progress` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T08:33:58Z (1151 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.provider` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-07-12T07:11:07Z (1177 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.provider.query` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-03T10:09:06Z (1155 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.stage` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-07T07:13:58Z (1151 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_cd.recon.transfer` (cd): no inserts (no *modified* date field: updates are not visible) since 2023-08-04T10:16:01Z (1154 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_gh.user` (gh): no inserts (no *modified* date field: updates are not visible) since 2024-10-14T14:49:25Z (717 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.kb` (ke): no inserts (no *modified* date field: updates are not visible) since 2021-08-12T20:48:48Z (1875 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.users` (ke): no inserts (no *modified* date field: updates are not visible) since 2018-11-14T09:34:56Z (2878 days before the collection date)
- **[INFO] STALE_COLLECTION** `betika_help_center.votes` (ke): no inserts (no *modified* date field: updates are not visible) since 2024-11-27T22:10:36Z (672 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.doc.extension` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:23:46Z (1017 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.doc.type` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:22:45Z (1017 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.field` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:30:36Z (1017 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.filter` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:36:49Z (210 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.job` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-05-07T07:29:25Z (147 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.provider` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:30:42Z (210 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.settlement` (ke): no inserts (no *modified* date field: updates are not visible) since 2026-03-05T10:31:48Z (210 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.transaction.type` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:22:23Z (1017 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.config.transfer.expiry` (ke): no inserts (no *modified* date field: updates are not visible) since 2023-12-19T12:16:50Z (1017 days before the collection date)
- **[INFO] STALE_COLLECTION** `recon-engine.recon.history` (ke): no inserts (no *modified* date field: updates are not visible) since 2024-03-04T07:36:59Z (941 days before the collection date)

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
| betika_cd | recon.history | collection | 16766 | 2.88 MiB | 788.00 KiB | 1 | 284.00 KiB | no | - | 0 |
| betika_cd | recon.job | collection | 39 | 26.05 KiB | 44.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.job.entries | collection | 23173 | 29.21 GiB | 4.48 GiB | 1 | 360.00 KiB | no | - | 0 |
| betika_cd | recon.job.info | collection | 12101 | 1.00 GiB | 202.18 MiB | 1 | 272.00 KiB | no | - | 1 |
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
| betika_help_center | votes | collection | 124802 | 12.85 MiB | 6.57 MiB | 1 | 2.89 MiB | no | - | 0 |
| recon-engine | recon.config.doc.extension | collection | 2 | 409 B | 36.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.doc.type | collection | 2 | 146 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.field | collection | 5 | 461 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.filter | collection | 7 | 2.86 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 1 |
| recon-engine | recon.config.job | collection | 8 | 6.80 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.provider | collection | 7 | 979 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.settlement | collection | 7 | 2.27 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.config.transaction.type | collection | 2 | 222 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.config.transfer.expiry | collection | 1 | 67 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| recon-engine | recon.history | collection | 632 | 112.08 KiB | 52.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| recon-engine | recon.job.entries | collection | 3391 | 3.25 GiB | 525.39 MiB | 1 | 92.00 KiB | no | - | 0 |
| recon-engine | recon.job.info | collection | 1714 | 3.05 MiB | 652.00 KiB | 1 | 76.00 KiB | no | - | 1 |
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

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field |
|---|---|---|---|---|---|
| betika_cd.recon.config.doc.extension | objectId | 2023-10-31T07:00:29Z | 2023-10-31T07:01:05Z | - | - |
| betika_cd.recon.config.doc.type | objectId | 2023-10-31T06:59:58Z | 2023-10-31T07:00:03Z | - | - |
| betika_cd.recon.config.field | objectId | 2023-10-31T07:03:01Z | 2023-10-31T07:03:41Z | - | - |
| betika_cd.recon.config.filter | objectId | 2023-12-05T10:27:43Z | 2025-09-09T09:10:52Z | - | - |
| betika_cd.recon.config.job | objectId | 2023-12-05T10:24:49Z | 2025-09-09T09:59:59Z | - | - |
| betika_cd.recon.config.provider | objectId | 2023-10-31T06:27:48Z | 2025-09-09T08:35:45Z | - | - |
| betika_cd.recon.config.settlement | objectId | 2023-11-29T09:26:58Z | 2025-09-09T09:26:34Z | - | - |
| betika_cd.recon.config.transaction.type | objectId | 2023-10-31T06:59:15Z | 2023-10-31T06:59:34Z | - | - |
| betika_cd.recon.config.transfer.expiry | objectId | 2023-10-30T14:38:25Z | 2023-10-30T14:38:25Z | - | - |
| betika_cd.recon.history | objectId | 2023-07-18T11:09:22Z | 2024-07-11T11:22:02Z | - | - |
| betika_cd.recon.job | objectId | 2023-07-18T11:09:22Z | 2023-08-07T07:12:46Z | - | - |
| betika_cd.recon.job.entries | objectId | 2023-12-05T10:40:42Z | 2026-10-01T16:05:29Z | - | - |
| betika_cd.recon.job.info | objectId | 2023-12-05T10:40:07Z | 2026-10-01T16:04:03Z | - | - |
| betika_cd.recon.notification | objectId | 2023-07-19T08:01:13Z | 2023-07-24T09:38:22Z | - | - |
| betika_cd.recon.progress | objectId | 2023-07-20T11:47:33Z | 2023-08-07T08:33:58Z | - | - |
| betika_cd.recon.provider | objectId | 2023-07-11T12:25:56Z | 2023-07-12T07:11:07Z | - | - |
| betika_cd.recon.provider.query | objectId | 2023-08-03T10:07:26Z | 2023-08-03T10:09:06Z | - | - |
| betika_cd.recon.stage | objectId | 2023-07-19T08:00:49Z | 2023-08-07T07:13:58Z | - | - |
| betika_cd.recon.transfer | objectId | 2023-07-19T08:01:13Z | 2023-08-04T10:16:01Z | - | - |

### Instance `gh`

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field |
|---|---|---|---|---|---|
| betika_gh.user | objectId | 2024-10-14T14:49:25Z | 2024-10-14T14:49:25Z | - | - |

### Instance `ke`

| Namespace | _id | First insert ~ | Last insert ~ | Last modified | Modified field |
|---|---|---|---|---|---|
| betika_favorites.favorites | other | - | - | - | - |
| betika_help_center.kb | objectId | 2018-12-03T15:11:27Z | 2021-08-12T20:48:48Z | - | - |
| betika_help_center.users | objectId | 2018-11-12T09:35:39Z | 2018-11-14T09:34:56Z | - | - |
| betika_help_center.votes | objectId | 2018-11-12T09:58:19Z | 2024-11-27T22:10:36Z | - | - |
| recon-engine.recon.config.doc.extension | objectId | 2023-12-19T12:23:19Z | 2023-12-19T12:23:46Z | - | - |
| recon-engine.recon.config.doc.type | objectId | 2023-12-19T12:22:40Z | 2023-12-19T12:22:45Z | - | - |
| recon-engine.recon.config.field | objectId | 2023-12-19T12:29:45Z | 2023-12-19T12:30:36Z | - | - |
| recon-engine.recon.config.filter | objectId | 2023-12-20T13:51:34Z | 2026-03-05T10:36:49Z | - | - |
| recon-engine.recon.config.job | objectId | 2023-12-20T13:21:51Z | 2026-05-07T07:29:25Z | - | - |
| recon-engine.recon.config.provider | objectId | 2023-12-20T13:19:08Z | 2026-03-05T10:30:42Z | - | - |
| recon-engine.recon.config.settlement | objectId | 2023-12-20T13:19:47Z | 2026-03-05T10:31:48Z | - | - |
| recon-engine.recon.config.transaction.type | objectId | 2023-12-19T12:22:16Z | 2023-12-19T12:22:23Z | - | - |
| recon-engine.recon.config.transfer.expiry | objectId | 2023-12-19T12:16:50Z | 2023-12-19T12:16:50Z | - | - |
| recon-engine.recon.history | objectId | 2023-12-19T12:39:06Z | 2024-03-04T07:36:59Z | - | - |
| recon-engine.recon.job.entries | objectId | 2023-12-19T12:45:41Z | 2026-10-01T12:19:25Z | - | - |
| recon-engine.recon.job.info | objectId | 2023-12-19T12:45:11Z | 2026-10-01T12:19:16Z | - | - |
| recon-engine.test | empty | - | - | - | - |

### Instance `mw`

_No collections._

### Instance `tz`

_No collections._

### Instance `ug`

_No collections._

## 9. Users

_No user information (collect with --include-security and/or --oplog-window / --activity-samples)._
