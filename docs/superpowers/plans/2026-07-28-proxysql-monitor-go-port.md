# ProxySQL Monitor Go Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an idiomatic Go 1.22+ ProxySQL monitor with Bash-feature parity, one persistent `mysql --login-path` child, race-tested offline coverage, and explicit read-only smoke validation across three ProxySQL nodes.

**Architecture:** A small command constructs internal packages for CLI validation, SQL definitions, typed models, persistent process transport, pure formatting, terminal control, and application orchestration. Context cancellation controls timeouts and shutdown; login-path credentials remain exclusively inside the MySQL CLI.

**Tech Stack:** Go 1.22+, standard library, `golang.org/x/term`, external MySQL CLI.

## Global Constraints

- Create all Go-port files under `mysql/proxysql/go/`.
- Support Go 1.22 or newer on macOS and Linux.
- Use idiomatic Go, explicit errors, bounded goroutines/channels, and context cancellation.
- Use only the standard library plus `golang.org/x/term`.
- Preserve the Bash monitor's flags, defaults, four views, keys, SQL meaning, colors, sanitization, delta semantics, clean logging, and stale-data behavior.
- Use one persistent `mysql --login-path=<name>` process per monitored node.
- Never invoke a shell or expose password/DSN arguments.
- Normal mode queries only the active view.
- Smoke mode queries all four views sequentially and executes only SELECT statements.
- Keep every code comment, document, log, and runtime message in English.
- Keep the simultaneous four-panel dashboard out of scope.

---

### Task 1: Go Module, Models, SQL Contract, and CLI

**Files:**
- Create: `mysql/proxysql/go/go.mod`
- Create: `mysql/proxysql/go/internal/model/model.go`
- Create: `mysql/proxysql/go/internal/queries/queries.go`
- Create: `mysql/proxysql/go/internal/queries/queries_test.go`
- Create: `mysql/proxysql/go/internal/cli/cli.go`
- Create: `mysql/proxysql/go/internal/cli/cli_test.go`

**Interfaces:**
- Produces: `model.View`, `model.SortMode`, `model.Config`, typed row structs,
  `model.BackendRows`, `model.State`, and `model.SmokeResult`.
- Produces: `cli.Parse(args []string) (model.Config, error)` and
  `cli.Help(program string) string`.
- Produces: `queries.ForView(view model.View, sort model.SortMode) (string,
  error)` plus version, hostname, backend SQL, and section marker constants.
- Consumes: no earlier Go task.

- [ ] **Step 1: Initialize the module**

Create:

```go
module github.com/Fenicce77/fenicceTools/mysql/proxysql/go

go 1.22

require golang.org/x/term v0.20.0
```

Run `go mod tidy` only after terminal code imports `x/term`; until then the
require line is intentionally retained.

- [ ] **Step 2: Write failing CLI and query tests**

```go
func TestParseNormalMode(t *testing.T) {
    cfg, err := Parse([]string{
        "--login-path=proxysql_admin",
        "--refresh-time=0.5",
        "--user-filter=app,report",
        "--threshold=12",
        "--output-file=/tmp/proxysql.log",
    })
    if err != nil {
        t.Fatal(err)
    }
    if got, want := strings.Join(cfg.LoginPaths, ","), "proxysql_admin"; got != want {
        t.Fatalf("login paths = %q, want %q", got, want)
    }
    if cfg.Refresh != 500*time.Millisecond ||
        cfg.UserFilter != "app,report" ||
        cfg.Threshold != 12 ||
        cfg.OutputFile != "/tmp/proxysql.log" ||
        cfg.Timeout != 5*time.Second {
        t.Fatalf("unexpected config: %+v", cfg)
    }
}

func TestParseSmokeRepeatedLoginPaths(t *testing.T) {
    cfg, err := Parse([]string{
        "--smoke-test",
        "--login-path=node01",
        "--login-path=node02",
    })
    if err != nil {
        t.Fatal(err)
    }
    if got, want := strings.Join(cfg.LoginPaths, ","), "node01,node02"; got != want {
        t.Fatalf("login paths = %q, want %q", got, want)
    }
}

func TestBackendSQLIsReadOnlyAndContainsBothSources(t *testing.T) {
    if !strings.Contains(BackendSQL, "stats.stats_mysql_connection_pool") ||
        !strings.Contains(BackendSQL, "monitor.mysql_server_ping_log") {
        t.Fatal("backend SQL does not contain both sources")
    }
    if strings.Contains(strings.ToUpper(BackendSQL), "UPDATE ") {
        t.Fatal("backend SQL is not read-only")
    }
}
```

