# Backend Status Colors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct backend and ping health colors consistently in the Bash, Python, and Go ProxySQL monitors.

**Architecture:** Each formatter maps normalized ProxySQL status values to a fixed full-row ANSI color and treats empty/textual `NULL` ping errors as success. Queries, models, transport, refresh behavior, clean output, and process counts remain unchanged.

**Tech Stack:** Bash 3.2 with POSIX AWK; Python 3 with type hints and `unittest`; Go 1.22+; ANSI SGR and ANSI 256-color index 208.

## Global Constraints

- Apply the same status semantics to Bash, Python, and Go.
- `ONLINE` is green, `SHUNNED` yellow, `OFFLINE_SOFT` orange 208, `OFFLINE_HARD` red, and unknown status red.
- `ConnERR` remains visible but never controls health color.
- Empty or textual `NULL` `ping_error` is green; actual errors are red.
- Preserve the original displayed status, counters, and ping-error text.
- Clean/log output remains ANSI-free.
- Do not add SQL, processes, timers, terminal-capability probes, or refresh work.
- Rebuild the tracked Darwin arm64 Go binary only after source verification.

---

### Task 1: Bash Backend and Ping Color Semantics

**Files:**
- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh`

**Interfaces:**
- Consumes: `format_backend_data "$payload"`, `AWK_SCRIPT_BACKEND`, and injected Bash color variables.
- Produces: full-row `F_POOL` and `F_PING` ANSI output with the approved mapping.

- [ ] **Step 1: Add failing Bash formatter assertions**

Add a test helper that finds the line containing a token and verifies its color prefix/suffix:

```bash
assert_line_color() {
    local output=$1
    local token=$2
    local color=$3
    local line=""

    while IFS= read -r line; do
        case "$line" in
            *"$token"*)
                case "$line" in
                    "$color"*"$off") return 0 ;;
                    *) fail "$token has the wrong row color: [$line]" ;;
                esac
                ;;
        esac
    done <<< "$output"
    fail "missing formatter row for $token"
}
```

Before the existing BACKEND formatter assertion, inject deterministic marker colors and format all states plus ping outcomes:

```bash
grn='<GREEN>'
yel='<YELLOW>'
ora='<ORANGE>'
red='<RED>'
off='<RESET>'
backend_payload=$'__PXMON_POOL__\n10\tonline:3306\tONLINE\t2\t3\t50\t9\n11\tshunned:3306\tSHUNNED\t0\t0\t0\t1\n12\tsoft:3306\tOFFLINE_SOFT\t0\t0\t0\t2\n13\thard:3306\tOFFLINE_HARD\t0\t0\t0\t3\n14\tunknown:3306\tNEW_STATE\t0\t0\t0\t4\n__PXMON_PING__\nok-null\t2026-08-04 12:00:00\t500\tNULL\nok-empty\t2026-08-04 12:00:01\t600\t\nbad\t2026-08-04 12:00:02\tNULL\tconnection refused'
format_backend_data "$backend_payload"
assert_line_color "$F_POOL" 'ONLINE' "$grn"
assert_line_color "$F_POOL" 'SHUNNED' "$yel"
assert_line_color "$F_POOL" 'OFFLINE_SOFT' "$ora"
assert_line_color "$F_POOL" 'OFFLINE_HARD' "$red"
assert_line_color "$F_POOL" 'NEW_STATE' "$red"
assert_line_color "$F_PING" 'ok-null' "$grn"
assert_line_color "$F_PING" 'ok-empty' "$grn"
assert_line_color "$F_PING" 'bad' "$red"
```

- [ ] **Step 2: Run the Bash suite and verify RED**

Run:

```bash
bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: FAIL because rows are not fully colored, non-ONLINE states are all red, and textual `NULL` ping errors are red.

- [ ] **Step 3: Implement the Bash status map**

Add the portable literal orange sequence in `initialize_colors`:

```bash
ora=$'\033[1;38;5;208m'
```

Update `AWK_SCRIPT_BACKEND` with deterministic normalization and selection:

```awk
function trimmed_upper(value) {
    gsub(/^[ \t]+|[ \t]+$/, "", value)
    return toupper(value)
}
function pool_color(status, normalized) {
    normalized = trimmed_upper(status)
    if (normalized == "ONLINE") return color_ok
    if (normalized == "SHUNNED") return color_warn
    if (normalized == "OFFLINE_SOFT") return color_soft
    return color_err
}
```

For pool rows, wrap the complete formatted row with `pool_color($3)` and `color_off`. For ping rows, use:

```awk
ping_key = trimmed_upper($4)
ping_color = (ping_key == "" || ping_key == "NULL") ? color_ok : color_err
```

Wrap the complete ping row with `ping_color` and `color_off`, preserving `$4` exactly. Pass the two new AWK variables from `format_backend_data`:

```bash
-v color_warn="$yel" \
-v color_soft="$ora" \
```

- [ ] **Step 4: Run Bash syntax and full tests and verify GREEN**

Run:

```bash
bash -n mysql/proxysql/proxysql_connections_monitor.sh
bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
bash mysql/proxysql/tests/benchmark_process_count.sh
```

Expected: syntax and behavior pass; the benchmark reports the existing single persistent MySQL child/process profile.

- [ ] **Step 5: Commit the Bash implementation**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests/test_proxysql_connections_monitor.sh
git commit -m "fix(bash): map backend health colors by status"
```

### Task 2: Python Backend and Ping Color Semantics

**Files:**
- Modify: `mysql/proxysql/python/tests/test_formatter.py`
- Modify: `mysql/proxysql/python/proxysql_monitor/formatter.py`

**Interfaces:**
- Consumes: `parse_backend(lines)` and `format_backend(rows) -> RenderedView`.
- Produces: `_backend_status_color(status: str) -> str` and corrected ping-row selection.

- [ ] **Step 1: Add failing Python formatter tests**

Import `GREEN`, `YELLOW`, `ORANGE`, and `RED` from the formatter and add:

```python
def test_backend_status_colors_ignore_cumulative_conn_errors(self) -> None:
    backend = parse_backend([
        "__PXMON_POOL__",
        "10\tonline:3306\tONLINE\t2\t3\t50\t9",
        "11\tshunned:3306\tSHUNNED\t0\t0\t0\t1",
        "12\tsoft:3306\tOFFLINE_SOFT\t0\t0\t0\t2",
        "13\thard:3306\tOFFLINE_HARD\t0\t0\t0\t3",
        "14\tunknown:3306\tNEW_STATE\t0\t0\t0\t4",
        "__PXMON_PING__",
    ])
    lines = format_backend(backend).colored.splitlines()[1:]
    self.assertTrue(lines[0].startswith(GREEN))
    self.assertTrue(lines[1].startswith(YELLOW))
    self.assertTrue(lines[2].startswith(ORANGE))
    self.assertTrue(lines[3].startswith(RED))
    self.assertTrue(lines[4].startswith(RED))

def test_backend_ping_null_and_empty_are_success(self) -> None:
    backend = parse_backend([
        "__PXMON_POOL__",
        "__PXMON_PING__",
        "ok-null\t2026-08-04 12:00:00\t500\tNULL",
        "ok-empty\t2026-08-04 12:00:01\t600\t",
        "bad\t2026-08-04 12:00:02\tNULL\tconnection refused",
    ])
    lines = format_backend(backend).colored.splitlines()[1:]
    self.assertTrue(lines[0].startswith(GREEN))
    self.assertTrue(lines[1].startswith(GREEN))
    self.assertTrue(lines[2].startswith(RED))
    self.assertNotIn("\x1b", format_backend(backend).clean)
```

- [ ] **Step 2: Run focused Python tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest \
  tests.test_formatter.FormatterTests.test_backend_status_colors_ignore_cumulative_conn_errors \
  tests.test_formatter.FormatterTests.test_backend_ping_null_and_empty_are_success -v
```

Expected: import/error or assertion failure because `ORANGE` and the new mapping do not exist and `NULL` is treated as an error.

- [ ] **Step 3: Implement the Python mapping**

