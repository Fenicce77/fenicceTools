# ProxySQL Monitor Python Port Design

## Objective

Create an idiomatic Python implementation of the ProxySQL Ultimate Monitor in
`mysql/proxysql/python/`. The Python port must preserve the behavior and
resource-efficiency contract of
`mysql/proxysql/proxysql_connections_monitor.sh` while providing modular,
typed, independently testable components.

The initial port retains the existing single-view interface and `v` key
navigation. A simultaneous four-panel dashboard is explicitly deferred to a
separate design after the parity port has been measured and validated.

## Runtime and Compatibility

- Python 3.9 or newer.
- macOS and Linux.
- Python standard library only.
- External MySQL command-line client available as `mysql`.
- ProxySQL credentials resolved exclusively through
  `mysql_config_editor --login-path`.
- No password, DSN, or clear-text credential flags.
- All code comments, documentation, help, logs, and messages in English.

The implementation must run without installation:

```text
python3 mysql/proxysql/python/proxysql_connections_monitor.py --login-path=NAME
```

## File Structure

```text
mysql/proxysql/python/
├── README.md
├── proxysql_connections_monitor.py
├── proxysql_monitor/
│   ├── __init__.py
│   ├── __main__.py
│   ├── app.py
│   ├── cli.py
│   ├── formatter.py
│   ├── models.py
│   ├── queries.py
│   ├── terminal.py
│   └── transport.py
└── tests/
    ├── __init__.py
    ├── fake_mysql.py
    ├── fixtures.py
    ├── test_app.py
    ├── test_cli.py
    ├── test_formatter.py
    ├── test_live_smoke.py
    ├── test_terminal.py
    └── test_transport.py
```

`proxysql_connections_monitor.py` is a thin install-free launcher.
`proxysql_monitor.__main__` supports `python3 -m proxysql_monitor`. Production
logic remains inside the package modules.

## Command-Line Contract

Normal interactive mode preserves these options:

```text
--login-path=NAME
-r, --refresh-time=SECONDS
-u, --user-filter=VALUE
-t, --threshold=COUNT
-o, --output-file=PATH
-h, --help
```

Defaults remain:

- Refresh time: `5`.
- User filter: disabled.
- Connection threshold: `0`, disabled.
- Initial view: CONN.
- Initial CONN sort: connection count descending.
- Query-response timeout: five seconds.

`--refresh-time` accepts positive integer and decimal values. `--threshold`
accepts non-negative integers. Normal mode requires exactly one login path.

Smoke mode adds:

```text
--smoke-test
```

Smoke mode requires one or more repeated `--login-path=NAME` options. It is
noninteractive and ignores refresh, filter, threshold, and output-file options
with a validation error rather than silently accepting incompatible settings.

The help includes normal, logging, sub-second, and three-node smoke examples
using `rmateos` when an operating-system user is shown.

## Persistent MySQL Transport

`transport.py` owns `PersistentMySQLSession`.

It starts one child process:

```text
mysql --login-path=<name> --batch --raw --skip-column-names --unbuffered --force
```

The process uses `subprocess.Popen` with text-mode stdin, stdout, and stderr.
The transport sends each SQL request between unique start and end sentinel
queries. A monotonically increasing request sequence and the monitor process ID
make sentinels unique. A dedicated reader thread consumes stdout and places
complete lines into a bounded `queue.Queue`; this permits deterministic
five-second timeouts without blocking the UI thread.

Stderr is consumed by a second daemon reader into a bounded ring buffer so a
long-running client cannot block or grow an unbounded in-memory error log.

Transport operations:

- `start()`: start the owned child and reader threads.
- `execute(sql, timeout=5.0)`: return the rows between matching sentinels.
- `is_alive()`: report child-process state.
- `reconnect()`: stop the failed child and create one replacement.
- `execute_with_retry(sql)`: execute, reconnect once on transport failure, and
  retry once.
- `close()`: idempotently close pipes, terminate then kill on a bounded
  timeout, join readers, and reap the child.

The transport never invokes a shell. SQL and login paths are passed through
direct argument and stdin APIs. Only the owned process is terminated.

## Queries and Typed Models

`queries.py` defines the exact read-only statements for:

- ProxySQL version and hostname.
- CONN aggregation from `stats.stats_mysql_processlist`.
- QUERY rows from `stats.stats_mysql_processlist`.
- DIGEST rows from `stats.stats_mysql_query_digest`.
- BACKEND pool rows from `stats.stats_mysql_connection_pool`.
- BACKEND ping rows from `monitor.mysql_server_ping_log`.

BACKEND uses one framed request containing section sentinels and both SELECT
statements.

At startup, the display target is parsed once from
`mysql_config_editor print --login-path=<name>`. If that command is unavailable
or has no host field, the application falls back to `SELECT @@hostname`.

