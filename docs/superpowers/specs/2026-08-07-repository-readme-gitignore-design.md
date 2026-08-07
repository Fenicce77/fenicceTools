# Repository README and Gitignore Design

## Goal

Improve repository navigation and prevent new local build or editor artifacts from appearing as untracked files, without deleting or untracking any existing artifact.

## Scope

The change modifies only:

- `.gitignore`
- `README.md`

No tracked files are removed. Existing tracked binaries, `.DS_Store` files, samples, output files, scripts, configuration templates, and login-path inventories remain unchanged.

## Gitignore Design

Preserve the existing `.worktrees/` entry and add conservative patterns for:

- macOS metadata: `.DS_Store`
- Python bytecode and cache directories: `__pycache__/`, `*.py[cod]`, `.pytest_cache/`
- Python coverage artifacts: `.coverage`, `.coverage.*`, `htmlcov/`
- Go test and coverage artifacts: `*.test`, `coverage.out`
- The known local ProxySQL Go build: `/mysql/proxysql/go/proxysql-monitor`

Do not add broad patterns for `*.out`, `*.log`, generic executables, or `porko*`. Those names overlap with tracked historical samples and tools and require a separate allowlist-driven cleanup.

Adding ignore rules does not remove matching files that are already tracked.

## README Design

Replace the one-line root README with an English operational index containing:

1. Repository purpose and supported macOS/Linux environments.
2. A maintained-tools section linking to the cardinality analyzer, ProxySQL Python monitor, ProxySQL Go monitor, and Cloud SQL general-log monitor.
3. A broader directory map for MySQL, MongoDB, SQL snippets, shell utilities, partitioning tools, and legacy C/binary experiments.
4. Existing local verification commands for the maintained tools.
5. Credential-handling rules requiring MySQL login paths and prohibiting real passwords in tracked configuration.
6. A legacy-code notice requiring review and testing before production use.

The README documents current capabilities without claiming that every historical script is standardized or supported.

## Validation

The implementation must verify:

- `git check-ignore` recognizes a root and nested `.DS_Store`, Python cache artifacts, Go test artifacts, and the ProxySQL Go build path.
- Existing tracked artifacts remain tracked.
- Every repository-relative Markdown link in `README.md` resolves to an existing path.
- `git diff --check` reports no whitespace errors.
- The diff contains only `.gitignore` and `README.md` after the design commit.

## Out of Scope

- Removing or untracking existing artifacts.
- Rewriting Git history.
- Changing scripts, SQL, tests, or configuration templates.
- Standardizing legacy tools.
- Adding CI workflows or external dependencies.
