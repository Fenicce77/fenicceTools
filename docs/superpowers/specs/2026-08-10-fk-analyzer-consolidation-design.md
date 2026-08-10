# MySQL Foreign Key Analyzer Consolidation Design

## Goal

Replace `mysql/analysis/fk_analyzer.sh` with one maintained, read-only MySQL 8.0/8.4 topology analyzer that reports physical and inferred virtual foreign keys, handles composite primary keys deterministically, renders aligned color-aware terminal views, and optionally publishes atomic CSV or TSV reports.

`mysql/analysis/fk_analyzer.v2.sh` remains byte-for-byte unchanged as a historical reference during this phase.

## Scope and Runtime

The maintained implementation remains a single Bash translation unit compatible with Bash 3.2 on macOS and Linux. It uses `set -euo pipefail`, a configurable MySQL client, temporary files with signal-safe cleanup, and no runtime language dependency beyond standard shell utilities and the MySQL CLI.

The analyzer executes only metadata queries, `SHOW CREATE TABLE`, and an optional exact row count. It never executes DDL, DML, `ANALYZE TABLE`, configuration changes, or automatic remediation.

## Command-Line Contract

Required options:

```text
-l, --login-path NAME
-s, --schema NAME
-t, --table NAME
--environment development|test|staging|production
```

Optional behavior:

```text
-r, --tree
-c
--cardinality metadata|exact
--physical-only
--allow-production
--output-file FILE
--format csv|tsv
--terminal-width COLUMNS
--mysql-bin PATH
--no-color
-h, --help
```

No arguments and `--help` render complete, sectioned help with examples. Colors are enabled only on an eligible TTY and can be disabled explicitly. `-c` is retained for compatibility and selects metadata cardinality; `--cardinality` accepts an explicit mode. The default mode is `metadata`.

`--environment` is always required so output records operational context. Metadata analysis is permitted in production without an extra flag because it is read-only and bounded. `--cardinality exact` in production additionally requires `--allow-production`. Supplying `--allow-production` outside that combination is rejected.

Schema and table names are validated against MySQL identifier length and control-character rules. SQL string values use hexadecimal `utf8mb4` literals. The table identifier required by `SHOW CREATE TABLE` is backtick-quoted after embedded backticks are doubled. Login-path values are passed only as MySQL CLI arguments and are never interpolated into SQL or diagnostics containing server errors.

## Data Acquisition

After a connection and target-table preflight, the analyzer performs bounded, set-based metadata reads instead of the current per-relation query pattern:

1. Target DDL, ordered primary-key columns, and full column definitions.
2. Physical inbound and outbound constraints, grouped by constraint and ordered by `ORDINAL_POSITION`.
3. Schema-wide primary-key and column metadata required for virtual-relation inference.
4. Schema-wide index structures ordered by `SEQ_IN_INDEX`.
5. `information_schema.TABLES.TABLE_ROWS` and relevant `STATISTICS.CARDINALITY` values.
6. One exact target-table row count only when `--cardinality exact` is selected.

The analyzer builds one normalized in-memory relation stream. Terminal tables, the tree, and reports consume that same stream so classifications cannot diverge between output formats.

## Physical Relationships

Physical foreign keys are grouped as tuples rather than emitted as unrelated column rows. Each relation records direction, constraint name, ordered source tuple, ordered target tuple, update/delete rules, and source supporting-index information.

A physical relation always takes precedence. An inferred virtual candidate with the same source and target tuples is suppressed rather than displayed twice.

## Virtual Relationship Inference

For each target table, primary-key components are ordered by their PK `ORDINAL_POSITION`. A source component may match either:

- the exact target PK column name; or
- `<target_table>_<target_pk_column>`.

An unqualified source column named only `id` cannot start a virtual relationship because it does not identify a target. A target whose PK is `id` therefore requires `<target_table>_id` as the first component. No singularization, pluralization, fuzzy comparison, or configurable regular expression is applied.

The first PK component is the minimum evidence required to create a virtual candidate. Once found, all remaining PK components are evaluated in PK order. Type compatibility uses the complete `COLUMN_TYPE`, including numeric signedness. Character types additionally require compatible character set and collation.

Index order is semantic. A complete virtual relation requires a source index whose leading columns reproduce the mapped PK tuple in order. Physical column `ORDINAL_POSITION` is not used as a substitute for relationship order.

Candidates are classified as:

- `PHYSICAL_FK`: an actual MySQL constraint.
- `COMPLETE_VIRTUAL_FK`: every PK component is present and type-compatible, and a source index has the tuple as its ordered leading prefix.
- `PARTIAL_VIRTUAL_FK`: the first component exists, but later components are absent or incompatible, or no source index proves the required order.
- `AMBIGUOUS_VIRTUAL_FK`: direct-name matching yields more than one compatible target in the schema.

Deterministic supplementary tags explain incomplete evidence:

- `MISSING_COMPONENTS`
- `TYPE_MISMATCH`
- `UNINDEXED`
- `INDEX_ORDER_MISMATCH`

