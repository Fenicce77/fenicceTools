# betika_mongodb_normalized

CLI tool (bash and Python implementations) that collects schema metadata from several
MongoDB instances, compares them, and produces a centralization plan with the required
modifications to consolidate every database into a single central instance.

Supports MongoDB 4.x - 8.x (incl. Percona Server for MongoDB), replica sets, sharded
clusters (through mongos) and standalone instances. Runs on Linux and macOS.

## Layout

```
betika_mongodb_normalized/
├── bash/
│   ├── mongo_schema_normalizer.sh      # bash CLI (bash >= 3.2, macOS default shell OK)
│   └── lib/
│       ├── collector.js                # mongosh collector (credentials via env, never argv)
│       ├── analyzer.js                 # offline analyzer + renderers (mongosh --nodb or node)
│       ├── atlassian.js                # Jira / Confluence payload builder + response parser
│       └── publish.sh                  # Jira / Confluence Data Center publisher (curl)
├── python/
│   ├── mongo_schema_normalizer.py      # Python CLI entry point (Python >= 3.8)
│   ├── requirements.txt                # pymongo
│   └── bmn/                            # config, collector, analyzer, renderers, cli, ui
├── share/templates/                    # generated-artifact templates shared by both CLIs
├── conf.example/
│   ├── instance.conf.example           # recommended instance configuration format
│   └── atlassian.conf.example          # Jira / Confluence Data Center publication settings
└── tests/
    ├── fixtures/                       # synthetic snapshots + mapping file
    └── parity_check.sh                 # asserts byte-identical output of both CLIs
```

Both implementations share the snapshot format, the analysis algorithm and the templates:
you can collect with one and analyze with the other.

## Requirements

| Implementation | Collection               | Analysis                    |
|----------------|--------------------------|-----------------------------|
| bash           | `mongosh` >= 1.x         | `mongosh` (or `node` >= 16) |
| python         | Python >= 3.8, `pymongo` | Python only                 |

```bash
pip3 install --user -r python/requirements.txt
```

## Configuration

One file per instance in `<project_root>/conf/<instance_name>.conf`
(see `conf.example/instance.conf.example`). Key points:

- Files are parsed as `KEY=VALUE` data and are **never sourced**: command substitutions
  (`` `which mongosh` ``, `$(...)`) are ignored with a warning.
- Legacy keys are still accepted: `MONGOHOST` (`rs/host1,host2`), `MONGOADMINUSR`,
  `MONGOADMINPAS`, `ADMINDB`. `MONGOSHBINPATH` is ignored (use `MONGOSH_BIN`).
- Password sources, in precedence order: `MONGO_PASSWORD_ENV` (variable name),
  `MONGO_PASSWORD_FILE` (first line, `chmod 600`), `MONGO_PASSWORD_CMD` (Keychain,
  libsecret, Vault, GCP Secret Manager...), `MONGO_PASSWORD` (plaintext, warned).
- Credentials never appear in process arguments nor in any generated file; the stored
  URI is redacted. Output directories are created with `umask 077`.
- `MONGO_ROLE="target"` (or `--target`) identifies the central instance. When present it
  is analyzed as well: existing namespaces, version and feature compatibility.

### Least-privilege user

Do not use `root`/`admin` accounts. Create a dedicated user on every instance:

```javascript
db.getSiblingDB("admin").createRole({
  role: "bmnSchemaAuditor",
  privileges: [
    { resource: { cluster: true }, actions: ["listDatabases", "serverStatus", "getParameter", "top", "inprog"] },
    { resource: { db: "", collection: "" }, actions: ["listCollections", "listIndexes", "collStats", "find"] },
    { resource: { db: "config", collection: "collections" }, actions: ["find"] },
    // --oplog-window:
    { resource: { db: "local", collection: "oplog.rs" }, actions: ["find"] },
    // --include-security and session user resolution of --oplog-window:
    { resource: { db: "", collection: "" }, actions: ["viewUser", "viewRole"] }
  ],
  roles: []
});
db.getSiblingDB("admin").createUser({
  user: "schema_auditor",
  pwd: passwordPrompt(),
  roles: [{ role: "bmnSchemaAuditor", db: "admin" }]
});
```

`find` is required by `$sample`, the `_id` bounds and the *modified* fields, `top` by
`--member-stats` and `inprog` by `--activity-samples`. With `--member-stats`, `--oplog-window`
or `--activity-samples` the user must be valid on every replica set member (direct connections). Snapshots store field paths and BSON type histograms
only, never document values (validators, partial filters and view pipelines are metadata
and are kept as defined).

## Usage

