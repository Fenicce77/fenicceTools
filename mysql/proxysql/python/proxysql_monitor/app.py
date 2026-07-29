from __future__ import annotations

import math
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, ContextManager, Optional, Protocol, Sequence

from .formatter import (
    RenderedView,
    compile_user_filter,
    format_backend,
    format_connections,
    format_digests,
    format_queries,
    parse_backend,
    parse_connections,
    parse_digests,
    parse_queries,
    sanitize_text,
)
from .models import Config, MonitorState, SmokeResult, SortMode, View
from .queries import (
    BACKEND_PING_MARKER,
    BACKEND_POOL_MARKER,
    HOSTNAME_SQL,
    VERSION_SQL,
    sql_for_view,
)
from .terminal import TerminalController
from .transport import PersistentMySQLSession, TransportError

_BOLD = "\x1b[1m"
_BLUE = "\x1b[1;34m"
_GREEN = "\x1b[1;32m"
_YELLOW = "\x1b[1;33m"
_RED = "\x1b[1;31m"
_MAGENTA = "\x1b[1;35m"
_RESET = "\x1b[0m"


def _interactive_legend() -> str:
    """Return the fixed-width colored controls shown below interactive data."""
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


class Session(Protocol):
    def execute_with_retry(self, sql: str, timeout: float = 5.0) -> Sequence[str]:
        ...

    def close(self) -> None:
        ...


class Terminal(Protocol):
    def prompt(self, message: str) -> str:
        ...

    def size(self) -> tuple[int, int]:
        ...

    def clear(self) -> None:
        ...

    def read_key(self, timeout: float) -> Optional[str]:
        ...

    def mark_geometry_dirty(self) -> None:
        ...


class MonitorApp:
    """Coordinate sampling, state transitions, rendering, and clean logging."""

    def __init__(
        self,
        config: Config,
        *,
        session: Optional[Session] = None,
        terminal: Optional[Terminal] = None,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], datetime] = datetime.now,
    ) -> None:
        self.config = config
        self.session = session or PersistentMySQLSession(config.login_paths[0])
        self.terminal = terminal or TerminalController()
        self.clock = clock
        self.wall_clock = wall_clock
        self.state = MonitorState()
        self.refresh_time = config.refresh_time
        self.user_filter = config.user_filter
        self.threshold = config.threshold
        self.running = True
        self.display_host = config.login_paths[0]
        self.proxy_version = "Unknown"
        self.last_colored = ""
        self.last_row_count = 0
        self._closed = False

    def sample_current_view(self) -> bool:
        """Sample exactly the active view, retaining the prior screen on failure."""
        view = self.state.view
        try:
            raw = self.session.execute_with_retry(
                sql_for_view(view, self.state.sort_mode),
                timeout=self.config.query_timeout,
            )
            width, _height = self.terminal.size()
            if view is View.CONN:
                rows = parse_connections(raw)
                rendered = format_connections(
                    rows,
                    self.state.previous_connections,
                    threshold=self.threshold,
                    user_filter=self.user_filter,
                )
                self.state.previous_connections = rows
            elif view is View.QUERY:
                rendered = format_queries(
                    parse_queries(raw),
                    user_filter=self.user_filter,
                    terminal_width=width,
                )
            elif view is View.DIGEST:
                rendered = format_digests(
                    parse_digests(raw),
                    user_filter=self.user_filter,
                    terminal_width=width,
                )
            else:
                rendered = format_backend(parse_backend(raw), terminal_width=width)
        except (TransportError, ValueError) as exc:
            self.state.stale = True
            self.state.last_error = str(exc)
            return False

        self._accept_rendered(rendered)
        self.log(rendered)
        return True

    def handle_key(self, key: str) -> None:
        """Apply one interactive command."""
        normalized = key.lower()
        if normalized == "q":
            self.running = False
        elif normalized == "v":
            order = (View.CONN, View.QUERY, View.DIGEST, View.BACKEND)
            self.state.view = order[(order.index(self.state.view) + 1) % len(order)]
            self.state.paused = False
            if self.state.view is View.CONN:
                self.state.previous_connections = ()
        elif normalized == "s":
            self.state.paused = False
            if self.state.view is View.CONN:
                self.state.sort_mode = (
                    SortMode.USER if self.state.sort_mode is SortMode.CONN else SortMode.CONN
                )
                self.state.previous_connections = ()
        elif normalized == "p":
            self.state.paused = not self.state.paused
        elif normalized == "r":
            value = self.terminal.prompt("Enter new refresh time (seconds, e.g. 0.5): ")
            try:
                parsed = float(value)
                if parsed > 0 and math.isfinite(parsed):
                    self.refresh_time = parsed
            except ValueError:
                pass
        elif normalized == "t":
            value = self.terminal.prompt("Enter new connection threshold: ")
            try:
                parsed_threshold = int(value)
                if parsed_threshold >= 0:
                    self.threshold = parsed_threshold
            except ValueError:
                pass
        elif normalized == "u":
            value = self.terminal.prompt("Enter new user filter (empty to disable): ")
            try:
                compile_user_filter(value)
                self.user_filter = value
            except ValueError:
                pass

    def render(self) -> str:
        """Build and emit the current full-screen representation."""
        flags = []
        if self.state.paused:
            flags.append("PAUSED")
        if self.state.stale:
            flags.append(
                f"STALE: {sanitize_text(self.state.last_error) or 'ProxySQL unavailable'}"
            )
        flag_text = f" [{' | '.join(flags)}]" if flags else ""
        header = (
            f"ProxySQL Monitor | Server: {sanitize_text(self.display_host)} | "
            f"Version: {sanitize_text(self.proxy_version)} | "
            f"Mode: {self.state.view.value} | Refresh: {self.refresh_time:g}s{flag_text}"
        )
        filters = []
        if self.user_filter:
            filters.append(f"Filter: {sanitize_text(self.user_filter)}")
        if self.threshold:
            filters.append(f"Threshold: >= {self.threshold} conn")
        body = self.last_colored or "No active data to display."
        screen = "\n".join(
            part for part in (header, " | ".join(filters), "=" * 110, body) if part
        )
        screen = f"{screen}\n\n{_interactive_legend()}"
        self.terminal.clear()
        output = getattr(self.terminal, "stdout", None)
        if output is not None:
            output.write(screen + "\n")
            output.flush()
        return screen

    def log(self, rendered: RenderedView) -> None:
        """Append a clean fresh sample only when it contains data."""
        path = self.config.output_file
        if path is None or rendered.row_count == 0:
            return
        timestamp = self.wall_clock().strftime("%Y-%m-%d %H:%M:%S")
        with Path(path).open("a", encoding="utf-8") as output:
            output.write(f"=== {timestamp} | MODE: {self.state.view.value} ===\n")
            output.write(rendered.clean.rstrip() + "\n")

    def run(self) -> None:
        """Run the interactive sampling loop until quit or cancellation."""
        while self.running:
            started = self.clock()
            if not self.state.paused:
                self.sample_current_view()
            self.render()
            remaining = max(0.0, self.refresh_time - (self.clock() - started))
            key = self.terminal.read_key(remaining)
            if key:
                self.handle_key(key)

    def close(self) -> None:
        """Release the persistent transport; safe to call repeatedly."""
        if self._closed:
            return
        self._closed = True
        self.session.close()

    def _accept_rendered(self, rendered: RenderedView) -> None:
        self.state.stale = False
        self.state.last_error = ""
        self.state.last_rendered = rendered.clean
        self.last_colored = rendered.colored
        self.last_row_count = rendered.row_count


