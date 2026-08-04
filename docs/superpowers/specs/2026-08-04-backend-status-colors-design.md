# Backend Status Color Semantics Design

## Goal

Correct backend and ping-row health coloring in the Bash, Python, and Go ProxySQL monitors while preserving their current queries, refresh cadence, process model, and clean logging.

## Root Cause

The Python and Go formatters currently color a backend green only when `status` is `ONLINE` and cumulative `ConnERR` is zero. ProxySQL defines `ConnERR` as the total number of failed connection attempts, so a currently healthy backend remains red after any historical failure.

All three implementations also treat the MySQL client's textual representation of SQL `NULL` in `ping_error` as an actual error. ProxySQL defines `ping_error=NULL` as a successful ping.

## Backend Pool Color Contract

The normalized backend status is the trimmed uppercase status returned by `stats_mysql_connection_pool`. The entire backend row uses this exact mapping:

| Status | Color | ANSI representation |
|---|---|---|
| `ONLINE` | Bold green | Existing green sequence |
| `SHUNNED` | Bold yellow | Existing yellow sequence |
| `OFFLINE_SOFT` | Bold orange | ANSI 256-color index `208`: `\033[1;38;5;208m` |
| `OFFLINE_HARD` | Bold red | Existing red sequence |
| Any unrecognized status | Bold red | Existing red sequence |

`ConnERR` remains visible as a cumulative diagnostic counter but has no effect on row color.

The orange sequence is identical in Bash, Python, and Go. It is supported by modern macOS and Linux terminals advertising 256-color capability and degrades to the terminal's nearest available palette color.

## Ping Color Contract

`ping_error` is evaluated after trimming whitespace and comparing case-insensitively:

- Empty and textual `NULL` mean success and produce a green row.
- Any other value is an actual error and produces a red row.

The displayed error text remains unchanged. Successful rows that currently display `NULL` continue to display `NULL`; only their health color changes.

## Implementation Boundaries

Each implementation owns a small deterministic color-selection function at its formatter layer:

- Bash AWK maps normalized status to the injected color variables and evaluates `ping_error` with the success rule.
- Python maps status in `format_backend` and evaluates the existing `PingRow.error` without changing the model or query.
- Go maps status in `FormatBackend` and evaluates the existing `PingRow.Error` without changing the model or query.

No SQL, transport, terminal lifecycle, interactive key, output-column, or row-count behavior changes.

## Logging

Clean output remains ANSI-free. The same status and ping text is emitted into clean/log output; only the colored terminal representation changes.

## Testing

Regression tests cover, independently in Bash, Python, and Go:

- `ONLINE` with nonzero cumulative `ConnERR` is green.
- `SHUNNED` is yellow.
- `OFFLINE_SOFT` is ANSI 256-color orange `208`.
- `OFFLINE_HARD` is red.
- An unknown status is red.
- A successful numeric ping with `ping_error=NULL` is green.
- A successful numeric ping with an empty error is green.
- A ping containing a real error is red.
- Clean output contains no ANSI sequences.

The complete Bash, Python, and Go test suites run after the focused RED/GREEN cycles. Go additionally runs the race detector, `go vet`, Darwin arm64 and Linux amd64 cross-builds, and rebuilds the tracked Darwin arm64 executable.

Live PTY verification uses `devel-proxysql01-node01` and confirms that current `ONLINE` rows and successful `NULL` ping rows are green without affecting refresh or key handling.

## Non-Goals

- Resetting or calculating deltas for `ConnERR`.
- Adding warning thresholds based on historical counters.
- Changing backend status values or ProxySQL configuration.
- Adding truecolor detection or launching extra terminal-capability processes.
- Changing the displayed `ping_error` text.

## Acceptance Criteria

- All three monitors implement the approved status-color mapping.
- Historical `ConnERR` values no longer create false red health rows.
- Successful `NULL` ping rows are green and real ping errors remain red.
- ANSI-free logs, queries, resource usage, and interactive behavior remain unchanged.
- Focused, full-suite, static, cross-build, and live verification pass.
