# GCP Cloud SQL General-Log Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate accurate Cloud SQL MySQL general-log inserts, reject malformed payloads safely, provide SQL-generation-only mode, and restore a temporarily enabled `general_log` flag when execution is interrupted.

**Architecture:** Keep `gcp_general_log_monitor.sh` as the single operational artifact. Its embedded Python parser becomes a marked import-safe module with a strict named-group parser API. Shell integration tests use stub `gcloud`, `mysql`, and `sleep` commands to prove control flow without calling GCP or a database.

**Tech Stack:** Bash, Python 3 standard library (`io`, `json`, `pathlib`, `re`, `stat`, `subprocess`, `tempfile`, `unittest`), ShellCheck.

## Global Constraints

- Work only in this repository-local path: `mysql/general_log/`.
- Do not invoke real `gcloud` or `mysql` during local testing.
- Keep the runtime deliverable as one Bash script with embedded Python.
- Use `set -euo pipefail` and preserve colourized help and output.
- Parser stdout is SQL only; raw rejection diagnostics go only to the mode-`0600` monitor log.
- Accept exactly the approved 36 MySQL command labels.
- Do not reconstruct truncated Cloud Logging fragments.
- `--dry-run` and `--generate-only` must fail together with exit status `2`.
- A flag originally enabled must remain enabled; a flag enabled by this execution must be restored before log retrieval and on interruption.

## File Structure

- Modify: `mysql/general_log/gcp_general_log_monitor.sh`
  - CLI validation, flag lifecycle cleanup, secure monitor log, embedded parser, and final load branch.
- Create: `mysql/general_log/tests/gcp-general-log-parser/test_parser.py`
  - Extracted-parser contract tests.
- Create: `mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh`
  - Stubbed shell workflow integration tests.
- Modify: `mysql/general_log/README.md`
  - Usage and local verification documentation reflecting the implementation.

---

### Task 1: Establish Parser Contract Tests

**Files:**
- Create: `mysql/general_log/tests/gcp-general-log-parser/test_parser.py`
- Read: `mysql/general_log/gcp_general_log_monitor.sh`

**Interfaces:**
- Consumes source between `# PARSER_PYTHON_BEGIN` and `# PARSER_PYTHON_END`.
- Produces executable coverage for `COMMAND_TYPES`, `GENERAL_LOG_PATTERN`, and `parse_mysql_general_log(json_input: str, target_schema: str, rejection_log: TextIO) -> str`.

- [ ] **Step 1: Write failing parser tests**

Create tests that load the marked Python block into a namespace with `__name__ = "embedded_general_log_parser"`. Cover the exact `Change user` fixture, canonical `user[user] @ [10.10.10.1] -> user@10.10.10.1`, IPv4/IPv6/hostname hosts, tabs, absent host/thread whitespace, argumentless commands, all 36 command labels, longest-command prefix collisions, malformed timestamps/brackets/IDs/commands, whitespace-only input, a truncated continuation fragment, mixed input, all-rejected input, invalid JSON, verbatim raw logging, summaries, and absence of fallback values.

- [ ] **Step 2: Verify RED**

Run:

```bash
python3 -m unittest discover \
  -s mysql/general_log/tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
```

Expected: failure because the source lacks the parser markers and the import-safe parser API.

- [ ] **Step 3: Commit the failing contract tests**

```bash
git add mysql/general_log/tests/gcp-general-log-parser/test_parser.py
git commit -m "test: define general log parser contract"
```

### Task 2: Implement the Strict Embedded Parser

**Files:**
- Modify: `mysql/general_log/gcp_general_log_monitor.sh`
- Test: `mysql/general_log/tests/gcp-general-log-parser/test_parser.py`

**Interfaces:**
- `parse_mysql_general_log(json_input: str, target_schema: str, rejection_log: TextIO) -> str` emits transaction-wrapped SQL or `""`.
- `log_rejection(rejection_log: TextIO, reason: str, raw_payload: str) -> None` writes unmodified payloads only to the log stream.

- [ ] **Step 1: Add marked import-safe parser boundary**

Wrap the embedded Python source with `# PARSER_PYTHON_BEGIN` and `# PARSER_PYTHON_END`. Move stdin, argv, log-file opening, and stdout emission under `if __name__ == "__main__":`.

- [ ] **Step 2: Replace permissive parsing**

Define the exact 36-item `COMMAND_TYPES` tuple. Build a longest-first escaped command alternation where command spaces become `\\s+`. Compile the approved `\\A...\\Z` named-group regex and use `fullmatch()`.

- [ ] **Step 3: Implement strict normalization and rejection logging**

Use the bracketed `username` and `host` groups to build `user_host = f"{username}@{host}"`. Preserve raw payload prior to `.strip()`. For every reject write begin/end markers and the raw payload directly to `rejection_log`; do not use shell `log_msg`. Log accepted/rejected summary counts. Return no SQL on invalid JSON, a non-list top-level value, or zero accepted payloads.

- [ ] **Step 4: Wire parser diagnostics to the monitor log**

