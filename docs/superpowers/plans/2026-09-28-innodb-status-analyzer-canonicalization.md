# InnoDB Status Analyzer Canonicalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish one portable, tested, unversioned InnoDB status analyzer while retaining all historical analyzer implementations under a legacy directory.

**Architecture:** The root-level `mysql/innodb/innodb_status_analyzer.sh` becomes the single supported command and receives the analytical behavior of the current `innodb_status_analyzer.v4.sh`. Historical implementations move, unchanged, under `mysql/innodb/innodb_analyzer/legacy/`. A Bash fixture suite locks down the public CLI, sample selection, aggregation, report routing, and macOS/Linux portability.

**Tech Stack:** Bash 3.2+, POSIX-compatible command-line utilities, AWK, BSD/GNU `md5` compatibility, `script` pseudo-TTY test harness.

**Spec:** `docs/superpowers/specs/2026-09-28-innodb-status-analyzer-canonicalization-design.md`

## Global Constraints

- The only supported analyzer command is `mysql/innodb/innodb_status_analyzer.sh`; do not create wrappers or symlinks at retired paths.
- Preserve `v4` analytical semantics, option names, defaults, report names, recap CSV schema, and source-sample read-only behavior.
- Keep all six historical implementations unchanged under `mysql/innodb/innodb_analyzer/legacy/`.
- Canonical Bash must use `set -euo pipefail`, run on macOS Bash 3.2 and Linux Bash, and avoid `readarray`, `sort -z`, GNU-only `sed`/`date`, and `md5sum`-only hashing.
- CLI errors return 2 and print `ERROR:` plus complete help; `--help` returns 0; ANSI is limited to interactive terminals and disabled by `--no-color`.
- All script comments, help, test diagnostics, and generated output remain English.

## Review Focus

- A live source sample containing spaces in its path must be selected once, analyzed correctly, and remain byte-for-byte unchanged.
- A sample with no deadlock or lock event must complete successfully, including under `set -euo pipefail`.
- A stale deadlock timestamp embedded in a later sample must be excluded by the existing `v4` anti-ghost rule.
- `--report-mode file` and `--report-mode both` must never place ANSI escapes in reports or CSV, even when terminal color is enabled.
- macOS fallback hash selection must still produce a deterministic 12-character digest when `md5sum` is unavailable.

---

### Task 1: Canonical path and historical archive

**Files:**
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_status_analyzer.root.sh`
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_status_analyzer.v2.sh`
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_status_analyzer.v4.sh`
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_analyzer.multiple.sh`
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_analyzer_extended.sh`
- Create: `mysql/innodb/innodb_analyzer/legacy/innodb_analyzer_extended.v2.sh`
- Modify: `mysql/innodb/innodb_status_analyzer.sh`
- Delete: `mysql/innodb/innodb_analyzer/innodb_status_analyzer.v2.sh`
- Delete: `mysql/innodb/innodb_analyzer/innodb_status_analyzer.v4.sh`
- Delete: `mysql/innodb/innodb_analyzer/innodb_analyzer.multiple.sh`
- Delete: `mysql/innodb/innodb_analyzer/innodb_analyzer_extended.sh`
- Delete: `mysql/innodb/innodb_analyzer/innodb_analyzer_extended.v2.sh`
- Create: `mysql/innodb/tests/test_innodb_status_analyzer.sh`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/20260928_10.sample`

**Interfaces:**
- Consumes: current `innodb_status_analyzer.v4.sh` as the behavior source and all six current scripts as archival inputs.
- Produces: the stable executable public path and a test fixture/harness used by Tasks 2 and 3.

- [ ] **Step 1: Write the failing layout regression**

In `test_innodb_status_analyzer.sh`, assert that the root canonical script is executable; exactly the six named scripts exist in `innodb_analyzer/legacy/`; the old active `innodb_analyzer/*.sh` paths are absent; and the fixture source sample is unchanged after invoking the canonical command in a harmless screen mode.

- [ ] **Step 2: Run the layout regression to verify it fails**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: FAIL because `legacy/` and the fixture suite do not exist.

- [ ] **Step 3: Move historical files and establish the canonical executable**

Move the existing root analyzer to `legacy/innodb_status_analyzer.root.sh`. Move each existing nested variant to the exact legacy name listed above. Promote the current `innodb_status_analyzer.v4.sh` content to the root canonical file and preserve its executable bit. Do not modify legacy file contents.

- [ ] **Step 4: Run the layout regression to verify it passes**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: PASS with canonical path, archival inventory, and source-fixture immutability confirmed.

- [ ] **Step 5: Commit the migration skeleton**

```bash
git add mysql/innodb/innodb_status_analyzer.sh mysql/innodb/innodb_analyzer mysql/innodb/tests
git commit -m "refactor(mysql): establish canonical innodb analyzer"
```

### Task 2: Portable CLI and file-selection foundation

