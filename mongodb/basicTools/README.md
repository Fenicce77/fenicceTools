# basicTools - MongoDB

Small toolbox to run admin/audit JavaScript against MongoDB 4.x - 8.x (Community and
Percona Server for MongoDB) from macOS or Linux.

| Path | Purpose |
|------|---------|
| `sh/mongo_exec.sh` | Wrapper: reads a config file, connects with a credential-less URI and authenticates through a 0600 preamble (password never in `ps`). Runs mongosh or the legacy `mongo` shell. |
| `js/mongo_list_users.js` | User audit: auth DB, SCRAM mechanisms, direct/inherited roles, databases granted. Text or JSON. |
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
