# Analyze Prefix Index Standardization Design

## Goal

Standardize `mysql/estimations/analyze_prefix_index.sh` as a safe, portable MySQL index-prefix analyzer while retaining its existing selectivity and marginal-gain algorithm.

## CLI and Safety Contract

The existing `-l`, `-d`, `-t`, `-c`, `-m`, and `-h` options remain supported. Add `--environment`, `--allow-production`, `--mysql-bin`, `--query-timeout`, and `--no-color`.

`--environment development|test|staging|production` is required. Production execution additionally requires `--allow-production`; all other environments reject that flag. SQL identifiers are validated before interpolation. `--mysql-bin`, then `MYSQL_BIN`, then `PATH` selects the local client.

## Runtime Behavior

Use Bash strict mode, portable temporary-file cleanup, deterministic exit codes (`0` success, `2` validation, `3` dependency/connection, `4` partial failures, `130` interruption), and color only when enabled and stdout is a TTY. Query failures for one column continue with other requested columns and produce exit `4`.

The analyzer applies `MAX_EXECUTION_TIME` through an optimizer hint to selectivity queries when `--query-timeout` is supplied. It never issues DDL or writes to the target server.

## Testing

Create a fake MySQL client and Bash test suite covering help, validation, production guards, safe SQL construction, client resolution, timeout hint, ANSI-free output, and partial-column failures. Tests must not contact a real server.

## Scope

Modify only the analyzer, its estimation README, and new tests/fixtures. Do not change `check_cardinality.sh`, `estimate_storage.sh`, or maintained ProxySQL/general-log tools.
