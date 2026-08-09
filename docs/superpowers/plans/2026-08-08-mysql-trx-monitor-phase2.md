# MySQL Transaction and Lock Monitor Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the unified monitor with safe exact filters, snapshot logging, complete terminal help, and resilient MySQL view fallbacks.

**Architecture:** Keep `mysql_trx_monitor.sh` as the sole unified implementation and retain legacy transaction scripts unchanged. Build SQL predicates from validated comma-separated literals, render a plain logical snapshot first, then optionally color terminal output and append the same ANSI-free snapshot to a log file. Treat each view independently so unavailable optional views do not prevent transactions from being inspected or manually killed.

**Tech Stack:** Bash 3.2+, MySQL CLI/login paths, `information_schema`, `performance_schema`, `sys`, POSIX-compatible shell utilities.

## Global Constraints

- Support macOS and Linux with Bash 3.2 and `set -euo pipefail`.
- Keep all code comments, help, and emitted messages in English.
- Do not alter legacy scripts under `mysql/trx/`; only modify the unified monitor and its tests.
- `--user-filter`, `--database-filter`, and `--host-filter` accept comma-separated exact values only; reject empty values and encode each as a mode-independent hexadecimal `utf8mb4` literal before rendering an `IN (...)` predicate.
- Normal operation is read-only. Only the `k` command may issue `KILL CONNECTION`, after a user-entered numeric identifier, target inspection, and exact `kill ID` confirmation. Each MySQL command uses a short-lived client session, so there is no persistent monitor connection to reject.
- Help must be sectioned, friendly, color-aware on an interactive terminal, and shown when invoked without parameters.
- `--output-file` appends ANSI-free timestamped snapshots atomically enough that each rendered snapshot is written as one grouped append; no interactive prompts or escape sequences enter the file.
- A missing `performance_schema` transaction query must fall back to `information_schema.PROCESSLIST` joined to `innodb_trx`; an unavailable `sys.innodb_lock_waits` must show a degraded locks message without failing the other view.

---

### Task 1: Extend the deterministic fake MySQL client and define failing regression tests

**Files:**
- Modify: `mysql/trx/tests/fake_mysql_trx.sh`
- Modify: `mysql/trx/tests/test_mysql_trx_monitor.sh`

**Interfaces:**
- Consumes: monitor invocations using `--mysql-bin "$FAKE"` and `FAKE_MYSQL_TRX_LOG`.
- Produces: `FAKE_MYSQL_TRX_MODE=normal|pfs-unavailable|sys-unavailable`, captured SQL statements, and assertions for all Phase 2 externally visible behavior.

- [ ] **Step 1: Add failing tests for help and filter validation**

  Add shell assertions that run the script with no arguments and with `--help`, asserting `Usage:`, `Filters`, `Logging`, `Interactive controls`, and `Examples` appear. Add exit-code assertions that `--user-filter app,,reporting` and `--database-filter ''` fail with a specific invalid-filter message.

- [ ] **Step 2: Run the focused test to verify it fails**

  Run: `bash mysql/trx/tests/test_mysql_trx_monitor.sh`

  Expected: FAIL because the current help has no sections and filter options are not parsed.

- [ ] **Step 3: Add failing tests for exact SQL filtering and ANSI-free snapshot logging**

  Invoke smoke mode with `--user-filter app,reporting --database-filter sales --host-filter host1 --output-file "$TMP/snapshot.log" --no-color`. Assert the captured transaction SQL contains exact `IN (...)` predicates using `CONVERT(X'...' USING utf8mb4)` literals; assert the log contains `Snapshot:` and `TRANSACTIONS`; assert no escape byte occurs in the log.

- [ ] **Step 4: Add fake client modes and failing fallback/degraded-view tests**

  In `fake_mysql_trx.sh`, inspect `FAKE_MYSQL_TRX_MODE`. Return a non-zero status for queries containing `performance_schema` in `pfs-unavailable` mode, and for `sys.innodb_lock_waits` in `sys-unavailable` mode. Add tests that verify a fallback transaction row is rendered in the former mode and that the latter mode emits `LOCK WAITS UNAVAILABLE` while retaining `TRANSACTIONS` for `--view all`.

- [ ] **Step 5: Add no-automatic-kill and manual kill safety tests**

  Preserve the smoke assertion that captured SQL has no `KILL`. Feed interactive input through a pipe for an invalid ID and a non-confirmed kill request, then assert no `KILL CONNECTION` was captured. Feed a valid ID followed by exact `kill ID` and assert precisely one matching `KILL CONNECTION ID` was captured.

