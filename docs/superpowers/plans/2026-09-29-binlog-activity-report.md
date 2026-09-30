# Binlog Activity Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one supported, tested report for local and remote MySQL/MariaDB binlog activity and archive the eight overlapping scripts.

**Architecture:** `binlog_activity_report.sh` owns CLI validation, reader selection, profiles and output. A stateful AWK normalizer consumes decoded reader text and emits normalized records; Bash aggregates them for an always-visible colored table and optional CSV.

**Tech Stack:** Bash 3.2+, AWK, POSIX utilities, `mysqlbinlog`/`mariadb-binlog`, shell fixtures.

**Spec:** `docs/superpowers/specs/2026-09-29-binlog-activity-report-design.md`

## Global Constraints

- The only supported command is `mysql/binlogs/binlog_activity_report.sh`.
- Use `set -euo pipefail`, Bash 3.2-compatible constructs and macOS/Linux utilities.
- `--source local|remote` is required; local requires explicit version and format.
- Remote mode requires `--login-path`, auto-detects omitted identity, and accepts no password argument.
- `MIXED` is classified event by event. Screen output is always shown; CSV is optional and ANSI-free.
- Archive the eight current variants unchanged in `mysql/binlogs/legacy/`, without wrappers.

## Review Focus

- Local MIXED with row DML plus statement DDL is covered by Task 2.
- MariaDB `Annotate_rows` and fragmented rows do not inflate counts; Task 2.
- Local filenames with spaces are selected once and remain unchanged; Task 1.
- Remote discovery and explicit override precedence are covered by Task 3.
- CSV quoting and ANSI isolation under a pseudo-TTY are covered by Task 3.

### Task 1: CLI, profiles, and local fixture harness

**Files:**
- Create: `mysql/binlogs/binlog_activity_report.sh`
- Create: `mysql/binlogs/tests/test_binlog_activity_report.sh`
- Create: `mysql/binlogs/tests/fake_binlog_reader.sh`
- Create: `mysql/binlogs/tests/fixtures/binlog_activity/mysql57_statement.sample`
- Create: `mysql/binlogs/tests/fixtures/binlog_activity/space dir/mysql80_row.sample`

**Interfaces:** Produces `parse_arguments "$@"`, `collect_local_files`, `resolve_reader`, and `resolve_profile FAMILY VERSION` returning `mysql-5.7`, `mysql-8.0+`, or `mariadb-10+`.

- [ ] **Step 1: Write failing local-contract tests**

Assert missing/invalid arguments return `2` plus help; local rejects omitted version or format; repeated files and spaced paths work; default top tables is `10`.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: FAIL because the command does not exist.

- [ ] **Step 3: Implement the local CLI foundation**

Implement color/help/error functions, deterministic local selection, profile derivation and reader discovery. Validate every local prerequisite before reading a file.

- [ ] **Step 4: Run GREEN**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: PASS for local contract and profile tests.

- [ ] **Step 5: Commit**

```bash
git add mysql/binlogs/binlog_activity_report.sh mysql/binlogs/tests
git commit -m "feat(mysql): add binlog report cli"
```

### Task 2: Event-level local normalization and screen report

**Files:**
- Modify: `mysql/binlogs/binlog_activity_report.sh`
- Modify: `mysql/binlogs/tests/test_binlog_activity_report.sh`
- Create: `mysql/binlogs/tests/fixtures/binlog_activity/mysql80_mixed.sample`
- Create: `mysql/binlogs/tests/fixtures/binlog_activity/mariadb10_row.sample`

**Interfaces:** Consumes Task 1 profile variables. Produces `normalize_events INPUT_FILE FAMILY PROFILE FORMAT` records with timestamp, position, class, operation, schema, table and transaction ID.

- [ ] **Step 1: Write failing normalization tests**

Assert multiline MySQL statement DML/DDL; decoded row INSERT/UPDATE/DELETE; MIXED row DML plus statement DDL; MariaDB `Annotate_rows`, `Table_map`, partial-row context; deterministic top tables and no-color behavior.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: FAIL because normalized records are absent.

