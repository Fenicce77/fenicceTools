# pbm-backup - installation and deployment guide

How to build the pbm-backup package and deploy it on the members of a MongoDB
replica set, by hand or with your own deployment tool (Satellite, Salt, CI/CD,
...). For what the tool does, see [README.md](README.md).

**Deployment in one paragraph:** build `pbm-backup-<version>.tar.gz` once,
copy it to **every** member of the replica set, verify the checksum, extract
it and run `install.sh`. Put the connection string and the tunables in
`/etc/sysconfig`, run `pbm-backup check` on every member, and only then
switch the timers on. All members run the same timers; pbm-backup's election
makes sure only one of them acts.

---

## 1. Prerequisites (every member)

| Item | Check |
|---|---|
| Linux with systemd, bash >= 3.2 | `systemctl --version`, `bash --version` |
| PBM 2.x, pbm-agent running and `ok` | `pbm version`, `systemctl status pbm-agent`, `pbm status` |
| Same PBM version for the CLI and every agent | `pbm status` (agent column) |
| PBM storage = GCS bucket (§1.2), compression configured | `pbm config` (`storage.type: gcs`; PBM < 2.10: `s3` + `endpointUrl: https://storage.googleapis.com`) |
| `jq` | `jq --version` |
| `mongosh` (or legacy `mongo` on old 4.x nodes) | `mongosh --version` |
| MongoDB >= 4.2 and the PBM version that supports it, pinned (§1.1) | `pbm version`, `dnf versionlock list` / `apt-mark showhold` |
| Members reach each other on the MongoDB port | the health probes connect to every member directly |
| PBM user with exactly the PBM roles (section 1.3) | `db.getSiblingDB("admin").getUser("pbmuser")` |
| Clock in sync (NTP / chrony) | `timedatectl` |
| Writable log directory (default `/data/backup/pbm/logs`) | created automatically if possible |

PBM `filesystem` storage is **not** supported (it needs a path shared by all
members, i.e. NFS). PSMDB members use the physical scheme and must have PITR
disabled; Community members use the logical scheme and pbm-backup enables
PITR itself.

### 1.1 Install the PBM package for your MongoDB version

pbm-agent and pbm CLI come from the `percona-backup-mongodb` package. Every
PBM release only works with some MongoDB versions, so install the one that
matches the replica set, **the same version on every member**, and pin it.

#### Which PBM version

From the version gate in the PBM source (`pbm/version/version.go` of each
release); pbm-backup's preflight enforces the same matrix:

| MongoDB | PBM releases that support it | Install | Native GCS storage (§1.2) | Agent config file (§4.3) |
|---|---|---|---|---|
| 4.0 | PBM 1.x only | not supported by pbm-backup | - | - |
| 4.2 | 2.0.0 - 2.3.1 (deprecated in 2.3.0, dropped in **2.4.0**) | **2.3.1** | no: S3 + HMAC | no: environment only |
| 4.4 | 2.0.0 - 2.5.0 (dropped in **2.6.0**) | **2.5.0** | no: S3 + HMAC | no: environment only |
| 5.0, 6.0 | up to 2.10.0 (dropped in **2.11.0**) | **2.10.0** | yes (`gcs`) | yes |
| 7.0 | 2.4.0 - current | latest (2.16.0 at the time of writing) | yes, from 2.10 | yes, from 2.9 |
| 8.0 | **2.7.0** - current | latest (2.16.0 at the time of writing) | yes, from 2.10 | yes, from 2.9 |

Pin the package whenever the version is not the latest (4.2, 4.4, 5.0,
6.0): a routine `dnf upgrade` would otherwise install a PBM that refuses
the replica set.

#### Fresh install (no PBM on the member yet)

RHEL / Rocky / Alma / Oracle Linux 8:

```bash
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release enable pbm release
sudo dnf --showduplicates list percona-backup-mongodb          # pick the exact version
sudo dnf install -y percona-backup-mongodb-2.5.0               # the version from the table
sudo dnf install -y python3-dnf-plugin-versionlock
sudo dnf versionlock add percona-backup-mongodb
pbm version                                                    # Version: 2.5.0
```

Debian / Ubuntu:

```bash
wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
sudo dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
sudo percona-release enable pbm release && sudo apt-get update
apt-cache madison percona-backup-mongodb                       # pick the exact version string
sudo apt-get install -y percona-backup-mongodb=2.5.0-1.$(lsb_release -sc)
sudo apt-mark hold percona-backup-mongodb
```

