# fenicceTools

DBRE tools, operational scripts, and diagnostic queries for MySQL-family databases, ProxySQL, Cloud SQL, MongoDB, and supporting Linux/macOS workflows.

The repository contains both maintained tools and historical utilities. Review each script and test it against a non-production target before operational use.

## Maintained tools

| Area | Tool | Purpose |
|---|---|---|
| MySQL | [Cardinality analyzer](mysql/estimations/README.md) | Compare InnoDB estimates with exact counts when safe and report column cardinality and selectivity. |
| MySQL | [Transaction and lock monitor](mysql/trx/mysql_trx_monitor.sh) | Inspect active transactions and lock waits, apply exact session filters, log snapshots, and explicitly terminate a selected connection. |
| ProxySQL | [Python monitor](mysql/proxysql/python/README.md) | Interactive, install-free ProxySQL connection and backend monitor using MySQL login paths. |
| ProxySQL | [Go monitor](mysql/proxysql/go/README.md) | Go implementation of the ProxySQL monitor with bounded resources and persistent clients. |
| Cloud SQL | [General-log monitor](mysql/general_log/README.md) | Capture and safely parse GCP Cloud SQL MySQL general-log entries. |

## Repository map

| Path | Contents |
|---|---|
| [`mysql/`](mysql/) | MySQL diagnostics, replication, InnoDB, binlog, dump, session, partitioning, and ProxySQL tools. |
| [`mongodb/`](mongodb/) | MongoDB operational snippets, including current-operation and connection inspection. |
| [`sql/`](sql/) | Standalone SQL diagnostics and test DDL. |
| [`sh/`](sh/) | Historical shell utilities and earlier MySQL operational scripts. |
| [`generic/`](generic/) | Generic session, query-generation, search, and user-management helpers. |
| [`partitioning/`](partitioning/) | Partitioning and `pt-online-schema-change` helper scripts. |
| [`docs/superpowers/`](docs/superpowers/) | Design specifications and implementation plans for maintained changes. |

## Requirements

- macOS or Linux.
- Bash 3.2 or newer for standardized shell tools.
- Python 3.9 or newer for the ProxySQL Python monitor.
- Go 1.22 or newer for the ProxySQL Go monitor.
- MySQL command-line client and `mysql_config_editor` where MySQL login paths are used.
- Tool-specific external commands documented in each tool's README.

## Local verification

Run maintained test suites from the repository root:

```bash
bash mysql/trx/tests/test_mysql_trx_monitor.sh
bash mysql/estimations/tests/test_check_cardinality.sh
bash mysql/estimations/tests/test_analyze_prefix_index.sh
bash mysql/estimations/tests/test_estimate_storage.sh

(
  cd mysql/proxysql/python
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -q
)

(
  cd mysql/proxysql/go
  go test ./...
  go vet ./...
)

(
  cd mysql/general_log
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
    -s tests/gcp-general-log-parser \
    -p 'test_parser.py' \
    -q
  bash tests/gcp-general-log-parser/test_shell_integration.sh
)

bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

## MySQL transaction and lock monitor

Use a MySQL login path to render active transactions and InnoDB lock waits:

```bash
mysql/trx/mysql_trx_monitor.sh \
  --login-path production-db \
  --view all \
  --min-age 30
```

Filters are comma-separated exact values. Host values include the client port when it is present in `PROCESSLIST.HOST`:

```bash
mysql/trx/mysql_trx_monitor.sh \
  --login-path staging-db \
  --user-filter app,reporting \
  --database-filter sales \
  --host-filter host1:3306 \
  --output-file mysql-trx-snapshots.log
```

Monitoring and snapshot logging are read-only. The interactive `k` command is the only path that can issue `KILL CONNECTION`; it requires a manually entered connection ID, displays the target, and executes only after the exact `kill ID` confirmation. Monitor queries use short-lived MySQL client sessions, so the tool has no persistent database connection of its own.

## Credential handling

- Store credentials in MySQL login paths created with `mysql_config_editor`.
- Do not commit real passwords, tokens, private keys, or production connection files.
- Treat host inventories and configuration templates according to their operational sensitivity.
- Rotate a credential if it has ever been committed, even if the containing file is later deleted.

## Legacy utilities

Files outside the maintained areas may predate current conventions such as `set -euo pipefail`, complete CLI help, deterministic exit codes, portable macOS/Linux behavior, and automated tests. Validate dependencies, SQL compatibility, privilege requirements, and failure handling before production use.
