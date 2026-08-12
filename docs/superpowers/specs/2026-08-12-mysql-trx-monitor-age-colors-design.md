# MySQL Transaction Monitor Age-Color Design

## Objective

Make long-running transactions and lock waits immediately distinguishable in
the interactive terminal view of `mysql/trx/mysql_trx_monitor.sh` without
changing its SQL, filtering, logging, or safety behavior.

## Scope

The change applies only to terminal rendering of rows in these sections:

- `TRANSACTIONS`, using the `AGE_S` column (field 5).
- `LOCK WAITS`, using the `WAIT_S` column (field 6).

The renderer will color the complete data row, not merely the duration cell:

| Duration | Terminal color |
| --- | --- |
| `< 60` seconds | Terminal default |
| `60–119` seconds | Yellow |
| `120–299` seconds | Orange (`ANSI 256-color 208`) when available; yellow fallback otherwise |
| `>= 300` seconds | Red |

Rows with malformed or non-numeric duration fields remain terminal-default.
Headers, snapshot title, unavailable diagnostics, and successful kill output
retain their existing semantic colors.

## Output and compatibility contract

Colorization is enabled only when the existing color eligibility contract is
true: stdout is a TTY, `TERM` is not `dumb`, and `--no-color` is absent.

`--no-color`, `--smoke-test` with redirected stdout, snapshot logs, and all
other non-TTY output remain ANSI-free. ANSI decoration is applied only at the
terminal display boundary; the raw snapshot text continues to feed logging
unchanged.

The interactive screen refresh remains independent of color eligibility:
`--no-color` still redraws an eligible TTY, but it does not apply row colors.

## Implementation shape

1. Extend color initialization with age-severity color variables, including a
   portable fallback for terminals that do not advertise 256 colors.
2. Add a small display-only row-color selector that receives the current
   section and the tab-separated row, extracts the documented duration field,
   and wraps the full line only when it meets a threshold.
3. Keep `render_snapshot` and `append_snapshot` unchanged so logs and
   redirected output stay raw and parser-safe.
4. Add pseudo-TTY behavioral tests covering all duration bands for both
   sections, the 256-color and fallback paths, complete-row decoration, and
   parity with `--no-color`/logging output.

## Verification

Run the transaction-monitor shell suite and Bash syntax checks. The tests must
invoke the public script through its fake MySQL client and assert emitted
terminal bytes and ANSI-free artifacts; they must not assert source text.