Then configure the agent environment (§4.3), the storage credentials (§1.2)
and start the agent: `sudo systemctl enable --now pbm-agent`.

#### Replace a PBM version that does not match (e.g. 2.16.0 on MongoDB 4.4)

All agents of a replica set must run the same version: change **every
member in the same window**. Use a downgrade (or upgrade) in place: it keeps
`/etc/sysconfig/pbm-agent` (`%config(noreplace)`). Removing the package
instead (`dnf remove`) saves a modified `/etc/sysconfig/pbm-agent` as
`/etc/sysconfig/pbm-agent.rpmsave`, which you must copy back after the new
install (`apt-get remove` keeps it; `purge` deletes it).

```bash
# 0. Inspect (each member) and save the PBM config (once; it holds secrets)
rpm -q percona-backup-mongodb
sudo dnf --showduplicates list percona-backup-mongodb | grep 2.5.0     # else: sudo percona-release enable pbm release
systemctl cat pbm-agent                                                # note any --config drop-in
pbm config > /root/pbm-config-before.yaml && chmod 600 /root/pbm-config-before.yaml

# 1. Stop backups and agents (all members)
sudo systemctl disable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer pbm-backup-metrics.timer
pbm status -s running                                                  # must be idle: {"running":{}}
sudo systemctl stop pbm-agent

# 2. Change the package (each member)
sudo dnf versionlock delete percona-backup-mongodb                     # if it was locked
sudo dnf downgrade -y percona-backup-mongodb-2.5.0                     # or: dnf upgrade -y percona-backup-mongodb-<version>
sudo dnf versionlock add percona-backup-mongodb
#   Debian/Ubuntu: sudo apt-mark unhold percona-backup-mongodb
#                  sudo apt-get install -y --allow-downgrades percona-backup-mongodb=2.5.0-1.$(lsb_release -sc)
#                  sudo apt-mark hold percona-backup-mongodb
pbm version

# 3. Adjust what the target version does not support (see the table)
#    - target < 2.9 : no agent config file. Remove the drop-in, keep /etc/sysconfig/pbm-agent (§4.3)
sudo rm -f /etc/systemd/system/pbm-agent.service.d/config.conf && sudo systemctl daemon-reload
#    - target < 2.10: no "gcs" storage. Apply the S3 + HMAC configuration (§1.2), agents still stopped
pbm config --file /root/pbm-config-s3.yaml

# 4. Start and verify (all members, then once)
sudo systemctl start pbm-agent
pbm status                                     # every agent on the new version and "OK"
pbm config --force-resync && pbm list

# 5. pbm-backup (each member)
sudo pbm-backup check
sudo systemctl enable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer
```

Going up again later (e.g. after a MongoDB upgrade) is the same procedure
with `dnf upgrade`; the S3 + HMAC storage keeps working on any PBM version,
and from 2.10 you may switch it to `gcs` (§1.2).

### 1.2 GCS bucket credentials (by PBM version)

PBM authenticates to the bucket with a Google service account. Which kind of
key you can use depends on the PBM version (checked in the PBM source:
`pbm/storage/s3`, `pbm/storage/gcs`):

| PBM version | `storage.type` | HMAC key (access id + secret) | Service account JSON key (`client_email` + `private_key`) |
|---|---|---|---|
| < 2.10 (e.g. **2.5.0** for MongoDB 4.4, 2.3.1 for 4.2) | `s3` with `endpointUrl: https://storage.googleapis.com` | **required**: `access-key-id` / `secret-access-key` | ❌ not supported |
| >= 2.10 | `gcs` (native) | optional: `hmacAccessKey` / `hmacSecret` | yes: `clientEmail` / `privateKey` |

- An HMAC key and a JSON key are **different credentials**: one cannot be
  derived from the other. The HMAC pair goes in `access-key-id` /
  `secret-access-key` (PBM < 2.10) or `hmacAccessKey` / `hmacSecret`
  (PBM >= 2.10): same values, different field names.
- Both kinds of keys can belong to the **same service account** and coexist:
  creating, disabling or deleting one does not affect the other. Permissions
  belong to the service account, not to the key.
- Using HMAC everywhere (S3 on PBM < 2.10, `gcs` + HMAC on >= 2.10) leaves a
  single kind of credential to rotate.
- `pbm status` shows PBM < 2.10 storage as
  `S3 s3://https://storage.googleapis.com/<bucket>/<prefix>`; pbm-backup
  accepts it as GCS (`REQUIRED_STORAGE_TYPES=GCS`, the default).

