# MySQL Foreign Key Topology Analyzer

`fk_analyzer.sh` is the maintained, read-only topology analyzer for MySQL 8.0
and 8.4. It is compatible with Bash 3.2 on macOS and Linux. It uses a MySQL
login path to examine one target table and its schema metadata.

It reports actual constraints and heuristic virtual relationships. **A virtual
relationship is a diagnostic finding, never an actual MySQL constraint.** The
tool does not create, alter, repair, or remove constraints or indexes.

## Usage

```bash
bash mysql/analysis/fk_analyzer.sh \\
  --login-path reporting \\
  --schema sales \\
  --table orders \\
  --environment test [options]
```

Required options:

| Option | Description |
|---|---|
| `-l`, `--login-path NAME` | MySQL login path passed to the client. |
| `-s`, `--schema NAME` | Target schema; identifier length and control characters are validated. |
| `-t`, `--table NAME` | Target table; identifier length and control characters are validated. |
| `--environment development\|test\|staging\|production` | Required operational context. |

Analysis options:

| Option | Description |
|---|---|
| `-r`, `--tree` | Append a dependency tree after the aligned relation tables. |
| `-c` | Compatibility alias for `--cardinality metadata`. |
| `--cardinality metadata\|exact` | Use `TABLE_ROWS` metadata (default), or add one exact `COUNT(*)` for the target table. |
| `--physical-only` | Disable virtual inference; physical constraints and their index analysis remain enabled. |
| `--allow-production` | Required only with `--environment production --cardinality exact`; rejected otherwise. |

Output and client options:

| Option | Description |
|---|---|
| `--output-file FILE` | Atomically publish a relation report to `FILE`. |
| `--format csv\|tsv` | Select report format. Without it, `.tsv`/`.TSV` selects TSV; all other names select CSV. |
| `--terminal-width COLUMNS` | Render at a width from 120 through 10000 columns. |
| `--mysql-bin PATH` | Use an explicit MySQL client executable. |
| `--no-color` | Suppress ANSI sequences without changing text, wrapping, connectors, indentation, or alignment. |
| `-h`, `--help` | Print complete command help. No arguments also print help. |

## Relationship classification

Physical constraints take precedence over inferred candidates with identical
source and target tuples.

| Classification | Meaning |
|---|---|
| `PHYSICAL_FK` | A declared MySQL foreign-key constraint, emitted as one ordered tuple per constraint. |
| `COMPLETE_VIRTUAL_FK` | An inferred relation whose complete target PK tuple is type-compatible and is the ordered leading prefix of a source index. |
| `PARTIAL_VIRTUAL_FK` | The first PK component has evidence, but a later one is missing/incompatible or index evidence is absent or incorrectly ordered. |
| `AMBIGUOUS_VIRTUAL_FK` | Direct PK-name matching finds more than one compatible target; every candidate is listed and none is selected. |

For a target primary key `(pk1, pk2, ...)`, a source component must be either
the exact PK name or `<target_table>_<target_pk_column>`. The first component
is minimum candidate evidence; remaining components are evaluated in PK order.
A source column named only `id` never starts a virtual relationship. A target
PK named `id` therefore needs `<target_table>_id` as the first mapped column.

Composite source tuples follow primary-key order. A complete virtual relation
requires a source index whose **leading columns** reproduce that tuple in the
same order; physical column ordinal position is not a replacement for index
order. Compatibility uses complete `COLUMN_TYPE`; character columns also need
compatible character set and collation.

| Tag | Meaning |
|---|---|
| `MISSING_COMPONENTS` | One or more later PK components are absent. |
| `TYPE_MISMATCH` | A mapped component is not type-compatible. |
| `UNINDEXED` | No supporting source index proves the tuple prefix. |
| `INDEX_ORDER_MISMATCH` | Columns occur in an index but not as the required ordered leading prefix. |

## Output, colors, and cardinality

Colors are active only on an eligible stdout TTY (`TERM` is not `dumb`). In
both tables and the optional tree, target/root is bold yellow;
`PHYSICAL_FK` cyan; `COMPLETE_VIRTUAL_FK` green; `PARTIAL_VIRTUAL_FK` yellow;
`AMBIGUOUS_VIRTUAL_FK` magenta; errors plus missing/type evidence red;
constraint/index names blue; and connectors dim cyan. `--no-color` removes
ANSI only, preserving identical visible geometry.

The terminal report presents these sections in order: physical outbound,
physical inbound, complete virtual relationships, partial and ambiguous virtual
relationships, supporting-index coverage, and cardinality. The supporting-index
coverage section reports the relevant `STATISTICS.CARDINALITY` estimate for the
index prefix matching each relation tuple. It is metadata, not an exact
distinct-value count; unavailable index metadata is shown explicitly.

The target identity block prints the selected `--environment`. If physical
metadata is unavailable, virtual inference is suppressed because physical
precedence cannot be established. If index metadata is unavailable, the
analyzer suppresses index-dependent tags and virtual classifications rather
than converting missing evidence into `UNINDEXED` or index-order facts. Each
affected terminal section is marked explicitly as unavailable.

`metadata` reports the target `information_schema.TABLES.TABLE_ROWS` estimate
and relevant `information_schema.STATISTICS.CARDINALITY`, without scanning
application tables. `exact` adds one target-only `COUNT(*)` and compares it
with `TABLE_ROWS`; it never runs per-relation or per-column exact counts.
Metadata is permitted in production. Exact production cardinality requires
both `--environment production` and `--allow-production`.

The runtime uses metadata reads, `SHOW CREATE TABLE`, and the optional exact
target count. It issues no DDL, DML, `ANALYZE`, configuration changes, or
automatic remediation. MySQL client processes are tracked and reaped during
normal execution and analyzer-only signal cleanup; cleanup sends `TERM`, waits
for a bounded interval, then escalates to `KILL` if required.

## CSV and TSV reports

`--output-file` writes an ANSI-free report to a same-directory temporary file,
then renames it after conversion succeeds. Query, conversion, and interruption
failures preserve an existing destination. Reports use the normalized relation
stream and exclude terminal wrapping and multiline DDL.

The stable column order is:

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

## Exit status

| Status | Meaning |
|---:|---|
| `0` | Analysis completed; partial and ambiguous virtual findings are not failures. |
| `2` | Command-line or input validation failure. |
| `3` | Client, connection, target preflight, required reducer/rendering pipeline, or report-publication failure. |
| `4` | An optional section degraded while other analysis remained usable. |
| `129` | Interrupted by `SIGHUP`. |
| `130` | Interrupted by `SIGINT` or `SIGTERM`. |

## Examples

Normal metadata analysis:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l reporting -s sales -t orders --environment test
```

Append the topology tree:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l reporting -s sales -t orders --environment staging --tree
```

Inspect physical constraints only:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l reporting -s sales -t orders --environment test --physical-only --no-color
```

Run exact cardinality outside production:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l reporting -s sales -t orders --environment development --cardinality exact
```

Run guarded exact cardinality in production:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l production -s sales -t orders --environment production \\
  --cardinality exact --allow-production
```

Publish a TSV report atomically:

```bash
bash mysql/analysis/fk_analyzer.sh \\
  -l reporting -s sales -t orders --environment test \\
  --output-file /tmp/orders-fk-topology.tsv --format tsv --no-color
```

## Verification

```bash
PATH=/bin:/usr/bin /bin/bash mysql/analysis/tests/test_fk_analyzer.sh
```
