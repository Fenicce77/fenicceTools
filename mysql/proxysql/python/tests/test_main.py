from __future__ import annotations

import signal
import unittest
from typing import List
from unittest.mock import patch

from proxysql_monitor.__main__ import MonitorCancelled, main


class FakeStartupSession:
    instances: List["FakeStartupSession"] = []

    def __init__(self, _login_path: str) -> None:
        self.closed = False
        self.instances.append(self)

    def execute_with_retry(self, _sql: str, timeout: float = 5.0) -> List[str]:
        del timeout
        raise MonitorCancelled(signal.SIGTERM)

    def close(self) -> None:
        self.closed = True


class MainSignalTests(unittest.TestCase):
    @patch("proxysql_monitor.__main__.signal.signal")
    @patch("proxysql_monitor.__main__.run_smoke")
    def test_smoke_cancellation_uses_signal_exit_code(
        self, run_smoke_mock: object, signal_mock: object
    ) -> None:
        run_smoke_mock.side_effect = MonitorCancelled(signal.SIGINT)
        status = main(["--smoke-test", "--login-path=node01"])
        self.assertEqual(128 + signal.SIGINT, status)
        installed = [call.args[0] for call in signal_mock.call_args_list]
        self.assertIn(signal.SIGINT, installed)
        self.assertIn(signal.SIGTERM, installed)

    @patch("proxysql_monitor.__main__.signal.signal")
    @patch(
        "proxysql_monitor.__main__.PersistentMySQLSession",
        FakeStartupSession,
    )
    def test_startup_cancellation_closes_owned_session(
        self, _signal_mock: object
    ) -> None:
        FakeStartupSession.instances.clear()
        status = main(["--login-path=node01"])
        self.assertEqual(128 + signal.SIGTERM, status)
        self.assertEqual(1, len(FakeStartupSession.instances))
        self.assertTrue(FakeStartupSession.instances[0].closed)


if __name__ == "__main__":
    unittest.main()