- [ ] **Step 3: Implement normalizer and colored renderer**

Use stateful AWK for timestamp, position, table mapping, SQL block and transaction state. Treat `Annotate_rows`/partial rows as context only. Render INSERT green, UPDATE yellow, DELETE red and DDL cyan.

- [ ] **Step 4: Run GREEN**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: PASS for all MySQL/MariaDB local fixtures.

- [ ] **Step 5: Commit**

```bash
git add mysql/binlogs/binlog_activity_report.sh mysql/binlogs/tests
git commit -m "feat(mysql): normalize binlog activity events"
```

### Task 3: Remote discovery, bounds, and CSV

**Files:**
- Modify: `mysql/binlogs/binlog_activity_report.sh`
- Modify: `mysql/binlogs/tests/test_binlog_activity_report.sh`
- Modify: `mysql/binlogs/tests/fake_binlog_reader.sh`
- Create: `mysql/binlogs/tests/fixtures/binlog_activity/mariadb11_mixed.sample`

**Interfaces:** Consumes `normalize_events`; produces `discover_remote_identity LOGIN_PATH`, `build_reader_command`, and `write_csv PATH`.

- [ ] **Step 1: Write failing remote/output tests**

Assert discovery of version/comment/format, valid explicit overrides, remote reader flag, time bounds, exact CSV header/quoting and ANSI-free artifact.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: FAIL because remote discovery and CSV do not exist.

- [ ] **Step 3: Implement remote and artifacts**

Implement remote identity query, family/profile reader command, start/stop bounds and RFC-4180 quoting. Prevalidate the CSV parent directory.

- [ ] **Step 4: Run GREEN**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: PASS for remote, override, bounds, top-table and CSV tests.

- [ ] **Step 5: Commit**

```bash
git add mysql/binlogs/binlog_activity_report.sh mysql/binlogs/tests
git commit -m "feat(mysql): add remote binlog reports"
```

### Task 4: Archive variants and document operations

**Files:**
- Create: `mysql/binlogs/README.md`
- Create: `mysql/binlogs/legacy/` containing the eight scripts named in the spec
- Delete: the eight active variant paths
- Modify: `mysql/binlogs/tests/test_binlog_activity_report.sh`

**Interfaces:** Consumes the verified canonical report and produces the final supported-path/archive contract.

- [ ] **Step 1: Write failing archival/documentation tests**

Assert canonical executable, exact eight archived paths, retired paths absent, and README coverage for sources, identity, colors, CSV and read-only behavior.

- [ ] **Step 2: Run RED**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Expected: FAIL because the archive and guide do not exist.

- [ ] **Step 3: Archive and document**

Move the eight scripts unchanged. Write English operating guidance with local/remote examples, profiles, colors, CSV schema and the reporting-only warning for decoded output.

- [ ] **Step 4: Run final matrix**

Run: `/bin/bash mysql/binlogs/tests/test_binlog_activity_report.sh`

Run: `/bin/bash mysql/innodb/innodb_engine_status_sampler/tests/test_innodb_engine_status_sampler.sh`

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Run: `/bin/bash mysql/innodb/tests/test_compress_sample_files.sh`

Run: `/bin/bash -n mysql/binlogs/binlog_activity_report.sh`

Run: `git diff --check`

Expected: every command exits `0` and the diff check has no output.

- [ ] **Step 5: Commit**

```bash
git add mysql/binlogs
git commit -m "refactor(mysql): establish canonical binlog report"
```

## Plan Self-Review

- **Spec coverage:** Tasks 1–3 implement contracts, profiles, events, remote mode, presentation and CSV; Task 4 archives and documents.
- **Step scan:** Every task has focused RED/GREEN steps and a scoped commit.
- **Type consistency:** Task 1 defines profiles, Task 2 defines normalized records, Task 3 consumes them, Task 4 depends on fully tested behavior.
- **Review Focus:** Each risk above maps to a fixture in Tasks 1–3.
- **Proportion:** Interfaces and assertions are fixed without transcribing the AWK implementation.
