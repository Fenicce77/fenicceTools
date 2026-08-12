# Open Sessions Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `mysql/sessions/check_opened_sessions_interactive.sh` into the canonical robust continuous monitor for aggregated MySQL open sessions.

**Architecture:** Replace the existing monolithic interactive loop with small Bash functions for terminal behavior, CLI validation, SQL literal generation, sample collection, rendering, logging, and key handling. A fake MySQL client records the generated query and returns deterministic TSV, so terminal and SQL contracts remain testable without a server.

**Tech Stack:** Bash (`set -euo pipefail`), MySQL CLI login paths, `information_schema.PROCESSLIST`, POSIX-compatible terminal utilities, Bash integration tests.

## Global Constraints

- Preserve existing short options: `-l`, `-t`, `-u`, `-d`, `-h`, and `-o`.
- Support macOS and Linux; do not depend on GNU-only options or external packages.
- Use English for code comments, help, errors, runtime output, and tests.
- `-l` / `--login-path` is mandatory; all invalid CLI input prints colored `ERROR` plus complete help and exits non-zero.
- Emit ANSI and clear-screen sequences only for an interactive terminal with usable `TERM`; `--no-color` disables styling but not TTY refresh.
- Never overwrite an existing destination selected through `--log-file`.
- Keep the existing sibling monitors untouched.

---

### Task 1: Establish the executable contract and fake client

**Files:**
- Create: `mysql/sessions/tests/fake_mysql_open_sessions.sh`
- Create: `mysql/sessions/tests/test_check_opened_sessions_interactive.sh`
- Modify: `mysql/sessions/check_opened_sessions_interactive.sh`

**Interfaces:**
- Consumes: `--mysql-bin PATH`, `--login-path NAME`, `--no-color`, and `--help` from the future monitor.
- Produces: a reusable fake client that writes received SQL to `$FAKE_MYSQL_SQL_LOG` and returns `$FAKE_MYSQL_OUTPUT`.

- [ ] **Step 1: Write failing CLI and help tests**

```bash
run_case no_args
assert_status 2
assert_contains "$TMP/no_args.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/no_args.err" 'Usage:'
assert_contains "$TMP/no_args.err" $'\033['

run_case help --help
assert_status 0
assert_contains "$TMP/help.out" 'Runtime keys:'
assert_contains "$TMP/help.out" '[q] Quit'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: FAIL because the test harness and standard help contract do not exist.

- [ ] **Step 3: Add the test harness and minimal standard entry point**

```bash
#!/usr/bin/env bash
set -euo pipefail

case "${1-}" in
  --version) printf 'fake-mysql\n'; exit 0 ;;
esac
printf '%s\n' "${*: -1}" >> "${FAKE_MYSQL_SQL_LOG:?}"
printf '%s\n' "${FAKE_MYSQL_OUTPUT:-}"
```

Implement `setup_colors`, `show_help`, `cli_error`, `require_value`, and
`parse_arguments` in the monitor. `cli_error` must call `show_help >&2` and
exit with status 2; `--help` must exit 0.

- [ ] **Step 4: Run the test to verify it passes**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: PASS for help, no-argument, unknown-option, missing-value, and
required-login-path assertions.

- [ ] **Step 5: Commit**

```bash
git add mysql/sessions/check_opened_sessions_interactive.sh \
  mysql/sessions/tests/fake_mysql_open_sessions.sh \
  mysql/sessions/tests/test_check_opened_sessions_interactive.sh
git commit -m "test(mysql): define open sessions monitor CLI contract"
```

### Task 2: Implement validated options and safe query construction

**Files:**
- Modify: `mysql/sessions/check_opened_sessions_interactive.sh`
- Modify: `mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

**Interfaces:**
- Consumes: `parse_arguments` and fake SQL log from Task 1.
- Produces: `build_filter_clause` and `collect_sample`, called once per frame.

- [ ] **Step 1: Write failing option and SQL-safety tests**