def resolve_display_host(login_path: str, session: Session) -> str:
    """Resolve a display host without exposing credentials or requiring connectivity."""
    try:
        result = subprocess.run(
            ["mysql_config_editor", "print", "--login-path=" + login_path],
            capture_output=True,
            check=False,
            shell=False,
            text=True,
            timeout=2.0,
        )
        match = re.search(r"^\s*host\s*=\s*(.+?)\s*$", result.stdout, re.MULTILINE)
        if result.returncode == 0 and match:
            return match.group(1)
    except (OSError, subprocess.TimeoutExpired):
        pass
    rows = session.execute_with_retry(HOSTNAME_SQL, timeout=2.0)
    return rows[0] if rows else "Unknown"


def _smoke_row_count(view: View, raw: Sequence[str]) -> int:
    if view is View.CONN:
        return len(parse_connections(raw))
    if view is View.QUERY:
        return len(parse_queries(raw))
    if view is View.DIGEST:
        return len(parse_digests(raw))
    if BACKEND_POOL_MARKER not in raw or BACKEND_PING_MARKER not in raw:
        raise ValueError("BACKEND payload is missing section markers.")
    backend = parse_backend(raw)
    return len(backend.pool) + len(backend.ping)


def run_smoke(
    config: Config,
    *,
    session_factory: Callable[[str], ContextManager[Session]] = PersistentMySQLSession,
    host_resolver: Callable[[str, Session], str] = resolve_display_host,
    clock: Callable[[], float] = time.monotonic,
) -> Sequence[SmokeResult]:
    """Run every read-only view sequentially for every configured login path."""
    results = []
    views = (View.CONN, View.QUERY, View.DIGEST, View.BACKEND)
    for login_path in config.login_paths:
        node_start = len(results)
        try:
            with session_factory(login_path) as session:
                version = session.execute_with_retry(
                    VERSION_SQL, timeout=config.query_timeout
                )
                if not version:
                    raise ValueError("ProxySQL returned an empty version.")
                host_resolver(login_path, session)
                for view in views:
                    started = clock()
                    try:
                        raw = session.execute_with_retry(
                            sql_for_view(view), timeout=config.query_timeout
                        )
                        rows = _smoke_row_count(view, raw)
                        results.append(
                            SmokeResult(
                                login_path, view, rows, clock() - started, True
                            )
                        )
                    except (TransportError, ValueError) as exc:
                        results.append(
                            SmokeResult(
                                login_path,
                                view,
                                0,
                                clock() - started,
                                False,
                                str(exc),
                            )
                        )
        except (TransportError, ValueError, OSError) as exc:
            completed = len(results) - node_start
            if completed == len(views):
                for index in range(node_start, len(results)):
                    prior = results[index]
                    results[index] = SmokeResult(
                        prior.login_path,
                        prior.view,
                        prior.rows,
                        prior.elapsed_seconds,
                        False,
                        str(exc),
                    )
            for view in views[completed:]:
                results.append(SmokeResult(login_path, view, 0, 0.0, False, str(exc)))
    return tuple(results)