#### Common steps (any PBM version)

```bash
PROJECT=<gcp-project> BUCKET=<bucket> SA=pbm-backup@${PROJECT}.iam.gserviceaccount.com

# Service account (skip if you reuse an existing one)
gcloud iam service-accounts create pbm-backup --project="$PROJECT" --display-name="PBM backups"

# PBM reads, lists, writes and deletes objects: roles/storage.objectAdmin on the bucket
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${SA}" --role="roles/storage.objectAdmin"
```

- One **`prefix` per replica set** (e.g. `mongocluster/rs44`), without a
  trailing `/`. Two clusters on the same path mix their backup lists, and a
  resync or cleanup of one sees (or deletes) the other's backups.
- Organization policies can block keys: `iam.disableServiceAccountKeyCreation`
  (JSON keys) and `storage.restrictAuthTypes` (HMAC). Up to 10 HMAC keys per
  service account.

#### A. HMAC key: PBM < 2.10 (required) or PBM >= 2.10 (optional)

```bash
gcloud storage hmac create "$SA" --project="$PROJECT" --format=json   # prints accessId and secret
gcloud storage hmac list --project="$PROJECT" --format="table(accessId,serviceAccountEmail,state)"
```

The **secret is shown only once**: store it in your secret manager right away.
The key must be `ACTIVE`.

PBM < 2.10 (`/root/pbm-config-s3.yaml`, `chmod 600`; block in `conf/pbm-conf.yaml`):

```yaml
storage:
  type: s3
  s3:
    region: europe-west3                         # the bucket location
    endpointUrl: https://storage.googleapis.com
    bucket: <bucket>
    prefix: mongocluster/rs44
    credentials:
      access-key-id: <accessId>
      secret-access-key: <secret>
backup:
  compression: gzip
  compressionLevel: 5
```

PBM >= 2.10, same HMAC key with the native type:

```yaml
storage:
  type: gcs
  gcs:
    bucket: <bucket>
    prefix: mongocluster/rs44
    credentials:
      hmacAccessKey: <accessId>
      hmacSecret: <secret>
```

Check the key from a member before giving it to PBM. A `403` from PBM has no
details; this tool prints the GCS error code (`AccessDenied`,
`InvalidAccessKeyId`, `SignatureDoesNotMatch`, `RequestTimeTooSkewed`...):

```bash
python3 /usr/local/share/doc/pbm-backup/gcs-hmac-test.py <bucket> mongocluster/rs44 europe-west3
```

#### B. Service account JSON key: PBM >= 2.10 only

```bash
gcloud iam service-accounts keys create /root/pbm-sa.json --iam-account="$SA"
chmod 600 /root/pbm-sa.json
jq -r .client_email /root/pbm-sa.json     # -> clientEmail
jq .private_key /root/pbm-sa.json         # -> privateKey, already quoted with \n escapes (paste as is)
```

```yaml
storage:
  type: gcs
  gcs:
    bucket: <bucket>
    prefix: mongocluster/rs44
    credentials:
      clientEmail: pbm-backup@<gcp-project>.iam.gserviceaccount.com
      privateKey: "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
```

Delete `/root/pbm-sa.json` once the key is in PBM (and in your secret
manager). This key **cannot** be used with PBM < 2.10.

#### Apply and verify (once per replica set)

```bash
pbm config --file /root/pbm-config.yaml     # replaces the whole PBM config: keep backup/pitr sections in it
sudo systemctl restart pbm-agent            # all members (agents re-check the storage)
pbm status                                  # every agent "OK"; storage line shows the bucket and prefix
pbm config --force-resync                   # needed when the storage type, bucket or prefix changed
```

Moving a replica set from `s3` (PBM < 2.10) to `gcs` after an upgrade to
PBM >= 2.10: keep the same bucket and prefix and run `--force-resync`; the
existing backups stay listed.

### 1.3 Create or fix the PBM user (once per replica set)

`mongodb/pbmuser.create.js` (in the package; also installed in
`/usr/local/share/doc/pbm-backup/`) creates the `pbmAnyAction` role and the
PBM user with exactly the roles PBM documents: `readWrite` (admin),
`backup`, `clusterMonitor`, `restore` and `pbmAnyAction`. Run it **by
hand** with mongosh, connected to the **primary** as an administrator. Users
and roles replicate, so once per replica set is enough.

