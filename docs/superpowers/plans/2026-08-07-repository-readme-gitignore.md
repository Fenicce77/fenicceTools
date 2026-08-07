# Repository README and Gitignore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add conservative ignore rules and replace the root README with an accurate operational index without changing maintained tools or removing tracked artifacts.

**Architecture:** `.gitignore` handles only well-known local metadata, language caches, test output, and the specific ProxySQL Go build path. `README.md` becomes the navigation layer for maintained tools and historical directories; it links to existing documentation instead of duplicating detailed tool contracts.

**Tech Stack:** Git ignore patterns, CommonMark Markdown, Bash-based validation on macOS and Linux.

## Global Constraints

- Modify only `.gitignore` and `README.md` during implementation.
- Do not modify `mysql/estimations/`, `mysql/proxysql/python/`, `mysql/proxysql/go/`, or `mysql/general_log/`.
- Do not remove or untrack existing artifacts.
- Do not add broad ignore patterns for `*.out`, `*.log`, generic executables, or `porko*`.
- Keep all documentation and command output examples in English.
- Add no CI workflow or external dependency.

---

### Task 1: Conservative Generated-Artifact Ignore Rules

**Files:**
- Modify: `.gitignore`
- Test: Git's built-in `check-ignore` command

**Interfaces:**
- Consumes: Existing `.worktrees/` ignore rule.
- Produces: Repository-wide ignore behavior for macOS metadata, Python caches and coverage, Go test artifacts, and the known ProxySQL Go build path.

- [ ] **Step 1: Verify representative artifacts are not ignored**

Run:

```bash
printf '%s\n' \
  '.DS_Store' \
  'mysql/.DS_Store' \
  'mysql/proxysql/python/__pycache__/app.cpython-313.pyc' \
  'mysql/proxysql/python/.pytest_cache/state' \
  'mysql/proxysql/python/.coverage' \
  'mysql/proxysql/python/htmlcov/index.html' \
  'mysql/proxysql/go/formatter.test' \
  'mysql/proxysql/go/coverage.out' \
  'mysql/proxysql/go/proxysql-monitor' |
  git check-ignore --no-index --stdin
```

Expected: The command does not print all nine paths and exits nonzero because the new rules are absent.

- [ ] **Step 2: Add the exact ignore rules**

Replace `.gitignore` with:

```gitignore
# Codex worktrees
.worktrees/

# macOS metadata
.DS_Store

# Python bytecode, test caches, and coverage
__pycache__/
*.py[cod]
.pytest_cache/
.coverage
.coverage.*
htmlcov/

# Go test and coverage artifacts
*.test
coverage.out

# Local ProxySQL monitor build
/mysql/proxysql/go/proxysql-monitor
```

- [ ] **Step 3: Verify every representative path is ignored**

Run:

```bash
matched=$(printf '%s\n' \
  '.DS_Store' \
  'mysql/.DS_Store' \
  'mysql/proxysql/python/__pycache__/app.cpython-313.pyc' \
  'mysql/proxysql/python/.pytest_cache/state' \
  'mysql/proxysql/python/.coverage' \
  'mysql/proxysql/python/htmlcov/index.html' \
  'mysql/proxysql/go/formatter.test' \
  'mysql/proxysql/go/coverage.out' \
  'mysql/proxysql/go/proxysql-monitor' |
  git check-ignore --no-index --stdin |
  wc -l |
  tr -d ' ')
test "$matched" -eq 9
```

Expected: Exit status `0`; `matched` equals `9`.

- [ ] **Step 4: Verify existing artifacts remain tracked**

Run:

```bash
test "$(git ls-files 'mysql/proxysql/go/proxysql-monitor' 'generic/.DS_Store' | wc -l | tr -d ' ')" -eq 2
```

Expected: Exit status `0`; ignore rules did not alter the index.

- [ ] **Step 5: Commit the ignore rules**

```bash
git add .gitignore
git commit -m "chore: ignore local development artifacts"
```

---

### Task 2: Root Operational Index

**Files:**
- Modify: `README.md`
- Test: Repository-relative link and whitespace validation

**Interfaces:**
- Consumes: Existing nested README files and current repository directory structure.
- Produces: A root navigation document for maintainers and DBRE operators.

- [ ] **Step 1: Replace the one-line README**

Write `README.md` with these sections and links:

```markdown
# fenicceTools

DBRE tools, operational scripts, and diagnostic queries for MySQL-family databases, ProxySQL, Cloud SQL, MongoDB, and supporting Linux/macOS workflows.

The repository contains both maintained tools and historical utilities. Review each script and test it against a non-production target before operational use.

## Maintained tools

| Area | Tool | Purpose |
|---|---|---|
| MySQL | [Cardinality analyzer](mysql/estimations/README.md) | Compare InnoDB estimates with exact counts when safe and report column cardinality and selectivity. |
| ProxySQL | [Python monitor](mysql/proxysql/python/README.md) | Interactive, install-free ProxySQL connection and backend monitor using MySQL login paths. |
| ProxySQL | [Go monitor](mysql/proxysql/go/README.md) | Go implementation of the ProxySQL monitor with bounded resources and persistent clients. |
| Cloud SQL | [General-log monitor](mysql/general_log/README.md) | Capture and safely parse GCP Cloud SQL MySQL general-log entries. |

## Repository map

| Path | Contents |
|---|---|
| [`mysql/`](mysql/) | MySQL diagnostics, replication, InnoDB, binlog, dump, session, partitioning, and ProxySQL tools. |
| [`mongodb/`](mongodb/) | MongoDB operational snippets, including current-operation and connection inspection. |
| [`sql/`](sql/) | Standalone SQL diagnostics and test DDL. |
| [`sh/`](sh/) | Historical shell utilities and earlier MySQL operational scripts. |
| [`generic/`](generic/) | Generic session, query-generation, search, and user-management helpers. |
| [`partitioning/`](partitioning/) | Partitioning and `pt-online-schema-change` helper scripts. |
| [`docs/superpowers/`](docs/superpowers/) | Design specifications and implementation plans for maintained changes. |

## Requirements

- macOS or Linux.
- Bash 3.2 or newer for standardized shell tools.
- Python 3.9 or newer for the ProxySQL Python monitor.
- Go 1.22 or newer for the ProxySQL Go monitor.
- MySQL command-line client and `mysql_config_editor` where MySQL login paths are used.
- Tool-specific external commands documented in each tool's README.

## Local verification

Run maintained test suites from the repository root:

```bash
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

## Credential handling

- Store credentials in MySQL login paths created with `mysql_config_editor`.
- Do not commit real passwords, tokens, private keys, or production connection files.
- Treat host inventories and configuration templates according to their operational sensitivity.
- Rotate a credential if it has ever been committed, even if the containing file is later deleted.

## Legacy utilities

Files outside the maintained areas may predate current conventions such as `set -euo pipefail`, complete CLI help, deterministic exit codes, portable macOS/Linux behavior, and automated tests. Validate dependencies, SQL compatibility, privilege requirements, and failure handling before production use.
```

- [ ] **Step 2: Verify every repository-relative Markdown link resolves**

Run:

```bash
rg -o '\]\([^):#]+\)' README.md |
  sed -E 's/^.*\]\(([^)]+)\)$/\1/' |
  while IFS= read -r path; do
    test -e "$path" || {
      printf 'Broken README link: %s\n' "$path" >&2
      exit 1
    }
  done
```

Expected: Exit status `0` and no output.

- [ ] **Step 3: Run the documented verification commands**

Run every command from the README `Local verification` section.

Expected: Cardinality tests report `39 passed, 0 failed`; Python reports `Ran 51 tests` and `OK`; Go tests and vet exit `0`; the general-log parser reports `Ran 10 tests` and `OK`; both shell integration suites exit `0`.

- [ ] **Step 4: Commit the README**

```bash
git add README.md
git commit -m "docs: add repository operations index"
```

---

### Task 3: Scope and Repository Validation

**Files:**
- Verify: `.gitignore`
- Verify: `README.md`
- Protect: `mysql/estimations/`, `mysql/proxysql/python/`, `mysql/proxysql/go/`, `mysql/general_log/`

**Interfaces:**
- Consumes: The two implementation commits from Tasks 1 and 2.
- Produces: Evidence that the implementation respects the approved scope.

- [ ] **Step 1: Verify the two implementation commits touch only approved files**

Run:

```bash
test "$(git diff --name-only HEAD~2..HEAD | sort | tr '\n' ' ')" = ".gitignore README.md "
```

Expected: Exit status `0`.

- [ ] **Step 2: Verify protected paths are unchanged**

Run:

```bash
test -z "$(git diff --name-only HEAD~2..HEAD -- \
  mysql/estimations \
  mysql/proxysql/python \
  mysql/proxysql/go \
  mysql/general_log)"
```

Expected: Exit status `0`.

- [ ] **Step 3: Verify formatting and repository state**

Run:

```bash
git diff --check HEAD~2..HEAD
git status --short --branch
```

Expected: No whitespace errors. The branch may be ahead of its upstream, and the root `.DS_Store` no longer appears because it is ignored.
