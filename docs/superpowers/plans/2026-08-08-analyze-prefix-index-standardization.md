# Analyze Prefix Index Standardization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Safely standardize the MySQL prefix-index analyzer.

**Architecture:** A Bash 3.2-compatible analyzer uses validated CLI inputs and a replaceable local MySQL client. A fake client drives tests without a database.

**Tech Stack:** Bash, MySQL CLI, `bc`, macOS/Linux utilities.

## Global Constraints

- Modify only `mysql/estimations/analyze_prefix_index.sh`, `mysql/estimations/README.md`, and new files under `mysql/estimations/tests/`.
- Preserve `-l`, `-d`, `-t`, `-c`, `-m`, and `-h`.
- Require `--environment`; production also requires `--allow-production`.
- Never execute DDL or mutate the target server.

### Task 1: Add a fake-client test suite

**Files:** Create `mysql/estimations/tests/fake_mysql_prefix.sh` and `mysql/estimations/tests/test_analyze_prefix_index.sh`.

- [ ] Compile test cases for help, missing/invalid options, production guard, `--mysql-bin`, safe identifier rejection, timeout hint, no-color output, and partial-column error behavior.
- [ ] Run `bash mysql/estimations/tests/test_analyze_prefix_index.sh`; expect failure before implementation.

### Task 2: Standardize the analyzer

**Files:** Modify `mysql/estimations/analyze_prefix_index.sh`.

- [ ] Add `set -euo pipefail`, signal-safe temporary files, ANSI gating, option parsing for `--environment`, `--allow-production`, `--mysql-bin`, `--query-timeout`, and `--no-color`.
- [ ] Validate identifiers and numerics; resolve client as explicit argument, `MYSQL_BIN`, then `PATH`.
- [ ] Use the configured client for every query and add `/*+ MAX_EXECUTION_TIME(ms) */` to selectivity SQL when requested.
- [ ] Continue after individual column failures and return `4`; use documented exit codes for global failures.
- [ ] Run the new test suite until it passes.

### Task 3: Document and verify

**Files:** Modify `mysql/estimations/README.md`.

- [ ] Document CLI, environment guard, safety characteristics, and examples.
- [ ] Run `bash mysql/estimations/tests/test_analyze_prefix_index.sh`, `bash mysql/estimations/tests/test_check_cardinality.sh`, and `git diff --check`.
- [ ] Verify only approved paths changed and commit with `feat(mysql): standardize prefix index analyzer`.