**Files:**
- Modify: `mysql/innodb/innodb_status_analyzer.sh`
- Modify: `mysql/innodb/tests/test_innodb_status_analyzer.sh`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/20260928_11.sample`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/invalid-name.sample.txt`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/space dir/20260928_12.sample`

**Interfaces:**
- Consumes: canonical root path and fixture harness from Task 1.
- Produces: CLI parser, color lifecycle, portable file enumeration, and `query_hash QUERY -> 12-character digest` helper consumed by Task 3's renderer.

- [ ] **Step 1: Write failing CLI and portability regressions**

Add cases that assert: no target exits 2 with full help; `--help` exits 0; pseudo-TTY help is colored; `--no-color` and redirected output contain no ESC; invalid options/values exit 2 with help; `-d`, repeated `-f`, and `-p` select valid samples once in stable order; invalid filenames warn and skip; paths with spaces work; and a PATH fixture that omits `md5sum` causes the expected 12-character `md5` fallback digest.

- [ ] **Step 2: Run the focused CLI regression to verify it fails**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: FAIL because the promoted implementation emits ANSI unconditionally, relies on GNU/macOS-incompatible utilities, and lacks `--no-color` and standard errors.

- [ ] **Step 3: Implement the CLI, terminal, and portable selection helpers**

Refactor the canonical script around `initialize_colors`, `show_help`, `error_exit`, `parse_arguments`, `collect_input_files`, and `query_hash`. Preserve all documented option names and defaults. Use Bash 3.2-compatible arrays/loops, `find -print0` read with `read -d`, deterministic sorting without `sort -z`, and a `md5sum`/`md5` selection helper. Limit colors to active TTY output and strip/no-op them for reports and redirection.

- [ ] **Step 4: Run the focused CLI regression to verify it passes**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: PASS for every CLI, color, path, ordering, and hash-fallback case.

- [ ] **Step 5: Commit the portable CLI foundation**

```bash
git add mysql/innodb/innodb_status_analyzer.sh mysql/innodb/tests
git commit -m "feat(mysql): standardize innodb analyzer cli"
```

### Task 3: Preserve v4 analysis semantics and output routing

**Files:**
- Modify: `mysql/innodb/innodb_status_analyzer.sh`
- Modify: `mysql/innodb/tests/test_innodb_status_analyzer.sh`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/20260928_13.sample`
- Create: `mysql/innodb/tests/fixtures/innodb_status_analyzer/20260928_14.sample`

**Interfaces:**
- Consumes: Task 2 `collect_input_files`, parsed filter values, `query_hash`, terminal-color state, and fixture harness.
- Produces: canonical deadlock/lock extraction, aggregation, terminal summaries, detail reports, and recap CSV outputs.

- [ ] **Step 1: Write failing semantic and artifact regressions**

Add fixtures and assertions for: `all`, `deadlocks`, and `locks` modes; table/user/date filters; default top 20; an active deadlock; a stale deadlock older than 2.5 hours than its containing sample; persistent-lock duration and occurrence aggregation; no-event success; deterministic summary ordering; unchanged source fixture bytes; report/CSV filenames and exact recap header; `screen`, `file`, and `both` routing; and ESC-free report/CSV artifacts under pseudo-TTY color.

- [ ] **Step 2: Run the semantic regression to verify it fails**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: FAIL until the refactored canonical execution retains all `v4` analytical semantics while obeying the new CLI/output contract.

- [ ] **Step 3: Refactor extraction and render flow without changing v4 meanings**

Keep the `v4` filename-derived time bounds, anti-ghost deadlock rule, lock grouping/duration rules, table/user matching, summary sort order, report naming, and recap CSV schema. Guard expected empty `grep`/filter results explicitly under `set -euo pipefail`; route plain report text through dedicated output functions rather than capturing ANSI terminal output.

- [ ] **Step 4: Run the semantic regression to verify it passes**

Run: `/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh`

Expected: PASS for analytical semantics, no-event behavior, artifact contents, source immutability, and ANSI isolation.

- [ ] **Step 5: Run the final verification matrix**

Run:

```bash
/bin/bash mysql/innodb/tests/test_innodb_status_analyzer.sh
/bin/bash mysql/innodb/innodb_engine_status_sampler/tests/test_innodb_engine_status_sampler.sh
/bin/bash -n mysql/innodb/innodb_status_analyzer.sh mysql/innodb/innodb_engine_status_sampler/innodb_engine_status.sampler.sh
git diff --check
```

Expected: every test command exits 0, syntax validation exits 0, and `git diff --check` has no output.

- [ ] **Step 6: Commit canonical analysis behavior**

```bash
git add mysql/innodb/innodb_status_analyzer.sh mysql/innodb/tests
git commit -m "feat(mysql): modernize innodb status analyzer"
```

## Plan Self-Review

- **Spec coverage:** Tasks 1–3 cover canonical migration, archive preservation, CLI contract, portability, analytical semantics, report/CSV routing, source immutability, and test verification. No spec requirement lacks a task.
- **Step scan:** Each task has one failing-test step, an expected RED command, one implementation step with named interfaces, a GREEN command, and a scoped commit.
- **Type consistency:** `collect_input_files` and `query_hash` are introduced in Task 2 and consumed by Task 3; the root canonical script and one shared test suite remain stable through every task.
- **Review focus:** Space-containing source paths and hash fallback are Task 2 cases; empty analysis, stale deadlocks, and ANSI-free artifacts are Task 3 cases.
- **Proportion:** The plan specifies path changes, contracts, named helpers, and evidence without prescribing the AWK implementation body.