Use manual literal comparisons; do not add a comparison dependency.

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/cli ./internal/queries
```

Expected: package/file errors because implementations do not exist.

- [ ] **Step 4: Implement models and validated parsing**

Define:

```go
type View string
const (
    ViewConn View = "CONN"
    ViewQuery View = "QUERY"
    ViewDigest View = "DIGEST"
    ViewBackend View = "BACKEND"
)

type SortMode string
const (
    SortConn SortMode = "CONN"
    SortUser SortMode = "USER"
)

type Config struct {
    LoginPaths  []string
    Refresh     time.Duration
    UserFilter  string
    Threshold   int
    OutputFile  string
    SmokeTest   bool
    Timeout     time.Duration
}
```

Add typed row structs with fields matching the approved specification.
`State` contains view, sort, paused/stale flags, last error, previous
connections, and last rendered output.

Implement a custom argument loop so both `--name=value`, `--name value`, and
short forms work. Parse decimal seconds with `strconv.ParseFloat`, reject zero
or negative values, reject negative thresholds, require exactly one normal
login path, and require one or more smoke login paths. Detect explicit
incompatible smoke options before defaults are applied.

- [ ] **Step 5: Implement exact SQL constants**

Copy SELECT statements from the merged Bash monitor. `ForView` changes only
the CONN ORDER BY clause. `BackendSQL` emits `__PXMON_POOL__` and
`__PXMON_PING__` rows around both backend SELECT statements.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/cli ./internal/queries
go vet ./internal/cli ./internal/queries
```

Expected: all commands exit 0.

- [ ] **Step 7: Commit**

```bash
git add mysql/proxysql/go
git commit -m "feat(go): add ProxySQL monitor contracts"
```

---

### Task 2: Persistent Framed MySQL Transport

**Files:**
- Create: `mysql/proxysql/go/internal/transport/transport.go`
- Create: `mysql/proxysql/go/internal/transport/fake_mysql_test.go`
- Create: `mysql/proxysql/go/internal/transport/transport_test.go`

**Interfaces:**
- Produces: `transport.Config`.
- Produces: `transport.Session` with `Start`, `Alive`, `Execute`, `Reconnect`,
  `ExecuteWithRetry`, `Stderr`, and `Close`.
- Consumes: context cancellation and a login-path name.

- [ ] **Step 1: Write a test-helper mode**

Implement `TestMain` that runs a fake MySQL protocol when
`GO_WANT_FAKE_MYSQL=1`; otherwise it calls `m.Run()`. The fake:

- Appends its PID to `$FAKE_MYSQL_STATE_DIR/launches`.
- Echoes begin/end sentinels.
- Returns literal rows for `TEST_CONNECTIONS`, `TEST_SECOND_SAMPLE`,
  `SELECT @@version`, and `SELECT @@hostname`.
- Suppresses one end marker when
  `FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH=1`.
- Exits on a configured token.
- Emits a configured number of stderr lines.

Tests launch the current test binary with `-test.run=TestFakeMySQLProcess`.

- [ ] **Step 2: Write failing transport tests**

