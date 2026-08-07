# Check Cardinality Result Sorting Design

## Objective

Add optional result ordering to `mysql/estimations/check_cardinality.sh` so a
DBA can rank table columns by cardinality or selectivity when evaluating
candidate composite-index column order. Terminal output and CSV/TSV exports
must present the same ordering.

## CLI Contract

Add this optional parameter:

```text
--sort-by cardinality|selectivity
```

Both `--sort-by=value` and `--sort-by value` forms are supported. When omitted,
the script preserves the table's physical column order from
`information_schema.COLUMNS.ORDINAL_POSITION`.

The selected metric is always sorted descending because the feature is focused
on surfacing higher-cardinality and higher-selectivity index candidates. No
ascending-order option is added. An unsupported or missing value is a CLI
error, returns exit status 2, and retains the existing `Try --help for usage.`
guidance.

The always-colored help documents the option under `Output and runtime` and
includes one cardinality and one selectivity example.

## Ordering Rules

For each table, sorting follows these rules:

1. Rows with a numeric selected metric precede rows where that metric is `N/A`
   or the row status is `ERROR`.
2. The selected metric sorts descending.
3. Equal selected values use the other metric descending as a secondary key.
4. Remaining ties preserve original physical column order.

Therefore:

- `--sort-by cardinality` uses cardinality, then selectivity, then ordinal;
- `--sort-by selectivity` uses selectivity, then cardinality, then ordinal;
- valid zero values sort before `N/A` values;
- error rows always remain visible but appear after analyzable candidates;
- warning rows retain their numeric ranking when their metrics are available.

## Data Flow

`RESULT_FILE` remains the normalized, physical-order source of truth produced by
column analysis. After analysis completes, the script prepares one ordered view:

- when `--sort-by` is omitted, `ORDERED_RESULT_FILE` references `RESULT_FILE`;
- when sorting is requested, `ORDERED_RESULT_FILE` references one sorted file in
  the existing per-run `WORK_DIR`.

Terminal rendering and CSV/TSV export both consume `ORDERED_RESULT_FILE`.
Status/error/warning detection continues to consume the original `RESULT_FILE`.
This guarantees consistent human- and machine-readable order without altering
analysis state or hiding failures.

The sorted view is generated once per table and reused. It does not execute any
additional MySQL queries and does not change metadata or exact-count collection
order.

## Portable Numeric Sort Keys

Raw cardinality can contain unsigned 64-bit values that are not exactly
representable by AWK or shell floating-point arithmetic. The sorter therefore
decorates each normalized row with textual numeric keys before invoking
`LC_ALL=C sort`.

Each nonnegative metric key contains:

- an availability flag;
- the length of its normalized integer component;
- normalized decimal digits with a fixed fractional scale for that metric.

Cardinality uses scale zero. Selectivity uses the existing two-decimal scale.
Equal integer-component lengths allow bytewise `LC_ALL=C` digit comparison
without numeric conversion. Integer-component length is compared first, so
unsigned 64-bit cardinalities and larger derived selectivity values retain
correct magnitude ordering. Original input line number is included as the final
ascending key.

The decorated rows are sorted by explicit tab-separated keys and then stripped
back to the original eleven normalized fields. The nontrivial AWK decorator is
declared as a shell string before invocation to preserve the existing macOS
Bash 3.2 parsing workaround.

## Resource Behavior

Sorting adds one local decorate/sort/strip pipeline per table only when the new
option is used. The work is O(columns log columns), uses the existing temporary
workspace, and does not add database load. Default execution adds no sort
process and retains the current result path directly.

Expected pipeline failures propagate as runtime failures under
`set -euo pipefail`; the script must not silently render partially sorted data.

## Unchanged Behavior

This feature does not change:

- SQL statements or `ORDINAL_POSITION` metadata collection;
- auto, metadata, or exact mode selection;
- cardinality, ratio, or selectivity calculations;
- `ANALYZE TABLE` safeguards;
- terminal widths, multiline wrapping, colors, or alignment;
- CSV/TSV schemas or field values;
- per-table status, warning, error, or final exit semantics.

## Index-Design Guidance

The help text describes sorting as candidate guidance, not an automatic index
definition. Final composite-index order must also consider equality and range
predicates, joins, `ORDER BY`/`GROUP BY`, covering requirements, workload
frequency, and MySQL's leftmost-prefix rule. High selectivity alone does not
determine the best production index.

## Tests

The fake-MySQL integration suite will verify:

- help and both parser forms;
- invalid and missing sort values return exit status 2;
- omitted sorting preserves physical column order in terminal and exports;
- cardinality sorting is descending;
- selectivity sorting is descending;
- the other metric provides the documented secondary ordering;
- physical ordinal provides stable final tie ordering;
- zero values precede `N/A`;
- error rows are last and remain visible;
- unsigned 64-bit cardinalities are ordered without precision loss;
- terminal and CSV/TSV row sequences are identical;
- analysis query count and SQL order remain unchanged;
- sorting does not alter terminal width, wrapping, ANSI behavior, or exported
  values;
- all existing tests remain green under macOS Bash 3.2 and Linux-compatible
  syntax.