```bash
# bash
./betika_mongodb_normalized/bash/mongo_schema_normalizer.sh --help
./betika_mongodb_normalized/bash/mongo_schema_normalizer.sh check --connect
./betika_mongodb_normalized/bash/mongo_schema_normalizer.sh run --target central01 --include-security

# python
./betika_mongodb_normalized/python/mongo_schema_normalizer.py --help
./betika_mongodb_normalized/python/mongo_schema_normalizer.py run -i cd01,cd02 -n prefix --sample-size 500

# offline re-analysis with explicit database mapping overrides
./betika_mongodb_normalized/python/mongo_schema_normalizer.py analyze \
    -s ./reports/20260930T101500Z/snapshots -m ./conf/mapping.txt -n keep
```

| Command   | Description                                                   |
|-----------|---------------------------------------------------------------|
| `run`     | collect + analyze (default)                                   |
| `collect` | snapshots only (`<output-dir>/snapshots/<instance>.json`)     |
| `analyze` | offline analysis of a snapshot directory (no DB access)       |
| `check`   | validate configuration files, `--connect` tests connectivity  |
| `publish` | publish an existing report directory to Jira / Confluence DC  |

Naming strategies (`-n`):

- `auto` (default): keep the database name unless it exists in more than one source or
  already exists on the target; then `<alias><sep><db>`.
- `keep`: never rename; collisions are reported as blocking errors.
- `prefix`: always `<alias><sep><db>`.

A mapping file (`-m`) overrides any strategy per database:
`<instance|alias>:<source_db>=<target_db>` (one entry per line, `#` comments).

Exit codes: `0` ok, `1` blocking findings, `2` usage/config error, `3` collection errors, `4` publication errors.

## Collected data

Per instance: version, FCV, topology, storage engine. Per collection: type
(collection/view/time-series), options (validators, collation, capped, clustered,
time-series, pre/post images, encryptedFields), indexes, `$collStats` storage statistics
(summed across shards), shard key, and a schema histogram from `$sample` (field paths up
to `--max-depth`, array elements as `path[]`). Optionally users and custom roles.
Reads use `readPreference=secondaryPreferred` and `appName=betika_mongodb_normalized`
(easy to spot in `currentOp`/PMM).

## Activity and users

MongoDB stores neither creation/modification dates nor per-user access history, so the
tool combines several sources and labels each one:

| Data | Source | Default | Cost | Caveats |
|---|---|---|---|---|
| First / last insert (`~`) | min/max ObjectId `_id` (2 index seeks) | on | negligible | ObjectId `_id` only; client clock; inserts only |
| Last modified | max of date fields whose name matches `--modified-pattern` (default `modif`: `modifiedAt`, `lastModified`, `date_modified`...) | on | index seek if the field leads a non-partial index; otherwise none (sample max) | without index the value is a lower bound (`≥`) from the sample; `--modified-scan` makes it exact with a COLLSCAN |
| Reads / writes since restart | `top` on every member (direct connection) | `--member-stats` | negligible | per-node counters reset on restart |
| Created, last write, i/u/d/c counts | oplog of a secondary, last `--oplog-window` hours | off | ∝ oplog volume in the window | creation only if inside the window |
| Users per collection (writes) | oplog `lsid.uid` = SHA-256 of `user@authDB`, matched against `usersInfo` | with oplog | none extra | only retryable writes and transactions carry `lsid` (`(no session)` otherwise) |
| Users, apps, clients (reads and writes) | `$currentOp` sampling on every member | off | N rounds × members | statistical: short operations can be missed |

`STALE_COLLECTION` (INFO) flags collections whose newest insert/modification is older than
`--stale-days` (default 180, `0` disables). It is only raised when the dates are exact (no
sample-based or failed *modified* field), so it is safe to use as an archiving shortlist.

The report adds section 8 (activity per collection) and section 9 (users: defined, effective
access, observed activity, applications, client hosts). The plan classifies users as
**migrate** (activity observed), **review** (access granted, nothing observed) or
**unknown** (no oplog window nor sampling collected). Typical run for user discovery:

```bash
mongo_schema_normalizer.sh run --include-security --oplog-window 24 --activity-samples 30 --activity-interval 10
```

## Generated artifacts

| File                           | Content                                                                 |
|--------------------------------|-------------------------------------------------------------------------|
| `report.md`                    | instances, findings, per-instance inventory, cross-instance drift        |
| `centralization_plan.md`       | capacity, database mapping, required modifications, runbook             |
| `report.jira.txt`              | Jira wiki markup summary for an issue description (<= 32,767 chars)     |
| `report.confluence.xml`        | full report + plan in Confluence storage format (macros, expands)       |
| `analysis.json`                | machine-readable analysis (mapping, drift, findings, capacity)          |
| `target_bootstrap.js`          | idempotent, phased mongosh bootstrap for the target (dry-run default)   |
| `migration_commands.sh`        | `mongodump \| mongorestore --nsFrom/--nsTo` jobs (dry-run default)      |
| `normalization_suggestions.js` | `$convert` fixes for fields with mixed scalar BSON types (dry-run)      |

