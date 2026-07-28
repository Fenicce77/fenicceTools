from __future__ import annotations

import math
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Protocol, Sequence

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
)
from .models import Config, MonitorState, SortMode, View
from .queries import sql_for_view
from .terminal import TerminalController
from .transport import PersistentMySQLSession, TransportError


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
            flags.append(f"STALE: {self.state.last_error or 'ProxySQL unavailable'}")
        flag_text = f" [{' | '.join(flags)}]" if flags else ""
        header = (
            f"ProxySQL Monitor | Login path: {self.config.login_paths[0]} | "
            f"Mode: {self.state.view.value} | Refresh: {self.refresh_time:g}s{flag_text}"
        )
        filters = []
        if self.user_filter:
            filters.append(f"Filter: {self.user_filter}")
        if self.threshold:
            filters.append(f"Threshold: >= {self.threshold} conn")
        body = self.last_colored or "No active data to display."
        screen = "\n".join(
            part for part in (header, " | ".join(filters), "=" * 110, body) if part
        )
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
