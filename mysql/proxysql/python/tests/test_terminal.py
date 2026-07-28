from __future__ import annotations

import io
import unittest
from unittest.mock import patch

from proxysql_monitor.terminal import TerminalController


class TerminalTests(unittest.TestCase):
    def test_non_tty_is_safe_and_clear_targets_injected_output(self) -> None:
        output = io.StringIO()
        terminal = TerminalController(stdin=io.StringIO(), stdout=output)
        with terminal:
            self.assertIsNone(terminal.read_key(0))
            terminal.clear()
        self.assertEqual("\x1b[H\x1b[2J", output.getvalue())

    @patch("proxysql_monitor.terminal.shutil.get_terminal_size")
    def test_narrow_terminal_uses_130_column_fallback(self, size: object) -> None:
        size.return_value = (80, 24)
        terminal = TerminalController(stdin=io.StringIO(), stdout=io.StringIO())
        self.assertEqual((130, 24), terminal.size())

    def test_geometry_can_be_marked_dirty(self) -> None:
        terminal = TerminalController(stdin=io.StringIO(), stdout=io.StringIO())
        terminal.mark_geometry_dirty()
        self.assertTrue(terminal.geometry_dirty)


if __name__ == "__main__":
    unittest.main()