### Jira and Confluence

`report.jira.txt` (Jira **wiki markup**) is an actionable summary for an issue description:
status panel, instances, findings (errors and warnings with details, info grouped by code),
database mapping, required modifications, users to migrate/review and next steps. It always
fits the 32,767-character description limit: above ~32,000 characters it switches to a compact
mode (no detail blocks, capped lists with "... N more"), and truncates only as a last resort.

`report.confluence.xml` (Confluence **storage format**) is the complete page: table of contents,
status lozenges per severity, warning/tip/info panels, finding details and per-instance
inventory in expand macros, activity and users tables, and the runbook.

#### Publishing to Jira / Confluence Data Center

Configure `conf/atlassian.conf` (template: `conf.example/atlassian.conf.example`, `chmod 600`):
URLs, a Personal Access Token per product (`*_TOKEN_ENV`, `*_TOKEN_FILE` or `*_TOKEN_CMD`;
`*_USER` switches to HTTP basic for servers without PAT support), Jira project / issue type /
labels and the Confluence space / parent page / title. Then:

```bash
# preview: read-only calls only (issue / page lookup), prints what would be created or updated
mongo_schema_normalizer.sh publish -o ./reports/20261013T100000Z --publish-jira --publish-confluence --publish-dry-run
# publish an existing report directory
mongo_schema_normalizer.sh publish -o ./reports/20261013T100000Z --publish-jira --publish-confluence --jira-attach
# or analyze and publish in one go
mongo_schema_normalizer.sh run --publish-jira --publish-confluence
# add the analysis as a comment to an existing ticket (e.g. the migration task)
mongo_schema_normalizer.sh publish -o ./reports/20261013T100000Z --jira-comment --jira-issue DBA-1234
```

| Product | Behaviour |
|---|---|
| Jira | `POST /rest/api/2/issue` (project, type, summary, description, labels, components), or `PUT` summary + description when an issue key is known: `--jira-issue`, `JIRA_ISSUE`, or the key stored in `<report_dir>/publish.json` by a previous publication. `--jira-attach` uploads `JIRA_ATTACH` files. |
| Jira comment | `--jira-comment --jira-issue KEY` (or `JIRA_ISSUE`): `POST /rest/api/2/issue/KEY/comment` with `report.jira.txt`; summary and description are left untouched. `JIRA_COMMENT_VISIBILITY="role:<name>"` or `"group:<name>"` restricts the comment. The key must be explicit (never taken from `publish.json`) and the result is stored separately (`jira_comment`), so a later `--publish-jira` never overwrites that ticket. `--jira-attach` also works. |
| Confluence | Looks up the page by title in `CONFLUENCE_SPACE`: updates it with a new version (history kept) or creates it under `CONFLUENCE_PARENT_ID`. |

- The token is never passed on the command line: Python sends it from memory, bash through a
  private curl header file (`-H @file`, mode 600, removed at exit). It is not written to any output.
- `ATLASSIAN_CA_FILE` sets an internal CA bundle for HTTPS.
- Results (issue key, page id/version, URLs) are stored in `<report_dir>/publish.json` (mode 600).
- Exit code `4` on any publication failure; a blocked analysis is still published (status BLOCKED).
- The bash implementation needs `curl`; JSON is handled by `lib/atlassian.js` (mongosh or node, no jq).

For Jira / Confluence **Cloud** (not handled by `publish`) use the REST examples below: Jira Cloud
accepts wiki markup only through REST API v2, and Confluence Cloud lives under `/wiki/rest/api`.
For a manual paste in Confluence use `report.md` with *Insert > Markup > Markdown*.

```bash
REPORT_DIR=./reports/20261013T100000Z
jq -n --arg project DBA --arg summary "MongoDB centralization analysis" \
      --rawfile desc "${REPORT_DIR}/report.jira.txt" \
      '{fields: {project: {key: $project}, issuetype: {name: "Task"}, summary: $summary, description: $desc}}' \
  | curl -sS -u "rmateos@example.com:${JIRA_API_TOKEN}" -H 'Content-Type: application/json' \
         -X POST "https://your-domain.atlassian.net/rest/api/2/issue" --data-binary @-
jq -n --arg space DBA --arg title "MongoDB centralization analysis" \
      --rawfile body "${REPORT_DIR}/report.confluence.xml" \
      '{type: "page", title: $title, space: {key: $space}, body: {storage: {value: $body, representation: "storage"}}}' \
  | curl -sS -u "rmateos@example.com:${CONFLUENCE_API_TOKEN}" -H 'Content-Type: application/json' \
         -X POST "https://your-domain.atlassian.net/wiki/rest/api/content" --data-binary @-
```

Runbook (also in `centralization_plan.md`):