```bash
# New user, generated 32-character password (default)
mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js

# New user, password typed by hand (asked twice)
PBM_PASSWORD_MODE=prompt mongosh "mongodb://rmateos@mongodbcluster-node01:27017/admin?replicaSet=rsName" --file pbmuser.create.js
```

- **New user:** the password (generated or typed) is **shown on screen in
  plain text** and saved to `~/.pbm-backup/<user>.<replset>.<timestamp>.env`
  on the machine where mongosh runs (directory `0700`, file `0600`, never
  overwritten). The path is printed. The file also contains the
  `PBM_MONGODB_URI` line for `/etc/sysconfig/pbm-conf` (every member) and
  one line per member for `/etc/sysconfig/pbm-agent` (each agent uses its
  own member), with the password already URI-encoded.
- **Existing user:** its roles are set to the PBM ones (extra roles such as
  `clusterAdmin`, `readWriteAnyDatabase` or `userAdminAnyDatabase` are
  removed and reported); **the password is not changed**, so running
  pbm-agents keep working. Nothing is shown or saved.
- **Rotate the password:** `PBM_ROTATE_PASSWORD=1`. Then update
  `pbm-conf` and `pbm-agent` on **every** member and restart `pbm-agent`.
- Other variables: `PBM_USER` (default `pbmuser`), `PBM_SECRET_DIR`
  (default `~/.pbm-backup`), `PBM_HELP=1`. Requires mongosh (not the legacy
  `mongo` shell).

The password is in your terminal scrollback and in that file: move it to
its final place (or your secret store) and delete the file.

## 2. Build the package

On any Linux or macOS machine with a clone of the repository:

```bash
cd mongodb/backupTool
packaging/build-dist.sh
```

It runs both test suites first, `tests/smoke.sh` (no MongoDB needed) and
`tests/pbmuser.test.sh` (needs mongosh; skipped if it is missing), and stops
if any check fails. Then it writes:

```
dist/pbm-backup-<version>.tar.gz          # top directory pbm-backup-<version>/
dist/pbm-backup-<version>.tar.gz.sha256   # sha256sum -c compatible
```

The version comes from `VERSION=` in `bin/pbm-backup`; bump it for every
release. Options: `--output DIR`, `--skip-tests` (not recommended),
`--help`.

Package contents:

| Path | Purpose |
|---|---|
| `install.sh` | installer / upgrader / uninstaller |
| `bin/pbm-backup`, `lib/*.sh` | the tool |
| `systemd/services`, `systemd/timers` | new units |
| `systemd/legacy/` | the old `pbm-physical-*` / `pbm-deletion` units (reference, rollback) |
| `etc/pbm-backup.conf.example` | all tunables with defaults |
| `sysconfig/pbm-conf` | template for `/etc/sysconfig/pbm-conf` (pbm CLI and pbm-backup) |
| `sysconfig/pbm-agent` | pbm-agent environment file, every PBM 2.x (the only agent config on PBM 2.0 - 2.8), §4.3 |
| `sysconfig/pbm-physical-*`, `sysconfig/pbm-deletion` | wrappers for the old units |
| `conf/pbm-conf.yaml` | PBM cluster configuration template (`pbm config --file`), GCS native or through S3 |
| `conf/pbm-agent.yaml`, `conf/pbm-agent-config.conf` | pbm-agent config file + systemd drop-in, PBM >= 2.9 only, §4.3 |
| `mongodb/pbmuser.create.js` | creates/fixes the PBM user and role (section 1.3) |
| `tools/gcs-hmac-test.py` | checks a GCS HMAC key the way PBM < 2.10 uses it (section 1.2) |
| `README.md`, `INSTALL.md`, `CHANGES.md`, `VERSION` | documentation |

## 3. Install on a member

The examples use `VERSION`: set it to the version of the package you
deploy (the `VERSION=` line in `bin/pbm-backup`, also in the package name).

```bash
VERSION=0.6.2
scp dist/pbm-backup-${VERSION}.tar.gz* rmateos@mongodbcluster-node01:/tmp/
ssh rmateos@mongodbcluster-node01
VERSION=0.6.2
cd /tmp
sha256sum -c pbm-backup-${VERSION}.tar.gz.sha256
tar -xzf pbm-backup-${VERSION}.tar.gz
sudo pbm-backup-${VERSION}/install.sh --dry-run      # review
sudo pbm-backup-${VERSION}/install.sh                 # install, timers NOT enabled yet
```