Add:

```python
ORANGE = "\x1b[1;38;5;208m"


def _backend_status_color(status: str) -> str:
    return {
        "ONLINE": GREEN,
        "SHUNNED": YELLOW,
        "OFFLINE_SOFT": ORANGE,
        "OFFLINE_HARD": RED,
    }.get(status.strip().upper(), RED)
```

Use `_backend_status_color(row.status)` for every pool row. For ping rows, preserve `row.error` in output and select:

```python
normalized_error = row.error.strip().upper()
color = GREEN if normalized_error in ("", "NULL") else RED
```

- [ ] **Step 4: Run focused and complete Python tests and verify GREEN**

Run:

```bash
python3 -m unittest \
  tests.test_formatter.FormatterTests.test_backend_status_colors_ignore_cumulative_conn_errors \
  tests.test_formatter.FormatterTests.test_backend_ping_null_and_empty_are_success -v
python3 -m compileall -q proxysql_monitor tests
python3 -m unittest discover -s tests -v
```

Expected: both focused tests and the complete suite pass.

- [ ] **Step 5: Commit the Python implementation**

```bash
git add mysql/proxysql/python/proxysql_monitor/formatter.py mysql/proxysql/python/tests/test_formatter.py
git commit -m "fix(python): map backend health colors by status"
```

### Task 3: Go Backend and Ping Color Semantics

**Files:**
- Modify: `mysql/proxysql/go/internal/formatter/formatter_test.go`
- Modify: `mysql/proxysql/go/internal/formatter/formatter.go`

**Interfaces:**
- Consumes: `ParseBackend([]string) (model.BackendRows, error)` and `FormatBackend(model.BackendRows) model.RenderedView`.
- Produces: `backendStatusColor(string) string` and corrected ping-row selection.

- [ ] **Step 1: Add failing Go formatter tests**

Add table-driven status and ping tests that parse real framed rows:

```go
func TestBackendStatusColorsIgnoreCumulativeConnErrors(t *testing.T) {
    rows, err := ParseBackend([]string{
        "__PXMON_POOL__",
        "10\tonline:3306\tONLINE\t2\t3\t50\t9",
        "11\tshunned:3306\tSHUNNED\t0\t0\t0\t1",
        "12\tsoft:3306\tOFFLINE_SOFT\t0\t0\t0\t2",
        "13\thard:3306\tOFFLINE_HARD\t0\t0\t0\t3",
        "14\tunknown:3306\tNEW_STATE\t0\t0\t0\t4",
        "__PXMON_PING__",
    })
    if err != nil { t.Fatal(err) }
    lines := strings.Split(FormatBackend(rows).Colored, "\n")[1:]
    wants := []string{green, yellow, orange, red, red}
    for index, want := range wants {
        if !strings.HasPrefix(lines[index], want) {
            t.Fatalf("line %d color = %q, want prefix %q", index, lines[index], want)
        }
    }
}

func TestBackendPingNullAndEmptyAreSuccess(t *testing.T) {
    rows, err := ParseBackend([]string{
        "__PXMON_POOL__", "__PXMON_PING__",
        "ok-null\t2026-08-04 12:00:00\t500\tNULL",
        "ok-empty\t2026-08-04 12:00:01\t600\t",
        "bad\t2026-08-04 12:00:02\tNULL\tconnection refused",
    })
    if err != nil { t.Fatal(err) }
    rendered := FormatBackend(rows)
    lines := strings.Split(rendered.Colored, "\n")[1:]
    wants := []string{green, green, red}
    for index, want := range wants {
        if !strings.HasPrefix(lines[index], want) {
            t.Fatalf("line %d color = %q, want prefix %q", index, lines[index], want)
        }
    }
    if strings.Contains(rendered.Clean, "\x1b") { t.Fatal("clean backend output contains ANSI") }
}
```

- [ ] **Step 2: Run focused Go tests and verify RED**

Run:

```bash
cd mysql/proxysql/go
go test ./internal/formatter -run 'TestBackend(StatusColors|PingNull)' -count=1
```