```go
func TestMultipleRequestsUseOneChild(t *testing.T) {
    state := t.TempDir()
    s := newFakeSession(t, state)
    ctx := context.Background()
    if err := s.Start(ctx); err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { _ = s.Close() })

    rows, err := s.Execute(ctx, "SELECT 'TEST_CONNECTIONS';")
    if err != nil {
        t.Fatal(err)
    }
    if got, want := rows[0], "app\tclient\tbackend:3306\tappdb\t4"; got != want {
        t.Fatalf("row = %q, want %q", got, want)
    }
    if _, err := s.Execute(ctx, "SELECT 'TEST_SECOND_SAMPLE';"); err != nil {
        t.Fatal(err)
    }
    if got := launchCount(t, state); got != 1 {
        t.Fatalf("launches = %d, want 1", got)
    }
}

func TestTimeoutReconnectsOnce(t *testing.T) {
    t.Setenv("FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH", "1")
    state := t.TempDir()
    s := newFakeSession(t, state)
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    if err := s.Start(ctx); err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { _ = s.Close() })
    rows, err := s.ExecuteWithRetry(ctx, "SELECT 'TEST_CONNECTIONS';", 100*time.Millisecond)
    if err != nil {
        t.Fatal(err)
    }
    if len(rows) != 1 || launchCount(t, state) != 2 {
        t.Fatalf("rows=%v launches=%d", rows, launchCount(t, state))
    }
}
```

- [ ] **Step 3: Run transport tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/transport -v
```

Expected: compile failure because `Session` is undefined.

- [ ] **Step 4: Implement bounded process transport**

Define:

```go
type Config struct {
    LoginPath   string
    MySQLBinary string
    ArgsPrefix  []string
    QueueSize   int
    StderrLines int
}

type Session struct {
    cfg       Config
    mu        sync.Mutex
    execMu    sync.Mutex
    cmd       *exec.Cmd
    stdin     io.WriteCloser
    lines     chan lineResult
    done      chan struct{}
    sequence  uint64
    stderr    *ringBuffer
}
```

Start with `exec.CommandContext` and direct arguments:

```go
[]string{
    "--login-path=" + cfg.LoginPath,
    "--batch", "--raw", "--skip-column-names", "--unbuffered", "--force",
}
```

Scanner goroutines publish stdout lines to a bounded channel and stderr lines
to a fixed-size ring. `Execute` serializes requests, uses PID and atomic
sequence markers, writes and flushes framed SQL, then selects on line channel,
timeout timer, context cancellation, and process completion. It returns only
rows between matching markers.

An internal `stopProcess` closes and reaps one process generation, joins its
reader goroutines, and replaces its channels on the next start. `Reconnect`
calls `stopProcess` and starts a new generation. Final `Close` marks the
session closed, calls `stopProcess`, rejects later starts, and is idempotent.
`stopProcess` closes stdin, waits up to one second, kills only the owned
process if needed, and calls `Wait` exactly once.

- [ ] **Step 5: Run tests and race detector**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/transport -v
go test -race ./internal/transport
```

Expected: both commands exit 0 with no goroutine leak reported by tests.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/go
git commit -m "feat(go): add persistent MySQL transport"
```

---

### Task 3: Typed Parsing and Pure Formatting

**Files:**
- Create: `mysql/proxysql/go/internal/formatter/formatter.go`
- Create: `mysql/proxysql/go/internal/formatter/formatter_test.go`
- Create: `mysql/proxysql/go/internal/formatter/testdata/conn_previous.tsv`
- Create: `mysql/proxysql/go/internal/formatter/testdata/conn_current.tsv`
- Modify: `mysql/proxysql/go/internal/model/model.go`

**Interfaces:**
- Produces: `ParseConnections`, `ParseQueries`, `ParseDigests`, and
  `ParseBackend`.
- Produces: `CompileUserFilter`.
- Produces: `FormatConnections`, `FormatQueries`, `FormatDigests`, and
  `FormatBackend`, returning `model.RenderedView`.
- Consumes: typed model structures.

- [ ] **Step 1: Write failing literal formatter tests**

Use these literal rows:

```go
previous := []string{"app\tclient\tbackend:3306\tappdb\t4"}
current := []string{"app\tclient\tbackend:3306\tappdb\t6"}
queries := []string{"11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n*\\tFROM t"}
backend := []string{
    "__PXMON_POOL__",
    "10\tbackend:3306\tONLINE\t2\t3\t50\t1",
    "__PXMON_PING__",
    "backend\t2026-07-28 12:00:00\t500\t",
}
```

Assert clean CONN output contains `+2`, QUERY clean output contains
`SELECT * FROM t`, colored QUERY output contains ANSI, BACKEND parses one pool
and one ping row, malformed rows error, empty lists succeed, comma-separated
regex filters match alternatives, and long DIGEST text truncates based on
terminal width.

- [ ] **Step 2: Run formatter tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/formatter -v
```