`models.py` defines typed dataclasses for configuration, monitor state, each
view row, backend sections, and smoke results. Parsing validates the expected
minimum field count and integer fields. Query text remains a single field
because MySQL batch mode escapes embedded control characters.

Only the active view is queried during interactive monitoring.

## Formatting

`formatter.py` is pure except for receiving terminal width. It:

- Preserves padded-column widths from the Bash monitor.
- Applies ANSI colors outside padded values.
- Sanitizes escaped `\n`, `\r`, and `\t` plus literal control characters.
- Dynamically truncates unpredictable query and hostname text.
- Highlights QUERY time above 500 ms in yellow and above 1000 ms in red.
- Applies the configured CONN threshold.
- Preserves the Bash user-filter contract: commas mean alternatives and each
  alternative is a regular expression matched against the user field.
- Calculates CONN row and global deltas from the previous successful sample.
- Produces both colored terminal output and clean log output without launching
  a `sed` process.

Clean logging occurs only after a successful nonempty sample. Retained stale
data is never appended as a new log sample.

## Terminal and Application Lifecycle

`terminal.py` uses `termios`, `tty`, `select`, `signal`, and
`shutil.get_terminal_size` from the standard library. It:

- Enters raw mode only when stdin is a TTY.
- Restores the original terminal state idempotently.
- Reads one key with a floating-point timeout.
- Marks geometry dirty on `SIGWINCH`.
- Emits ANSI clear/home sequences without starting external processes.
- Temporarily restores cooked terminal mode for `r`, `u`, and `t` prompts,
  then re-enters raw mode after validated input.

Interactive keys preserve the Bash contract:

- `v`: cycle CONN, QUERY, DIGEST, BACKEND.
- `r`: change refresh interval.
- `s`: toggle CONN sort.
- `p`: pause or resume sampling.
- `u`: change user filter.
- `t`: change connection threshold.
- `q`: exit.

`app.py` coordinates transport, active-view sampling, formatting, logging, and
terminal input. A failed sample is retried once through the transport. A double
failure retains the last successfully formatted view, marks it stale, displays
the error, and retries on the next refresh. View changes unpause sampling.
Returning to CONN or changing its sort resets the delta baseline.

`SIGINT` and `SIGTERM` trigger bounded, idempotent cleanup.

## Live Smoke Mode

Smoke mode accepts repeated login paths and processes nodes sequentially. For
each node it:

1. Starts one persistent MySQL client.
2. Validates nonempty ProxySQL version and hostname results.
3. Executes CONN, QUERY, DIGEST, and BACKEND once.
4. Parses every returned row into its typed model.
5. Records elapsed time and row count per view.
6. Closes and reaps the child.

An empty statistics view is valid. A transport failure, malformed nonempty row,
missing BACKEND section sentinel, empty version, or cleanup failure is an
error. Output is a colored node/view PASS/FAIL summary with timings and row
counts. Exit status is zero only if every view succeeds on every node.

The approved live targets are:

- `devel-proxysql01-node01`
- `devel-proxysql01-node02`
- `devel-proxysql01-node03`

Smoke mode executes only the SELECT statements defined in `queries.py`.

## Testing

Tests use `unittest` and standard-library fixtures only.

`fake_mysql.py` implements the persistent framed protocol and supports normal
responses, empty views, malformed rows, delayed responses, EOF, failed writes,
and reconnect scenarios.

Required coverage:

- CLI help, validation, examples, and repeated smoke login paths.
- One MySQL child across multiple successful samples.
- One reconnect and one retry after EOF or timeout.
- Bounded stderr behavior and cleanup after success, failure, and signals.
- Exact SQL routing for all four views.
- BACKEND section parsing from one request.
- CONN deltas and baseline resets.
- QUERY thresholds and control-character sanitization.
- DIGEST dynamic truncation.
- ANSI alignment and clean logging.
- Pause, view, sort, filter, threshold, resize, and quit transitions.
- Last-valid-data preservation and stale-state recovery.
- Smoke orchestration across multiple fake nodes.

Offline tests must not depend on configured login paths or network access.

Live acceptance executes smoke mode against all three approved login paths and
requires every node/view result to pass. Live output must not expose passwords
or expanded credential material.

## Acceptance Criteria

- Normal CLI and interactive behavior match the Bash monitor.
- One persistent MySQL child is used per monitored node.
- All four views preserve SQL meaning and formatting semantics.
- Default refresh does not launch per-cycle helper processes.
- Offline tests pass on Python 3.9+.
- Live smoke passes all four views on all three approved nodes.
- No temporary files, threads, or child processes remain after exit.
- README documents requirements, usage, options, keys, tests, smoke mode, and
  examples.

## Out of Scope

- Simultaneous four-panel output.
- Native MySQL drivers, DSNs, or clear-text credential flags.
- Windows support.
- Background collection of inactive views.
- Changes to ProxySQL configuration or statistics retention.
- Packaging or publishing to PyPI.
