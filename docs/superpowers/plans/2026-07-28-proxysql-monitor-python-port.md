# ProxySQL Monitor Python Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an install-free Python 3.9+ ProxySQL monitor with Bash-feature parity, one persistent `mysql --login-path` child, deterministic offline tests, and explicit read-only smoke validation across three ProxySQL nodes.

**Architecture:** A thin launcher delegates to a typed `proxysql_monitor` package. The package separates CLI validation, SQL definitions, typed parsing, persistent process transport, pure formatting, terminal control, and application orchestration. All credentials remain inside the MySQL login-path mechanism.

**Tech Stack:** Python 3.9+, standard library (`argparse`, `dataclasses`, `subprocess`, `threading`, `queue`, `selectors`, `termios`, `unittest`), external MySQL CLI.

## Global Constraints

- Create all Python-port files under `mysql/proxysql/python/`.
- Support Python 3.9 or newer on macOS and Linux.
- Use Python type hints for every public function and method.
- Use only the Python standard library at runtime and in tests.
- Preserve the Bash monitor's flags, defaults, four views, keys, SQL meaning, colors, sanitization, delta semantics, clean logging, and stale-data behavior.
- Use one persistent `mysql --login-path=<name>` process per monitored node.
- Never invoke a shell or expose password/DSN arguments.
- Normal mode queries only the active view.
- Smoke mode queries all four views sequentially and executes only SELECT statements.
- Keep every code comment, document, log, and runtime message in English.
- Keep the simultaneous four-panel dashboard out of scope.

---

### Task 1: Typed Models, SQL Contract, and CLI

**Files:**
- Create: `mysql/proxysql/python/proxysql_monitor/__init__.py`
- Create: `mysql/proxysql/python/proxysql_monitor/models.py`
- Create: `mysql/proxysql/python/proxysql_monitor/queries.py`
- Create: `mysql/proxysql/python/proxysql_monitor/cli.py`
- Create: `mysql/proxysql/python/tests/__init__.py`
- Create: `mysql/proxysql/python/tests/test_cli.py`
- Create: `mysql/proxysql/python/tests/test_models.py`

**Interfaces:**
- Produces: `View`, `SortMode`, `Config`, `ConnectionRow`, `QueryRow`,
  `DigestRow`, `PoolRow`, `PingRow`, `BackendRows`, `MonitorState`, and
  `SmokeResult`.
- Produces: `parse_args(argv: Sequence[str]) -> Config`.
- Produces: `sql_for_view(view: View, sort_mode: SortMode) -> str`.
- Produces constants: `VERSION_SQL`, `HOSTNAME_SQL`, `BACKEND_SQL`,
  `BACKEND_POOL_MARKER`, and `BACKEND_PING_MARKER`.
- Consumes: no earlier task.

- [ ] **Step 1: Write failing CLI and SQL-contract tests**

Create literal behavior tests:

```python
from __future__ import annotations

import unittest

from proxysql_monitor.cli import parse_args
from proxysql_monitor.models import SortMode, View
from proxysql_monitor.queries import BACKEND_SQL, sql_for_view


class CLITests(unittest.TestCase):
    def test_normal_mode_preserves_float_refresh_and_threshold(self) -> None:
        config = parse_args([
            "--login-path=proxysql_admin",
            "--refresh-time=0.5",
            "--user-filter=app,report",
            "--threshold=12",
            "--output-file=/tmp/proxysql.log",
        ])
        self.assertEqual(("proxysql_admin",), config.login_paths)
        self.assertEqual(0.5, config.refresh_time)
        self.assertEqual(12, config.threshold)
        self.assertFalse(config.smoke_test)

    def test_smoke_mode_accepts_repeated_login_paths(self) -> None:
        config = parse_args([
            "--smoke-test",
            "--login-path=node01",
            "--login-path=node02",
            "--login-path=node03",
        ])
        self.assertEqual(("node01", "node02", "node03"), config.login_paths)

    def test_normal_mode_rejects_multiple_login_paths(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one"):
            parse_args(["--login-path=node01", "--login-path=node02"])

    def test_zero_refresh_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "greater than zero"):
            parse_args(["--login-path=node01", "--refresh-time=0"])

    def test_backend_sql_contains_both_read_only_sources(self) -> None:
        self.assertIn("stats.stats_mysql_connection_pool", BACKEND_SQL)
        self.assertIn("monitor.mysql_server_ping_log", BACKEND_SQL)
        self.assertNotIn("UPDATE ", BACKEND_SQL.upper())

    def test_conn_sort_changes_only_order_clause(self) -> None:
        by_conn = sql_for_view(View.CONN, SortMode.CONN)
        by_user = sql_for_view(View.CONN, SortMode.USER)
        self.assertIn("ORDER BY COUNT(*) DESC", by_conn)
        self.assertIn("ORDER BY user ASC", by_user)
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_cli -v
```

