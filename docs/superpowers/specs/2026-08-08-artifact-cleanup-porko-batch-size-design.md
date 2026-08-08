# Artifact Cleanup and Porko Batch Size Design

## Goal

Remove tracked generated artifacts under a source-only policy and make Porko's SQL transaction batch size configurable at runtime.

## Scope

The implementation has two independent deliverables:

1. Remove exactly the 22 generated artifacts listed in this document and prevent their reintroduction through targeted `.gitignore` rules.
2. Update `porko.c` with a documented `-b` / `--batch-size` option while preserving its stdin-to-stdout SQL transformation model.

No source file other than `porko.c`, no maintained ProxySQL/Python/Go implementation, and no MySQL operational script is modified.

## Artifact Removal Allowlist

Remove exactly these paths:

```text
generic/.DS_Store
mysql/.DS_Store
mysql/general_log/.DS_Store
mysql/innodb/.DS_Store
mysql/monitoring/.DS_Store
rdsproxytest/sh/.DS_Store
sh/.DS_Store
myporko
myporko2
mysql/proxysql/go/proxysql-monitor
newobj_mac/porko
newobj_mac/porko500
obj/mac/porko10k
obj/mac/porko1k
obj/mac/porko2k
obj/mac/porko5k
poko5000
porko10000
porko10k
porko2000
porko20k
porko5k
```

The allowlist contains seven macOS Finder metadata files and 15 compiled executables. They are reproducible from their Go or C sources where applicable. Existing sources, including `porko.c`, `porko500.c`, `porko1k.c`, `porko2k.c`, `porko5k.c`, `porko10k.c`, and `porko20k.c`, remain tracked.

Deletion affects the current Git tree only. It does not rewrite history. The deleted files remain recoverable from prior commits until history is rewritten by a separately authorized operation.

## Ignore Rules

Keep the existing general local-artifact rules. Add targeted root and directory rules for the removed Porko binaries and the Go ProxySQL monitor so fresh local builds do not appear as untracked files.

The new rules must not ignore any `.c` source file, generic executable, `*.out`, `*.log`, or unrelated file under `mysql/`, `obj/`, or `newobj_mac/`.

## Porko CLI Contract

Porko remains a Unix filter: it reads SQL statements from standard input and writes transaction-wrapped SQL to standard output.

```text
porko [-b SIZE | --batch-size SIZE]
```

- The default batch size is `2000`, preserving current behavior.
- `-b SIZE` and `--batch-size SIZE` set the number of input lines emitted per transaction.
- `-h` and `--help` print usage and examples to standard output and exit successfully.
- Invalid values include a missing value, non-decimal text, zero, negative values, and values outside the representable positive `int` range. They print an English diagnostic to standard error and exit nonzero.
- More than one batch-size option or positional arguments are rejected to keep invocation deterministic.

## SQL Output Contract

For valid input, Porko emits:

1. `START TRANSACTION;` before the first input statement.
2. Every input line unchanged.
3. After each complete batch: `COMMIT;`, `SELECT SLEEP(0.3);`, and `START TRANSACTION;`.
4. One final `COMMIT;` after EOF, including empty input.

`START TRANSACTION;` replaces the previous `BEGIN;` output to align with standard SQL and MySQL terminology. The sleep interval remains fixed at `0.3` seconds and is not an option in this change.

## Testing

Add a self-contained shell test that compiles `porko.c` into a temporary directory using `cc`, `clang`, or `gcc` available on macOS or Linux. It must verify:

- Default batch size preserves the 2000-line boundary.
- `-b 2` and `--batch-size 3` produce correct transaction boundaries.
- Output contains `START TRANSACTION;` and never emits `BEGIN;`.
- Help succeeds and documents the options.
- Invalid batch-size forms fail with an English error.
- Temporary compiler output is deleted by the test cleanup trap.

## Validation

Before committing the implementation:

- Confirm every allowlisted path is tracked before deletion.
- Confirm `git diff --name-status` contains exactly 22 deletions plus the approved source, test, documentation, and ignore-rule modifications.
- Confirm no protected maintained-tool path changes.
- Run the new Porko test, existing maintained test suites, `git diff --check`, and targeted `git check-ignore` assertions.

## Out of Scope

- Rewriting Git history.
- Modifying the six fixed-size Porko source variants.
- Adding a configurable sleep interval.
- Changing the semantics of input SQL lines.
- Modifying MySQL, ProxySQL, Cloud SQL, MongoDB, or other maintained tools.
