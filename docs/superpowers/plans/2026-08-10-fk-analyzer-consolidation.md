# MySQL Foreign Key Analyzer Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one maintained Bash analyzer that reports physical and inferred virtual MySQL foreign keys, classifies composite mappings, renders aligned color-aware tables and trees, and publishes atomic relation reports.

**Architecture:** Replace only `mysql/analysis/fk_analyzer.sh` with a Bash 3.2-compatible, sourceable implementation. Set-based MySQL queries write normalized metadata files; deterministic AWK reducers build one 12-field relation stream consumed by terminal tables, the optional tree, and CSV/TSV exports. A fake MySQL client drives all behavior without a live server.

**Tech Stack:** Bash 3.2, POSIX AWK, MySQL 8.0/8.4 CLI, `information_schema`, BSD/GNU userland, ANSI SGR, shell regression tests.

## Global Constraints

- Keep `mysql/analysis/fk_analyzer.v2.sh` byte-for-byte unchanged; its SHA-256 before implementation is `d33d27dbe2b6a9f5e3f67085d9ebb87bb79cf41493e32105a2ec589a379ab62e`.
- Runtime code, help, diagnostics, test messages, and documentation are written in English.
- The maintained script uses `set -euo pipefail` and runs under macOS `/bin/bash` 3.2 and Linux Bash.
- Runtime dependencies are limited to the MySQL CLI and standard macOS/Linux shell utilities.
- The analyzer never executes DDL, DML, `ANALYZE TABLE`, configuration changes, or automatic remediation.
- Virtual detection is enabled by default; `--physical-only` disables it.
- Metadata analysis is allowed in production; exact cardinality in production requires `--allow-production`.
- Terminal tables and the tree retain identical visible geometry with and without ANSI colors.
- Reports are ANSI-free, unwrapped, and atomically published in the destination directory.
- Use `check_cardinality.sh` as the reference for help layout, TTY color handling, terminal-width precedence, and multiline alignment.

## File Structure

- Modify: `mysql/analysis/fk_analyzer.sh` — canonical CLI, MySQL acquisition, relation reduction, rendering, export, and cleanup.
- Create: `mysql/analysis/tests/fake_mysql_fk.sh` — deterministic tagged-query fake with physical, composite, ambiguous, error, exact, and interruption fixtures.
- Create: `mysql/analysis/tests/test_fk_analyzer.sh` — Bash 3.2 behavioral suite and TTY/alignment assertions.
- Create: `mysql/analysis/README.md` — operational contract, classification rules, safety, examples, and exit codes.
- Modify: `README.md` — maintained-tools link and local verification command.
- Do not modify: `mysql/analysis/fk_analyzer.v2.sh`.

The runtime remains one file because single-file deployment is an approved requirement. Tests and documentation are split by responsibility.

---

### Task 1: CLI, Help, Safety Validation, and Tagged Fake Client

**Files:**
- Modify: `mysql/analysis/fk_analyzer.sh`
- Create: `mysql/analysis/tests/fake_mysql_fk.sh`
- Create: `mysql/analysis/tests/test_fk_analyzer.sh`

**Interfaces:**
- Consumes: MySQL client path from `--mysql-bin`, `MYSQL_BIN`, or `PATH`, in that precedence order.
- Produces: `parse_arguments`, `validate_arguments`, `resolve_mysql_bin`, `sql_literal`, `quote_identifier`, `run_mysql_query`, and a signal-safe `WORK_DIR` used by every later task.
- Produces query markers: `fk-analyzer:connection`, `fk-analyzer:target`, `fk-analyzer:ddl`, `fk-analyzer:columns`, `fk-analyzer:pks`, `fk-analyzer:physical`, `fk-analyzer:indexes`, `fk-analyzer:stats`, and `fk-analyzer:exact`.

- [ ] **Step 1: Create the test harness and assert the CLI contract**

Create a strict-mode test with a temporary run directory, `fail`, `assert_contains`, `assert_not_contains`, `run_case`, and `assert_status` helpers. Add these exact behavioral cases:

```bash
run_case no_args
assert_status 0
assert_contains "$OUTPUT" 'MySQL Foreign Key Topology Analyzer'
assert_contains "$OUTPUT" 'Required options:'
assert_contains "$OUTPUT" 'Virtual relationship rules:'
assert_contains "$OUTPUT" 'Exit status:'
assert_contains "$OUTPUT" 'Examples:'

run_case help --help --no-color
assert_status 0
assert_not_contains "$OUTPUT" $'\033'

run_case missing_schema -l test -t orders --environment test
assert_status 2
assert_contains "$OUTPUT" '--schema is required.'

run_case bad_environment -l test -s sales -t orders --environment qa
assert_status 2

run_case exact_prod_guard -l test -s sales -t orders \
    --environment production --cardinality exact --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$OUTPUT" 'Exact cardinality in production requires --allow-production.'

run_case stray_allow -l test -s sales -t orders --environment test --allow-production
assert_status 2

run_case width_small -l test -s sales -t orders --environment test --terminal-width 119
assert_status 2

run_case missing_client -l test -s sales -t orders --environment test \
    --mysql-bin "$TMP/missing-mysql"
assert_status 3
```

Also assert both `--option=value` and `--option value`, legacy `-c` as metadata, unknown-option rejection, empty values, 64-character schema/table limits, trailing-space rejection, control-character rejection, and numeric overflow-safe terminal-width validation from 120 through 10000.