Pass `${LOGFILE}` as a Python argument. Keep stdout redirected to `${OUTFILE}` and append Python stderr to `${LOGFILE}`.

- [ ] **Step 5: Verify GREEN**

Run the Task 1 test command. Expected: all parser tests pass and no external command is executed.

- [ ] **Step 6: Commit**

```bash
git add mysql/general_log/gcp_general_log_monitor.sh \
  mysql/general_log/tests/gcp-general-log-parser/test_parser.py
git commit -m "fix: strictly parse Cloud SQL general log payloads"
```

### Task 3: Add Generate-Only and Interrupt-Safe Flag Control

**Files:**
- Modify: `mysql/general_log/gcp_general_log_monitor.sh`
- Create: `mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh`

**Interfaces:**
- `-G|--generate-only` skips only the final MySQL import.
- `GENERAL_LOG_MODIFIED` records ownership of a temporary flag enable.
- `cleanup_general_log` restores only a flag enabled by this process.

- [ ] **Step 1: Write failing stubbed shell integration tests**

Create a Bash test that creates a temporary `bin/` with executable stubs. The `gcloud` stub records ordered calls, returns a disabled/enabled flag JSON for `sql instances describe`, records `sql instances patch`, and serves a complete fixture from `logging read`. The `mysql` stub records invocation. The test must assert:

```text
--dry-run --generate-only exits 2 before a stub is called
--fetch-only --generate-only produces SQL and never calls mysql
normal --generate-only calls patch on, then patch off, then logging read, and never mysql
normal mode calls mysql after SQL generation
an initially enabled flag is never patched off
SIGTERM after temporary enable produces a patch off call
the monitor log mode is 0600
```

- [ ] **Step 2: Verify RED**

Run:

```bash
bash mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh
```

Expected: failure because `--generate-only` and cleanup behavior do not exist.

- [ ] **Step 3: Add CLI and secure log initialization**

Introduce `GENERATE_ONLY="false"`, parse `-G|--generate-only`, document it in help, and reject it with `--dry-run` via exit `2`. Replace bare log redirection with `umask 077`, `mkdir -p`, `: > "${LOGFILE}"`, and `chmod 600 "${LOGFILE}"`.

- [ ] **Step 4: Add flag ownership and cleanup**

Set `GENERAL_LOG_MODIFIED="false"`. Set it only after a successful `apply_flags "on"`; clear it after normal `apply_flags "off"`. Install an EXIT cleanup path plus INT/TERM exit handlers. Cleanup disables recursion, returns the original status when restore succeeds, and emits an error plus nonzero status if it cannot restore a flag this execution enabled.

- [ ] **Step 5: Add final-load branch**

After verifying a nonempty SQL file with inserts, log and exit success when `GENERATE_ONLY=true`; otherwise retain the existing MySQL import branch. Preserve existing all-rejected/no-output failure behaviour.

- [ ] **Step 6: Verify GREEN**

Run the Task 3 test command. Expected: exit `0`, with only stubs invoked.

- [ ] **Step 7: Commit**

```bash
git add mysql/general_log/gcp_general_log_monitor.sh \
  mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh
git commit -m "feat: add generate-only general log capture mode"
```

### Task 4: Update Handoff and Run Full Verification

**Files:**
- Modify: `mysql/general_log/README.md`
- Verify: parser, shell test, and script.

- [ ] **Step 1: Update README**

Replace obsolete absolute source/test paths with repository-local paths. Document `--generate-only`, its output path, its incompatibility with `--dry-run`, strict parser/rejection behavior, and tests that do not access GCP or MySQL.

- [ ] **Step 2: Run full local verification**

```bash
python3 -m unittest discover \
  -s mysql/general_log/tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
bash mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh
bash -n mysql/general_log/gcp_general_log_monitor.sh \
  mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh
shellcheck -x mysql/general_log/gcp_general_log_monitor.sh \
  mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh
! rg -n 'user_host = "unknown"|thread_id = "0"|server_id = "1"' \
  mysql/general_log/gcp_general_log_monitor.sh
shasum -a 256 mysql/general_log/gcp_general_log_monitor.sh \
  mysql/general_log/tests/gcp-general-log-parser/test_parser.py \
  mysql/general_log/tests/gcp-general-log-parser/test_shell_integration.sh \
  mysql/general_log/README.md \
  mysql/general_log/2026-07-24-gcp-general-log-parser-design.md \
  mysql/general_log/2026-07-24-gcp-general-log-parser.md
```

Expected: all tests pass, Bash syntax passes, no fallback assignments match, and ShellCheck has no new warnings beyond baseline `SC2034` and `SC2046`.

- [ ] **Step 3: Commit**

```bash
git add mysql/general_log/README.md \
  mysql/general_log/2026-07-24-gcp-general-log-parser.md
git commit -m "docs: document general log parser workflow"
```

## Plan Self-Review

- Parser correctness and rejection contract: Task 1 and Task 2.
- `--generate-only`, dry-run conflict, log permissions, flag lifecycle, and interruption restoration: Task 3.
- Documentation, full verification, and final hashes: Task 4.
- No task accesses GCP or a database; shell tests use local command stubs.
