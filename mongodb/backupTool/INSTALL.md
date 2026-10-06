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
| PBM storage = GCS bucket, compression configured | `pbm config` (`storage.type: gcs`; PBM < 2.10: `s3` + `endpointUrl: https://storage.googleapis.com`, see §13) |
| `jq` | `jq --version` |
| `mongosh` (or legacy `mongo` on old 4.x nodes) | `mongosh --version` |
| MongoDB >= 4.2. 4.4: PBM <= 2.5.0 (§13); 4.2: PBM < 2.4.0. Package pinned on 4.x | `dnf versionlock add percona-backup-mongodb` / `apt-mark hold percona-backup-mongodb` |
| Members reach each other on the MongoDB port | the health probes connect to every member directly |
| PBM user with exactly the PBM roles (section 1.1) | `db.getSiblingDB("admin").getUser("pbmuser")` |
| Clock in sync (NTP / chrony) | `timedatectl` |
| Writable log directory (default `/data/backup/pbm/logs`) | created automatically if possible |

PBM `filesystem` storage is **not** supported (it needs a path shared by all
members, i.e. NFS). PSMDB members use the physical scheme and must have PITR
disabled; Community members use the logical scheme and pbm-backup enables
PITR itself.

### 1.1 Create or fix the PBM user (once per replica set)

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
| `mongodb/pbmuser.create.js` | creates/fixes the PBM user and role (section 1.1) |
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

What it installs:

```
/usr/local/bin/pbm-backup
/usr/local/lib/pbm-backup/*.sh
/usr/local/share/doc/pbm-backup/{README.md,INSTALL.md,CHANGES.md,VERSION,pbm-backup.conf.example,pbmuser.create.js}
/etc/sysconfig/pbm-backup                        (only if it does not exist)
/etc/sysconfig/pbm-conf                          (template, 0600, only if it does not exist)
/etc/systemd/system/pbm-backup-{full,incr,cleanup,metrics}.{service,timer}
/etc/systemd/system/pbm-backup-incr.timer.d/schedule.conf   (logical scheme only)
```

It creates `/etc/sysconfig/pbm-backup` and `/etc/sysconfig/pbm-conf` from
their templates only when they do not exist, and never overwrites them
(install, upgrade or uninstall). A freshly created `pbm-conf` holds
placeholders: `pbm-backup` refuses to run (exit code 2) until they are
replaced (section 4.1).

## 4. Configure

### 4.1 Connection string: `/etc/sysconfig/pbm-conf`

`install.sh` creates it from the template (`sysconfig/pbm-conf` in the
package) when it does not exist. Replace the placeholders; the
`PBM_MONGODB_URI` line printed by `pbmuser.create.js` (section 1.1) can be
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
  `endpointUrl: https://storage.googleapis.com` and GCS HMAC keys (block in
  `conf/pbm-conf.yaml`). `pbm status` reports `S3
  s3://https://storage.googleapis.com/...`; pbm-backup accepts it as GCS,
  so `REQUIRED_STORAGE_TYPES=GCS` (default) still applies.
- **Agent configuration by environment only** (§4.3): no `/etc/pbm-agent.yaml`,
  no `--config` drop-in.

### Downgrade from a newer PBM (EL8, every member of the replica set)

All agents must run the same version: do every member in the same window.

```bash
# 0. Check: package, available version, drop-ins, lock
rpm -q percona-backup-mongodb
sudo dnf --showduplicates list percona-backup-mongodb | grep 2.5.0   # else: sudo percona-release enable pbm release
systemctl cat pbm-agent                                              # look for a --config drop-in
pbm config > /root/pbm-config-before.yaml && chmod 600 /root/pbm-config-before.yaml   # once; holds secrets

# 1. Stop backups and agents (all members)
sudo systemctl disable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer pbm-backup-metrics.timer
pbm status -s running            # must be idle: {"running":{}}
sudo systemctl stop pbm-agent

# 2. Downgrade (each member)
sudo dnf versionlock delete percona-backup-mongodb    # only if locked
sudo dnf downgrade percona-backup-mongodb-2.5.0-1.el8 # exact name from --showduplicates
sudo dnf versionlock add percona-backup-mongodb
sudo rm -f /etc/systemd/system/pbm-agent.service.d/config.conf && sudo systemctl daemon-reload
# /etc/sysconfig/pbm-agent is %config(noreplace): it is kept. Check its URI (§4.3).

# 3. Storage compatible with 2.5.0 (once, agents still stopped), if it was "type: gcs"
pbm config --file /root/pbm-config-2.5.yaml           # S3 block of conf/pbm-conf.yaml, chmod 600

# 4. Start and verify
sudo systemctl start pbm-agent                        # all members
pbm status                                            # every agent v2.5.0 and ok, storage S3 s3://https://storage.googleapis.com/...
pbm config --force-resync && pbm list

# 5. pbm-backup (each member)
sudo pbm-backup check
sudo systemctl enable --now pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer
```

Install pbm-backup on these members with `--scheme logical`; before the first
logical full `check` warns that PITR is disabled (the first full enables it).