Expected: compile failure because formatter functions do not exist.

- [ ] **Step 3: Implement strict parsing**

Use `strings.SplitN` so final query text stays intact. Enforce minimum field
counts 5/7/6/7/4 for CONN/QUERY/DIGEST/POOL/PING. Parse numeric fields with a
helper returning `fmt.Errorf("invalid %s %q: %w", field, value, err)`.
`ParseBackend` rejects nonempty data missing either marker.

- [ ] **Step 4: Implement pure formatting**

Add:

```go
type RenderedView struct {
    Colored  string
    Clean    string
    RowCount int
}
```

Build padded text before adding ANSI colors. Generate clean output from the
same typed row data rather than stripping ANSI. Sanitize escaped/literal
controls, calculate CONN deltas with a four-field key, use red above 1000 ms
and yellow above 500 ms, and use `max(50, terminalWidth-75)` for DIGEST query
width.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/formatter -v
go test ./internal/model ./internal/queries ./internal/formatter
go vet ./internal/...
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/go
git commit -m "feat(go): add typed ProxySQL view formatting"
```

---

### Task 4: Terminal State and Interactive Application

**Files:**
- Create: `mysql/proxysql/go/internal/terminal/terminal.go`
- Create: `mysql/proxysql/go/internal/terminal/terminal_test.go`
- Create: `mysql/proxysql/go/internal/app/app.go`
- Create: `mysql/proxysql/go/internal/app/app_test.go`

**Interfaces:**
- Produces: `terminal.Controller` with `Enter`, `Restore`, `Keys`, `Prompt`,
  `Size`, `Clear`, and `MarkGeometryDirty`.
- Produces: `app.App` with `SampleCurrentView`, `HandleKey`, `Render`, `Log`,
  `Run`, and `Close`.
- Consumes: `model.Config`, transport interface, queries, formatter, terminal
  interface, clock/timer factories, and output writer.

- [ ] **Step 1: Write failing application state tests**

Define narrow test interfaces and fakes. Assert:

```go
a := newTestApp(t)
a.HandleKey(context.Background(), 'v')
if a.State.View != model.ViewQuery || a.State.Paused {
    t.Fatalf("state after v = %+v", a.State)
}
a.HandleKey(context.Background(), 'p')
if !a.State.Paused {
    t.Fatal("p did not pause")
}

a.State.LastRendered = "last valid"
a.session.err = errors.New("ProxySQL unavailable")
if a.SampleCurrentView(context.Background()) {
    t.Fatal("failed sample reported success")
}
if !a.State.Stale || a.State.LastRendered != "last valid" {
    t.Fatalf("stale state = %+v", a.State)
}
```

Add tests for exact view order, CONN sort/baseline reset, validated prompts,
filter and threshold transitions, resize, quit, clean logging only on
successful nonempty samples, and no stale log duplication.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/terminal ./internal/app -v
```

Expected: package or symbol failures because implementations do not exist.

- [ ] **Step 3: Implement terminal control**

Use `term.IsTerminal`, `term.MakeRaw`, `term.Restore`, and
`term.GetSize`. A single goroutine reads one byte at a time and sends keys to a
bounded channel until context cancellation or read error. `Prompt` restores
cooked mode, reads a line with `bufio.Reader`, and re-enters raw mode in a
deferred block. `Clear` writes `"\x1b[H\x1b[2J"`. Enforce a 110-column minimum
with 130-column fallback.

- [ ] **Step 4: Implement application orchestration**

Define a transport interface:

```go
type Session interface {
    ExecuteWithRetry(context.Context, string, time.Duration) ([]string, error)
    Close() error
}
```

Inject terminal, session, output writer, wall clock, and timer factory.
`SampleCurrentView` selects one query, parses/formats it, updates CONN baseline
only on success, retains output on failure, and marks stale. `Run` selects
between refresh timer, key channel, resize signal, and context cancellation.
View changes trigger immediate samples and unpause.

`Close` uses `sync.Once`, restores the terminal, closes the log, and closes the
session while returning joined errors.

- [ ] **Step 5: Fetch dependency, format, and verify**

