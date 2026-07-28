# ProxySQL Monitor Go Port Design

## Objective

Create an idiomatic Go implementation of the ProxySQL Ultimate Monitor in
`mysql/proxysql/go/`. The Go port must preserve the behavior and
resource-efficiency contract of
`mysql/proxysql/proxysql_connections_monitor.sh` while producing a single
monitor binary with modular, typed, independently testable packages.

The initial port retains the existing single-view interface and `v` key
navigation. A simultaneous four-panel dashboard is explicitly deferred to a
separate design after the parity port has been measured and validated.

## Runtime and Compatibility

- Go 1.22 or newer.
- macOS and Linux.
- Standard library plus `golang.org/x/term`.
- External MySQL command-line client available as `mysql`.
- ProxySQL credentials resolved exclusively through
  `mysql_config_editor --login-path`.
- No password, DSN, or clear-text credential flags.
- All code comments, documentation, help, logs, and messages in English.

The implementation builds and runs as:

```text
cd mysql/proxysql/go
go build -o proxysql-monitor ./cmd/proxysql-monitor
./proxysql-monitor --login-path=NAME
```

## File Structure

```text
mysql/proxysql/go/
├── README.md
├── go.mod
├── go.sum
├── cmd/
│   └── proxysql-monitor/
│       └── main.go
└── internal/
    ├── app/
    │   ├── app.go
    │   └── app_test.go
    ├── cli/
    │   ├── cli.go
    │   └── cli_test.go
    ├── formatter/
    │   ├── formatter.go
    │   ├── formatter_test.go
    │   └── testdata/
    ├── model/
    │   └── model.go
    ├── queries/
    │   ├── queries.go
    │   └── queries_test.go
    ├── terminal/
    │   ├── terminal.go
    │   └── terminal_test.go
    └── transport/
        ├── fake_mysql_test.go
        ├── transport.go
        └── transport_test.go
```

The `internal` boundary prevents accidental library API commitments.
`cmd/proxysql-monitor/main.go` contains only dependency construction, signal
context setup, error reporting, and exit status handling.

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
noninteractive and rejects refresh, filter, threshold, or output-file settings
instead of silently ignoring them.

The CLI parser supports both `--name=value` and `--name value` forms plus the
existing short options. Help includes normal, logging, sub-second, and
three-node smoke examples using `rmateos` when an operating-system user is
shown.

## Persistent MySQL Transport

`internal/transport` owns `Session`.

It starts one child process with `exec.CommandContext`:

```text
mysql --login-path=<name> --batch --raw --skip-column-names --unbuffered --force
```

The process has dedicated stdin, stdout, and stderr pipes. Each SQL request is
wrapped in unique start and end sentinel queries. Sentinels contain a
monotonically increasing request sequence and the monitor process ID.

One goroutine scans stdout and publishes complete lines to a bounded channel.
A second goroutine scans stderr into a mutex-protected bounded ring buffer.
`Execute(ctx, sql)` selects between response lines, context timeout, child
exit, and cancellation. It discards output until the matching start sentinel
and returns rows only after the matching end sentinel.

Transport operations:

- `Start(ctx) error`
- `Execute(ctx, sql string) ([]string, error)`
- `Alive() bool`
- `Reconnect(ctx) error`
- `ExecuteWithRetry(ctx, sql string) ([]string, error)`
- `Close() error`

`ExecuteWithRetry` reconnects once after a transport error and retries once.
`Close` is idempotent, closes stdin, waits for graceful exit for a bounded
interval, kills only the owned process if necessary, waits, and joins reader
goroutines.

The transport never invokes a shell. Arguments, login paths, and SQL use
direct process APIs.

## Queries and Typed Models

`internal/queries` defines the exact read-only statements for:

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

`internal/model` defines configuration, monitor state, view enumeration, row
structures, backend sections, and smoke result structures. Parse functions
validate minimum field counts and use `strconv` for numeric fields. Query text
remains one field because MySQL batch mode escapes embedded controls.

Only the active view is queried during interactive monitoring.

## Formatting

`internal/formatter` contains pure functions parameterized by terminal width
and color capability. It:

- Preserves padded-column widths from the Bash monitor.
- Applies ANSI colors outside padded values.
- Sanitizes escaped `\n`, `\r`, and `\t` plus literal control characters.
- Dynamically truncates unpredictable query and hostname text.
- Highlights QUERY time above 500 ms in yellow and above 1000 ms in red.
- Applies the configured CONN threshold.
- Preserves the Bash user-filter contract: commas mean alternatives and each
  alternative is a regular expression matched against the user field.
- Calculates CONN row and global deltas from the previous successful sample.
- Produces colored terminal output and clean log output without external
  cleanup processes.

Clean logging occurs only after a successful nonempty sample. Retained stale
data is not appended as a new log sample.

## Terminal and Application Lifecycle

`internal/terminal` uses `golang.org/x/term`, `os.Signal`, and standard-library
I/O. It:

- Enters raw mode only when stdin is a terminal.
- Restores the exact original terminal state idempotently.
- Reads keys in a goroutine and delivers them over a bounded channel.
- Uses timers for floating-point refresh intervals.
- Marks geometry dirty on `SIGWINCH`.
- Emits ANSI clear/home sequences without external processes.
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

`internal/app` owns the event loop and coordinates transport, active-view
sampling, formatting, logging, key events, resize events, timers, and signal
cancellation. View changes trigger immediate sampling and unpause the monitor.
Returning to CONN or changing its sort resets the delta baseline.

A failed sample is retried once through the transport. A double failure retains
the last successfully formatted view, marks it stale, displays the error, and
retries on the next refresh.

`context.Context` cancellation from `SIGINT` or `SIGTERM` initiates bounded,
idempotent cleanup.

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
counts. Exit status is zero only when every view succeeds on every node.

The approved live targets are:

- `devel-proxysql01-node01`
- `devel-proxysql01-node02`
- `devel-proxysql01-node03`

Smoke mode executes only the SELECT statements defined in
`internal/queries`.

## Testing

Tests use Go's `testing` package. Transport tests build or execute a temporary
fake MySQL helper that implements the framed protocol and supports normal
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
- Race-free transport and application execution with `go test -race`.

Offline tests must not depend on configured login paths or network access.

Live acceptance runs the built binary in smoke mode against all three approved
login paths and requires every node/view result to pass. Live output must not
expose passwords or expanded credential material.

## Acceptance Criteria

- Normal CLI and interactive behavior match the Bash monitor.
- One persistent MySQL child is used per monitored node.
- All four views preserve SQL meaning and formatting semantics.
- Default refresh does not launch per-cycle helper processes.
- `go test ./...` and `go test -race ./...` pass on Go 1.22+.
- Live smoke passes all four views on all three approved nodes.
- No temporary files, goroutines, or child processes remain after exit.
- README documents requirements, build, usage, options, keys, tests, smoke
  mode, and examples.

## Out of Scope

- Simultaneous four-panel output.
- Native MySQL drivers, DSNs, or clear-text credential flags.
- Windows support.
- Background collection of inactive views.
- Changes to ProxySQL configuration or statistics retention.
- Publishing a Go module or release artifact.
