from __future__ import annotations

import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from proxysql_monitor.transport import PersistentMySQLSession, TransportError


class TransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="pxmon-python-")
        self.state = Path(self.tmp.name)
        os.environ["FAKE_MYSQL_STATE_DIR"] = str(self.state)
        self.mysql_bin = str(Path(__file__).with_name("fake_mysql.py"))

    def tearDown(self) -> None:
        for name in (
            "FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH",
            "FAKE_MYSQL_EXIT_ON_TOKEN",
            "FAKE_MYSQL_STDERR_LINES",
            "FAKE_MYSQL_STATE_DIR",
        ):
            os.environ.pop(name, None)
        self.tmp.cleanup()

    def launch_count(self) -> int:
        return len((self.state / "launches").read_text().splitlines())

    def test_multiple_requests_use_one_child(self) -> None:
        with PersistentMySQLSession("node01", mysql_bin=self.mysql_bin) as session:
            self.assertEqual(
                ["app\tclient\tbackend:3306\tappdb\t4"],
                session.execute("SELECT 'TEST_CONNECTIONS';"),
            )
            session.execute("SELECT 'TEST_SECOND_SAMPLE';")
        self.assertEqual(1, self.launch_count())

    def test_timeout_reconnects_once_and_retries(self) -> None:
        os.environ["FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH"] = "1"
        with PersistentMySQLSession("node01", mysql_bin=self.mysql_bin) as session:
            rows = session.execute_with_retry("SELECT 'TEST_CONNECTIONS';", timeout=0.5)
        self.assertEqual(["app\tclient\tbackend:3306\tappdb\t4"], rows)
        self.assertEqual(2, self.launch_count())

    def test_close_is_idempotent_and_reaps_child(self) -> None:
        session = PersistentMySQLSession("node01", mysql_bin=self.mysql_bin)
        session.start()
        process = session.process
        session.close()
        session.close()
        self.assertIsNotNone(process)
        assert process is not None
        self.assertIsNotNone(process.poll())

    def test_execute_after_close_is_rejected(self) -> None:
        session = PersistentMySQLSession("node01", mysql_bin=self.mysql_bin)
        session.close()
        with self.assertRaisesRegex(TransportError, "closed"):
            session.execute("SELECT 1;")

    def test_stderr_buffer_is_bounded(self) -> None:
        os.environ["FAKE_MYSQL_STDERR_LINES"] = "20"
        with PersistentMySQLSession(
            "node01", mysql_bin=self.mysql_bin, stderr_lines=3
        ) as session:
            session.execute("SELECT @@version;")
            self.assertLessEqual(len(session.recent_stderr), 3)

    def test_sql_error_terminates_frame_and_retry_fails(self) -> None:
        os.environ["FAKE_MYSQL_EXIT_ON_TOKEN"] = "TEST_SQL_ERROR"
        with PersistentMySQLSession("node01", mysql_bin=self.mysql_bin) as session:
            with self.assertRaises(TransportError):
                session.execute_with_retry(
                    "SELECT 'TEST_SQL_ERROR';", timeout=0.5
                )
        self.assertEqual(2, self.launch_count())

    def test_mysql_bin_environment_override(self) -> None:
        os.environ["MYSQL_BIN"] = self.mysql_bin
        try:
            with PersistentMySQLSession("node01") as session:
                self.assertEqual(["2.7.3"], session.execute("SELECT @@version;"))
        finally:
            os.environ.pop("MYSQL_BIN", None)

    @patch("proxysql_monitor.transport.subprocess.Popen")
    def test_batch_client_keeps_control_character_escaping(
        self, popen: object
    ) -> None:
        mocked = popen.return_value
        mocked.poll.return_value = None
        mocked.stdin = io.StringIO()
        mocked.stdout = io.StringIO()
        mocked.stderr = io.StringIO()
        session = PersistentMySQLSession("node01", mysql_bin=self.mysql_bin)
        session.start()
        command = popen.call_args.args[0]
        self.assertIn("--batch", command)
        self.assertNotIn("--raw", command)
        self.assertNotIn("--force", command)
        mocked.poll.return_value = 0
        session.close()


if __name__ == "__main__":
    unittest.main()