`install.sh` options:

| Option | Use |
|---|---|
| `--scheme physical` (default) | PSMDB members: hourly incremental timer (01:15..23:15) |
| `--scheme logical --incr-every-min 360` | Community members: oplog check every N minutes (must divide a day) |
| `--metrics` | also install/enable the 5-minute metrics timer |
| `--enable` | enable and start the timers (see section 6 for when) |
| `--disable-legacy` | disable and stop the old `pbm-physical-*` / `pbm-deletion` timers |
| `--legacy-wrappers` | turn the old `/etc/sysconfig/pbm-*` scripts into wrappers around pbm-backup |
| `--prefix DIR` | default `/usr/local` |
| `--sysconfdir DIR` | default `/etc/sysconfig` (or `/etc/default` when missing) |
| `--destdir DIR` | install under a staging root (image builds); no systemctl, no root |
| `--uninstall` | remove timers, units, binary, libraries, docs (config and logs kept) |
| `--dry-run` | print every action, change nothing |

What a member looks like after `install.sh` (✎ = file you configure;
⚙ = created/managed by `install.sh`; ◆ = owned by the Percona package):

```
/
├── usr/local/
│   ├── bin/pbm-backup                          ⚙ entry point
│   ├── lib/pbm-backup/                         ⚙ common.sh compat.sh metrics.sh mongo.sh pbm.sh topology.sh
│   └── share/doc/pbm-backup/                   ⚙ README.md INSTALL.md CHANGES.md VERSION
│                                                  pbm-backup.conf.example pbmuser.create.js gcs-hmac-test.py
├── etc/
│   ├── sysconfig/                              (/etc/default on Debian-like systems)
│   │   ├── pbm-conf                         ✎ ⚙ 0600 PBM_MONGODB_URI for pbm CLI + pbm-backup (§4.1);
│   │   │                                         created from the template if missing, never overwritten
│   │   ├── pbm-backup                       ✎ ⚙ 0640 pbm-backup tunables (§4.2); created if missing
│   │   ├── pbm-agent                        ✎ ◆ 0640 pbm-agent environment, every PBM 2.x (§4.3);
│   │   │                                         template: sysconfig/pbm-agent
│   │   └── pbm-physical-full-base              ⚙ only with --legacy-wrappers (old units -> pbm-backup)
│   │       pbm-physical-incremental
│   │       pbm-deletion
│   ├── pbm-agent.yaml                       ✎   0600 PBM >= 2.9 only, optional (§4.3); template: conf/pbm-agent.yaml
│   └── systemd/system/
│       ├── pbm-backup-full.service / .timer    ⚙ daily full, 00:00
│       ├── pbm-backup-incr.service / .timer    ⚙ physical: hourly 01:15..23:15
│       ├── pbm-backup-incr.timer.d/
│       │   └── schedule.conf                   ⚙ logical scheme only: every OPLOG_INCR_MIN (e.g. 00/6:30)
│       ├── pbm-backup-cleanup.service / .timer ⚙ retention, 00:40
│       ├── pbm-backup-metrics.service / .timer ⚙ every 5 min (enabled with --metrics)
│       └── pbm-agent.service.d/
│           └── config.conf                  ✎   PBM >= 2.9 only, optional (§4.3); template: conf/pbm-agent-config.conf
├── usr/lib/systemd/system/pbm-agent.service    ◆ not modified (/lib/systemd/system on Debian-like)
├── data/backup/pbm/                            PBM_LOCAL_ROOT
│   ├── logs/                                   incrbase.log incr.log logical-full.log oplog.log deletion.log restore.log
│   └── <replset>.lastbackup.index              physical scheme: last base (JSON)
├── run/lock/pbm-backup-<command>.lock          one run per command and member
└── <METRICS_DIR>/                              only if METRICS_DIR is set:
                                                pbm_backup_state.prom pbm_backup_run_{full,incr,cleanup}.prom
```

Not files on the members:

- **PBM cluster configuration** (storage, backup compression, PITR): stored in
  MongoDB and applied once with `pbm config --file` (template
  `conf/pbm-conf.yaml`). pbm-backup sets the `pitr.*` keys itself in the
  logical scheme.
- **PBM user password file**: `~/.pbm-backup/<user>.<replset>.<timestamp>.env`
  on the machine where `pbmuser.create.js` ran (§1.3). Delete it after use.

