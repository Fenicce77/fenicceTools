# Artifact Cleanup and Porko Batch Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove reproducible generated artifacts and make Porko transaction batching configurable without changing its SQL-filter semantics.

**Architecture:** Porko remains a single portable C translation unit that parses its own short and long options before reading standard input. A shell regression test compiles the source into a temporary directory and asserts output behavior. Generated artifacts are removed only through an exact allowlist and guarded by exact `.gitignore` entries.

**Tech Stack:** ISO C with `strtol`, POSIX shell/Bash, `cc`/`clang`/`gcc`, Git.

## Global Constraints

- Delete only the 22 allowlisted generated artifacts from the approved specification.
- Modify only `porko.c`, `.gitignore`, and the new `tests/test_porko.sh` besides plan/spec documentation.
- Do not modify `porko500.c`, `porko1k.c`, `porko2k.c`, `porko5k.c`, `porko10k.c`, or `porko20k.c`.
- Do not modify maintained source under `mysql/estimations/`, `mysql/proxysql/python/`, `mysql/proxysql/go/`, or `mysql/general_log/`.
- Keep default batch size `2000`, use `START TRANSACTION;`, preserve `COMMIT;` and `SELECT SLEEP(0.3);` placement.
- Use English help, diagnostics, documentation, and test output.
- Support macOS and Linux without external C libraries.

---

### Task 1: Porko CLI Regression Test

**Files:**
- Create: `tests/test_porko.sh`
- Test: `tests/test_porko.sh`

**Interfaces:**
- Consumes: `porko.c`, a C compiler selected from `CC`, `cc`, `clang`, or `gcc`.
- Produces: A temporary `porko` test binary and assertions for the CLI and SQL output contract.

- [ ] **Step 1: Write the failing test**

Create `tests/test_porko.sh` with `set -euo pipefail`, a `mktemp -d` workspace, a cleanup trap, and these checks:

```bash
printf 'one;\ntwo;\nthree;\n' | "$binary_path" -b 2
```

must equal:

```text
START TRANSACTION;
one;
two;
COMMIT;
SELECT SLEEP(0.3);
START TRANSACTION;
three;
COMMIT;
```

The test must also assert that `--batch-size 3` creates one three-line transaction, generated 2001-line input produces its intermediate boundary after line 2000 with no `BEGIN;`, help succeeds and names both options, and `-b`, `-b 0`, `--batch-size nope`, a repeated option, and a positional argument fail with a nonempty English stderr diagnostic.

- [ ] **Step 2: Run the test against the existing source**

Run:

```bash
bash tests/test_porko.sh
```

Expected: Failure because the current source prints `BEGIN;`, has a fixed 2000-line batch size, and accepts no CLI option.

- [ ] **Step 3: Commit the regression test after the source implementation passes**

```bash
git add tests/test_porko.sh porko.c
git commit -m "feat: configure porko transaction batches"
```

---

### Task 2: Runtime Batch Size in Porko

**Files:**
- Modify: `porko.c`
- Test: `tests/test_porko.sh`

**Interfaces:**
- Consumes: `argc`, `argv`, standard input, and C library functions `strtol`, `strcmp`, `fprintf`, and `fgets`.
- Produces: `porko [-b SIZE | --batch-size SIZE]` command-line interface.

- [ ] **Step 1: Add usage and parsing helpers**

Implement these functions before `main`:

```c
static void print_usage(const char *program_name);
static int parse_batch_size(const char *value, int *batch_size);
static int parse_arguments(int argc, char *argv[], int *batch_size);
```

`print_usage` writes usage and two pipeline examples to `stdout`. `parse_batch_size` uses `strtol` with `errno = 0`, checks that the entire value was consumed, and accepts only `1..INT_MAX`. `parse_arguments` accepts no option, exactly one `-b SIZE`, exactly one `--batch-size SIZE`, or exactly one help option; it rejects every other form with a specific English message on `stderr`.

- [ ] **Step 2: Replace the fixed macro and update output statements**

Remove `#define COMMIT_SIZE 2000`. Change `main` to `int main(int argc, char *argv[])`, initialize `batch_size` to `2000`, call `parse_arguments`, and compare the line counter to `batch_size`. Emit `START TRANSACTION;` initially and after each intermediate `COMMIT;`/sleep sequence. Retain the final `COMMIT;` and return `EXIT_SUCCESS` or `EXIT_FAILURE`.

