# Check Cardinality Adaptive Report Width Design

## Objective

Improve the terminal report produced by
`mysql/estimations/check_cardinality.sh` so common column names are fully
visible and index information receives substantially more width at the
120-column fallback, without wrapping rows or changing machine-readable
exports.

## Root Cause

The existing fallback layout is exactly 120 visible characters wide. It uses
15 characters for `COLUMN`, 14 for `TYPE`, 17 for `SOURCE`, and only 10 for
`INDEXES`. The source cell is rendered as `source:source_index`, even though
the index name is also present in `INDEXES`. That duplicated value consumes
space while the two operator-critical identity fields are truncated.

## Scope

This change affects only terminal report geometry and display-only source
labels. SQL, cardinality calculations, normalized result files, ANSI color
rules, CSV/TSV schemas, and untruncated export values remain unchanged.

## Fallback Geometry

At 120 columns, the table uses these widths:

```text
COLUMN       24
TYPE         12
ELIGIBLE      8
CARDINALITY  11
RATIO         6
SELECT.       8
SOURCE       10
INDEXES      20
SEPARATORS   21
TOTAL       120
```

The shorter `SELECT.` heading is display-only; exported field names do not
change.

## Adaptive Allocation

Before rendering, the formatter scans the normalized per-table result file to
find the longest column name.

1. `TYPE` and `SOURCE` remain 12 and 10 characters at the fallback.
2. `COLUMN` starts at 24 characters.
3. When the longest column name exceeds 24 characters, `COLUMN` may grow to a
   maximum of 32 by borrowing from `INDEXES`.
4. `INDEXES` must never shrink below 12 characters.
5. At terminal widths above 120, the additional text budget goes to `INDEXES`.
   `COLUMN` still grows only as required by actual names, up to 32 characters.
6. Values exceeding their allocated widths continue to use deterministic
   `...` truncation, so no table row exceeds the chosen terminal width.

This guarantees full display for ordinary names such as
`vendor_transaction_id`. It intentionally caps unusually long identifiers at
32 characters because arbitrary MySQL identifiers and index lists cannot both
fit in a finite single-line report.

## Display-Only Source Labels

The terminal `SOURCE` cell no longer appends `source_index`. It maps normalized
sources to compact labels:

```text
exact_key_shortcut      -> exact/key
exact_unique_nullable   -> exact/uniq
exact                   -> exact
metadata                -> metadata
UNAVAILABLE             -> unavailable
```

Unknown future source values are truncated normally rather than discarded.
The normalized `source` and `source_index` fields remain complete and separate
in CSV/TSV output.

## Alignment and Colors

Rows are still assembled without ANSI sequences, padded into their allocated
visible widths, then wrapped with color prefixes and resets. Header and data
separators must therefore occur at identical visible offsets. Existing row
colors and status behavior do not change.

## Tests

The fake-MySQL integration suite will add a wide-layout fixture containing:

- `vendor_transaction_id`;
- `processing_status`;
- `bigint unsigned` and `varchar(128)` types;
- long `idx_aviator_*` index names;
- exact key shortcut and nullable-unique source paths.

Tests will verify:

- the fallback report is no wider than 120 visible characters;
- `vendor_transaction_id` is not truncated;
- `INDEXES` retains at least 20 visible characters when column names fit in 24;
- a 25-32 character column borrows width while leaving at least 12 for indexes;
- compact source labels are rendered without `source_index` duplication;
- header and row separators have identical visible offsets;
- truncation remains deterministic;
- CSV/TSV exports retain full column, source, source-index, and index-list
  values;
- the full Bash 3.2 suite remains green on macOS and Linux-compatible syntax.
