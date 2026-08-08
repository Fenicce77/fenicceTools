# Estimate Storage Standardization Design

## Goal

Standardize `mysql/estimations/estimate_storage.sh` as a safe, portable capacity-estimation tool with the same operational UX as `check_cardinality.sh`.

## CLI and Help

Preserve `-l`, `-d`, `-t`, `-r`, `-u`, `-k`, `-i`, and `-h`. Add `--environment`, `--allow-production`, `--mysql-bin`, `--output-file`, `--format csv|tsv`, and `--no-color`.

With no arguments and with `--help`, show a full sectioned, colored TTY help screen modeled after `check_cardinality.sh`; `--no-color` produces plain text.

## Table Prefix Semantics

`--table-prefix` accepts a prefix without `%`; the script appends one final `%` internally and uses `LIKE '<prefix>%'`. Input containing `%` is rejected. Underscores are preserved intentionally, allowing callers to decide whether `_` is a literal naming separator or a SQL `LIKE` wildcard.

## Safety and Output

Require `--environment`; production also requires `--allow-production`. Validate all numeric inputs, database identifiers, client executable, unit, format, and output path. The script reads metadata and server variables only and never performs DDL/DML.

Machine-readable CSV/TSV output is atomic and ANSI-free. Human terminal output is colored only for a TTY. Exit codes are `0` success, `2` validation, `3` dependency/connection/output failure, `4` partial table failures, and `130` interruption.

## Testing and Scope

Use a fake MySQL client to test CLI validation, production guard, prefix SQL, output formats, client resolution, and no-color behavior without a real server. Modify only the estimator, estimations README, and new test fixtures.