Expected: import failure because the package modules do not exist.

- [ ] **Step 3: Implement the typed configuration and models**

Define exact enums and dataclasses:

```python
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Optional, Tuple


class View(str, Enum):
    CONN = "CONN"
    QUERY = "QUERY"
    DIGEST = "DIGEST"
    BACKEND = "BACKEND"


class SortMode(str, Enum):
    CONN = "CONN"
    USER = "USER"


@dataclass(frozen=True)
class Config:
    login_paths: Tuple[str, ...]
    refresh_time: float = 5.0
    user_filter: str = ""
    threshold: int = 0
    output_file: Optional[Path] = None
    smoke_test: bool = False
    query_timeout: float = 5.0


@dataclass(frozen=True)
class ConnectionRow:
    user: str
    client_host: str
    server_host: str
    schema: str
    connections: int


@dataclass(frozen=True)
class QueryRow:
    session_id: str
    hostgroup: str
    user: str
    client_host: str
    server_host: str
    time_ms: int
    query: str


@dataclass(frozen=True)
class DigestRow:
    digest: str
    count: int
    sum_time: int
    min_time: int
    max_time: int
    query: str


@dataclass(frozen=True)
class PoolRow:
    hostgroup: str
    server_host: str
    status: str
    conn_used: int
    conn_free: int
    conn_ok: int
    conn_err: int


@dataclass(frozen=True)
class PingRow:
    hostname: str
    last_ping: str
    success_us: Optional[int]
    error: str


@dataclass(frozen=True)
class BackendRows:
    pool: Tuple[PoolRow, ...]
    ping: Tuple[PingRow, ...]


@dataclass
class MonitorState:
    view: View = View.CONN
    sort_mode: SortMode = SortMode.CONN
    paused: bool = False
    stale: bool = False
    last_error: str = ""
    previous_connections: Tuple[ConnectionRow, ...] = field(default_factory=tuple)
    last_rendered: str = ""
```

Add `SmokeResult` with `login_path`, `view`, `rows`, `elapsed_seconds`,
`success`, and `error` fields.

- [ ] **Step 4: Implement validated CLI parsing and exact SQL constants**

Use one `argparse.ArgumentParser(add_help=True)` with `action="append"` for
login paths. Track whether incompatible smoke options were explicitly passed
by scanning `argv` before applying defaults. Raise `ValueError` for semantic
validation so tests and the launcher can handle errors consistently.

Define SQL by copying the SELECT statements from the merged Bash monitor.
`BACKEND_SQL` must emit `__PXMON_POOL__` and `__PXMON_PING__` section rows
around both backend SELECT statements.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_cli tests.test_models -v
python3 -m compileall -q .
```

Expected: all tests and compilation exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/python
git commit -m "feat(python): add ProxySQL monitor contracts"
```

---

### Task 2: Persistent Framed MySQL Transport

**Files:**
- Create: `mysql/proxysql/python/proxysql_monitor/transport.py`
- Create: `mysql/proxysql/python/tests/fake_mysql.py`
- Create: `mysql/proxysql/python/tests/test_transport.py`

