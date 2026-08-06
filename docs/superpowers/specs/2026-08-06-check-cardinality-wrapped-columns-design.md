# Check Cardinality Wrapped Columns Design

## Objective

Update the terminal report produced by
`mysql/estimations/check_cardinality.sh` so every relevant `TYPE` value and
every index entry is visible, while preserving aligned columns and the detected
terminal width. `ENUM` member definitions are intentionally omitted from the
terminal because they are outside cardinality analysis. Machine-readable CSV
and TSV output remains unchanged.

## Scope

The change is limited to terminal width allocation and multiline rendering.
SQL generation, cardinality calculations, normalized intermediate records,
status colors, exit codes, and export schemas are unchanged.

## Width Allocation

Before rendering a table, the formatter scans its normalized result file and
measures the longest `COLUMN`, `TYPE`, numeric, and derived-metric values.

- `COLUMN` keeps the existing adaptive behavior and 32-character preferred
  maximum.
- `TYPE` expands to display ordinary type definitions in full when the terminal
  budget permits.
- Exceptional definitions, such as long `SET` declarations, use a bounded
  `TYPE` column and wrap instead of being truncated.
- `INDEXES` retains a minimum width of 12 characters and receives remaining
  terminal space after identity, numeric, and source fields are allocated.
- Numeric counts are never truncated. Derived ratios may continue to use the
  existing terminal-only scientific notation when required.
- Every physical header or result line remains within the detected terminal
  width, using 120 columns as the fallback when terminal detection is absent or
  smaller.
- No calculated width may become negative.

The formatter selects a practical `TYPE` width from the longest actual value
and the available text budget. This shows common values such as
`bigint unsigned`, `decimal(20,6)`, and `varchar(128)` without truncation. A
type that cannot fit without violating the report-width contract is wrapped
across continuation lines.

## Display-Only Type Normalization

For terminal output, any case-insensitive `ENUM(...)` definition is rendered as
`ENUM`. Its member list does not affect width calculation and is never printed
on a continuation line. This normalization is terminal-only: the normalized
result record and CSV/TSV exports retain the complete original `ENUM(...)`
definition returned by MySQL.

## Multiline Rendering

Each logical result row is converted into one or more physical terminal lines.
The renderer wraps `TYPE` and `INDEXES` independently, then emits the greater
number of required lines.

The first physical line contains all fields. Continuation lines contain only
the remaining `TYPE` and/or `INDEXES` fragments; `COLUMN`, `ELIGIBLE`,
`CARDINALITY`, `RATIO`, `SELECT.`, and `SOURCE` are blank. Every physical line
uses the same widths and separators as the header.

Example shape using an exceptionally long non-`ENUM` type:

```text
COLUMN       | TYPE             | ELIGIBLE | ... | SOURCE     | INDEXES
flags        | set('audit',     |       75 | ... | exact/key  | idx_flags(#1),
             | 'billing',       |          | ... |            | idx_flags_date(#1),
             | 'security')      |          | ... |            | uk_flags_ref(#1)
```

ANSI sequences remain outside padded values. The logical row's status color is
applied consistently to every physical line and reset at the end of each line,
so visible widths and separator offsets are unaffected.

## Wrapping Rules

### TYPE

After applying display-only `ENUM` normalization, `TYPE` is split into chunks
no longer than the allocated width. The renderer prefers syntactically useful
break points such as commas in `SET` definitions. When no break point exists
within the available width, it performs a deterministic hard wrap. No ellipsis
is inserted and no character is lost.

### INDEXES

The index list is parsed at the existing comma-plus-space separators. Complete
`index_name(#sequence)` entries are packed onto a line while they fit. An entry
that would exceed the remaining space moves to the next line. If one individual
entry is wider than the entire `INDEXES` column, only that entry is
deterministically hard-wrapped. Delimiters remain visible so the original list
can be reconstructed from the displayed fragments.

The sentinel value `---` remains a single entry.

## Data Integrity and Errors

Wrapping is display-only. The normalized result file retains the complete
`column_type`, `source`, `source_index`, and `existing_indexes` values. CSV and
TSV exports continue to consume those original values rather than rendered
fragments.

Existing table- and column-level error behavior remains unchanged. An error
message is printed once after all physical lines for its logical row.

## Compatibility

The implementation remains compatible with macOS Bash 3.2 and Linux Bash. It
will not use arrays requiring Bash 4, `mapfile`, GNU-only `sed` features, or
platform-specific text-width options. Expected non-zero shell operations remain
safe under `set -euo pipefail`.

## Tests

The fake-MySQL integration suite will verify:

- common type definitions are displayed completely;
- `ENUM(...)` is displayed only as `ENUM`, without exposing or measuring its
  member list;
- a long `SET` value wraps without truncation or character loss;
- all comma-separated index entries appear and wrap at entry boundaries;
- one oversized index entry hard-wraps without data loss;
- continuation lines leave non-wrapping cells blank;
- header, primary row, and continuation-line separators have identical visible
  offsets;
- every physical line is at most 120 columns under fallback geometry and at
  most 160 columns in the wide-terminal fixture;
- ANSI row color is consistently applied to all lines of a logical row;
- errors print once after the complete logical row;
- CSV and TSV exports contain the original unwrapped values, including complete
  `ENUM(...)` definitions;
- all existing CLI, SQL, analysis, alignment, and export tests remain green.