```bash
BMN_PHASE=collections            mongosh "$TARGET_URI" --quiet --norc --file target_bootstrap.js
BMN_PHASE=collections BMN_APPLY=1 mongosh "$TARGET_URI" --quiet --norc --file target_bootstrap.js
./migration_commands.sh --list && ./migration_commands.sh --apply        # writes frozen on sources
for p in indexes views security verify; do
  BMN_PHASE=$p BMN_APPLY=1 mongosh "$TARGET_URI" --quiet --norc --file target_bootstrap.js
done
```

`migration_commands.sh` reads connection strings (credentials included) from
database-tools YAML files (`uri: ...`, `chmod 600`) in
`~/.config/betika_mongodb_normalized/tools/<alias>.yaml` and `target.yaml`; it refuses
`--apply` while the analysis has blocking errors unless `--force` is given.

## Findings

| Severity | Code | Meaning |
|---|---|---|
| ERROR | `COLLECT_ERROR`, `TARGET_NOT_FOUND` | instance could not be collected / unknown target |
| ERROR | `NS_COLLISION` | several sources map to the same target namespace |
| ERROR | `TARGET_NS_EXISTS` | namespace already exists on the target |
| ERROR | `DB_NAME_INVALID`, `NS_TOO_LONG` | invalid target database name / namespace > 255 bytes |
| ERROR | `FEATURE_UNSUPPORTED` | time-series, clustered, pre/post images or QE not supported by target version |
| ERROR | `INDEX_TYPE_REMOVED` | `geoHaystack` index (removed in 5.0) |
| WARN | `SCHEMA_DRIFT_INDEXES/OPTIONS/TYPES` | same namespace differs across instances |
| WARN | `FIELD_TYPE_MIXED` | field with inconsistent non-numeric BSON types |
| WARN | `NO_USER_DATABASES` | no user databases and no listing details (snapshot from an older collector): re-collect |
| WARN | `DB_LISTING_PARTIAL` | user without the `listDatabases` privilege: only authorized databases were listed |
| WARN | `VERSION_DOWNGRADE` | source newer than target |
| WARN | `SHARD_KEY_LOST`, `TIMESERIES_RENAME`, `TARGET_DB_EXISTS` | sharding / time-series remap / existing target database |
| WARN | `USER_CONFLICT`, `ROLE_CONFLICT`, `OPTION_LEGACY`, `STATS_ERROR`, `SAMPLE_ERROR` | security conflicts, legacy options, partial collection |
| WARN | `ACTIVITY_ERROR` | unreachable member, oplog/sampling/user-resolution failure |
| INFO | `NO_RECENT_ACTIVITY` | no writes in the oplog window nor reads/writes since restart: archiving candidate |
| INFO | `OPLOG_WINDOW_SHORT` | the oplog covers less than the requested window |
| INFO | `NO_USER_DATABASES` | instance with only `admin`/`config`/`local` (or all databases filtered out): nothing to migrate |
| INFO | `ARRAY_TYPES_POLYMORPHIC` | array elements mixing types inside the same document (key/value pattern), not a normalization candidate |
| INFO | `STALE_COLLECTION` | no inserts/modifications for `--stale-days` (exact dates only) |
| INFO | `MODIFIED_FROM_SAMPLE` | last modification is a lower bound from the sample (field not indexed) |
| INFO | `USER_NO_ACTIVITY`, `USER_UNRESOLVED` | user with access but no observed activity / session user not resolvable |
| INFO | `DB_MERGE`, `NUMERIC_TYPE_MIXED`, `TTL_INDEX`, `CAPPED`, `VIEW`, `SHARD_KEY`, `INDEX_LEGACY_OPTION`, `MIXED_VERSIONS`, `NO_TARGET`, `SCHEMA_TRUNCATED`, `USER_DUPLICATE`, `ROLE_DUPLICATE` | informational |

Informational findings are grouped by instance in every report (`report.md`, Jira,
Confluence): a per-instance summary table (findings and codes), then one subsection per
instance with its findings grouped by code. Findings that span several instances, or
none, are listed last under *Cross-instance*.

## Limitations

- Schema inference is sample-based (`$sample`, default 100 docs per collection): rare
  shapes may be missed; increase `--sample-size` on critical collections.
- The bash collector requests `promoteValues: false` so int/long/double are distinguished;
  if a mongosh build ignores it, numeric widths degrade to int/double (reported as INFO).
- `mongodump` without `--oplog` is not point-in-time: freeze writes or plan a CDC-based
  cutover for online migrations.
- Document counts in `verify` come from snapshot metadata (`$collStats`), not exact counts.

## Tests

```bash
tests/parity_check.sh                        # bash vs python, all naming strategies
BMN_JS_RUNTIME=node tests/parity_check.sh    # without mongosh
```