It creates `/etc/sysconfig/pbm-backup` and `/etc/sysconfig/pbm-conf` from
their templates only when they do not exist, and never overwrites them
(install, upgrade or uninstall). A freshly created `pbm-conf` holds
placeholders: `pbm-backup` refuses to run (exit code 2) until they are
replaced (section 4.1).

## 4. Configure

### 4.1 Connection string: `/etc/sysconfig/pbm-conf`

`install.sh` creates it from the template (`sysconfig/pbm-conf` in the
package) when it does not exist. Replace the placeholders; the
`PBM_MONGODB_URI` line printed by `pbmuser.create.js` (section 1.3) can be
pasted as is. Members that already have the file from the old scripts keep
it untouched.

```bash
PBM_MONGODB_URI="mongodb://<pbm_user>:<pbm_password>@mongodbcluster-node01:27017,mongodbcluster-node02:27017,mongodbcluster-node03:27017/?authSource=admin&replicaSet=<replica_set>"
export PBM_MONGODB_URI
```

```bash
sudo chmod 0600 /etc/sysconfig/pbm-conf
```

- `replicaSet=` must be present (used for logs, metrics and the per-member
  probes).
- `mongodb+srv://` cannot be used: the probes connect to each member
  directly.
- This file holds a password: deploy it from your secret store, never from
  the repository.

### 4.2 Tunables: `/etc/sysconfig/pbm-backup`

Created from `etc/pbm-backup.conf.example`, all values commented (defaults).
The ones usually set:

| Variable | Default | When to change |
|---|---|---|
| `RETENTION_DAYS` | `7` | retention policy |
| `LOCAL_NODE_NAMES` | empty | when `hostname`/`hostname -f` differ from the member name in the replica set config |
| `PREFERRED_NODES` | empty | order of members after the chain owner |
| `OPLOG_INCR_MIN` | `360` | Community: minutes between oplog slices (keep in line with `--incr-every-min`) |
| `METRICS_DIR` | empty | textfile-collector directory (node_exporter, PMM2, PMM3) |
| `MAX_REPL_LAG_SEC` / `MAX_QUEUE` / `MAX_WT_DIRTY_PCT` | `60` / `50` / `20` | overload thresholds of the election |
| `PBM_LOCAL_ROOT` / `LOG_DIR` | `/data/backup/pbm` / `.../logs` | log location |
| `BACKUP_COMPRESSION` / `BACKUP_COMPRESSION_LEVEL` | `gzip` / `5` | compression (`none` is rejected) |

Keep this file identical on every member of a replica set: they must all
compute the same election.

### 4.3 pbm-agent configuration (per member, by PBM version)

pbm-backup does not install the agent configuration (the Percona package
owns it), but the package ships templates for both agent generations:

Files of the agent, by PBM version:

```
PBM 2.0 - 2.8 (e.g. 2.5.0 for MongoDB 4.4)     PBM >= 2.9
/etc/sysconfig/pbm-agent   ✎ (required)        /etc/sysconfig/pbm-agent                          ✎ (required, or…)
                                               /etc/pbm-agent.yaml                               ✎ (optional, with…)
                                               /etc/systemd/system/pbm-agent.service.d/config.conf  (…this drop-in)
```

| PBM version | Agent configuration | Templates |
|---|---|---|
| 2.0 - 2.8 (e.g. **2.5.0 for MongoDB 4.4**) | environment only: `/etc/sysconfig/pbm-agent` (`PBM_MONGODB_URI`, `PBM_DUMP_PARALLEL_COLLECTIONS`); logs in journald | `sysconfig/pbm-agent` |
| >= 2.9 | the same environment file, or `/etc/pbm-agent.yaml` loaded with `--config` (adds log file, level, JSON) | `conf/pbm-agent.yaml` + `conf/pbm-agent-config.conf` |

```bash
# PBM 2.0 - 2.8 (and any version): environment file
sudo install -m 0640 sysconfig/pbm-agent /etc/sysconfig/pbm-agent     # then edit
sudo systemctl restart pbm-agent

# PBM >= 2.9, optional: YAML file + drop-in
sudo install -m 0600 -o mongod -g mongod conf/pbm-agent.yaml /etc/pbm-agent.yaml   # then edit
sudo install -D -m 0644 conf/pbm-agent-config.conf /etc/systemd/system/pbm-agent.service.d/config.conf
sudo systemctl daemon-reload && sudo systemctl restart pbm-agent
```

