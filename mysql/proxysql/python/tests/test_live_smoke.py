from __future__ import annotations

import unittest
import signal
from typing import Dict, List

from proxysql_monitor.app import run_smoke
from proxysql_monitor.__main__ import MonitorCancelled
from proxysql_monitor.models import Config, View
from proxysql_monitor.queries import HOSTNAME_SQL, VERSION_SQL
from tests.fixtures import BACKEND, CONNECTIONS_CURRENT, DIGEST_ESCAPED, QUERY_ESCAPED


class SmokeSession:
    def __init__(self, login_path: str, responses: Dict[View, List[str]]) -> None:
        self.login_path = login_path
        self.responses = responses
        self.closed = False
        self.close_error: Exception | None = None
        self.cancel_on_version = False

    def __enter__(self) -> "SmokeSession":
        return self

    def __exit__(self, *_args: object) -> None:
        self.closed = True
        if self.close_error:
            raise self.close_error

    def execute_with_retry(self, sql: str, timeout: float = 5.0) -> List[str]:
        del timeout
        if sql == VERSION_SQL:
            if self.cancel_on_version:
                raise MonitorCancelled(signal.SIGTERM)
            return ["2.7.3"]
        if sql == HOSTNAME_SQL:
            return [self.login_path]
        if "stats_mysql_connection_pool" in sql:
            return self.responses[View.BACKEND]
        if "stats_mysql_query_digest" in sql:
            return self.responses[View.DIGEST]
        if "info IS NOT NULL" in sql:
            return self.responses[View.QUERY]
        return self.responses[View.CONN]

    def close(self) -> None:
        self.closed = True


class LiveSmokeTests(unittest.TestCase):
    def responses(self) -> Dict[View, List[str]]:
        return {
            View.CONN: CONNECTIONS_CURRENT,
            View.QUERY: QUERY_ESCAPED,
            View.DIGEST: DIGEST_ESCAPED,
            View.BACKEND: BACKEND,
        }

    def test_node_and_view_order_and_cleanup(self) -> None:
        sessions: List[SmokeSession] = []

        def factory(login_path: str) -> SmokeSession:
            session = SmokeSession(login_path, self.responses())
            sessions.append(session)
            return session

        results = run_smoke(
            Config(login_paths=("node01", "node02"), smoke_test=True),
            session_factory=factory,
            host_resolver=lambda login_path, _session: login_path,
        )
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
        self.assertEqual(expected, [(item.login_path, item.view) for item in results])
        self.assertTrue(all(item.success for item in results))
        self.assertTrue(all(session.closed for session in sessions))

    def test_empty_views_are_successful(self) -> None:
        responses = {
            View.CONN: [],
            View.QUERY: [],
            View.DIGEST: [],
            View.BACKEND: ["__PXMON_POOL__", "__PXMON_PING__"],
        }
        results = run_smoke(
            Config(login_paths=("node01",), smoke_test=True),
            session_factory=lambda login_path: SmokeSession(login_path, responses),
            host_resolver=lambda login_path, _session: login_path,
        )
        self.assertTrue(all(item.success and item.rows == 0 for item in results))

    def test_malformed_view_is_reported_without_stopping_later_views(self) -> None:
        responses = self.responses()
        responses[View.QUERY] = ["bad"]
        results = run_smoke(
            Config(login_paths=("node01",), smoke_test=True),
            session_factory=lambda login_path: SmokeSession(login_path, responses),
            host_resolver=lambda login_path, _session: login_path,
        )
        self.assertFalse(results[1].success)
        self.assertTrue(results[2].success)
        self.assertTrue(results[3].success)

    def test_missing_backend_markers_fail(self) -> None:
        responses = self.responses()
        responses[View.BACKEND] = []
        results = run_smoke(
            Config(login_paths=("node01",), smoke_test=True),
            session_factory=lambda login_path: SmokeSession(login_path, responses),
            host_resolver=lambda login_path, _session: login_path,
        )
        self.assertFalse(results[-1].success)

    def test_cleanup_failure_fails_node(self) -> None:
        def factory(login_path: str) -> SmokeSession:
            session = SmokeSession(login_path, self.responses())
            session.close_error = OSError("cleanup failed")
            return session

        results = run_smoke(
            Config(login_paths=("node01",), smoke_test=True),
            session_factory=factory,
            host_resolver=lambda login_path, _session: login_path,
        )
        self.assertTrue(
            all(not item.success and "cleanup failed" in item.error for item in results)
        )

    def test_signal_cancellation_unwinds_node_session(self) -> None:
        sessions: List[SmokeSession] = []

        def factory(login_path: str) -> SmokeSession:
            session = SmokeSession(login_path, self.responses())
            session.cancel_on_version = True
            sessions.append(session)
            return session

        with self.assertRaises(MonitorCancelled):
            run_smoke(
                Config(login_paths=("node01",), smoke_test=True),
                session_factory=factory,
                host_resolver=lambda login_path, _session: login_path,
            )
        self.assertTrue(sessions[0].closed)


if __name__ == "__main__":
    unittest.main()
