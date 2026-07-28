# ProxySQL Monitor Local Resource Optimization Design

## Objective

Reduce local CPU consumption and process creation in
`mysql/proxysql/proxysql_connections_monitor.sh`, especially with a `0.5`
second refresh interval, while preserving the existing command-line interface,
interactive controls, four monitoring views, output formatting, and Bash 3.2
compatibility.

The optimization targets the laptop running the monitor. It must not increase
the ProxySQL query rate or query more views than the currently visible view.

## Current Cost Model

Every active refresh currently performs the following external work:

- Starts one `mysql` client in CONN, QUERY, and DIGEST views.
- Starts two `mysql` clients in BACKEND view.
- Starts `date`, `tput`, two `tr` processes, and at least one `awk` process.
- Starts additional processes through command substitutions and process
  substitutions.
- Starts `sed` when continuous file logging is enabled.

At sub-second refresh intervals, repeated MySQL client startup,
authentication, terminal discovery, and process creation dominate the local
cost. The AWK aggregation itself is not the primary bottleneck.

## Selected Architecture

### Persistent MySQL Transport

The monitor will start one long-lived MySQL client with options equivalent to:

```text
mysql --login-path=<name> --batch --raw --skip-column-names --unbuffered --force
```

The client will communicate through private named pipes created in a directory
returned by `mktemp -d`. Dedicated Bash file descriptors will isolate SQL
requests from keyboard input.

Each request will contain unique start and end sentinel queries. The transport
will discard input until it sees the expected start sentinel, collect result
rows, and stop at the matching end sentinel. Sentinel values will include a
monotonically increasing request sequence so delayed output from an earlier
request cannot be mistaken for the current response.

The transport interface will be isolated behind functions with these
responsibilities:

- `start_mysql_session`: create pipes, launch the client, and open descriptors.
- `execute_query`: frame a request, write it, read its complete response, and
  expose a success or failure result.
- `stop_mysql_session`: close descriptors, terminate only the owned client, and
  remove only the owned temporary directory.
- `reconnect_mysql_session`: stop the failed session and create a replacement.

No `coproc` feature will be used because macOS Bash 3.2 does not provide it.
No `eval` or unquoted command-string expansion will be used.

### Query Sampling

Only the active view will be sampled:

- CONN: one process-list aggregation statement.
- QUERY: one active-process-list statement.
- DIGEST: one digest statement.
- BACKEND: the pool and ping statements will be sent in one framed request
  through the same persistent client. An internal section sentinel will
  distinguish the two result sets.

Changing views triggers an immediate sample of the newly selected view. CONN
history is reset under the same circumstances as the current implementation,
so delta semantics remain stable.

## Loop and Rendering Optimizations

The refresh loop will eliminate avoidable external processes:

- Replace the external `clear` command with a Bash `printf` of ANSI clear/home
  control sequences.
- Cache terminal width and separator strings. A `WINCH` trap will mark terminal
  geometry dirty, and the next render will recalculate it.
- Build separator strings with `printf -v` and Bash parameter substitution,
  removing both `tr` calls.
- Replace command substitutions used for sort selection, pause state, mode
  labels, and state toggles with Bash conditionals and direct assignment.
- Replace `echo` process substitutions used as AWK inputs with Bash 3.2-safe
  input redirection and explicit in-band section delimiters.
- Format both BACKEND result sections in one AWK invocation where doing so
  keeps the rendering contract clear.
- Cache the displayed local timestamp and invoke external `date` no more than
  once for each change of Bash's integer `SECONDS` value.

AWK programs will remain assigned to variables before invocation to preserve
the existing macOS parsing workaround. ANSI color values will continue to be
passed outside padded fields. SQL text sanitization will retain both escaped
and literal newline, carriage-return, and tab handling.

## Logging

The `-o` interface and clean-text output format will remain compatible.
Logging will still occur only when the active view returned data.

The established portable `sed` expression will remain the ANSI/control
character cleanup mechanism. Its process cost is accepted only when logging is
explicitly enabled. The default monitor path will not start `sed`.

## Connection Failure Behavior

The monitor will detect:

- An owned MySQL process that has exited.
- EOF while reading a framed response.
- Failure to receive the matching end sentinel before the query timeout.
- Failure to write a framed request.

On the first failure for a sample, it will:

1. Stop the failed session and clean up its descriptors and pipes.
2. Start a replacement session.
3. Retry the current view sample once.

If the retry also fails, the monitor will retain the last successfully
formatted view data, mark it stale, and show a concise connection error in the
header. A later refresh will attempt reconnection again. A transient failure
will therefore not terminate the monitor or erase the last useful screen.

The query-response timeout will be independent of the display refresh interval
and default to five seconds. It is an internal transport timeout, not a new CLI
option. Normal `read -t` timeouts will be guarded for strict mode.

`EXIT`, `INT`, and `TERM` handling will call idempotent cleanup. Cleanup must
only target the recorded child PID and the exact temporary directory created
for the current monitor process.

## Compatibility Requirements

- Bash 3.2 and newer on macOS and Linux.
- `set -euo pipefail`.
- BSD and GNU userlands without GNU-only `sed` syntax.
- Existing CLI flags and interactive keys.
- Floating-point refresh values already accepted by the monitor.
- Existing ProxySQL SQL table and column names.
- No additional runtime dependency beyond the tools already required by the
  script.

All code comments, help text, log text, and runtime messages remain in English.

## Test Strategy

Tests will be dependency-free Bash scripts executable with Bash 3.2. They will
use a fake `mysql` executable placed first in `PATH`. The fake client will
implement the framed persistent input/output behavior and record launches and
received SQL.

Automated coverage will verify:

- Multiple requests use one MySQL client process.
- A BACKEND sample sends both SQL statements through one framed request and
  separates their results correctly.
- A dead or timed-out client is replaced and the current sample is retried
  once.
- A double failure preserves the last valid data and exposes stale status.
- Normal exit and signal cleanup remove the owned pipes and client.
- CONN deltas preserve the current baseline and view-reset semantics when rows
  appear or change.
- QUERY and DIGEST sanitization handles escaped and literal control
  characters.
- ANSI colors do not alter padded-column alignment.
- Empty results and timed `read` operations do not terminate strict-mode
  execution.
- Existing argument validation and help examples remain available.

A repeatable mocked benchmark will compare external-process launches over a
fixed number of refreshes. Acceptance requires:

- One MySQL client launch across multiple successful refreshes.
- One MySQL client, not two, for a successful BACKEND refresh sequence.
- No per-refresh `tput`, `tr`, or `clear` process.
- No `sed` process unless `-o` is enabled.

Functional tests and the process-count benchmark will be run with Bash 3.2 on
macOS. Syntax validation and ShellCheck will be run when available.

## Out of Scope

- Reimplementing the monitor in Python or Go.
- Changing the four views or their SQL meaning.
- Adding collection of inactive views in the background.
- Reducing the user-selected query sampling frequency.
- Changing ProxySQL configuration or server-side statistics retention.
- Introducing a daemon, service, package, or third-party test framework.
