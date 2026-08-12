# ProxySQL Bash Monitor Terminal Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize the Bash ProxySQL monitor's terminal colors, screen refresh, and plain output behavior.

**Architecture:** A capability layer, initialized after parsing, maintains independent `COLOR_ENABLED` and `SCREEN_REFRESH_ENABLED` flags. Existing renderers use empty style variables for plain output and retain their current styles in a capable interactive terminal.

**Tech Stack:** Bash 3.2, ANSI, `tput`, macOS/Linux `script`, shell fake MySQL client.

## Global Constraints

- Keep Bash 3.2 compatibility and `set -euo pipefail`.
- Do not change SQL, transport, sampling, render content, logging format, key controls, or refresh timing.
- Colors require stdout TTY, a usable non-dumb TERM, and no `--no-color`.
- Refresh requires stdout TTY and a usable non-dumb TERM; `--no-color` does not disable it.
- Help, errors, redirection, and logs must contain no ANSI control bytes.

---

### Task 1: Define regression coverage

**Files:**

- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh:1-320`

**Interfaces:**

- Produces: `assert_no_ansi`, `run_pseudo_tty`, and terminal-contract tests.

- [ ] **Step 1: Write failing tests**

Add a helper that rejects an ESC byte and a Darwin/Linux pseudo-TTY runner based on the transaction-monitor suite. Assert `--no-color` parses; redirected help, sourced no-color rendering, and logs contain no ESC; and normal plus `--no-color` pseudo-TTY captures have two clear-screen frames, with styles present only in normal output.

- [ ] **Step 2: Capture RED**

Run `/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh`.

Expected: failure because the option/capability state does not exist and redirected output contains ANSI bytes.

- [ ] **Step 3: Commit tests**

Run `git add mysql/proxysql/tests/test_proxysql_connections_monitor.sh` then `git commit -m "test(mysql): define proxysql monitor terminal contract"`.

### Task 2: Implement capability layer

**Files:**

- Modify: `mysql/proxysql/proxysql_connections_monitor.sh:9-90,559-825`
- Test: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`

**Interfaces:**

- Consumes: `NO_COLOR`, stdout TTY state, and `TERM`.
- Produces: `initialize_terminal_capabilities`, `refresh_interactive_screen`, `COLOR_ENABLED`, and `SCREEN_REFRESH_ENABLED`.

- [ ] **Step 1: Implement option and state**

Initialize `NO_COLOR=false`, `COLOR_ENABLED=false`, and `SCREEN_REFRESH_ENABLED=false`. Parse and document `--no-color`. Initialize capabilities after parsing: enable refresh for TTY plus usable TERM; enable colors only when refresh is enabled and no-color is false. Clear all style variables when color is unavailable; otherwise preserve current tput and orange values. Remove duplicate eager color initialization.

- [ ] **Step 2: Implement independent refresh**

Add the refresh helper to print home-and-clear only when the refresh flag is true. Replace unconditional clear calls in help and frame rendering. Order main initialization as defaults, parsing, capabilities, colors, validation.

- [ ] **Step 3: Verify GREEN and commit**

Run focused tests, Bash syntax validation, and `git diff --check`. Redirect `--help` to `/private/tmp/proxysql-help.out` and check it contains no ESC byte. Commit monitor/test as `fix(mysql): standardize proxysql monitor terminal output`.

### Task 3: Final verification and handoff

**Files:**

- Verify: `mysql/proxysql/proxysql_connections_monitor.sh`
- Verify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`

- [ ] **Step 1: Run final matrix**

Run the focused test, Bash syntax validation, `git diff --check HEAD~2..HEAD`, and `git status --short --branch`. Confirm only the monitor and test changed in implementation commits.

- [ ] **Step 2: Report without push**

Report the contract, command evidence, and commit IDs. Push only with explicit user authorization.