- [ ] **Step 2: Run the new suite and verify RED**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh
```

Expected: FAIL because the current script exits nonzero for help, has no long-option contract, no environment guard, and no fake-client override.

- [ ] **Step 3: Implement the strict-mode CLI foundation**

Replace global execution with sourceable functions and this entry guard:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

Initialize these exact defaults:

```bash
CARDINALITY_MODE=metadata
SHOW_TREE=false
PHYSICAL_ONLY=false
ALLOW_PRODUCTION=false
OUTPUT_FILE=""
OUTPUT_FORMAT=""
TERMINAL_WIDTH_OPTION=""
NO_COLOR=false
WORK_DIR=""
EXPORT_TEMP=""
FINAL_STATUS=0
```

Implement a custom `while [[ $# -gt 0 ]]` parser supporting all short and long forms from the design. `-c` consumes no value and sets `CARDINALITY_MODE=metadata`; `--cardinality` requires `metadata` or `exact`. Pre-scan arguments for `--no-color` so `--help --no-color` is colorless regardless of ordering.

Use these exit helpers:

```bash
cli_error() { printf 'ERROR: %s\nTry --help for usage.\n' "$1" >&2; exit 2; }
runtime_error() { local status=$1; shift; printf 'ERROR: %s\n' "$*" >&2; exit "$status"; }
```

Validate schema/table as 1-64 characters, reject control characters and trailing ASCII space, but do not impose an `[A-Za-z0-9_]` policy. Implement `sql_literal` with `od -An -tx1` and `quote_identifier` by doubling embedded backticks. Never concatenate raw schema/table values into string predicates.

Create the workspace with `mktemp -d "${TMPDIR:-/tmp}/fk-analyzer.XXXXXX"`, install `trap cleanup EXIT`, `trap 'exit 129' HUP`, and `trap 'exit 130' INT TERM`, and remove only paths matching that exact prefix.

- [ ] **Step 4: Create the tagged fake MySQL client**

Parse `-e`, `--execute`, `--batch`, `--table`, and `--database` arguments without evaluating them. Append each SQL string to `${FAKE_MYSQL_FK_LOG:?}`. Route on markers and `${FAKE_MYSQL_FK_MODE:-physical}`.

Use this stable TSV contract for later fixtures:

```text
columns:  schema table column ordinal column_type charset collation
pks:      schema table column pk_ordinal
physical: constraint source_schema source_table source_column target_schema target_table target_column fk_ordinal update_rule delete_rule
indexes:  schema table index_name non_unique seq_in_index column cardinality
stats:    table_rows
```

For `fk-analyzer:connection`, return `8.4.2<TAB>8589934592`. For `connection-failure`, write `access denied for configured login path` to stderr and exit 1. For `target`, return `orders<TAB>InnoDB`, or no row in `target-missing` mode. Return a two-column `SHOW CREATE TABLE` row for `ddl`.

- [ ] **Step 5: Add connection and target preflight**

Resolve the client, then execute:

```sql
SELECT /* fk-analyzer:connection */ VERSION(), @@innodb_buffer_pool_size;
```

The target marker queries `information_schema.TABLES` using hexadecimal literals and requires exactly one base-table row. Connection or target failure exits `3` before any topology query. Sanitize stderr into one ANSI-free, newline-free message capped at 240 characters.

- [ ] **Step 6: Run the focused suite and verify GREEN**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh
/bin/bash -n mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
```

Expected: PASS for the Task 1 CLI group and zero syntax errors.

- [ ] **Step 7: Commit the CLI foundation**

```bash
git add mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
git commit -m "refactor(mysql): standardize foreign key analyzer CLI"
```

---

### Task 2: Set-Based Metadata and Composite Physical Relations

**Files:**
- Modify: `mysql/analysis/fk_analyzer.sh`
- Modify: `mysql/analysis/tests/fake_mysql_fk.sh`
- Modify: `mysql/analysis/tests/test_fk_analyzer.sh`

**Interfaces:**
- Consumes: the Task 1 tagged-query runner and `WORK_DIR`.
- Produces: `columns.tsv`, `pks.tsv`, `physical-components.tsv`, `indexes.tsv`, `stats.tsv`, and `relations.tsv`.
- Produces normalized relation fields: `Direction`, `Classification`, `Source_Schema`, `Source_Table`, `Source_Columns`, `Target_Schema`, `Target_Table`, `Target_Columns`, `Constraint_Name`, `Supporting_Index`, `Status_Tags`, `Details`.

- [ ] **Step 1: Add failing physical-relation tests**

Extend the physical fake fixture with:

```text
fk_orders_customer  sales  orders          customer_id  sales  customers  id         1  RESTRICT  CASCADE
fk_items_order      sales  shipment_items  tenant_id    sales  orders     tenant_id  1  RESTRICT  CASCADE
fk_items_order      sales  shipment_items  order_id     sales  orders     order_id   2  RESTRICT  CASCADE
```

Add indexes whose leading columns support both constraints. Assert that one outbound simple row and one inbound composite row are emitted, the tuple is `(tenant_id, order_id)`, update/delete rules remain in `Details`, and the composite constraint appears only once.

Reducer assertions source `fk_analyzer.sh`, set `WORK_DIR`, `SCHEMA_NAME`, and `TABLE_NAME`, write the raw fixture files, call `build_physical_relations`, and inspect `relations.tsv` directly. This keeps relation-model tests independent from the Task 4 terminal renderer.

Assert the SQL log contains every set-based marker exactly once and contains none of `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `ANALYZE`, `KILL`, or `SET GLOBAL` as standalone SQL keywords.

- [ ] **Step 2: Run the physical tests and verify RED**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh physical
```

Expected: FAIL because the normalized physical relation stream does not exist.

- [ ] **Step 3: Implement set-based acquisition queries**

Write raw batch output to fixed workspace files. Query schema columns, ordered PK components, relevant physical FK components, complete schema index components, and target statistics once each. Use these joins for physical constraints:

```sql
FROM information_schema.KEY_COLUMN_USAGE AS kcu
JOIN information_schema.REFERENTIAL_CONSTRAINTS AS rc
  ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
 AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
 AND rc.TABLE_NAME = kcu.TABLE_NAME
WHERE kcu.CONSTRAINT_SCHEMA = ${SQL_SCHEMA_LITERAL}
  AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
  AND (kcu.TABLE_NAME = ${SQL_TABLE_LITERAL}
       OR kcu.REFERENCED_TABLE_NAME = ${SQL_TABLE_LITERAL})
ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
```

Do not use `GROUP_CONCAT`; preserve raw components so identifier length cannot truncate tuples at `group_concat_max_len`.

- [ ] **Step 4: Reduce physical components into normalized relations**

Implement `build_physical_relations` as one POSIX AWK reduction. Group by constraint schema/name/source/target, append columns in numeric FK ordinal order, find a source index whose leading ordered tuple matches the FK tuple, and emit exactly 12 tab-separated fields.

Use these values:

```text
Classification = PHYSICAL_FK
Status_Tags     = empty when indexed, UNINDEXED otherwise
Details         = "ON UPDATE " update_rule "; ON DELETE " delete_rule
Direction       = OUTBOUND when Source_Table is the selected table, otherwise INBOUND
```

Keep raw values ANSI-free. Rendering is not part of this reducer.

- [ ] **Step 5: Run focused and CLI tests**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh cli physical
```

Expected: PASS with one normalized row per constraint.

- [ ] **Step 6: Commit the physical engine**

```bash
git add mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
git commit -m "feat(mysql): analyze composite physical foreign keys"
```

---

### Task 3: Composite Virtual Inference, Ambiguity, and Duplicate Suppression

**Files:**
- Modify: `mysql/analysis/fk_analyzer.sh`
- Modify: `mysql/analysis/tests/fake_mysql_fk.sh`
- Modify: `mysql/analysis/tests/test_fk_analyzer.sh`

**Interfaces:**
- Consumes: raw `columns.tsv`, `pks.tsv`, `indexes.tsv`, and physical `relations.tsv` from Task 2.
- Produces: virtual rows appended to the same 12-field `relations.tsv` contract.
- Produces classifications `COMPLETE_VIRTUAL_FK`, `PARTIAL_VIRTUAL_FK`, and `AMBIGUOUS_VIRTUAL_FK` with deterministic tags.

- [ ] **Step 1: Add complete and partial composite fixtures**

In `composite` mode define target PK `orders(tenant_id, order_id)` plus these source tables:

```text
audit_orders:    orders_tenant_id BIGINT UNSIGNED, orders_order_id BIGINT UNSIGNED
legacy_orders:   orders_tenant_id BIGINT UNSIGNED
shuffled_orders: orders_tenant_id BIGINT UNSIGNED, orders_order_id BIGINT UNSIGNED
typed_orders:    orders_tenant_id BIGINT,          orders_order_id BIGINT UNSIGNED
```

Give `audit_orders` index `(orders_tenant_id, orders_order_id)`, no index to `legacy_orders`, reversed index order to `shuffled_orders`, and a nominally ordered index to `typed_orders`.

Assert:

```text
audit_orders    COMPLETE_VIRTUAL_FK
legacy_orders   PARTIAL_VIRTUAL_FK  MISSING_COMPONENTS,UNINDEXED
shuffled_orders PARTIAL_VIRTUAL_FK  INDEX_ORDER_MISMATCH
typed_orders    PARTIAL_VIRTUAL_FK  TYPE_MISMATCH
```

- [ ] **Step 2: Add naming and ambiguity fixtures**

Cover all approved rules:

```text
customers(id)            <- purchases.customers_id
countries(code)          <- addresses.code when countries(code) is the only compatible schema PK
countries(code)          <- addresses.countries_code
countries(code) and
currencies(code)         <- ledger.code, classified AMBIGUOUS_VIRTUAL_FK
customers(id)            <- source.id, which must produce no candidate
```

Add a physical constraint identical to one naming-derived candidate and assert only `PHYSICAL_FK` remains.

- [ ] **Step 3: Run virtual tests and verify RED**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh virtual
```

Expected: FAIL because Task 2 emits physical relations only.

- [ ] **Step 4: Implement the virtual inference reducer**

Implement `build_virtual_relations` as a deterministic AWK program reading the three metadata files plus physical relations. Build maps keyed by schema/table/ordinal and schema/table/column.

For each source/target table pair involving the selected table:

1. Require the first PK component to match exact PK name or `<target_table>_<pk_column>`.
2. Reject unqualified `id` as the first match.
3. For later components, prefer exact PK-column name, then the prefixed form.
4. Compare complete `COLUMN_TYPE`; for character types also compare charset and collation.
5. Test whether one source index begins with the mapped tuple in PK order.
6. If all columns exist and types match but no index exists, add `UNINDEXED`.
7. If the same columns exist in a different index order, add `INDEX_ORDER_MISMATCH` instead of `UNINDEXED`.
8. Add `MISSING_COMPONENTS` and `TYPE_MISMATCH` independently when applicable.
9. Suppress a candidate whose source and target tuples equal a physical row.

Build direct-name candidates schema-wide before emission. When more than one compatible target remains for a direct first-component match, emit one `AMBIGUOUS_VIRTUAL_FK` row whose `Details` lists candidate targets in lexical order. Never select the first metadata row.

Sort status tags in this fixed order:

```text
MISSING_COMPONENTS,TYPE_MISMATCH,UNINDEXED,INDEX_ORDER_MISMATCH
```

- [ ] **Step 5: Test physical-only and stable ordering**

Source the analyzer with the comprehensive raw fixture, set `PHYSICAL_ONLY=true`, run the relation builders, and assert no classification containing `VIRTUAL` appears in `relations.tsv`. With `PHYSICAL_ONLY=false`, run the reducers twice into separate files and compare them byte-for-byte to prove stable relation ordering.

- [ ] **Step 6: Run focused, physical, and CLI groups**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh cli physical virtual
```

Expected: PASS for every relation classification and no physical duplicate.

- [ ] **Step 7: Commit virtual inference**

```bash
git add mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
git commit -m "feat(mysql): infer composite virtual foreign keys"
```

---

### Task 4: Aligned Terminal Tables, Wrapping, and Semantic Tree

**Files:**
- Modify: `mysql/analysis/fk_analyzer.sh`
- Modify: `mysql/analysis/tests/test_fk_analyzer.sh`

**Interfaces:**
- Consumes: the normalized ANSI-free relation stream from Tasks 2-3.
- Produces: `detect_terminal_width`, `render_relation_tables`, `wrap_relation_fields`, `render_tree`, and semantic color constants shared by both views.
- Preserves: relation values and ordering; presentation never modifies `relations.tsv`.

- [ ] **Step 1: Add failing table geometry tests**

Run a fixture with long composite tuples at `--terminal-width 120`, `160`, and `220`. Strip ANSI with the same POSIX AWK expression used by `test_check_cardinality.sh` and assert:

- every table line is no wider than the selected width;
- separators and data rows have equal visible widths;
- continuation rows keep fixed columns blank and wrap only source tuple, target tuple, and details;
- identifiers are present after concatenating continuation rows;
- colored and `--no-color` output have byte-identical stripped table sections.

Add width-source tests for explicit option, `COLUMNS`, active `stty size`, invalid candidates, redirected stdin, and 120-column fallback. Copy the Darwin/GNU `script` invocation branches into this test file; do not source another suite.

- [ ] **Step 2: Add failing semantic tree tests**

Invoke `--tree` with a fixture containing every classification. Assert branch order is:

```text
OUTBOUND PHYSICAL
OUTBOUND VIRTUAL
INBOUND PHYSICAL
INBOUND VIRTUAL
```

Assert composite tuples and every tag remain visible. Capture a TTY run and verify SGR colors by semantic label: cyan physical, green complete, yellow partial, magenta ambiguous, red mismatch/error, blue constraint/index, bold yellow root, and dim cyan connectors. Strip ANSI and compare the entire tree with `--no-color`; indentation and connectors must match exactly.

- [ ] **Step 3: Run presentation tests and verify RED**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh presentation tree
```

Expected: FAIL because output is not yet width-aware and no semantic tree renderer exists.

- [ ] **Step 4: Implement terminal-width detection and wrapping**

Port the proven precedence from `check_cardinality.sh`:

1. validated `--terminal-width`;
2. integer `COLUMNS` in range;
3. active controlling-TTY `stty size` result;
4. active TTY `tput cols` result;
5. `120` fallback.

Allocate fixed widths for direction, classification, and status first. Divide remaining space between source tuple, target tuple, and details with documented minimum widths. Implement a POSIX AWK word/identifier-boundary wrapper that hard-splits an individual token only when it exceeds its column width.

Emit ANSI before each padded field and reset after it:

```bash
printf '%s%-*s%s' "$field_color" "$field_width" "$field_value" "$COLOR_RESET"
```

Never pad a string that already contains ANSI.

- [ ] **Step 5: Implement the tree from normalized relations**

Group stable sorted rows into the four fixed branches. Calculate `├──` versus `└──` from raw group counts before adding colors. Render the root in bold yellow, connectors in dim cyan, classifications with shared semantic constants, constraint/index names in blue, and mismatch tags in red. Use terminal-default color for tuples.

`--tree` appends after tables. Empty branches render one dim `None` child. `--no-color` changes only color variables.

- [ ] **Step 6: Run presentation plus relation tests**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh \
    cli physical virtual presentation tree
```

Expected: PASS with identical stripped geometry across color modes.

- [ ] **Step 7: Commit presentation**

```bash
git add mysql/analysis/fk_analyzer.sh mysql/analysis/tests/test_fk_analyzer.sh
git commit -m "feat(mysql): render aligned foreign key topology"
```

---

### Task 5: Cardinality Modes, Degraded Sections, and Atomic Reports

**Files:**
- Modify: `mysql/analysis/fk_analyzer.sh`
- Modify: `mysql/analysis/tests/fake_mysql_fk.sh`
- Modify: `mysql/analysis/tests/test_fk_analyzer.sh`

**Interfaces:**
- Consumes: Task 1 CLI modes, Task 2 statistics file, and the shared relation stream.
- Produces: guarded exact comparison, optional-section exit `4`, and atomic CSV/TSV with the 12 stable headers.

- [ ] **Step 1: Add failing cardinality and safety tests**

Assert metadata mode queries `information_schema.TABLES` and `STATISTICS` but never logs `fk-analyzer:exact` or `COUNT(` against an application table. Assert exact mode logs exactly one query:

```sql
SELECT /* fk-analyzer:exact */ COUNT(*) FROM `sales`.`orders`;
```

Execute exact in development without an extra flag, reject exact production without `--allow-production`, and accept it with the flag. Display estimated rows, exact rows, absolute difference, and percentage drift. Do not execute `COUNT(DISTINCT ...)`.

- [ ] **Step 2: Add failing degraded-section tests**

Make `physical-failure`, `virtual-metadata-failure`, and `stats-failure` fail only their tagged query. Assert usable sections still render, one sanitized degraded message appears, and final status is `4`. Connection, target preflight, and DDL failure remain global status `3` because the selected target cannot be represented reliably.

- [ ] **Step 3: Add failing report and interruption tests**

Create CSV and inferred `.tsv` reports and assert these exact headers:

```text
Direction,Classification,Source_Schema,Source_Table,Source_Columns,Target_Schema,Target_Table,Target_Columns,Constraint_Name,Supporting_Index,Status_Tags,Details
```

Assert CSV doubles embedded quotes, TSV retains MySQL batch escaping, neither format contains ANSI or wrapped lines, and report row order equals terminal relation order.

Run the same comprehensive fixture twice and compare the two TSV reports byte-for-byte, extending the Task 3 reducer-order check through the public report interface.

Pre-create a destination containing `ORIGINAL`. In `report-failure` and `slow-report` plus `TERM` modes, assert the destination is unchanged, no `.fk-analyzer.*` file remains, and interruption returns `130`.

- [ ] **Step 4: Run Task 5 tests and verify RED**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh cardinality degraded export signals
```

Expected: FAIL because exact execution, degraded views, and report publication are not implemented.

- [ ] **Step 5: Implement guarded cardinality and degraded status**

Keep metadata as the default. Execute exact only after full validation and production guard evaluation. Calculate drift with AWK decimal arithmetic; handle exact zero without division. Mark an optional acquisition failure in `FINAL_STATUS=4` and continue with available files. A later optional failure must not overwrite an existing nonzero status.

- [ ] **Step 6: Implement atomic CSV/TSV publication**

Create `EXPORT_TEMP` with:

```bash
EXPORT_TEMP=$(mktemp "$(dirname "$OUTPUT_FILE")/.fk-analyzer.XXXXXX") \
    || runtime_error 3 "Unable to create a temporary report."
```

Write the fixed header and normalized rows. For CSV, quote every field and replace `"` with `""` in POSIX AWK. For TSV, copy the normalized escaped representation. Publish with `mv -f` only after conversion succeeds, then clear `EXPORT_TEMP`. Cleanup removes an unpublished temporary file on all exits and signals.

- [ ] **Step 7: Run the complete focused suite**

Run:

```bash
/bin/bash mysql/analysis/tests/test_fk_analyzer.sh
/bin/bash -n mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
```

Expected: all FK analyzer groups pass and syntax validation exits `0`.

- [ ] **Step 8: Commit cardinality and reports**

```bash
git add mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
git commit -m "feat(mysql): add guarded foreign key reports"
```

---

### Task 6: Documentation, Cross-Suite Verification, and Scope Audit

**Files:**
- Create: `mysql/analysis/README.md`
- Modify: `README.md`
- Verify unchanged: `mysql/analysis/fk_analyzer.v2.sh`

**Interfaces:**
- Consumes: the final CLI, classifications, colors, report schema, and exit codes.
- Produces: operational documentation and repository navigation for the maintained analyzer.

- [ ] **Step 1: Write analysis documentation**

Document in `mysql/analysis/README.md`:

- physical, complete virtual, partial virtual, and ambiguous classifications;
- exact naming rules and the unqualified-`id` exclusion;
- composite PK and supporting-index order requirements;
- semantic table/tree colors and `--no-color` parity;
- metadata versus exact cardinality and production guard;
- every CLI option and exit code;
- CSV/TSV schema and atomic behavior;
- examples for normal, tree, physical-only, exact non-production, exact production, and report execution;
- explicit statement that virtual relations are heuristic findings, never actual constraints.

Add the analyzer to the root maintained-tools table and add:

```bash
bash mysql/analysis/tests/test_fk_analyzer.sh
```

to local verification.

- [ ] **Step 2: Run the new suite with macOS system Bash**

Run:

```bash
PATH=/bin:/usr/bin /bin/bash mysql/analysis/tests/test_fk_analyzer.sh
```

Expected: all groups pass under Bash 3.2 with no Homebrew-only utility dependency.

- [ ] **Step 3: Run maintained shell regressions**

Run each command independently and require exit `0`:

```bash
/bin/bash mysql/estimations/tests/test_check_cardinality.sh
/bin/bash mysql/estimations/tests/test_analyze_prefix_index.sh
/bin/bash mysql/estimations/tests/test_estimate_storage.sh
/bin/bash mysql/trx/tests/test_mysql_trx_monitor.sh
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: cardinality reports `39 passed, 0 failed`; every other suite prints its PASS summary.

- [ ] **Step 4: Verify syntax, whitespace, read-only SQL, and protected file hash**

Run:

```bash
/bin/bash -n mysql/analysis/fk_analyzer.sh \
    mysql/analysis/tests/fake_mysql_fk.sh \
    mysql/analysis/tests/test_fk_analyzer.sh
git diff --check
shasum -a 256 mysql/analysis/fk_analyzer.v2.sh
```

Expected: syntax and whitespace checks exit `0`; the hash remains `d33d27dbe2b6a9f5e3f67085d9ebb87bb79cf41493e32105a2ec589a379ab62e`. The focused suite's captured-SQL assertion proves that no modifying statement was issued.

- [ ] **Step 5: Audit changed paths against the approved baseline**

Run:

```bash
git diff --name-only c869c65...HEAD
git status --short
```

Expected runtime/documentation paths are limited to:

```text
README.md
mysql/analysis/README.md
mysql/analysis/fk_analyzer.sh
mysql/analysis/tests/fake_mysql_fk.sh
mysql/analysis/tests/test_fk_analyzer.sh
```

The design and plan documents may also appear as documentation commits. No other legacy analyzer or maintained tool may be modified.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md mysql/analysis/README.md
git commit -m "docs(mysql): document foreign key topology analyzer"
```

- [ ] **Step 7: Request code review and resolve only verified findings**

Review the complete diff against `docs/superpowers/specs/2026-08-10-fk-analyzer-consolidation-design.md`. Verify MySQL 8.0/8.4 `information_schema` column semantics, composite tuple grouping, inference ambiguity, Bash 3.2 behavior, signal cleanup, and ANSI-free geometry. Add a failing regression before any behavioral fix, rerun the focused suite, then repeat Steps 2-5 after the last change.

- [ ] **Step 8: Publish only after user approval**

Show the exact changed-file list, commit list, test results, and remaining heuristic limitations. After explicit approval, push the current `main` branch without force.
