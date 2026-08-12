# Safe Buffer Pool Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unsafe Buffer Pool dashboard defaults with low-risk global telemetry and explicit opt-in correlation views.

**Architecture:** Default sampling aggregates `INFORMATION_SCHEMA.INNODB_BUFFER_POOL_STATS`. Terminal capability, metric state, and optional expensive sections are isolated helpers in one Bash script.

**Tech Stack:** Bash 3.2, MySQL 8.0/8.4, sys schema, INFORMATION_SCHEMA, ANSI, macOS/Linux `script`, shell fake MySQL.

## Global Constraints

- Keep `set -euo pipefail`, Bash 3.2, macOS/Linux support, and no mutating SQL.
- Require `-l, --login-path`; default telemetry only queries aggregated `INNODB_BUFFER_POOL_STATS`.
- `--top-objects` and `--active-sessions` are opt-in; top objects run at most once per 60 seconds.
- Colors need TTY plus usable TERM and no `--no-color`; refresh needs TTY plus usable TERM independently.
- Redirection, errors, and logs are ANSI-free; non-TTY produces one snapshot and exits.
- Preserve unrelated `lists/servers_login_list.hex.txt` changes.

---

### Task 1: Create test harness and capture RED

**Files:**

- Create: `mysql/monitoring/tests/fake_mysql_bp_tracker.sh`
- Create: `mysql/monitoring/tests/test_bp_tracker.sh`

**Interfaces:**

- Consumes: public tracker path, `MYSQL_BIN`, and `FAKE_MYSQL_BP_LOG`.
- Produces: query-tagged fake output, ANSI assertions, and a pseudo-TTY helper.

- [ ] **Step 1: Write failing CLI and terminal tests**

Create an executable fake that records every query and returns two Buffer Pool instances for `bp-tracker:global`. Test mandatory login, help, no-color, invalid interval/count, redirected help without ESC, and a one-shot redirected snapshot.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/monitoring/tests/test_bp_tracker.sh`.

Expected: the legacy tracker fails because it lacks the CLI, ANSI, fake-client, and one-shot contracts.

- [ ] **Step 3: Commit test harness**

```bash
git add mysql/monitoring/tests
git commit -m "test(mysql): define safe buffer pool tracker contract"
```

### Task 2: Implement safe default telemetry

**Files:**

- Modify: `mysql/monitoring/bp_tracker.sh`
- Test: `mysql/monitoring/tests/test_bp_tracker.sh`

**Interfaces:**

- Produces: terminal capability helpers, `sample_global_metrics`, `render_global_metrics`, and one-shot non-TTY execution.

- [ ] **Step 1: Implement parser and terminal contract**

Add mandatory login path, short/long options, interval/count validation, no-color pre-scan, independent color/refresh helpers, and complete help.

- [ ] **Step 2: Implement global query and delta metrics**

Aggregate `POOL_SIZE`, `FREE_BUFFERS`, `DATABASE_PAGES`, `MODIFIED_DATABASE_PAGES`, dirty percentage, `PAGES_READ_RATE`, `PAGES_MADE_YOUNG`, and `PAGES_NOT_MADE_YOUNG`. Persist timestamps/counters and show N/A on the first, reset, or invalid-interval sample. Label read I/O, young promotions/s, and old-list stays/s precisely; red above 5000 pages/s and yellow above zero.

- [ ] **Step 3: Implement output and logging boundaries**

TTY loops with m/q; non-TTY emits one snapshot. Logs are plain global data and never terminal escapes.

- [ ] **Step 4: Verify GREEN and commit**

Run focused tests, Bash syntax, and diff check. Commit `fix(mysql): make buffer pool tracker safe by default`.

### Task 3: Add opt-in correlation and degradation

**Files:**

- Modify: `mysql/monitoring/bp_tracker.sh`
- Modify: `mysql/monitoring/tests/fake_mysql_bp_tracker.sh`
- Modify: `mysql/monitoring/tests/test_bp_tracker.sh`

**Interfaces:**

- Produces: `escape_like_literal`, `sample_top_objects`, `sample_active_sessions`, cached top-object state, and unavailable sections.

- [ ] **Step 1: Write optional-view RED cases**

Verify defaults never query sys top objects/sessions. Verify top-object limit, literal UTF-8 hex filter, 60-second cache, session limit, statement omission from logs, and independent UNAVAILABLE diagnostics.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/monitoring/tests/test_bp_tracker.sh`.

Expected: optional modes, cadence, escaping, and degradation are missing.

- [ ] **Step 3: Implement and verify GREEN**

Hex-encode and LIKE-escape filters. Cache top objects, retain prior data on failure, and never log session statement text. Run focused tests, syntax, and diff check; commit `feat(mysql): add opt-in buffer pool correlation views`.

### Task 4: Final verification

**Files:**

- Verify: `mysql/monitoring/bp_tracker.sh`
- Verify: `mysql/monitoring/tests/test_bp_tracker.sh`
- Verify: `mysql/monitoring/tests/fake_mysql_bp_tracker.sh`

- [ ] **Step 1: Run the full Bash suite**

Run every `test_*.sh`, Buffer Pool syntax checks, and `git diff --check HEAD~3..HEAD`.

- [ ] **Step 2: Audit and hand off**

Confirm only tracker/tests are in implementation commits and `lists/servers_login_list.hex.txt` stays outside staging. Report commits without push.
