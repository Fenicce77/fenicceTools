# MySQL Transaction and Lock Monitor Design

## Goal

Create one interactive MySQL monitor for active transactions and lock waits, retaining explicit operator control for connection termination.

## CLI

`mysql_trx_monitor.sh --login-path NAME [OPTIONS]` supports `--view transactions|locks|all`, `--refresh-time`, `--min-age`, `--user-filter`, `--database-filter`, `--host-filter`, `--output-file`, `--mysql-bin`, `--no-color`, `--smoke-test`, and `--help`.

No arguments and `--help` render full colored TTY help, modeled after `check_cardinality.sh`. Non-TTY output and `--no-color` contain no ANSI sequences.

## Views

`transactions` shows connection ID, user, host, schema, transaction age, start time, state, query digest/text, and InnoDB history-list length. `locks` shows blocker and waiter connection IDs, users, locked object, wait duration, and query text. `all` renders both from independent read-only queries.

## Safety

Normal and smoke modes execute only `SELECT`. The interactive `k` command requires a manually entered numeric connection ID, validates it is not the monitor's own connection and exists, displays the target, and requires the exact confirmation `kill <ID>` before issuing `KILL CONNECTION <ID>`. No timeout, flag, view, or filter initiates automatic termination.

## Compatibility

Use `information_schema.innodb_trx`, `performance_schema.threads/events_statements_current`, `information_schema.innodb_metrics`, and `sys.innodb_lock_waits` when available. Missing views or privileges produce explicit degraded-view messages without terminating unrelated views. Support MySQL 8/8.4, Cloud SQL, RDS, macOS, and Linux.

## Migration and Tests

Keep all existing `mysql/trx` scripts unchanged. Add the new monitor plus a fake-MySQL test suite covering CLI, views, filters, ANSI behavior, logging, smoke mode, degraded views, and the manual `KILL` confirmation sequence.