Each agent uses the URI of **its own** member (`pbmuser.create.js` prints one
line per member). The `--config` drop-in must not exist on PBM 2.0 - 2.8:
those agents do not know the option and do not start (remove it before a
downgrade).

## 5. Validate (every member, before enabling)

```bash
sudo pbm-backup check
```

Read-only. Expect on every member:

- `[PRECHECK][COMPAT][OK]` with the right MongoDB version, edition and scheme;
- `[PRECHECK][STORAGE][OK] Storage GCS gs://...`;
- an election table with exactly one `#0` member, the primary marked
  `SKIP(primary)`;
- no `This host (...) is not in the replica set member list`. If you see it,
  set `LOCAL_NODE_NAMES`;
- exit code `0`.

Then simulate the jobs (nothing is executed):

```bash
sudo pbm-backup full --dry-run
sudo pbm-backup incr --dry-run
sudo pbm-backup cleanup --dry-run    # shows exactly which backups would be deleted
```

And check the units on one member:

```bash
systemd-analyze verify /etc/systemd/system/pbm-backup-*.service
systemctl list-timers 'pbm-backup-*' --all
```

## 6. Switch over (whole replica set)

Do it on **all members in the same window**, so the old and the new timers
never run together. Avoid the minutes around 00:00, 00:40 and hh:15.

1. Install (section 3) and validate (section 5) on every member, timers not enabled.
2. On every member, stop the old timers:
   ```bash
   sudo systemctl disable --now pbm-physical-full-base.timer pbm-physical-incremental.timer pbm-deletion.timer
   ```
3. On every member, start the new ones:
   ```bash
   sudo systemctl enable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer
   sudo systemctl enable --now pbm-backup-metrics.timer   # only with METRICS_DIR
   ```
   Equivalent: rerun `install.sh` with `--disable-legacy --enable` (plus the
   same `--scheme`/`--metrics` options).
4. Next hour, check that exactly one member logged the incremental:
   ```bash
   sudo tail -n 20 /data/backup/pbm/logs/incr.log      # physical
   sudo tail -n 20 /data/backup/pbm/logs/oplog.log     # logical
   ```

**Community (logical) members, first time:** the oplog check fails until a
logical full exists. Either wait for the 00:00 full, or start it right away
(the election still decides which member runs it):

```bash
sudo pbm-backup full
```

## 7. Deploying with your own tool

The package is designed for unattended use:

- **Idempotent:** running `install.sh` again with the same options gives the
  same result. Binaries, libraries and units are replaced; configuration is
  never touched.
- **Exit codes:** `install.sh`: `0` ok, `1` a step failed, `2` usage or
  environment error. `pbm-backup check`: `0` ok, `1` a backup would fail,
  `2` configuration error.
- **Installed version:** `/usr/local/share/doc/pbm-backup/VERSION` and
  `pbm-backup --version`.

Recommended job, per member:

```bash
set -e
cd /tmp
sha256sum -c pbm-backup-${VERSION}.tar.gz.sha256
tar -xzf pbm-backup-${VERSION}.tar.gz
# /etc/sysconfig/pbm-conf (secret) and /etc/sysconfig/pbm-backup are
# templated by the deployment tool BEFORE this step.
pbm-backup-${VERSION}/install.sh --scheme physical          # or: --scheme logical --incr-every-min 360
/usr/local/bin/pbm-backup --no-color check
rm -rf pbm-backup-${VERSION} pbm-backup-${VERSION}.tar.gz*
```

Enable the timers (`--disable-legacy --enable`) as a separate step, once
`check` passed on **every** member of the replica set (section 6).

To build images or OS packages, install into a staging root:

```bash
./install.sh --destdir /tmp/stage --scheme physical
```

## 8. Upgrade

Same as an install with the new package (sections 3 and 5). Timers that are
enabled stay enabled. A backup already running keeps its old code until it
finishes.

```bash
VERSION=<new version>
sudo pbm-backup-${VERSION}/install.sh --scheme physical   # same options as the first install
pbm-backup --version
```

Read `CHANGES.md` for new tunables (they all have safe defaults).

## 9. Rollback

- **To a previous pbm-backup version:** install its package again.
- **To the old scripts:**
  ```bash
  sudo systemctl disable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer pbm-backup-metrics.timer
  sudo systemctl enable --now pbm-physical-full-base.timer pbm-physical-incremental.timer pbm-deletion.timer
  ```
  The old timers call `/etc/sysconfig/pbm-*`. If those were replaced by
  wrappers (`--legacy-wrappers`), they keep calling pbm-backup. Restore the
  original scripts from git (they are in `CHANGES.md` too) to run the old code.

