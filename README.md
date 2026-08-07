# fenicceTools

DBRE tools, operational scripts, and diagnostic queries for MySQL-family databases, ProxySQL, Cloud SQL, MongoDB, and supporting Linux/macOS workflows.

The repository contains both maintained tools and historical utilities. Review each script and test it against a non-production target before operational use.

## Maintained tools

| Area | Tool | Purpose |
|---|---|---|
| MySQL | [Cardinality analyzer](mysql/estimations/README.md) | Compare InnoDB estimates with exact counts when safe and report column cardinality and selectivity. |
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
bash mysql/estimations/tests/test_check_cardinality.sh

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

## Credential handling

- Store credentials in MySQL login paths created with `mysql_config_editor`.
- Do not commit real passwords, tokens, private keys, or production connection files.
- Treat host inventories and configuration templates according to their operational sensitivity.
- Rotate a credential if it has ever been committed, even if the containing file is later deleted.

## Legacy utilities

Files outside the maintained areas may predate current conventions such as `set -euo pipefail`, complete CLI help, deterministic exit codes, portable macOS/Linux behavior, and automated tests. Validate dependencies, SQL compatibility, privilege requirements, and failure handling before production use.
