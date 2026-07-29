# Python and Go Key Legend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved two-line colored interactive key legend to every normal Python and Go monitor refresh.

**Architecture:** Each application layer owns a deterministic private legend helper and appends its result after the rendered database body. Database formatters, smoke output, logging data, SQL execution, and terminal lifecycle remain unchanged.

**Tech Stack:** Python 3 with type hints and `unittest`; Go 1.22+ with the standard testing package; ANSI SGR terminal sequences; macOS Darwin arm64 and Linux amd64 build verification.

## Global Constraints

- The change applies only to normal interactive mode.
- Smoke-test output and clean file logging remain unchanged.
- The options occupy two explicit lines beneath a bold `Interactive Options:` heading.
- Key letters use bold magenta; labels preserve the approved Bash color mapping.
- No additional SQL execution, child process, goroutine, timer, terminal-size lookup, or refresh cycle is introduced.
- The tracked Darwin arm64 Go executable is rebuilt only after source verification passes.
- Linux deployments continue to build from source.

---

### Task 1: Python Interactive Legend

**Files:**
- Modify: `mysql/proxysql/python/tests/test_app.py`
- Modify: `mysql/proxysql/python/proxysql_monitor/app.py`

**Interfaces:**
- Consumes: `MonitorApp.render() -> str`, `MonitorApp.last_colored`, and the existing terminal writer.
- Produces: `_interactive_legend() -> str`, called only by the normal interactive render path.

- [ ] **Step 1: Write the failing Python render test**

Add `import re` and this regression test to `AppTests`:

```python
def test_render_includes_two_line_colored_key_legend(self) -> None:
    app, _session, _terminal = self.make_app()
    screen = app.render()
    plain = re.sub(r"\x1b\[[0-9;]*m", "", screen)
    self.assertEqual(
        [
            "Interactive Options:",
            " [v] Toggle View (Conn/Query/Digest/Backend) | [r] Refresh | [s] Sort | [p] Pause",
            " [u] Filter | [t] Threshold | [q] Quit",
        ],
        plain.splitlines()[-3:],
    )
    self.assertIn("\x1b[1;35m", screen)
    self.assertIn("\x1b[1;34m", screen)
```

Extend `test_logging_occurs_only_for_fresh_nonempty_samples` with:

```python
self.assertNotIn("Interactive Options:", first)
```

- [ ] **Step 2: Run the focused Python test and verify RED**

Run:

```bash
python3 -m unittest tests.test_app.AppTests.test_render_includes_two_line_colored_key_legend -v
```

Expected: FAIL because the final three screen lines do not contain the legend.

- [ ] **Step 3: Implement the Python legend helper and render integration**

Add application-level ANSI constants and a typed helper:

```python
_BOLD = "\x1b[1m"
_BLUE = "\x1b[1;34m"
_GREEN = "\x1b[1;32m"
_YELLOW = "\x1b[1;33m"
_RED = "\x1b[1;31m"
_MAGENTA = "\x1b[1;35m"
_RESET = "\x1b[0m"


def _interactive_legend() -> str:
    return (
        f"{_BOLD}Interactive Options:{_RESET}\n"
        f" [{_MAGENTA}v{_RESET}] {_BLUE}Toggle View{_RESET} "
        f"(Conn/Query/Digest/Backend) | "
        f"[{_MAGENTA}r{_RESET}] {_GREEN}Refresh{_RESET} | "
        f"[{_MAGENTA}s{_RESET}] {_GREEN}Sort{_RESET} | "
        f"[{_MAGENTA}p{_RESET}] {_YELLOW}Pause{_RESET}\n"
        f" [{_MAGENTA}u{_RESET}] {_GREEN}Filter{_RESET} | "
        f"[{_MAGENTA}t{_RESET}] {_RED}Threshold{_RESET} | "
        f"[{_MAGENTA}q{_RESET}] {_RED}Quit{_RESET}"
    )
```

After assembling the existing header/body frame in `MonitorApp.render`, append:

```python
screen = f"{screen}\n\n{_interactive_legend()}"
```

- [ ] **Step 4: Run the focused and complete Python tests and verify GREEN**

Run:

```bash
python3 -m unittest tests.test_app.AppTests.test_render_includes_two_line_colored_key_legend -v
python3 -m unittest discover -s tests -v
```

Expected: PASS, including the log assertion.

- [ ] **Step 5: Commit the Python implementation**

```bash
git add mysql/proxysql/python/proxysql_monitor/app.py mysql/proxysql/python/tests/test_app.py
git commit -m "feat(python): show interactive key legend"
```

### Task 2: Go Interactive Legend

**Files:**
- Modify: `mysql/proxysql/go/internal/app/app_test.go`
- Modify: `mysql/proxysql/go/internal/app/app.go`

**Interfaces:**
- Consumes: `(*App).Render() error`, `App.lastColored`, and `App.output`.
- Produces: `interactiveLegend() string`, called only by the normal interactive render path.

- [ ] **Step 1: Write the failing Go render test**

Add `regexp` to the test imports and add:

```go
func TestRenderIncludesTwoLineColoredKeyLegend(t *testing.T) {
    application, _, _ := newTestApp(t, "")
    var output bytes.Buffer
    application.output = &output
    if err := application.Render(); err != nil {
        t.Fatal(err)
    }
    plain := regexp.MustCompile(`\x1b\[[0-9;]*m`).ReplaceAllString(output.String(), "")
    want := "Interactive Options:\n" +
        " [v] Toggle View (Conn/Query/Digest/Backend) | [r] Refresh | [s] Sort | [p] Pause\n" +
        " [u] Filter | [t] Threshold | [q] Quit\n"
    if !strings.HasSuffix(plain, want) {
        t.Fatalf("legend absent or malformed: %q", plain)
    }
    if !strings.Contains(output.String(), "\x1b[1;35m") ||
        !strings.Contains(output.String(), "\x1b[1;34m") {
        t.Fatalf("legend colors absent: %q", output.String())
    }
}
```

Extend `TestPromptsAndCleanFreshLogging` with:

```go
if bytes.Contains(first, []byte("Interactive Options:")) {
    t.Fatal("log contains interactive legend")
}
```

- [ ] **Step 2: Run the focused Go test and verify RED**

Run:

```bash
go test ./internal/app -run TestRenderIncludesTwoLineColoredKeyLegend -count=1
```

Expected: FAIL because `Render` does not emit the legend.

- [ ] **Step 3: Implement the Go legend helper and render integration**

Add private application-level color constants and:

```go
func interactiveLegend() string {
    return fmt.Sprintf(
        "%sInteractive Options:%s\n"+
            " [%sv%s] %sToggle View%s (Conn/Query/Digest/Backend) | "+
            "[%sr%s] %sRefresh%s | [%ss%s] %sSort%s | [%sp%s] %sPause%s\n"+
            " [%su%s] %sFilter%s | [%st%s] %sThreshold%s | [%sq%s] %sQuit%s",
        appBold, appReset,
        appMagenta, appReset, appBlue, appReset,
        appMagenta, appReset, appGreen, appReset,
        appMagenta, appReset, appGreen, appReset,
        appMagenta, appReset, appYellow, appReset,
        appMagenta, appReset, appGreen, appReset,
        appMagenta, appReset, appRed, appReset,
        appMagenta, appReset, appRed, appReset,
    )
}
```

Update the existing screen write to append one blank separator line and `interactiveLegend()`:

```go
_, err := fmt.Fprintf(
    a.output, "%s%s%s\n%s\n\n%s\n",
    header, filterLine, strings.Repeat("=", 110), body, interactiveLegend(),
)
```

- [ ] **Step 4: Run the focused and complete Go tests and verify GREEN**

Run:

```bash
gofmt -w internal/app/app.go internal/app/app_test.go
go test ./internal/app -run TestRenderIncludesTwoLineColoredKeyLegend -count=1
go test ./...
```

Expected: PASS, including the clean-log assertion.

- [ ] **Step 5: Commit the Go source implementation**

```bash
git add mysql/proxysql/go/internal/app/app.go mysql/proxysql/go/internal/app/app_test.go
git commit -m "feat(go): show interactive key legend"
```

### Task 3: Cross-Platform, Live, and Generated-Binary Verification

**Files:**
- Modify: `mysql/proxysql/go/proxysql-monitor`
- Verify: `mysql/proxysql/python/...`
- Verify: `mysql/proxysql/go/...`

**Interfaces:**
- Consumes: verified Python and Go render implementations.
- Produces: a refreshed tracked Darwin arm64 `proxysql-monitor` binary and release-ready verification evidence.

- [ ] **Step 1: Run full language verification**

Run:

```bash
cd mysql/proxysql/python
python3 -m compileall -q proxysql_monitor tests
python3 -m unittest discover -s tests -v

cd ../go
go test ./...
go test -race ./...
go vet ./...
```

Expected: all commands exit zero with no test failures, race reports, or vet findings.

- [ ] **Step 2: Cross-build supported Go targets**

Run:

```bash
GOOS=darwin GOARCH=arm64 go build -o /private/tmp/proxysql-monitor-darwin-arm64-legend ./cmd/proxysql-monitor
GOOS=linux GOARCH=amd64 go build -o /private/tmp/proxysql-monitor-linux-amd64-legend ./cmd/proxysql-monitor
file /private/tmp/proxysql-monitor-darwin-arm64-legend /private/tmp/proxysql-monitor-linux-amd64-legend
```

Expected: one Mach-O arm64 executable and one ELF x86-64 executable.

- [ ] **Step 3: Run Python and Go live PTY tests**

Run each monitor in a PTY with:

```bash
MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql ./proxysql_connections_monitor.py --login-path=devel-proxysql01-node01
MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql /private/tmp/proxysql-monitor-darwin-arm64-legend --login-path=devel-proxysql01-node01
```

Observe two refreshes and send `q` to each.

Expected: both screens show the colored two-line legend without wrapping, key input remains immediate, and each process exits zero.

- [ ] **Step 4: Rebuild and commit the tracked Darwin arm64 binary**

Run:

```bash
GOOS=darwin GOARCH=arm64 go build -o proxysql-monitor ./cmd/proxysql-monitor
file proxysql-monitor
git add proxysql-monitor
git commit -m "build(go): refresh monitor binary"
```

Expected: the tracked executable is Mach-O arm64 and contains the verified source behavior.

- [ ] **Step 5: Verify the final branch**

Run:

```bash
git diff main...HEAD --check
git status --short --branch
```

Expected: no whitespace errors and a clean feature branch.