Expected: compilation/assertion failure because `orange` and the required mapping do not exist.

- [ ] **Step 3: Implement the Go mapping**

Add the constant and helper:

```go
orange = "\x1b[1;38;5;208m"

func backendStatusColor(status string) string {
    switch strings.ToUpper(strings.TrimSpace(status)) {
    case "ONLINE":
        return green
    case "SHUNNED":
        return yellow
    case "OFFLINE_SOFT":
        return orange
    case "OFFLINE_HARD":
        return red
    default:
        return red
    }
}
```

Use `backendStatusColor(row.Status)` for pool rows. For ping rows, preserve `row.Error` and select green when:

```go
normalizedError := strings.ToUpper(strings.TrimSpace(row.Error))
color := green
if normalizedError != "" && normalizedError != "NULL" {
    color = red
}
```

- [ ] **Step 4: Format and run focused/full Go tests and verify GREEN**

Run:

```bash
gofmt -w internal/formatter/formatter.go internal/formatter/formatter_test.go
go test ./internal/formatter -run 'TestBackend(StatusColors|PingNull)' -count=1
go test ./...
```

Expected: focused and complete tests pass.

- [ ] **Step 5: Commit the Go source implementation**

```bash
git add mysql/proxysql/go/internal/formatter/formatter.go mysql/proxysql/go/internal/formatter/formatter_test.go
git commit -m "fix(go): map backend health colors by status"
```

### Task 4: Full, Cross-Platform, Live, and Binary Verification

**Files:**
- Modify: `mysql/proxysql/go/proxysql-monitor`
- Verify: all Bash, Python, and Go monitor sources/tests.

**Interfaces:**
- Consumes: the three verified formatter implementations.
- Produces: final cross-platform evidence and a refreshed tracked Darwin arm64 Go executable.

- [ ] **Step 1: Run complete static and automated verification**

Run:

```bash
bash -n mysql/proxysql/proxysql_connections_monitor.sh
bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
bash mysql/proxysql/tests/benchmark_process_count.sh

cd mysql/proxysql/python
python3 -m compileall -q proxysql_monitor tests
python3 -m unittest discover -s tests -v

cd ../go
go test ./...
go test -race ./...
go vet ./...
```

Expected: every command exits zero, with no race report or vet finding and no process-count regression.

- [ ] **Step 2: Cross-build Darwin and Linux**

Run:

```bash
GOOS=darwin GOARCH=arm64 go build -o /private/tmp/proxysql-monitor-darwin-arm64-colors ./cmd/proxysql-monitor
GOOS=linux GOARCH=amd64 go build -o /private/tmp/proxysql-monitor-linux-amd64-colors ./cmd/proxysql-monitor
file /private/tmp/proxysql-monitor-darwin-arm64-colors /private/tmp/proxysql-monitor-linux-amd64-colors
```

Expected: Mach-O arm64 and ELF x86-64 executables.

- [ ] **Step 3: Run live PTY verification**

Run Bash, Python, and the temporary Go Darwin build in PTYs with `--login-path=devel-proxysql01-node01`. Observe the BACKEND view and exit each with `q`:

```bash
MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql ./proxysql_connections_monitor.sh --login-path=devel-proxysql01-node01
MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql ./proxysql_connections_monitor.py --login-path=devel-proxysql01-node01
MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql /private/tmp/proxysql-monitor-darwin-arm64-colors --login-path=devel-proxysql01-node01
```

Expected: `ONLINE` rows with historical `ConnERR` and successful `ping_error=NULL` rows are green in all three monitors; refresh and keys remain responsive.

- [ ] **Step 4: Rebuild and commit the tracked Go binary**

Run:

```bash
GOOS=darwin GOARCH=arm64 go build -o proxysql-monitor ./cmd/proxysql-monitor
file proxysql-monitor
git add proxysql-monitor
git commit -m "build(go): refresh backend color binary"
```

- [ ] **Step 5: Verify the final branch**

Run:

```bash
git diff main...HEAD --check
git status --short --branch
```

Expected: a clean feature branch with no whitespace errors.