**Interfaces:**
- Consumes: a login-path name and five-second default timeout from `Config`.
- Produces: `TransportError`.
- Produces: `PersistentMySQLSession.start()`, `is_alive()`, `execute(sql,
  timeout=5.0)`, `execute_with_retry(sql, timeout=5.0)`, `reconnect()`, and
  `close()`.
- Produces: context-manager methods returning and closing the same session.

- [ ] **Step 1: Write a protocol-aware fake MySQL process**

Implement a standalone standard-library fake that reads stdin line by line,
records its PID in `FAKE_MYSQL_STATE_DIR/launches`, echoes PXMON begin/end
sentinels, and returns literal fixture rows for tokens:

```python
RESPONSES = {
    "TEST_CONNECTIONS": "app\tclient\tbackend:3306\tappdb\t4",
    "TEST_SECOND_SAMPLE": "app\tclient\tbackend:3306\tappdb\t6",
    "SELECT @@version": "2.7.3",
    "SELECT @@hostname": "proxysql-test",
}
```

Environment switches:

- `FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH=1`: suppress one end sentinel.
- `FAKE_MYSQL_EXIT_ON_TOKEN=<token>`: exit when that token is read.
- `FAKE_MYSQL_STDERR_LINES=<count>`: emit that many stderr lines.

Start the file with `#!/usr/bin/env python3` and mark it executable before
running transport tests:

```bash
chmod +x mysql/proxysql/python/tests/fake_mysql.py
```

- [ ] **Step 2: Write failing transport lifecycle tests**

```python
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from proxysql_monitor.transport import PersistentMySQLSession


class TransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="pxmon-python-")
        self.state = Path(self.tmp.name)
        os.environ["FAKE_MYSQL_STATE_DIR"] = str(self.state)
        self.mysql_bin = str(Path(__file__).with_name("fake_mysql.py"))

    def tearDown(self) -> None:
        os.environ.pop("FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH", None)
        self.tmp.cleanup()

    def test_multiple_requests_use_one_child(self) -> None:
        with PersistentMySQLSession("node01", mysql_bin=self.mysql_bin) as session:
            self.assertEqual(
                ["app\tclient\tbackend:3306\tappdb\t4"],
                session.execute("SELECT 'TEST_CONNECTIONS';"),
            )
            session.execute("SELECT 'TEST_SECOND_SAMPLE';")
        self.assertEqual(1, len((self.state / "launches").read_text().splitlines()))

    def test_timeout_reconnects_once_and_retries(self) -> None:
        os.environ["FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH"] = "1"
        with PersistentMySQLSession("node01", mysql_bin=self.mysql_bin) as session:
            rows = session.execute_with_retry(
                "SELECT 'TEST_CONNECTIONS';", timeout=0.1
            )
        self.assertEqual(["app\tclient\tbackend:3306\tappdb\t4"], rows)
        self.assertEqual(2, len((self.state / "launches").read_text().splitlines()))

    def test_close_is_idempotent_and_reaps_child(self) -> None:
        session = PersistentMySQLSession("node01", mysql_bin=self.mysql_bin)
        session.start()
        process = session.process
        session.close()
        session.close()
        self.assertIsNotNone(process)
        self.assertIsNotNone(process.poll())
```

- [ ] **Step 3: Run transport tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_transport -v
```

Expected: import failure because `transport.py` does not exist.

- [ ] **Step 4: Implement the transport**

Use these exact constructor fields:

```python
class PersistentMySQLSession:
    def __init__(
        self,
        login_path: str,
        *,
        mysql_bin: str = "mysql",
        queue_size: int = 4096,
        stderr_lines: int = 100,
    ) -> None:
        self.login_path = login_path
        self.mysql_bin = mysql_bin
        self.queue_size = queue_size
        self.stderr_lines = stderr_lines
        self.process: Optional[subprocess.Popen[str]] = None
        self._sequence = 0
        self._closed = False
