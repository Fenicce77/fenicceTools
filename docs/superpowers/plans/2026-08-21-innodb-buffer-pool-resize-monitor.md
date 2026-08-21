# InnoDB Buffer Pool Resize Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize the legacy buffer pool status script as a safe online `innodb_buffer_pool_size` resize monitor.

**Architecture:** Preserve the existing command path and replace its hard-coded, load-status-only loop with isolated Bash CLI, collector, renderer, and terminal-loop functions. A fake MySQL client returns fixed status fixtures so behavior is verified without a live server.

**Tech Stack:** Bash (`set -euo pipefail`), MySQL 8.0/8.4 `performance_schema.global_status`, MySQL CLI login paths, `tput`, BSD/util-linux `script`.

**Spec:** `docs/superpowers/specs/2026-08-21-innodb-buffer-pool-resize-monitor-design.md`

## Global Constraints

- Preserve `mysql/Innodb_buffer_pool_status.check.sh` as the entry point.
- Use English for code comments, help, errors, runtime output, and tests.
- Require `-l` / `--login-path`; all invalid CLI input emits colored `ERROR` plus complete help.
- `-i` / `--interval` defaults to `5` and only accepts positive integers.
- Query only resize status variables and `@@GLOBAL.innodb_buffer_pool_size`; never modify the server.
- The displayed percentage is explicitly `Stage progress`, not whole-operation completion.
- ANSI and screen refresh are TTY-only; `--no-color` preserves TTY refresh.
- Do not edit, stage, or delete the user-owned `mysql/.Innodb_buffer_pool_status.check.sh.swp`.

---

### Task 1: CLI and read-only query contract

**Files:**

- Modify: `mysql/Innodb_buffer_pool_status.check.sh`
- Create: `mysql/monitoring/tests/fake_mysql_bp_resize.sh`
- Create: `mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

**Interfaces:**

- Produces: `setup_terminal`, `show_help`, `cli_error`, `parse_arguments`, `collect_resize_state`.
- Consumes: `FAKE_MYSQL_BP_RESIZE_LOG` and `FAKE_MYSQL_BP_RESIZE_MODE` from the fake client.

- [ ] **Step 1: Write failing tests**

```bash
run_case no_arguments
assert_status 2
assert_contains "$TMP/no_arguments.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/no_arguments.err" 'Usage:'

run_case invalid_interval --login-path monitor --interval 0
assert_status 2
assert_contains "$TMP/invalid_interval.err" 'ERROR: --interval must be a positive integer.'

FAKE_MYSQL_BP_RESIZE_LOG="$TMP/sql.log" "$SCRIPT" --login-path monitor --no-color --mysql-bin "$FAKE" >"$TMP/sample.out"
assert_contains "$TMP/sql.log" 'Innodb_buffer_pool_resize_status_progress'
assert_contains "$TMP/sql.log" '@@GLOBAL.innodb_buffer_pool_size'
assert_not_contains "$TMP/sql.log" 'SET '
```

- [ ] **Step 2: Run tests to verify RED**

Run: `/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

Expected: FAIL because the old script hard-codes `--login-path=prod` and queries load status instead of resize status.

- [ ] **Step 3: Implement minimal contract**

```bash
collect_resize_state() {
  RESIZE_STATE=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names -e "SELECT
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_code' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_progress' THEN VARIABLE_VALUE END),
    @@GLOBAL.innodb_buffer_pool_size
  FROM performance_schema.global_status
  WHERE VARIABLE_NAME IN (...);" )
}
```

Implement standard colored help, `--no-color` preparse, positive interval validation, and a regular executable `--mysql-bin` check. The fake records SQL and exposes active, complete, failed, unavailable-numeric, and query-failure fixtures.

- [ ] **Step 4: Run focused tests to verify GREEN**

Run: `/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

Expected: PASS for complete help/errors, default and invalid interval, resolved MySQL binary, and exact read-only query.

- [ ] **Step 5: Commit**

```bash
git add mysql/Innodb_buffer_pool_status.check.sh mysql/monitoring/tests/fake_mysql_bp_resize.sh mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh
git commit -m "test(mysql): define buffer pool resize monitor contract"
```

### Task 2: Stage-aware progress rendering

**Files:**

- Modify: `mysql/Innodb_buffer_pool_status.check.sh`
- Modify: `mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

**Interfaces:**

- Consumes: tab-separated `RESIZE_STATE` from `collect_resize_state`.
- Produces: `stage_label`, `stage_color`, `render_frame`, and `run_sample`.

- [ ] **Step 1: Write failing rendering tests**