- [ ] **Step 6: Run the focused test to verify it fails only for unimplemented Phase 2 behavior**

  Run: `bash mysql/trx/tests/test_mysql_trx_monitor.sh`

  Expected: FAIL on filters, logging, fallback/degraded rendering, or interaction behaviors until Task 2 changes the monitor.

- [ ] **Step 7: Commit the red test harness**

  Run:

  ```bash
  git add mysql/trx/tests/fake_mysql_trx.sh mysql/trx/tests/test_mysql_trx_monitor.sh
  git commit -m "test(mysql): cover monitor phase two behavior"
  ```

### Task 2: Implement option parsing, complete help, and safe exact predicates

**Files:**
- Modify: `mysql/trx/mysql_trx_monitor.sh`
- Test: `mysql/trx/tests/test_mysql_trx_monitor.sh`

**Interfaces:**
- Consumes: `--user-filter LIST`, `--database-filter LIST`, `--host-filter LIST`, `--output-file FILE`, `--no-color`, existing connection/runtime options.
- Produces: `sql_literal VALUE` emitting a hexadecimal `utf8mb4` literal; `rebuild_transaction_filters` emitting safe processlist predicates; ANSI-free `render_snapshot` output.

- [ ] **Step 1: Implement terminal color helpers and the sectioned help renderer**

  Define color state only when stdout is a terminal and `--no-color` is absent. Replace `help()` with headings for `Required options`, `Views and runtime`, `Filters`, `Logging`, `Interactive controls`, `Safety`, and `Examples`. Keep the help content readable without color and make zero positional arguments call it with exit code 0.

- [ ] **Step 2: Parse and validate the three filters and output file**

  Add long options `--user-filter`, `--database-filter`, `--host-filter`, and `--output-file`, each requiring a next argument. Split comma-separated input using a Bash-3.2-compatible loop, reject an empty item, and quote SQL apostrophes by replacing `'` with `''`. Do not accept shell patterns, regular expressions, or raw SQL fragments.

- [ ] **Step 3: Build exact predicates against the processlist aliases**

  Implement a helper that transforms the validated literal list into `p.USER IN (...)`, `p.DB IN (...)`, or `p.HOST IN (...)`. Join present predicates with `AND`, preserving the existing `p.ID != CONNECTION_ID()` and minimum-age clauses. Use the same predicate builder in both the preferred and fallback transaction SQL so the displayed population is consistent.

- [ ] **Step 4: Run the tests covering help, invalid filters, and captured SQL**

  Run: `bash mysql/trx/tests/test_mysql_trx_monitor.sh`

  Expected: Tests for help, invalid filters, and exact SQL predicates pass; logging, fallbacks, and interactive controls may still fail.

- [ ] **Step 5: Commit the CLI and predicate implementation**

  Run:

  ```bash
  git add mysql/trx/mysql_trx_monitor.sh mysql/trx/tests/test_mysql_trx_monitor.sh
  git commit -m "feat(mysql): add safe monitor filters"
  ```

### Task 3: Render resilient snapshots and append plain logs

**Files:**
- Modify: `mysql/trx/mysql_trx_monitor.sh`
- Test: `mysql/trx/tests/fake_mysql_trx.sh`
- Test: `mysql/trx/tests/test_mysql_trx_monitor.sh`

**Interfaces:**
- Consumes: query exit status, `--view`, `--output-file`, `FAKE_MYSQL_TRX_MODE`.
- Produces: `render_snapshot` with a `Snapshot: YYYY-MM-DD HH:MM:SS` banner; `append_snapshot FILE SNAPSHOT`; transaction fallback and degraded-lock messages.

- [ ] **Step 1: Refactor rendering around a plain snapshot buffer**

  Have view functions return uncolored text. Make `render_snapshot` assemble a timestamp line and requested view sections in a temporary file or shell variable. Apply color only while writing the terminal representation, ensuring stored snapshots are plain text.

- [ ] **Step 2: Add a transaction-query fallback**

  Attempt the preferred `performance_schema`-based transaction query first. If it exits non-zero, run the existing `information_schema.PROCESSLIST` plus `innodb_trx` query. If the fallback also fails, emit a clear `TRANSACTIONS UNAVAILABLE` section instead of exiting the entire monitor.

- [ ] **Step 3: Make the lock view degrade independently**

  Run `sys.innodb_lock_waits` through a query wrapper that captures failures. When it cannot be read, emit `LOCK WAITS UNAVAILABLE: sys.innodb_lock_waits cannot be queried.` and keep the transaction section and process alive.

