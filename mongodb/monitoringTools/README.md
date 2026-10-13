# monitoringTools

| Script | Bash | Python | Purpose |
|---|---|---|---|
| analyze_oplog | `sh/analyze_oplog.sh <conf> [--include-pbm] [--exclude-internal] [--group hour\|day]` | `python3 python/analyze_oplog.py <conf> ...` | Oplog usage by namespace/op, deltas, TTL deletes |
| mongo_top | `sh/mongo_top.sh -c <conf> [-d N] [-u users] [-t secs]` | `python3 python/mongo_top.py -c <conf> ...` | Live `$currentOp` monitor |

## Configuration

Copy the template and name it `<name>_mongo_config.conf` (git-ignored):

```bash
cp sh/mongo_config.template.conf sh/prod_mongo_config.conf
cp python/conf/mongo_config.template.conf python/conf/prod_mongo_config.conf
chmod 600 sh/prod_mongo_config.conf python/conf/prod_mongo_config.conf
```

`MONGOHOST` accepts `rsName/node1:27017,node2:27017` (replica set) or `host[:port][,host...]`.

### Password sources (first one defined wins)

| Key | Value |
|---|---|
| `MONGOADMINPAS_ENV` | Name of an environment variable holding the password |
| `MONGOADMINPAS_FILE` | File whose first line is the password (`chmod 600`, `~` allowed) |
| `MONGOADMINPAS_CMD` | Command printing the password (macOS Keychain, `pass`, Vault...) |
| `MONGOADMINPAS` | Plaintext password: legacy, still accepted, prints a warning (`MT_QUIET_PLAINTEXT_WARNING=1` silences it) |

```bash
# Environment variable (no trace in shell history)
read -rs MONGO_PWD_PROD && export MONGO_PWD_PROD     # conf: MONGOADMINPAS_ENV="MONGO_PWD_PROD"
sh/analyze_oplog.sh sh/prod_mongo_config.conf --exclude-internal

# macOS Keychain
security add-generic-password -a rmateos -s mongo-prod -w   # prompts for the password
# conf: MONGOADMINPAS_CMD="security find-generic-password -a rmateos -s mongo-prod -w"
```

The password never reaches a command line:

- Bash: `mongosh --nodb` receives it in the `MT_MONGO_PASSWORD` environment variable of that single process; a JS prelude (`sh/lib/mongo_auth.sh`) reads it, removes it from `process.env` and calls `connect()` with URL-encoded credentials. `ps`/`/proc/<pid>/cmdline` only show `mongosh --nodb --quiet <file>`.
- Python: `MongoClient(username=..., password=..., authSource=...)` (`python/mt_credentials.py`); the password is not embedded in a URI, so special characters need no escaping and errors never echo it.

Config files are still compatible with the previous format: existing files with `MONGOADMINPAS="..."` keep working.
