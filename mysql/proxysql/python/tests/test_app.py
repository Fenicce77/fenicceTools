from __future__ import annotations

import io
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List

from proxysql_monitor.app import MonitorApp
from proxysql_monitor.models import Config, SortMode, View
from proxysql_monitor.transport import TransportError
from tests.fixtures import BACKEND, CONNECTIONS_CURRENT, DIGEST_ESCAPED, QUERY_ESCAPED


class FakeSession:
    def __init__(self) -> None:
        self.error: Exception | None = None
        self.calls: List[str] = []
        self.responses: Dict[View, List[str]] = {
            View.CONN: CONNECTIONS_CURRENT,
            View.QUERY: QUERY_ESCAPED,
            View.DIGEST: DIGEST_ESCAPED,
            View.BACKEND: BACKEND,
        }
        self.closed = False

    def execute_with_retry(self, sql: str, timeout: float = 5.0) -> List[str]:
        del timeout
        self.calls.append(sql)
        if self.error:
            raise self.error
        if "stats_mysql_connection_pool" in sql:
            return self.responses[View.BACKEND]
        if "stats_mysql_query_digest" in sql:
            return self.responses[View.DIGEST]
        if "info IS NOT NULL" in sql:
            return self.responses[View.QUERY]
        return self.responses[View.CONN]

    def close(self) -> None:
        self.closed = True


class FakeTerminal:
    def __init__(self) -> None:
        self.prompts: List[str] = []
        self.answers: List[str] = []
        self.output = io.StringIO()
        self.geometry_dirty = False

    def prompt(self, message: str) -> str:
        self.prompts.append(message)
        return self.answers.pop(0)

    def size(self) -> tuple[int, int]:
        return (130, 24)

    def clear(self) -> None:
        self.output.write("<clear>")

    def read_key(self, timeout: float) -> None:
        del timeout
        return None

    def mark_geometry_dirty(self) -> None:
        self.geometry_dirty = True


class AppTests(unittest.TestCase):
    def make_app(
        self, output_file: Path | None = None
    ) -> tuple[MonitorApp, FakeSession, FakeTerminal]:
        session = FakeSession()
        terminal = FakeTerminal()
        config = Config(login_paths=("node01",), output_file=output_file)
        return MonitorApp(config, session=session, terminal=terminal), session, terminal

    def test_view_cycle_unpauses_and_resets_conn_baseline(self) -> None:
        app, _session, _terminal = self.make_app()
        app.state.paused = True
        for expected in (View.QUERY, View.DIGEST, View.BACKEND, View.CONN):
            app.handle_key("v")
            self.assertEqual(expected, app.state.view)
            self.assertFalse(app.state.paused)
        self.assertEqual((), app.state.previous_connections)

    def test_pause_sort_and_quit_transitions(self) -> None:
        app, _session, _terminal = self.make_app()
        app.handle_key("p")
        self.assertTrue(app.state.paused)
        app.handle_key("p")
        self.assertFalse(app.state.paused)
        app.handle_key("s")
        self.assertEqual(SortMode.USER, app.state.sort_mode)
        app.handle_key("q")
        self.assertFalse(app.running)

    def test_render_uses_resolved_target_and_version(self) -> None:
        app, _session, terminal = self.make_app()
        app.display_host = "proxysql01.internal"
        app.proxy_version = "2.7.3"
        app.state.stale = True
        app.state.last_error = "down\x1b[31m"
        app.user_filter = "app\x7f"
        screen = app.render()
        self.assertIn("Server: proxysql01.internal", screen)
        self.assertIn("Version: 2.7.3", screen)
        self.assertNotIn("\x1b[31m", screen)
        self.assertNotIn("\x7f", screen)

    def test_failed_sample_preserves_last_valid_output(self) -> None:
        app, session, _terminal = self.make_app()
        app.state.last_rendered = "last valid"
        session.error = TransportError("ProxySQL unavailable")
        self.assertFalse(app.sample_current_view())
        self.assertTrue(app.state.stale)
        self.assertEqual("last valid", app.state.last_rendered)

    def test_prompts_validate_refresh_threshold_and_filter(self) -> None:
        app, _session, terminal = self.make_app()
        terminal.answers = ["0", "0.25", "-1", "9", "app,report"]
        app.handle_key("r")
        self.assertEqual(5.0, app.refresh_time)
        app.handle_key("r")
        self.assertEqual(0.25, app.refresh_time)
        app.handle_key("t")
        self.assertEqual(0, app.threshold)
        app.handle_key("t")
        self.assertEqual(9, app.threshold)
        app.handle_key("u")
        self.assertEqual("app,report", app.user_filter)

    def test_logging_occurs_only_for_fresh_nonempty_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "monitor.log"
            app, session, _terminal = self.make_app(path)
            self.assertTrue(app.sample_current_view())
            first = path.read_text()
            self.assertNotIn("\x1b[", first)
            session.error = TransportError("down")
            self.assertFalse(app.sample_current_view())
            self.assertEqual(first, path.read_text())
            app.close()
            self.assertTrue(session.closed)


if __name__ == "__main__":
    unittest.main()
