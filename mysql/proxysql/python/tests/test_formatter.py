from __future__ import annotations

import re
import unittest

from proxysql_monitor.formatter import (
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
from tests.fixtures import (
    BACKEND,
    CONNECTIONS_CURRENT,
    CONNECTIONS_PREVIOUS,
    DIGEST_ESCAPED,
    QUERY_ESCAPED,
)


class FormatterTests(unittest.TestCase):
    def test_connection_delta(self) -> None:
        previous = parse_connections(CONNECTIONS_PREVIOUS)
        current = parse_connections(CONNECTIONS_CURRENT)
        rendered = format_connections(current, previous, threshold=0, user_filter="")
        self.assertIn("+2", rendered.clean)
        self.assertEqual(1, rendered.row_count)

    def test_query_controls_are_sanitized_and_slow_query_is_colored(self) -> None:
        rendered = format_queries(parse_queries(QUERY_ESCAPED), user_filter="")
        self.assertIn("SELECT * FROM t", rendered.clean)
        self.assertNotIn("\\n", rendered.clean)
        self.assertIn("\x1b[", rendered.colored)

    def test_backend_sections_are_parsed(self) -> None:
        backend = parse_backend(BACKEND)
        self.assertEqual("ONLINE", backend.pool[0].status)
        self.assertEqual(500, backend.ping[0].success_us)
        self.assertEqual(2, format_backend(backend).row_count)

    def test_null_ping_success_is_optional(self) -> None:
        backend = parse_backend([
            "__PXMON_POOL__",
            "__PXMON_PING__",
            "backend\t2026-07-28 12:00:00\tNULL\tconnection refused",
        ])
        self.assertIsNone(backend.ping[0].success_us)

    def test_digest_query_truncates_to_terminal_width(self) -> None:
        rows = parse_digests([
            "0x123\t8\t12000\t100\t4000\t" + ("SELECT col FROM table " * 20)
        ])
        rendered = format_digests(rows, user_filter="", terminal_width=110)
        self.assertTrue(all(len(line) <= 110 for line in rendered.clean.splitlines()))

    def test_regex_filter_treats_commas_as_alternation(self) -> None:
        matcher = compile_user_filter("app,report.*")
        self.assertIsNotNone(matcher.search("APP"))
        self.assertIsNotNone(matcher.search("reporting"))
        self.assertIsNone(matcher.search("batch"))

    def test_malformed_rows_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_connections(["only\tfour\tfields\there"])
        with self.assertRaises(ValueError):
            parse_queries(["1\t2"])
        with self.assertRaises(ValueError):
            parse_digests(["digest\tbad"])
        with self.assertRaisesRegex(ValueError, "markers"):
            parse_backend(["10\tbackend\tONLINE\t1\t2\t3\t4"])

    def test_empty_inputs_are_valid(self) -> None:
        self.assertEqual((), parse_connections([]))
        self.assertEqual((), parse_queries([]))
        self.assertEqual((), parse_digests([]))

    def test_ansi_does_not_change_visible_padding(self) -> None:
        rendered = format_queries(parse_queries(QUERY_ESCAPED), user_filter="")
        stripped = re.sub(r"\x1b\[[0-9;]*m", "", rendered.colored)
        self.assertEqual(rendered.clean, stripped)

    def test_conn_output_preserves_bash_widths_and_global_delta(self) -> None:
        rendered = format_connections(
            parse_connections(CONNECTIONS_CURRENT),
            parse_connections(CONNECTIONS_PREVIOUS),
            threshold=0,
            user_filter="",
        )
        header = rendered.clean.splitlines()[0]
        self.assertTrue(header.startswith("USER                 | SOURCE (Cli)"))
        self.assertIn("GLOBAL TOTALS", rendered.clean)
        self.assertIn("+2", rendered.clean.splitlines()[-1])

    def test_all_terminal_control_characters_are_neutralized(self) -> None:
        rendered = format_queries(
            parse_queries([
                "11\t10\tapp\tclient\tbackend:3306\t1\tSELECT \x1b[31m bad\x7f"
            ]),
            user_filter="",
        )
        self.assertNotIn("\x1b[31m bad", rendered.clean)
        self.assertNotIn("\x7f", rendered.clean)


if __name__ == "__main__":
    unittest.main()
