# MySQL Transaction and Lock Monitor Phase 2 Design

## Goal

Complete the unified monitor with safe exact filters, plain snapshot logging, complete help, and degraded-view handling.

## Filters

`--user-filter`, `--database-filter`, and `--host-filter` accept comma-separated exact values. Empty items are rejected. Values are SQL-escaped and rendered as `IN (...)`; they do not support regular expressions or arbitrary `LIKE` patterns.

## Logging and Interaction

`--output-file FILE` appends plain, ANSI-free timestamped snapshots. Interactive `l` toggles logging, `f` edits filters, and `p` pauses. Existing manual `k` confirmation remains unchanged.

## Compatibility

The transaction view falls back to `information_schema.PROCESSLIST` and `innodb_trx` when `performance_schema` tables cannot be queried. Missing `sys.innodb_lock_waits` produces a clear degraded locks-view message while other views continue.

## UX and Tests

Help is sectioned and colored on TTY, modeled after `check_cardinality.sh`; no arguments display it. Tests add exact filters, plain log output, fallback, and no automatic kill assertions.