```

Start `subprocess.Popen` with the argument list:

```python
[
    self.mysql_bin,
    f"--login-path={self.login_path}",
    "--batch",
    "--raw",
    "--skip-column-names",
    "--unbuffered",
    "--force",
]
```

Set `shell=False`, `text=True`, `bufsize=1`, and pipe stdin/stdout/stderr.
Reader threads publish stripped stdout lines to a bounded queue and append
stderr lines to `collections.deque(maxlen=stderr_lines)`.

`execute` increments a sequence under a lock, writes the three framed SQL
parts, flushes, waits on `queue.get(timeout=remaining)`, ignores data before
the matching begin marker, and returns only after the matching end marker.
Raise `TransportError` on timeout, EOF, dead process, queue overflow, or write
failure. Serialize requests with one execution lock.

An internal `_stop_process()` closes the current generation, joins its readers,
and clears its queue. `reconnect()` calls `_stop_process()` and starts a fresh
generation with new pipes, queue, and readers. Final `close()` marks the
session closed so later starts are rejected, calls `_stop_process()`, and is
idempotent. Process shutdown closes stdin, calls `terminate`, waits at most one
second, calls `kill` if required, and waits again.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_transport -v
python3 -m unittest discover -s tests -v
```

Expected: all tests exit 0 and no `fake_mysql.py` child remains.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/python
git commit -m "feat(python): add persistent MySQL transport"
```

---

### Task 3: Typed Parsing and Pure Formatting

**Files:**
- Create: `mysql/proxysql/python/proxysql_monitor/formatter.py`
- Create: `mysql/proxysql/python/tests/fixtures.py`
- Create: `mysql/proxysql/python/tests/test_formatter.py`
- Modify: `mysql/proxysql/python/proxysql_monitor/models.py`

**Interfaces:**
- Produces: `parse_connections`, `parse_queries`, `parse_digests`, and
  `parse_backend`.
- Produces: `compile_user_filter`.
- Produces: `format_connections`, `format_queries`, `format_digests`, and
  `format_backend`, each returning `RenderedView(colored, clean, row_count)`.
- Consumes: typed rows and `MonitorState`.

- [ ] **Step 1: Write failing parsing and golden-output tests**

Use literal fixtures:

```python
CONNECTIONS_PREVIOUS = ["app\tclient\tbackend:3306\tappdb\t4"]
CONNECTIONS_CURRENT = ["app\tclient\tbackend:3306\tappdb\t6"]
QUERY_ESCAPED = ["11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n*\\tFROM t"]
DIGEST_ESCAPED = ["0x123\t8\t12000\t100\t4000\tSELECT\\tcol FROM t"]
BACKEND = [
    "__PXMON_POOL__",
    "10\tbackend:3306\tONLINE\t2\t3\t50\t1",
    "__PXMON_PING__",
    "backend\t2026-07-28 12:00:00\t500\t",
]
```

Tests must assert:

```python
previous = parse_connections(CONNECTIONS_PREVIOUS)
current = parse_connections(CONNECTIONS_CURRENT)
rendered = format_connections(current, previous, threshold=0, user_filter="")
self.assertIn("+2", rendered.clean)
self.assertEqual(1, rendered.row_count)

query = format_queries(parse_queries(QUERY_ESCAPED), user_filter="")
self.assertIn("SELECT * FROM t", query.clean)
self.assertIn("\x1b[", query.colored)

backend = parse_backend(BACKEND)
self.assertEqual("ONLINE", backend.pool[0].status)
self.assertEqual(500, backend.ping[0].success_us)
```

Also assert malformed nonempty rows raise `ValueError`, empty lists parse
successfully, regex filters preserve comma-as-alternation, ANSI does not change
visible padded width, and long DIGEST text truncates according to terminal
width.

- [ ] **Step 2: Run formatter tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_formatter -v
```

Expected: import failure because formatter functions do not exist.

- [ ] **Step 3: Implement strict parsers**

Split each row on `"\t"` with a bounded maximum split that preserves the final
query field. Validate exact minimum counts:

- CONN: 5.
- QUERY: 7, split at most 6 times.
- DIGEST: 6, split at most 5 times.
- POOL: 7.
- PING: 4, split at most 3 times.