If every candidate component exists but no supporting index exists, the result is `PARTIAL_VIRTUAL_FK [UNINDEXED]`. Direct PK-name matches are accepted only when schema-wide comparison produces one compatible target. Multiple compatible targets remain visible as one ambiguous result with the candidate targets listed; the analyzer never chooses one arbitrarily.

Virtual detection is enabled by default for both inbound and outbound views. `--physical-only` disables all virtual inference while retaining the same physical-relation and index analysis.

## Cardinality Modes

`metadata` reports the target `TABLE_ROWS` estimate and relevant index cardinalities without scanning application tables.

`exact` adds one exact row count for the target table and compares it with `TABLE_ROWS`. It does not execute `COUNT(DISTINCT ...)` for every relationship column and does not count every related table. Exact per-column analysis remains the responsibility of `mysql/estimations/check_cardinality.sh`.

Partial or ambiguous virtual findings are diagnostic results, not execution failures.

## Terminal Presentation

The terminal report contains these ordered sections:

1. Target identity and `SHOW CREATE TABLE`.
2. Physical outbound relationships.
3. Physical inbound relationships.
4. Complete virtual relationships.
5. Partial and ambiguous virtual relationships.
6. Supporting-index coverage.
7. Metadata or exact row comparison.
8. Optional dependency tree.

Relation rows are sorted stably by direction, classification, table, and constraint. Composite columns are rendered as ordered tuples.

Table widths are calculated from ANSI-free values. Escape sequences are emitted outside padded fields and never contribute to geometry. Terminal width follows the established `check_cardinality.sh` precedence and accepts an explicit `--terminal-width` value from 120 through 10000 columns. Automatic detection uses the active TTY and falls back to 120. Long source tuples, target tuples, and details wrap onto aligned continuation rows instead of truncating identifiers.

## Tree View and Semantic Colors

`--tree` appends a topology tree; it does not replace the aligned tables. The target table is the root. Stable branches separate physical and virtual outbound relationships from physical and virtual inbound relationships. Composite tuples, classification labels, and supplementary tags remain visible. Ambiguous relationships list every compatible target.

The same classification has the same semantic color in tables and the tree:

- target/root: bold yellow;
- `PHYSICAL_FK`: cyan;
- `COMPLETE_VIRTUAL_FK`: green;
- `PARTIAL_VIRTUAL_FK`: yellow;
- `AMBIGUOUS_VIRTUAL_FK`: magenta;
- type mismatches, missing targets, and execution errors: red;
- constraint and index names: blue;
- tree connectors: dim cyan;
- supplementary tags: their severity color.

Column tuples use the terminal default color to preserve readability. `--no-color` removes ANSI only; labels, connectors, indentation, and alignment remain identical.

## Machine-Readable Reports

`--output-file` publishes a CSV or TSV report through a same-directory temporary file followed by an atomic rename. Existing destinations remain unchanged after query, conversion, or interruption failures. Reports never contain ANSI or terminal wrapping.

The stable relation schema is:

```text
Direction
Classification
Source_Schema
Source_Table
Source_Columns
Target_Schema
Target_Table
Target_Columns
Constraint_Name
Supporting_Index
Status_Tags
Details
```

The DDL is intentionally excluded because it is multiline and does not belong in the relation-row model. It remains available in terminal output.

## Errors and Exit Status

- `0`: the requested analysis completed, including when partial or ambiguous virtual relations were found.
- `2`: command-line or input validation failed.
- `3`: the client, connection, target preflight, or report publication failed globally.
- `4`: an optional analysis section failed while other sections remained usable.
- `129`: `SIGHUP` interrupted execution.
- `130`: `SIGINT` or `SIGTERM` interrupted execution.

Server diagnostics are reduced to one ANSI-free, length-bounded line. A failed optional view is rendered as degraded and does not erase successful sections. Temporary resources are removed on normal exit and signals.

## Verification

A deterministic fake MySQL client and Bash test suite cover:

- no-argument help, explicit help, TTY colors, and `--no-color`;
- short and long parsing, validation, identifier encoding, and client selection;
- simple and composite physical foreign keys;
- complete, partial, ambiguous, and type-incompatible virtual relations;
- `id`, `<table>_id`, custom PK names, and composite PKs;
- correct, absent, and incorrectly ordered supporting indexes;
- physical/virtual duplicate suppression;
- metadata behavior and exact-production guards;
- independent degraded sections and deterministic exit codes;
- aligned colored tables, multiline wrapping, terminal-width precedence, and ANSI-free geometry parity;
- semantic tree colors and identical stripped tree structure;
- plain CSV/TSV output and atomic destination preservation;
- absence of modifying SQL;
- Bash 3.2 compatibility on macOS and Linux-oriented syntax checks.

Repository verification also runs all existing maintained MySQL analysis, estimation, transaction-monitor, and ProxySQL shell suites. Scope checks prove that `fk_analyzer.v2.sh` is unchanged.
