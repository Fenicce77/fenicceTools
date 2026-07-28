from __future__ import annotations

import unittest

from proxysql_monitor.models import Config, MonitorState, SortMode, View


class ModelTests(unittest.TestCase):
    def test_monitor_defaults_match_bash_monitor(self) -> None:
        state = MonitorState()
        self.assertEqual(View.CONN, state.view)
        self.assertEqual(SortMode.CONN, state.sort_mode)
        self.assertFalse(state.paused)
        self.assertFalse(state.stale)

    def test_config_is_immutable(self) -> None:
        config = Config(login_paths=("node01",))
        with self.assertRaises(AttributeError):
            config.threshold = 4  # type: ignore[misc]


if __name__ == "__main__":
    unittest.main()
