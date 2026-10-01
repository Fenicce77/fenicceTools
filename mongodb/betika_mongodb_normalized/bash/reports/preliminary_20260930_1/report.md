# MongoDB Schema Analysis Report

- Generated at: `2026-09-30T17:49:28Z` (bash implementation)
- Naming strategy: `auto` (separator `_`, mapping entries: 0)
- Target instance: _not defined_
- Findings: **0** errors, **4** warnings, **2** info

## 1. Instances

| Instance | Alias | Role | Status | Version | FCV | Topology | DBs | Collections | Views | Documents | Data | Storage | Indexes |
|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| cd | cd | source | ok | 4.4.15 | 4.4 | replicaset | 1 | 19 | 0 | 52299 | 30.13 GiB | 4.67 GiB | 1.42 MiB |
| gh | gh | source | ok | 4.4.29 | 4.4 | replicaset | 1 | 1 | 0 | 1 | 52 B | 32.00 KiB | 32.00 KiB |
| ke | ke | source | ok | 4.4.3 | 4.4 | replicaset | 3 | 17 | 0 | 130550 | 3.19 GiB | 522.03 MiB | 3.51 MiB |
| mw | mw | source | ok | 4.4.13 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| tz | tz | source | ok | 4.4.22 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |
| ug | ug | source | ok | 4.4.25 | 4.4 | replicaset | 0 | 0 | 0 | 0 | 0 B | 0 B | 0 B |

## 2. Findings summary

| Severity | Code | Count |
|---|---|---:|
| WARN | FIELD_TYPE_MIXED | 4 |
| INFO | NO_TARGET | 1 |
| INFO | SCHEMA_TRUNCATED | 1 |

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
| betika_cd | recon.job.entries | collection | 23138 | 29.13 GiB | 4.47 GiB | 1 | 372.00 KiB | no | - | 0 |
| betika_cd | recon.job.info | collection | 12083 | 1.00 GiB | 201.06 MiB | 1 | 268.00 KiB | no | - | 1 |
| betika_cd | recon.notification | collection | 13 | 6.54 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.progress | collection | 66 | 77.17 KiB | 56.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.provider | collection | 4 | 514 B | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.provider.query | collection | 8 | 2.45 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.stage | collection | 82 | 31.84 KiB | 44.00 KiB | 1 | 36.00 KiB | no | - | 0 |
| betika_cd | recon.transfer | collection | 6 | 2.22 KiB | 36.00 KiB | 1 | 36.00 KiB | no | - | 0 |

### Instance `gh`

| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |
|---|---|---|---:|---:|---:|---:|---:|---|---|---:|
| betika_gh | user | collection | 1 | 52 B | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |

### Instance `ke`

| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator | Shard key | Mixed-type fields |
|---|---|---|---:|---:|---:|---:|---:|---|---|---:|
| betika_favorites | favorites | collection | 3 | 1.28 KiB | 32.00 KiB | 1 | 32.00 KiB | no | - | 0 |
| betika_help_center | kb | collection | 29 | 76.56 KiB | 92.00 KiB | 1 | 32.00 KiB | no | - | 0 |
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
| recon-engine | recon.job.entries | collection | 3347 | 3.17 GiB | 514.02 MiB | 1 | 92.00 KiB | no | - | 0 |
| recon-engine | recon.job.info | collection | 1692 | 3.02 MiB | 648.00 KiB | 1 | 76.00 KiB | no | - | 1 |
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
