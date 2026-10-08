# basicTools - MongoDB

Small toolbox to run admin/audit JavaScript against MongoDB 4.x - 8.x (Community and
Percona Server for MongoDB) from macOS or Linux.

| Path | Purpose |
|------|---------|
| `sh/mongo_exec.sh` | Wrapper: reads a config file, connects with a credential-less URI and authenticates through a 0600 preamble (password never in `ps`). Runs mongosh or the legacy `mongo` shell. |
| `js/mongo_list_users.js` | User audit: auth DB, SCRAM mechanisms, direct/inherited roles and an abbreviated access summary. Text (default), `--compact` (one line per user), `--table` (full report as a table) or JSON. |
| `conf/mongodb_config.template.conf` | Config template (copy, fill in, `chmod 600`). |

## Quick start

```bash
cp conf/mongodb_config.template.conf conf/prod_rs.conf   # ignored by git
chmod 600 conf/prod_rs.conf && vim conf/prod_rs.conf

sh/mongo_exec.sh -c conf/prod_rs.conf -f js/mongo_list_users.js
sh/mongo_exec.sh -q -c conf/prod_rs.conf -f js/mongo_list_users.js -a --json -a --user=rmateos | jq .
sh/mongo_exec.sh -f js/mongo_list_users.js -a --help
```

Script arguments go with `-a` (repeatable); client arguments (TLS, etc.) after `--`.

## Access summary (`mongo_list_users.js`)

Output modes: default (one block per user), `-a --compact` (one line per user) and
`-a --table` (the default report as a bordered table, list values one per line;
`INHERITED ROLES` / `AUTH RESTRICTIONS` columns only when there is data).

```
USER      AUTH_DB  SCRAM   ACCESS
dba       admin    SHA256  CLU-ADMIN, *:RW+ADM_DB
pbm       admin    SHA256  MON, BACKUP, RESTORE, admin:RW
rmateos   admin    BOTH    ROOT
owner     app      SHA256  app:ALL, reporting:RO
reporter  app      SHA256  app(3 colls):RO, app.audit:RW, reporting:RO
```

```
+---+------+---------+---------+----------------------+-----------------+----------+
| # | USER | AUTH_DB | SCRAM   | DIRECT ROLES         | INHERITED ROLES | ACCESS   |
+---+------+---------+---------+----------------------+-----------------+----------+
| 1 | pbm  | admin   | SHA-256 | backup@admin         | None            | MON      |
|   |      |         |         | clusterMonitor@admin |                 | BACKUP   |
|   |      |         |         | readWrite@admin      |                 | RESTORE  |
|   |      |         |         | restore@admin        |                 | admin:RW |
+---+------+---------+---------+----------------------+-----------------+----------+
```

- Format: `<scope>:<level>[+ADM_DB][+ADM_USR]`, scope = `db` | `db.coll` | `db(N colls)` | `*` (all databases).
  Levels come from the actions of the effective privileges:

  | Code | Meaning |
  |------|---------|
  | `RO` | read-only: `find` on documents |
  | `RW` | read/write: RO + insert/update/remove (readWrite) |
  | `ALL` | full control of the scope: RW + ADM_DB + ADM_USR (dbOwner) or `anyAction` |
  | `+ADM_DB` | database administration: indexes, collMod, compact, validate, profiler, dropDatabase (dbAdmin) |
  | `+ADM_USR` | user/role administration: create/drop users, grant/revoke roles, change passwords (userAdmin) |
  | `INFO` | metadata/stats only, no document access |
  | `?` | privileges not readable: custom/dropped role, `--no-resolve` or missing `viewRole` |

- Built-in system roles become tags and their privileges are not expanded: `ROOT`, `SYSTEM`,
  `CLU-ADMIN` (includes `CLU-MGR`, `MON`, `HOST`), `CLU-MGR`, `MON` (clusterMonitor), `HOST`,
  `BACKUP`, `RESTORE`, `QBACKUP`, `SHARDING`, `SHARD-DIRECT`, `SEARCH`. Custom cluster grants:
  `CLU-RO` (monitoring only) / `CLU-OPS`.
- The legend after the report always lists every level and only the tags present
  (`--no-legend` to hide it); `--help` lists all of them.
- Scopes covered by a broader one are omitted (`app:RO` disappears under `*:RW`).
- `role@db:?` = role whose privileges could not be read; built-in db roles are still mapped
  by name in that case.
- JSON adds `access`, `accessTags` and `accessScopes`.

## Client / server compatibility

| Server | Client |
|--------|--------|
| 4.2 - 8.x | mongosh (default) |
| 4.0 - 4.4, or when mongosh rejects the server's wire version | legacy `mongo` 4.x shell: `-C /path/to/mongo` or `MONGO_CLIENT_BIN` |

Scripts under `js/` are written in ES5 and avoid mongosh-only APIs so both shells run
them. The wrapper exposes `MONGO_EXEC_CTX` (`args`, `color`, `nodb`) to the script.

## Writing new scripts

- ES5 only (`var`, `function`, no template literals/arrow functions/`Set`), wrapped in an IIFE.
- Output with `print()`; errors with `console.error` only when `process` exists (mongosh).
- Normalise `runCommand` results: mongosh throws on `ok: 0`, the legacy shell returns it.
- Exit with `quit(n)`: 1 server error, 2 usage error (3 is reserved for wrapper auth failures).
- No shell API calls inside `Array.prototype.*` callbacks (mongosh async rewriter).
