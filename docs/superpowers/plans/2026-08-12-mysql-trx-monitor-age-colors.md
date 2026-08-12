# MySQL Transaction Monitor Age Colors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color complete interactive transaction and lock-wait rows according to duration severity.

**Architecture:** Keep snapshots raw until `display_snapshot`. Extend the color state with duration severity values; at the display boundary track the active section, extract its tab-separated duration field, and decorate only eligible data rows. Pseudo-TTY tests validate emitted bytes; logging and non-TTY behavior stay unchanged.

**Tech Stack:** Bash 3.2, ANSI terminal escapes, macOS/Linux `script` pseudo-TTY, shell fake MySQL client.

## Global Constraints

- Preserve `set -euo pipefail` and Bash 3.2 compatibility on macOS and Linux.
- Do not change SQL, filtering, kill safeguards, raw snapshot content, or output-file format.
- Apply row color only on eligible stdout TTY output; `--no-color`, redirected stdout, and logs remain ANSI-free.
- Use complete-row thresholds: `<60` default, `60–119` yellow, `120–299` orange ANSI 256-color 208 with yellow fallback, `>=300` red.
- Apply the same thresholds to transaction `AGE_S` field 5 and lock-wait `WAIT_S` field 6.
- Keep malformed/non-numeric durations terminal-default and refresh independent of `--no-color`.

---

### Task 1: Add duration-severity row rendering

**Files:**

- Modify: `mysql/trx/mysql_trx_monitor.sh:25-45,395-411`
- Modify: `mysql/trx/tests/test_mysql_trx_monitor.sh:189-221`
- Test: `mysql/trx/tests/test_mysql_trx_monitor.sh`

**Interfaces:**

- Consumes: raw `TRANSACTIONS` and `LOCK WAITS` snapshots, with tab-separated data rows.
- Produces: `display_snapshot` wraps complete eligible rows; `append_snapshot` remains raw.

- [ ] **Step 1: Write failing pseudo-TTY tests**

Use the public script with the fake client, `TERM=xterm-256color`, `--view all`, and no `--no-color`. Extend the fake fixture with literal 59, 60, 120, and 300 second rows for both sections. Assert that 60, 120, and 300 rows are fully wrapped in yellow, ANSI-256 orange, and red respectively; assert 59 is unwrapped. Run a separate `--no-color` case and verify both it and the snapshot log contain no ESC bytes.

Run `/bin/bash mysql/trx/tests/test_mysql_trx_monitor.sh`. Expected RED: complete age-severity spans are absent.

- [ ] **Step 2: Implement minimal display-only selection**

Extend `initialize_colors` with `COLOR_AGE_ORANGE`, defaulting to `COLOR_WARNING`; select `\033[38;5;208m` when `TERM` contains `256color` or `COLORTERM` contains `truecolor`.

Add one helper accepting active section and raw row. It selects field 5 for transactions or field 6 for lock waits, requires `^[0-9]+$`, and wraps the complete row using `COLOR_WARNING`, `COLOR_AGE_ORANGE`, or `COLOR_ERROR` at the documented thresholds. It prints all headers, unavailable diagnostics, unknown sections, and malformed durations without modification.

In `display_snapshot`, preserve the title, section, and unavailable branches. Track the last section and delegate only its data rows to the helper. Do not invoke the helper from `render_snapshot` or `append_snapshot`.

- [ ] **Step 3: Run focused GREEN verification**

Run `/bin/bash mysql/trx/tests/test_mysql_trx_monitor.sh`, `/bin/bash -n mysql/trx/mysql_trx_monitor.sh mysql/trx/tests/test_mysql_trx_monitor.sh`, and `git diff --check`.

Expected: `PASS: mysql_trx_monitor`, no syntax errors, and no whitespace errors.

- [ ] **Step 4: Review scope and commit**

Confirm `git diff --name-only` lists only the monitor and its shell test. Commit with `feat(mysql): color transaction monitor rows by age`.