Run:

```bash
cd mysql/proxysql/go
go mod tidy
gofmt -w internal
go test ./internal/terminal ./internal/app -v
go test -race ./internal/...
go vet ./...
```

Expected: `go.sum` is generated and every command exits 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/go
git commit -m "feat(go): add interactive ProxySQL monitor"
```

---

### Task 5: Command, Smoke Mode, Documentation, and Live Acceptance

**Files:**
- Create: `mysql/proxysql/go/cmd/proxysql-monitor/main.go`
- Create: `mysql/proxysql/go/internal/app/smoke.go`
- Create: `mysql/proxysql/go/internal/app/smoke_test.go`
- Create: `mysql/proxysql/go/README.md`
- Modify: `mysql/proxysql/go/internal/cli/cli.go`

**Interfaces:**
- Produces: `app.RunSmoke(ctx, config, sessionFactory) []model.SmokeResult`.
- Produces executable `proxysql-monitor`.
- Consumes: all earlier Go components.

- [ ] **Step 1: Write failing multi-node smoke tests**

Inject a session factory keyed by login path and assert exact node/view order:

```go
want := []string{
    "node01/CONN", "node01/QUERY", "node01/DIGEST", "node01/BACKEND",
    "node02/CONN", "node02/QUERY", "node02/DIGEST", "node02/BACKEND",
}
results := RunSmoke(context.Background(), cfg, factory)
got := make([]string, 0, len(results))
for _, result := range results {
    got = append(got, result.LoginPath+"/"+string(result.View))
}
if strings.Join(got, ",") != strings.Join(want, ",") {
    t.Fatalf("order = %v, want %v", got, want)
}
```

Also test empty-view success, malformed-row failure, missing BACKEND marker
failure, cleanup per node, continued processing after one node fails, and
nonzero aggregate exit status.

- [ ] **Step 2: Run smoke tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/app -run Smoke -v
```

Expected: compile failure because `RunSmoke` does not exist.

- [ ] **Step 3: Implement smoke orchestration**

For each login path, create one session, validate version and resolved
hostname, execute CONN/QUERY/DIGEST/BACKEND in exact order, parse every row,
measure elapsed time, append a result, and close before moving to the next
node. Empty views succeed. Continue after recording a node failure.

- [ ] **Step 4: Implement command entry point**

`main.go` must:

1. Parse CLI arguments and print English errors plus help.
2. Create `signal.NotifyContext` for `SIGINT` and `SIGTERM`.
3. Run smoke mode or construct the interactive app.
4. Print colored smoke rows with node, view, rows, elapsed milliseconds, and
   error.
5. Exit zero only when the selected mode succeeds.

Use `exec.Command("mysql_config_editor", "print",
"--login-path="+name)` once to resolve the display host; fall back to
`SELECT @@hostname`.

- [ ] **Step 5: Write complete README**

Document requirements, build command, all options and keys, persistent
transport/reconnect behavior, clean logging, offline test commands, exact
three-node smoke command, SELECT-only smoke guarantee, and normal/filter/log/
`rmateos` sub-second examples.

- [ ] **Step 6: Run offline verification**

Run:

```bash
cd mysql/proxysql/go
gofmt -w cmd internal
go test ./...
go test -race ./...
go vet ./...
go build -o proxysql-monitor ./cmd/proxysql-monitor
./proxysql-monitor --help
```

Expected: all commands exit 0 and help contains every approved option/example.
Remove only the generated `proxysql-monitor` binary after verification.

- [ ] **Step 7: Run approved live smoke validation**

Run:

```bash
cd mysql/proxysql/go
go run ./cmd/proxysql-monitor \
  --smoke-test \
  --login-path=devel-proxysql01-node01 \
  --login-path=devel-proxysql01-node02 \
  --login-path=devel-proxysql01-node03
```

Expected: twelve PASS rows—four views for each of three nodes—and exit 0.
Empty views are PASS with zero rows.

- [ ] **Step 8: Verify cleanup and commit**

Verify no monitor child/goroutine remains, `git diff --check` exits 0, then:

```bash
git add mysql/proxysql/go
git commit -m "feat(go): complete ProxySQL monitor port"
```