Use a shared `_parse_int(value, field_name)` that raises
`ValueError(f"Invalid {field_name}: {value!r}")`. `parse_backend` must reject a
nonempty payload without both section markers.

- [ ] **Step 4: Implement pure rendering**

Define:

```python
@dataclass(frozen=True)
class RenderedView:
    colored: str
    clean: str
    row_count: int
```

Use ANSI constants, a `sanitize_text` function with replacements for escaped
and literal controls, and `truncate(value, width)`. Build padded text first and
add colors around the already padded fields. Derive `clean` from the same
logical row data, never by stripping the colored result.

CONN deltas use a key tuple of user, client host, server host, and schema.
QUERY time uses red above 1000 ms, yellow above 500 ms, white otherwise.
DIGEST query width is `max(50, terminal_width - 75)`.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_formatter -v
python3 -m unittest discover -s tests -v
```

Expected: all tests exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/python
git commit -m "feat(python): add typed ProxySQL view formatting"
```

---

### Task 4: Terminal State and Interactive Application

**Files:**
- Create: `mysql/proxysql/python/proxysql_monitor/terminal.py`
- Create: `mysql/proxysql/python/proxysql_monitor/app.py`
- Create: `mysql/proxysql/python/tests/test_terminal.py`
- Create: `mysql/proxysql/python/tests/test_app.py`

**Interfaces:**
- Produces: `TerminalController` context manager with `read_key`,
  `prompt`, `size`, `clear`, and `mark_geometry_dirty`.
- Produces: `MonitorApp.sample_current_view`, `handle_key`, `render`, `log`,
  `run`, and `close`.
- Consumes: `Config`, `PersistentMySQLSession`, queries, parsers, formatters,
  input/output streams, and a clock dependency.

- [ ] **Step 1: Write failing state-transition tests**

Use an in-memory fake session whose `execute_with_retry` returns literal rows.
Assert:

```python
app = MonitorApp(config, session=fake_session, terminal=fake_terminal)
app.handle_key("v")
self.assertEqual(View.QUERY, app.state.view)
self.assertFalse(app.state.paused)

app.handle_key("p")
self.assertTrue(app.state.paused)
app.handle_key("p")
self.assertFalse(app.state.paused)

app.state.last_rendered = "last valid"
fake_session.error = TransportError("ProxySQL unavailable")
self.assertFalse(app.sample_current_view())
self.assertTrue(app.state.stale)
self.assertEqual("last valid", app.state.last_rendered)
```

Add tests for view order, CONN sort reset, validated refresh/threshold prompts,
filter changes, resize dirtiness, quit, logging only successful nonempty
samples, and no stale log duplication.

- [ ] **Step 2: Run app tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_terminal tests.test_app -v
```

Expected: imports fail because terminal and application modules do not exist.

- [ ] **Step 3: Implement terminal control**

`TerminalController.__enter__` stores `termios.tcgetattr(fd)` and calls
`tty.setcbreak(fd)` only when `isatty()` is true. `read_key(timeout)` uses
`select.select([stdin], [], [], timeout)`. `prompt` restores saved terminal
attributes, reads one line, and re-enters cbreak mode in `finally`.
`__exit__` restores the exact saved attributes once.

Use `shutil.get_terminal_size(fallback=(130, 24))` and enforce a 110-column
minimum matching Bash behavior. `clear` writes `"\x1b[H\x1b[2J"` to the
configured output stream.

- [ ] **Step 4: Implement application sampling and event loop**

Inject `session`, `terminal`, `clock=time.monotonic`, and
`wall_clock=datetime.now` for deterministic tests. `sample_current_view`
selects exactly one SQL payload, parses and formats it, updates CONN baseline
only on success, clears stale state, and writes a clean log sample only when
row count is nonzero.

`run` samples, renders, waits for a key for the remaining refresh interval,
handles it, and repeats until quit or signal cancellation. `close` is
idempotent and closes the session and output file.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_terminal tests.test_app -v
python3 -m unittest discover -s tests -v
```