```bash
run_case escaped_filters --login-path reporting --user "alice,o'connor" \
  --database "billing'archive" --host 'api%_west\\node' --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/sql.log" "USER IN ('alice', 'o\\'connor')"
assert_contains "$TMP/sql.log" "DB = 'billing\\'archive'"
assert_contains "$TMP/sql.log" "HOST LIKE '%api\\%\\_west\\\\node%' ESCAPE '\\\\'"
assert_contains "$TMP/sql.log" 'UNION ALL'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: FAIL because current filter interpolation does not quote or escape
values safely and runs two separate queries.

- [ ] **Step 3: Implement the options and query builders**

```bash
sql_quote() { local value=${1//\\\\/\\\\\\\\}; value=${value//\'/\\\'}; printf "'%s'" "$value"; }
like_literal() { local value=$1; value=${value//\\\\/\\\\\\\\}; value=${value//%/\\%}; value=${value//_/\\_}; printf '%s' "$value"; }
```

Accept `--login-path`, `--refresh-time`, `--user`, `--database`, `--host`,
`--logging`, `--diff`, `--log-file`, `--mysql-bin`, and `--no-color`, including
`--name=value` where a value is accepted. Validate positive integer refresh
intervals, an executable client, and a writable non-existing log destination.
Build one `UNION ALL` query: grouped rows tagged `ROW`, then the filtered total
tagged `TOTAL`. Parse that single TSV result into frame state.

- [ ] **Step 4: Run the test to verify it passes**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: PASS for short/long option compatibility, invalid-value help, SQL
quoting, literal host matching, and one-query-per-frame behavior.

- [ ] **Step 5: Commit**

```bash
git add mysql/sessions/check_opened_sessions_interactive.sh \
  mysql/sessions/tests/test_check_opened_sessions_interactive.sh
git commit -m "feat(mysql): add safe open sessions monitor filters"
```

### Task 3: Add deterministic presentation, terminal contract, and logging

**Files:**
- Modify: `mysql/sessions/check_opened_sessions_interactive.sh`
- Modify: `mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

**Interfaces:**
- Consumes: tagged sample rows from `collect_sample` in Task 2.
- Produces: `render_frame`, `append_log`, and `is_interactive_terminal`.

- [ ] **Step 1: Write failing presentation and logging tests**

```bash
run_case redirected --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_not_contains "$TMP/redirected.out" $'\033['
assert_not_contains "$TMP/redirected.out" $'\033[H\033[2J'
assert_not_contains "$TMP/redirected.out" 'Interactive options:'

touch "$TMP/existing.log"
run_case existing_log --login-path reporting --log-file "$TMP/existing.log" --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/existing_log.err" 'ERROR:'
assert_contains "$TMP/existing_log.err" 'Usage:'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: FAIL because redirected output currently clears the screen and logging
can select an existing destination.

- [ ] **Step 3: Implement rendering and log boundaries**

```bash
is_interactive_terminal() {
  [[ -t 1 && -t 0 && -n "${TERM-}" && "${TERM}" != dumb ]]
}

refresh_screen() {
  [[ "$SCREEN_REFRESH_ENABLED" == true ]] && printf '\033[H\033[2J'
}
```

Calculate visible field widths before printing and apply color around complete
cells only, so alignment is identical with and without color. `render_frame`
prints header, filters, totals, rows, and active diff state. `append_log` writes
the same data as plain text. A redirected run calls `collect_sample` once,
renders once, and exits; it emits neither color nor the runtime legend.

- [ ] **Step 4: Run the test to verify it passes**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: PASS for non-TTY behavior, no-color behavior, TTY clear sequences,
aligned plain/color output, and non-overwriting log validation.

- [ ] **Step 5: Commit**

```bash
git add mysql/sessions/check_opened_sessions_interactive.sh \
  mysql/sessions/tests/test_check_opened_sessions_interactive.sh
git commit -m "feat(mysql): standardize open sessions monitor output"
```

### Task 4: Implement runtime controls and regression verification

**Files:**
- Modify: `mysql/sessions/check_opened_sessions_interactive.sh`
- Modify: `mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

**Interfaces:**
- Consumes: rendering/logging functions from Task 3 and mutable filter state.
- Produces: `handle_key`, `prompt_filters`, `toggle_diff`, and `toggle_logging`.

- [ ] **Step 1: Write failing pseudo-TTY runtime tests**

```bash
run_pseudo_tty "$TMP/tty.out" '{ sleep 1; printf d; sleep 1; printf l; sleep 1; printf q; }' \
  --login-path reporting --refresh-time 1 --mysql-bin "$FAKE"
assert_contains "$TMP/tty.out" 'Interactive options:'
assert_contains "$TMP/tty.out" '[q]'
assert_contains "$TMP/tty.out" '[m]'
assert_contains "$TMP/tty.out" 'Diff: ON'
assert_contains "$TMP/tty.out" 'Logging: ON'
assert_contains "$TMP/tty.out" $'\033[H\033[2J'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh`

Expected: FAIL because the canonical key contract and reduced legend do not
exist.

- [ ] **Step 3: Implement the four-key interaction contract**

```bash
handle_key() {
  case "${1-}" in
    q|Q) return 10 ;;
    m|M) prompt_filters ;;
    d|D) DIFF_ENABLED=$([[ "$DIFF_ENABLED" == true ]] && printf false || printf true) ;;
    l|L) toggle_logging ;;
  esac
}
```

`prompt_filters` must show the cursor before reading and hide it again after
the prompt. Blank values retain the current filters. `d` compares the present
sample with the immediately prior sample keyed by user, database, and host.
`l` creates a timestamped log only when logging was not configured; it must
never replace a pre-existing file. `render_frame` always ends with the compact,
colored runtime legend in TTY mode. `q` restores the cursor and exits 0.

- [ ] **Step 4: Run the focused and repository regression suites**

Run:

```bash
/bin/bash mysql/sessions/tests/test_check_opened_sessions_interactive.sh
/bin/bash mysql/monitoring/tests/test_bp_tracker.sh
/bin/bash mysql/trx/tests/test_mysql_trx_monitor.sh
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/sessions/check_opened_sessions_interactive.sh \
  mysql/sessions/tests/fake_mysql_open_sessions.sh \
  mysql/sessions/tests/test_check_opened_sessions_interactive.sh
git diff --check
```

Expected: all suites exit 0; the new suite covers TTY `q/m/d/l`, colored
legend, screen refresh, filters, logging, diff, error help, and redirection.

- [ ] **Step 5: Commit**

```bash
git add mysql/sessions/check_opened_sessions_interactive.sh \
  mysql/sessions/tests/test_check_opened_sessions_interactive.sh
git commit -m "feat(mysql): add open sessions monitor runtime controls"
```