- [ ] **Step 3: Run the Porko regression test**

Run:

```bash
bash tests/test_porko.sh
```

Expected: Exit status `0` and every assertion passes.

---

### Task 3: Exact Generated-Artifact Cleanup

**Files:**
- Modify: `.gitignore`
- Delete: The 22 paths listed in `docs/superpowers/specs/2026-08-08-artifact-cleanup-porko-batch-size-design.md`

**Interfaces:**
- Consumes: Git index and the approved artifact allowlist.
- Produces: A source-only tree in which fresh local Porko builds are ignored.

- [ ] **Step 1: Verify the complete allowlist is still tracked**

Run:

```bash
allowlisted_count=$(git ls-files -- \
  generic/.DS_Store \
  mysql/.DS_Store \
  mysql/general_log/.DS_Store \
  mysql/innodb/.DS_Store \
  mysql/monitoring/.DS_Store \
  rdsproxytest/sh/.DS_Store \
  sh/.DS_Store \
  myporko \
  myporko2 \
  mysql/proxysql/go/proxysql-monitor \
  newobj_mac/porko \
  newobj_mac/porko500 \
  obj/mac/porko10k \
  obj/mac/porko1k \
  obj/mac/porko2k \
  obj/mac/porko5k \
  poko5000 \
  porko10000 \
  porko10k \
  porko2000 \
  porko20k \
  porko5k | wc -l | tr -d ' ')
test "$allowlisted_count" -eq 22
```

Expected: Count equals `22` before deletion.

- [ ] **Step 2: Remove only the allowlisted artifacts**

Use an exact `git rm --` path list. Do not use wildcards or recursive directory removal.

- [ ] **Step 3: Add exact Porko build ignore entries**

Add these entries to `.gitignore`:

```gitignore
# Local Porko builds
/myporko
/myporko2
/poko5000
/porko10000
/porko2000
/porko10k
/porko20k
/porko5k
/newobj_mac/porko
/newobj_mac/porko500
/obj/mac/porko10k
/obj/mac/porko1k
/obj/mac/porko2k
/obj/mac/porko5k
```

The existing `.DS_Store` and `/mysql/proxysql/go/proxysql-monitor` rules cover the remaining allowlisted paths.

- [ ] **Step 4: Verify removal and ignores**

Run `git diff --name-only --diff-filter=D` and confirm exactly 22 paths. Use `git check-ignore --no-index` to verify all 14 Porko build names are ignored. Verify `porko.c` and every fixed-size C source remain tracked and are not ignored.

- [ ] **Step 5: Commit the cleanup**

```bash
git add .gitignore
git rm -- <exact 22 paths>
git commit -m "chore: remove generated local artifacts"
```

---

### Task 4: Full Validation and Scope Check

**Files:**
- Verify: `porko.c`, `tests/test_porko.sh`, `.gitignore`
- Protect: All paths outside the approved source, test, ignore, and artifact allowlists.

**Interfaces:**
- Consumes: The implementation and cleanup commits.
- Produces: Evidence of behavioral correctness and constrained scope.

- [ ] **Step 1: Run all maintained suites and the Porko test**

Run:

```bash
bash tests/test_porko.sh
bash mysql/estimations/tests/test_check_cardinality.sh
(
  cd mysql/proxysql/python
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -q
)
(
  cd mysql/proxysql/go
  go test ./...
  go vet ./...
)
(
  cd mysql/general_log
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
    -s tests/gcp-general-log-parser \
    -p 'test_parser.py' \
    -q
  bash tests/gcp-general-log-parser/test_shell_integration.sh
)
bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: Every command exits `0`.

- [ ] **Step 2: Verify scope and formatting**

Run:

```bash
git diff --check HEAD~2..HEAD
test "$(git diff --name-only --diff-filter=D HEAD~2..HEAD | wc -l | tr -d ' ')" -eq 22
test -z "$(git diff --name-only HEAD~2..HEAD -- \
  porko500.c porko1k.c porko2k.c porko5k.c porko10k.c porko20k.c \
  mysql/estimations mysql/proxysql/python mysql/proxysql/go mysql/general_log)"
```

Expected: Exit status `0`; no fixed-size Porko source or protected maintained-tool path changed.

- [ ] **Step 3: Record verification outcome**

Report the exact deletion count, relevant test results, and any intentionally untouched artifacts.
