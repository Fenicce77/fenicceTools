# Estimate Storage Standardization Implementation Plan

**Goal:** Standardize the storage estimator with safe CLI behavior and reproducible tests.

## Constraints

- Modify only `estimate_storage.sh`, `README.md`, and new files under `tests/`.
- Use `check_cardinality.sh` as the help and portability reference.
- Require `--environment`; production requires `--allow-production`.
- `--table-prefix` rejects `%` and appends the final `%` internally; underscores remain unescaped.

### Task 1: Fake MySQL tests

- Create `tests/fake_mysql_storage.sh` and `tests/test_estimate_storage.sh`.
- Test no-argument help, `--help`, `--no-color`, validation, production guard, `%` rejection, generated `LIKE 'prefix%'`, formats, and output atomicity.
- Run the test against the existing script; expect failure.

### Task 2: Estimator refactor

- Add strict mode, Bash 3.2-safe parsing, colors gated by TTY, client resolution, traps, deterministic exit codes, and all specified options.
- Preserve the storage calculation SQL and read-only behavior.
- Emit human output or clean CSV/TSV report based on requested format.

### Task 3: Documentation and verification

- Update `mysql/estimations/README.md` with CLI, safety and examples.
- Run storage tests, cardinality tests, and `git diff --check`.
- Commit with `feat(mysql): standardize storage estimator`.