## 10. Uninstall

```bash
sudo pbm-backup-${VERSION}/install.sh --uninstall
```

It stops and removes the timers and units, the binary, the libraries and the
docs. It keeps `/etc/sysconfig/pbm-backup`, `/etc/sysconfig/pbm-conf`, the
logs, PBM itself and every backup in the bucket. If the old scripts in `/etc/sysconfig` were
replaced by wrappers (`--legacy-wrappers`), it warns: they point to the
removed binary, so restore the originals before re-enabling the old timers.

## 11. Operations

| What | Where |
|---|---|
| Timers and next runs | `systemctl list-timers 'pbm-backup-*'` |
| Last run of a job | `journalctl -u pbm-backup-incr.service -n 50` |
| Logs | `/data/backup/pbm/logs/{incrbase,incr,logical-full,oplog,deletion,restore}.log` |
| Overall state | `pbm-backup check`, `pbm status`, `pbm list` |
| Metrics | `${METRICS_DIR}/pbm_backup_state.prom`, `pbm_backup_run_*.prom` |

## 12. Troubleshooting

| Message | Cause / fix |
|---|---|
| `This host (...) is not in the replica set member list` | set `LOCAL_NODE_NAMES` to the member name used in the replica set config |
| `No eligible node` | every secondary is down, lagging, overloaded or has no healthy pbm-agent: check `pbm status` and the election table in `pbm-backup check` |
| `PBM_MONGODB_URI in ... still has template placeholders` | fill in `/etc/sysconfig/pbm-conf` (section 4.1) |
| `PBM storage is 'FS' ...; allowed: ...` | PBM uses filesystem storage: configure the GCS bucket (`pbm config --file`) |
| `PBM storage is 'S3' (s3://...); allowed: ...` | S3 that is not GCS: fix the endpoint, or allow it with `REQUIRED_STORAGE_TYPES="GCS S3"` |
| `PBM x.y does not support MongoDB 4.4 / 4.2` | install PBM 2.5.0 (4.4) or < 2.4.0 (4.2), §13 |
| pbm-agent does not start after a downgrade | remove the `--config` drop-in (§4.3) |
| `PITR is enabled, but the physical scheme runs without PITR` | PSMDB: `pbm config --set pitr.enabled=false` |
| `Oplog window ... < 2 x expected dump` | Community: enlarge the oplog (`replSetResizeOplog`) or set `EXPECTED_DUMP_SEC` / `OPLOG_WINDOW_ENFORCE=false` |
| `Last full ... started N min ago (< FULL_MIN_INTERVAL_SEC)` | normal: a full already ran today. Use `pbm-backup full --force` to take another one |
| `PBM executed the backup on X, not on this node` | PBM picked another member by `backup.priority`; keep the primary lowest in `conf/pbm-conf.yaml` |
| `Cannot read buildInfo` | `mongosh` missing or the URI is wrong; or set `MONGODB_VERSION` + `MONGODB_EDITION` |

## 13. MongoDB 4.4: PBM 2.5.0

PBM 2.6.0 dropped MongoDB 4.4, so **PBM 2.5.0 is the last release for 4.4**
(from the PBM source: v2.5.0 "PBM works with v4.4, v5.0, v6.0, v7.0", v2.6.0
"v5.0, v6.0, v7.0"). pbm-backup works with it as is (all the `pbm` commands
and JSON fields it uses were checked in the v2.5.0 source). Two differences
matter:

- **No native GCS before PBM 2.10:** the bucket is configured as S3 with
  `endpointUrl: https://storage.googleapis.com` and a GCS HMAC key (§1.2 A,
  block in `conf/pbm-conf.yaml`); a service account JSON key cannot be used. `pbm status` reports `S3
  s3://https://storage.googleapis.com/...`; pbm-backup accepts it as GCS,
  so `REQUIRED_STORAGE_TYPES=GCS` (default) still applies.
- **Agent configuration by environment only** (§4.3): no `/etc/pbm-agent.yaml`,
  no `--config` drop-in.

### Install or downgrade

Follow §1.1 with version **2.5.0** (fresh install, or "Replace a PBM version
that does not match" for a member with a newer PBM), and §1.2 option A for
the bucket credentials (HMAC key, `type: s3`).

Install pbm-backup on these members with `--scheme logical`; before the first
logical full `check` warns that PITR is disabled (the first full enables it).
