import io
import json
import os
import re
import unittest
from pathlib import Path


SCRIPT = Path(
    os.environ.get(
        "GCP_GENERAL_LOG_MONITOR_SCRIPT",
        Path(__file__).resolve().parents[2] / "gcp_general_log_monitor.sh",
    )
)

EXPECTED_COMMAND_TYPES = (
    "Sleep", "Quit", "Init DB", "Query", "Field List", "Create DB",
    "Drop DB", "Refresh", "Shutdown", "Statistics", "Processlist",
    "Connect", "Kill", "Debug", "Ping", "Time", "Delayed insert",
    "Change user", "Binlog Dump", "Table Dump", "Connect Out",
    "Register Replica", "Register Slave", "Prepare", "Execute", "Long Data",
    "Close stmt", "Reset stmt", "Set option", "Fetch", "Daemon",
    "Binlog Dump GTID", "Reset Connection", "clone",
    "Group Replication Data Stream subscription", "Error",
)


def load_parser_namespace() -> dict[str, object]:
    source = SCRIPT.read_text(encoding="utf-8")
    start_marker = "# PARSER_PYTHON_BEGIN\n"
    end_marker = "# PARSER_PYTHON_END"
    start = source.index(start_marker) + len(start_marker)
    end = source.index(end_marker, start)
    namespace: dict[str, object] = {"__name__": "embedded_general_log_parser"}
    exec(compile(source[start:end], str(SCRIPT), "exec"), namespace)
    return namespace


class ParserContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.namespace = load_parser_namespace()
        cls.parse = staticmethod(cls.namespace["parse_mysql_general_log"])

    def parse_payloads(self, payloads: list[str]) -> tuple[str, str]:
        entries = [
            {"textPayload": payload, "timestamp": "2026-07-23T12:01:55.896580Z"}
            for payload in payloads
        ]
        rejection_log = io.StringIO()
        sql = self.parse(json.dumps(entries), "rmc_betika", rejection_log)
        return sql, rejection_log.getvalue()

    def test_command_whitelist_is_complete_and_exact(self) -> None:
        self.assertEqual(tuple(self.namespace["COMMAND_TYPES"]), EXPECTED_COMMAND_TYPES)

    def test_supplied_change_user_uses_canonical_bracketed_username(self) -> None:
        payload = (
            "2026-07-23T12:01:55.896580Z\t"
            "dev-userapp[dev-userapp] @  [10.10.10.1]15397 4226757038 Change user\t"
            "dev-userapp@10.10.10.1 on dev_betika_africa using TCP/IP"
        )
        sql, log = self.parse_payloads([payload])
        self.assertIn("(15397, 'dev-userapp@10.10.10.1', 4226757038, 'Change user'", sql)
        self.assertIn("'2026-07-23 12:01:55.896580'", sql)
        self.assertIn("[PARSER SUMMARY] accepted=1 rejected=0", log)
        self.assertNotIn("dev-userapp[dev-userapp]@", sql)

    def test_whitespace_hosts_and_argumentless_command(self) -> None:
        payloads = [
            "2026-07-23T12:01:55Z user[user]\t@\t[2001:db8::1]99 1 Query\tSELECT 1\nFROM dual",
            "2026-07-23T12:01:56Z outer[user] @ [db.internal] 100 1 Quit",
        ]
        sql, log = self.parse_payloads(payloads)
        self.assertIn("'user@2001:db8::1'", sql)
        self.assertIn("'Query', 'SELECT 1\\nFROM dual'", sql)
        self.assertIn("'user@db.internal'", sql)
        self.assertIn("'Quit', ''", sql)
        self.assertIn("accepted=2 rejected=0", log)

    def test_all_supported_commands_and_prefix_collisions(self) -> None:
        for command in EXPECTED_COMMAND_TYPES:
            with self.subTest(command=command):
                payload = (
                    "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]99 1 "
                    f"{command} payload"
                )
                sql, _ = self.parse_payloads([payload])
                self.assertIn(f", '{command}', 'payload', ", sql)

    def test_malformed_and_truncated_payloads_are_logged_without_sql(self) -> None:
        payloads = [
            "   ",
            "2026-07-23 12:01:55Z user[user] @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55.1234567Z user[user] @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55Z user[user @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]x 1 Query x",
            "20605075,20605076,20605077) ORDER BY id DESC LIMIT ?",
        ]
        sql, log = self.parse_payloads(payloads)
        self.assertEqual(sql, "")
        self.assertEqual(log.count("[PARSER RAW PAYLOAD BEGIN]"), len(payloads))
        self.assertIn("[PARSER REJECT] empty payload", log)
        for payload in payloads:
            self.assertIn(payload, log)
        self.assertIn("accepted=0 rejected=6", log)

    def test_mixed_batch_keeps_only_valid_payload(self) -> None:
        valid = "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]99 1 Ping"
        rejected = "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]x 1 Query x"
        sql, log = self.parse_payloads([valid, rejected])
        self.assertEqual(sql.count("INSERT INTO"), 1)
        self.assertIn("'Ping', ''", sql)
        self.assertNotIn(rejected, sql)
        self.assertIn(rejected, log)
        self.assertIn("accepted=1 rejected=1", log)

    def test_invalid_json_produces_no_sql(self) -> None:
        rejection_log = io.StringIO()
        sql = self.parse("{not-json", "rmc_betika", rejection_log)
        self.assertEqual(sql, "")
        self.assertIn("[PARSER ERROR] invalid JSON", rejection_log.getvalue())

    def test_pattern_is_anchored_and_uses_named_groups(self) -> None:
        pattern = self.namespace["GENERAL_LOG_PATTERN"]
        self.assertIsInstance(pattern, re.Pattern)
        self.assertEqual(
            set(pattern.groupindex),
            {
                "event_time", "outer_username", "username", "host", "thread_id",
                "server_id", "command_type", "argument",
            },
        )

    def test_fallback_assignments_are_absent(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('thread_id = "0"', source)
        self.assertNotIn('user_host = "unknown"', source)
        self.assertNotIn('server_id = "1"', source)


if __name__ == "__main__":
    unittest.main()
