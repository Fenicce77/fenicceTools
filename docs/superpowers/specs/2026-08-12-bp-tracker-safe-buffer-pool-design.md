# Buffer Pool Tracker Safe Monitoring Design

## Objective

Refactor `mysql/monitoring/bp_tracker.sh` into a safe-by-default Buffer Pool
monitor for MySQL 8.0 and 8.4. The default dashboard must query only global,
low-risk Buffer Pool telemetry. Expensive per-object residency and session
activity views become explicit opt-in sections.

## Command-Line Contract

- `-l, --login-path NAME` is mandatory; no implicit `default` login path exists.
- `-i, --interval SECONDS` is a positive integer, defaulting to 10.
- `-o, --output-file FILE` records plain text snapshots.
- `--top-objects [COUNT]` enables the expensive per-table residency section;
  omitted count defaults to 10 and valid counts are 1 through 100.
- `--active-sessions [COUNT]` enables the session-correlation section;
  omitted count defaults to 5 and valid counts are 1 through 100.
- `--object-filter TEXT` and `--user-filter TEXT` apply only to their respective
  opt-in section. They are literal substring filters, not SQL patterns.
- `--no-color` disables styling without disabling refresh in eligible terminals.

## Terminal and Execution Contract

- Colors require stdout TTY, a non-empty non-`dumb` `TERM`, and no `--no-color`.
- Home-and-clear redraw requires stdout TTY and usable `TERM`, independently of
  the color choice.
- Redirected stdout, `TERM=dumb`, errors, help, and logs contain no ANSI bytes.
- Interactive TTY mode refreshes continuously and accepts `m` and `q`.
- Non-TTY mode renders one snapshot then exits successfully; it never enters an
  uncontrolled timed read loop.

## Query Safety and Semantics

### Default global telemetry

The default query aggregates all rows in
`INFORMATION_SCHEMA.INNODB_BUFFER_POOL_STATS`. It retrieves total/free/data/
dirty pages, dirty percentage, and `PAGES_READ_RATE`. It also retrieves the
monotonic `PAGES_MADE_YOUNG` and `PAGES_NOT_MADE_YOUNG` counters for local
delta-rate computation.

The first sample shows unavailable delta rates. Later samples divide nonnegative
counter deltas by elapsed wall-clock seconds. A counter decrease, including a
server restart, resets the baseline and reports unavailable rates for that
sample. `PAGES_READ_RATE` remains server-provided read I/O telemetry; young and
non-young movements are never labelled as evictions or churn.

Read I/O is red over 5000 pages/s, yellow from 1 through 5000, and normal at
zero. The dashboard labels this section `BUFFER POOL ACTIVITY`.

### Optional top objects

`--top-objects` queries `sys.innodb_buffer_stats_by_table`, which summarizes
`INFORMATION_SCHEMA.INNODB_BUFFER_PAGE`. MySQL documents this path as potentially
performance-affecting, so it is not enabled by default. The script runs it no
more often than once every 60 seconds regardless of dashboard interval; interim
frames preserve the last successful result and show its sample time. Errors or
insufficient privileges render `TOP OBJECTS UNAVAILABLE` and leave global
telemetry running.

### Optional active sessions

`--active-sessions` queries `sys.session` for connection correlation only. It
returns user, elapsed time, state, and a 64-character statement prefix on screen.
The statement prefix is not written to the output file. Errors or unavailable
instrumentation render `ACTIVE USER SESSIONS UNAVAILABLE` without stopping global
telemetry.

### Literals and privilege failures

All user-provided filter text is converted to a UTF-8 hex literal and escaped
for `LIKE` so `%`, `_`, and `\\` are literal characters. The monitor never
interpolates the raw filter into SQL. Each optional query captures errors and
reports a plain diagnostic in the relevant section; global telemetry remains
available whenever its query succeeds.

## Logging and Tests

Logs contain no ANSI or clear sequences. They record global Buffer Pool metrics,
optional top-object data, and session metadata without query text. A fake MySQL
client test suite covers CLI validation, ANSI and pseudo-TTY contract, exact SQL
shape/escaping, multi-instance aggregation, delta/reset calculation, optional
sampling cadence, degradation, and plain logs.
