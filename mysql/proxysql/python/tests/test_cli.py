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

    def test_login_path_is_required(self) -> None:
        with self.assertRaisesRegex(ValueError, "login-path"):
            parse_args([])

    def test_negative_threshold_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "non-negative"):
            parse_args(["--login-path=node01", "--threshold=-1"])

    def test_backend_sql_contains_both_read_only_sources(self) -> None:
        self.assertIn("stats.stats_mysql_connection_pool", BACKEND_SQL)
        self.assertIn("monitor.mysql_server_ping_log", BACKEND_SQL)
        self.assertNotIn("UPDATE ", BACKEND_SQL.upper())

    def test_conn_sort_changes_only_order_clause(self) -> None:
        by_conn = sql_for_view(View.CONN, SortMode.CONN)
        by_user = sql_for_view(View.CONN, SortMode.USER)
        self.assertIn("ORDER BY COUNT(*) DESC", by_conn)
        self.assertIn("ORDER BY user ASC", by_user)

    def test_help_contains_operational_examples(self) -> None:
        from proxysql_monitor.cli import _parser

        help_text = _parser().format_help()
        for value in ("--output-file", "rmateos", "--smoke-test", "node03"):
            self.assertIn(value, help_text)


if __name__ == "__main__":
    unittest.main()