```bash
FAKE_MYSQL_BP_RESIZE_MODE=withdrawing "$SCRIPT" -l monitor --no-color --mysql-bin "$FAKE" >"$TMP/withdrawing.out"
assert_contains "$TMP/withdrawing.out" 'Stage: Withdrawing blocks (3)'
assert_contains "$TMP/withdrawing.out" 'Stage progress: 42%'
assert_contains "$TMP/withdrawing.out" '[########--------] 42%'
assert_contains "$TMP/withdrawing.out" 'Target buffer pool size: 8.00 GiB'

FAKE_MYSQL_BP_RESIZE_MODE=unavailable_numeric "$SCRIPT" -l monitor --no-color --mysql-bin "$FAKE" >"$TMP/unavailable.out"
assert_contains "$TMP/unavailable.out" 'Stage progress: N/A'
assert_contains "$TMP/unavailable.out" 'Numeric resize status is unavailable'
```

- [ ] **Step 2: Run tests to verify RED**

Run: `/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

Expected: FAIL because no stage parser, progress bar, target-size formatter, or fallback exists.

- [ ] **Step 3: Implement rendering**

```bash
case "$RESIZE_CODE" in
  0) label='No resize in progress'; color=$C_GREEN ;;
  1) label='Starting resize'; color=$C_CYAN ;;
  2|3|4|5|6) label=$(stage_name "$RESIZE_CODE"); color=$C_YELLOW ;;
  7) label='Resize failed'; color=$C_RED ;;
  *) label='Numeric resize status unavailable'; color=$C_RED ;;
esac
```

Use a 16-cell ASCII bar, clamp valid stage progress to 0–100, and format target bytes with `awk` as KiB/MiB/GiB/TiB. Render server text unchanged. Code `0` succeeds after one frame, code `7` fails after a red frame, codes `1`–`6` remain eligible for polling, and unavailable numeric status displays `N/A` without an invented percentage.

- [ ] **Step 4: Run focused tests to verify GREEN**

Run: `/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

Expected: PASS for stage labels/colors, bar boundaries, completion/failure, target size, and unavailable numeric variables.

- [ ] **Step 5: Commit**

```bash
git add mysql/Innodb_buffer_pool_status.check.sh mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh
git commit -m "feat(mysql): render buffer pool resize progress"
```

### Task 3: TTY loop and cross-monitor verification

**Files:**

- Modify: `mysql/Innodb_buffer_pool_status.check.sh`
- Modify: `mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

**Interfaces:**

- Consumes: result code from `run_sample`.
- Produces: `is_interactive_terminal`, `refresh_screen`, `monitor_loop`.

- [ ] **Step 1: Write failing TTY tests**

```bash
run_pseudo_tty "$TMP/tty.out" '{ sleep 1; printf q; }' --login-path monitor --interval 1 --mysql-bin "$FAKE"
assert_contains "$TMP/tty.out" $'\033[H\033[2J'
assert_contains "$TMP/tty.out" 'Interactive options: [q] Quit'
assert_contains "$TMP/tty.out" $'\033[32mq'

run_pseudo_tty "$TMP/tty-no-color.out" '{ sleep 1; printf q; }' --login-path monitor --interval 1 --no-color --mysql-bin "$FAKE"
remove_refresh_sequences "$TMP/tty-no-color.out" >"$TMP/tty-no-color.plain"
assert_not_contains "$TMP/tty-no-color.plain" $'\033'
```

- [ ] **Step 2: Run tests to verify RED**

Run: `/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh`

Expected: FAIL because the old loop has no TTY detection, standard legend, or q handling.

- [ ] **Step 3: Implement terminal-safe loop**

```bash
if ! is_interactive_terminal; then
  run_sample
  exit $?
fi
while true; do
  run_sample
  result=$?
  [[ "$result" -eq 2 ]] && exit 0
  [[ "$result" -eq 7 ]] && exit 7
  read -r -s -n 1 -t "$INTERVAL" key || true
  [[ "${key:-}" =~ ^[qQ]$ ]] && exit 0
done
```

Refresh only in eligible TTYs. Redirection and `TERM=dumb` produce one ANSI-free sample with no legend. Interactive active-resize frames append the colored `Interactive options: [q] Quit` footer. `--no-color` keeps refresh but removes styles.

- [ ] **Step 4: Run all affected suites**

```bash
/bin/bash mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh
/bin/bash mysql/monitoring/tests/test_bp_tracker.sh
/bin/bash mysql/trx/tests/test_mysql_trx_monitor.sh
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/Innodb_buffer_pool_status.check.sh mysql/monitoring/tests/fake_mysql_bp_resize.sh mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh
git diff --check
```

Expected: all commands exit 0; coverage proves q exit, active polling, completion/failure exits, no-color refresh, and one-shot non-TTY output.

- [ ] **Step 5: Commit**

```bash
git add mysql/Innodb_buffer_pool_status.check.sh mysql/monitoring/tests/fake_mysql_bp_resize.sh mysql/monitoring/tests/test_innodb_buffer_pool_status_check.sh
git commit -m "feat(mysql): standardize buffer pool resize monitor"
```
