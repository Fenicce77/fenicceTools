# MySQL Transaction and Lock Monitor Phase 2 Design

## Goal

Complete the unified monitor with safe exact filters, plain snapshot logging, complete help, and degraded-view handling.

## Filters

`--user-filter`, `--database-filter`, and `--host-filter` accept comma-separated exact values. Empty items are rejected. Values are encoded as hexadecimal `utf8mb4` literals and rendered as `IN (...)`, preserving exact matching independently of `NO_BACKSLASH_ESCAPES`; they do not support regular expressions or arbitrary `LIKE` patterns.

## Logging and Interaction

`--output-file FILE` appends plain, ANSI-free timestamped snapshots. Interactive `l` toggles logging, `f` edits filters, and `p` pauses. Existing manual `k` confirmation remains unchanged.

## Compatibility

The monitor performs a connection preflight before rendering. The preferred transaction query treats only `events_transactions_current.STATE = 'ACTIVE'` as transaction state and falls back to `information_schema.PROCESSLIST` and `innodb_trx` when `performance_schema` tables cannot be queried. Missing `sys.innodb_lock_waits` produces a clear degraded locks-view message with a single-line MySQL diagnostic while other views continue.

## UX and Tests

Help is sectioned and colored on TTY, modeled after `check_cardinality.sh`; no arguments display it. Tests add exact filters, plain log output, fallback, and no automatic kill assertions.
