# Real PBM 2.5.0 output - MongoDB 4.4 Community replica sets

Captured on 2026-10-16 from three production replica sets (MongoDB 4.4.3,
4.4.15 and 4.4.29, PBM 2.5.0, GCS through the S3-compatible endpoint,
PITR enabled by pbm-backup). Anonymized: replica set names (`rs44`), member
host names (`mongocluster-nodeNN`, same member numbers and roles), bucket and
prefix. Everything else (timestamps, sizes, opids, field layout) is as PBM
printed it.

| File | Command | What it shows |
|---|---|---|
| `status-one-full.json` | `pbm status -o json` | one logical full, oplog range starting at restoreTo + 1 |
| `list-one-full.json` | `pbm list -o json` | same replica set: `.pitr.ranges[].range.{start,end}` |
| `status-two-fulls.json` | `pbm status -o json` | two fulls, ONE continuous oplog range across both |
| `status-nobase.json` | `pbm status -o json` | seven daily fulls and a `noBaseSnapshot` range (PITR enabled before the first full) |
| `describe-backup-logical.json` | `pbm describe-backup NAME -o json` | logical backup with `mongodb_version`, `fcv`, executing node |

PBM 2.5.0 specifics: members are reported as `<replset>/<host>:<port>`, the
role of a secondary is empty, storage type is `S3` with path
`s3://https://storage.googleapis.com/...`.