Expected: all tests exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/python
git commit -m "feat(python): add interactive ProxySQL monitor"
```

---

### Task 5: Launcher, Smoke Mode, Documentation, and Live Acceptance

**Files:**
- Create: `mysql/proxysql/python/proxysql_monitor/__main__.py`
- Create: `mysql/proxysql/python/proxysql_connections_monitor.py`
- Create: `mysql/proxysql/python/README.md`
- Create: `mysql/proxysql/python/tests/test_live_smoke.py`
- Modify: `mysql/proxysql/python/proxysql_monitor/app.py`
- Modify: `mysql/proxysql/python/proxysql_monitor/cli.py`

**Interfaces:**
- Produces: `run_smoke(config: Config) -> Sequence[SmokeResult]`.
- Produces: `resolve_display_host(login_path, session) -> str`.
- Produces: `main(argv: Optional[Sequence[str]] = None) -> int`.
- Consumes: every earlier Python component.

- [ ] **Step 1: Write failing multi-node smoke tests**

Inject a session factory keyed by login path. Assert node order, view order,
typed parsing, timings, cleanup after each node, empty-view success, malformed
row failure, missing BACKEND marker failure, and aggregate nonzero status.

Literal order:

```python
expected = [
    ("node01", View.CONN),
    ("node01", View.QUERY),
    ("node01", View.DIGEST),
    ("node01", View.BACKEND),
    ("node02", View.CONN),
    ("node02", View.QUERY),
    ("node02", View.DIGEST),
    ("node02", View.BACKEND),
]
self.assertEqual(expected, [(r.login_path, r.view) for r in results])
```

- [ ] **Step 2: Run smoke tests and verify RED**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest tests.test_live_smoke -v
```

Expected: import failure because `run_smoke` and launcher `main` do not exist.

- [ ] **Step 3: Implement smoke orchestration and entry points**

For each login path, create one session in a context manager, validate version
and resolved hostname, then run CONN, QUERY, DIGEST, and BACKEND in that exact
order. `resolve_display_host` calls `subprocess.run` with the direct argument
list `["mysql_config_editor", "print", "--login-path="+login_path]`, a
two-second timeout, `shell=False`, and captured text. It parses the first host
field and falls back to `session.execute(HOSTNAME_SQL)` when the command fails
or has no host. Measure views with `time.monotonic`. Append one `SmokeResult`
per view and continue to later nodes after recording a node failure.

`main` prints colored PASS/FAIL rows containing login path, view, row count,
elapsed milliseconds, and error. Return 0 only when every result succeeds.
Normal mode installs `SIGINT`/`SIGTERM` handlers, creates the terminal/session,
and runs `MonitorApp`.

The top-level launcher must contain:

```python
#!/usr/bin/env python3
from proxysql_monitor.__main__ import main

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Write complete README**

Document:

- Python 3.9+, macOS/Linux, and MySQL CLI requirements.
- Install-free invocation.
- Every option and interactive key.
- Persistent-session and reconnect behavior.
- Output logging behavior.
- Offline test commands.
- Exact three-node smoke command.
- Explicit statement that smoke mode issues SELECT statements only.
- Normal, filtered, logging, and `rmateos` sub-second examples.

- [ ] **Step 5: Run offline verification**

Run:

```bash
cd mysql/proxysql/python
python3 -m unittest discover -s tests -v
python3 -m compileall -q .
python3 proxysql_connections_monitor.py --help
```

Expected: tests and compilation exit 0; help lists all options and examples.

- [ ] **Step 6: Run approved live smoke validation**

Run:

```bash
cd mysql/proxysql/python
python3 proxysql_connections_monitor.py \
  --smoke-test \
  --login-path=devel-proxysql01-node01 \
  --login-path=devel-proxysql01-node02 \
  --login-path=devel-proxysql01-node03
```

Expected: twelve PASS rows—four views for each of three nodes—and exit 0.
Record empty views as PASS with zero rows.

- [ ] **Step 7: Verify cleanup and commit**

Verify no monitor child remains, `git diff --check` exits 0, then:

```bash
git add mysql/proxysql/python
git commit -m "feat(python): complete ProxySQL monitor port"
```