- [ ] **Step 4: Append snapshots safely and only when requested**

  Validate that `--output-file` names a writable path or a creatable parent directory before entering the loop. After every successful render, append the full plain snapshot and one trailing newline in a single grouped redirection. In interactive mode, `l` toggles append logging without changing the configured filename; if no output file exists, display an explanatory status message.

- [ ] **Step 5: Run the full monitor test suite**

  Run: `bash mysql/trx/tests/test_mysql_trx_monitor.sh`

  Expected: PASS, including normal, fallback, degraded locks, exact filters, plain logging, and no-automatic-kill scenarios.

- [ ] **Step 6: Commit resilient rendering and logging**

  Run:

  ```bash
  git add mysql/trx/mysql_trx_monitor.sh mysql/trx/tests/fake_mysql_trx.sh mysql/trx/tests/test_mysql_trx_monitor.sh
  git commit -m "feat(mysql): add monitor logging and view fallbacks"
  ```

### Task 4: Finish interactive controls and verify repository compatibility

**Files:**
- Modify: `mysql/trx/mysql_trx_monitor.sh`
- Modify: `README.md`
- Test: `mysql/trx/tests/test_mysql_trx_monitor.sh`

**Interfaces:**
- Consumes: single-key input `v`, `p`, `f`, `l`, `k`, and `q`.
- Produces: interactive view cycling, paused state, in-session exact-filter updates, log toggle state, and the existing explicit kill path.

- [ ] **Step 1: Implement `p`, `f`, and `l` without weakening kill safety**

  Make `p` toggle a paused status and wait for a next key before rendering again. Make `f` prompt independently for the three comma-separated filter strings, validate them with the same CLI helper, retain prior values on invalid input, and rebuild predicates. Make `l` toggle logging only when `--output-file` was supplied. Leave `k` as an explicit manual sequence: prompt ID, validate, query/display target, require exact lower-case `kill ID`, then execute `KILL CONNECTION ID`.

- [ ] **Step 2: Document the unified monitor in the operation index**

  Add a concise `README.md` entry with the script path, a login-path invocation, `--view all`, exact filter examples, `--output-file`, and an explicit note that killing requires interactive confirmation. Do not delete or rewrite references to legacy scripts.

- [ ] **Step 3: Run focused regression and syntax checks**

  Run:

  ```bash
  bash -n mysql/trx/mysql_trx_monitor.sh
  bash -n mysql/trx/tests/fake_mysql_trx.sh
  bash -n mysql/trx/tests/test_mysql_trx_monitor.sh
  bash mysql/trx/tests/test_mysql_trx_monitor.sh
  ```

  Expected: every command exits 0 and prints `PASS: mysql_trx_monitor`.

- [ ] **Step 4: Run compatible project regression suites**

  First enumerate test entry points without executing unrelated mutation scripts:

  ```bash
  rg --files -g 'test_*.sh' -g '*_test.go' mysql proxysql general-log | sort
  ```

  Then run each existing shell test discovered above that is executable and non-destructive, plus `go test ./...` only in Go module directories returned by `find . -name go.mod -print`. Record any pre-existing failure separately; do not modify unrelated tools to silence it.

- [ ] **Step 5: Verify legacy isolation and review the final diff**

  Run:

  ```bash
  git diff --check
  git diff --name-only HEAD~3..HEAD
  git status --short
  ```

  Expected: no whitespace errors, changed runtime files limited to the unified monitor/tests/README, and no legacy transaction script changes.

- [ ] **Step 6: Commit the interactive finish and documentation**

  Run:

  ```bash
  git add mysql/trx/mysql_trx_monitor.sh mysql/trx/tests/test_mysql_trx_monitor.sh README.md
  git commit -m "docs(mysql): document unified transaction monitor"
  ```

## Self-Review

- **Spec coverage:** Task 2 covers friendly color-aware help and exact filters. Task 3 covers plain timestamped snapshots, output-file behavior, transaction fallback, and independently degraded locks. Task 4 covers `p`, `f`, `l`, the retained explicit manual kill sequence, documentation, and broad verification. Task 1 establishes deterministic regression coverage for every requested behavior.
- **Placeholder scan:** The plan gives concrete commands, required option names, SQL predicate forms, fake-client modes, and expected outcomes rather than deferred implementation notes.
- **Interface consistency:** The option names and test interfaces are identical across tasks: `--user-filter`, `--database-filter`, `--host-filter`, `--output-file`, `FAKE_MYSQL_TRX_MODE`, `render_snapshot`, and `append_snapshot`.
