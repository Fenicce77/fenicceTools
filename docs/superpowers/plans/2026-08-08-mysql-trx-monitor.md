# MySQL Transaction and Lock Monitor Implementation Plan

**Goal:** Provide one safe interactive monitor for MySQL transactions and lock waits.

## Constraints

- Create `mysql/trx/mysql_trx_monitor.sh` and tests only; retain legacy scripts unchanged.
- Bash 3.2, macOS/Linux, login paths, strict mode, full colored help on TTY.
- Normal mode is read-only. `KILL CONNECTION` requires manual ID and exact confirmation.

### Task 1: Test harness

- Create `mysql/trx/tests/fake_mysql_trx.sh` and `test_mysql_trx_monitor.sh`.
- Cover help, CLI validation, transaction/lock/all views, filters, no-color, smoke mode, missing-view fallback, logging, and kill confirmation.

### Task 2: Monitor core

- Implement CLI, client resolution, color/terminal lifecycle, safe filters, read-only query execution, and view renderers.
- Add interactive key handling and logging from plain logical output.
- Implement `k`: validate numeric ID, reject own connection, query target, display it, require exact `kill ID`, then execute `KILL CONNECTION ID`.

### Task 3: Verification

- Run monitor tests plus existing estimation, ProxySQL, Go and general-log suites.
- Verify no legacy `mysql/trx` script changed and commit with `feat(mysql): add transaction and lock monitor`.
