from __future__ import annotations

import os
import select
import shutil
import sys
import termios
import tty
from types import TracebackType
from typing import List, Optional, TextIO, Tuple, Type


class TerminalController:
    """Portable macOS/Linux terminal lifecycle and nonblocking key input."""

    def __init__(
        self,
        *,
        stdin: TextIO = sys.stdin,
        stdout: TextIO = sys.stdout,
    ) -> None:
        self.stdin = stdin
        self.stdout = stdout
        self.geometry_dirty = True
        self._saved_attributes: Optional[List[object]] = None
        self._tty_active = False

    def __enter__(self) -> "TerminalController":
        try:
            fd = self.stdin.fileno()
            is_tty = os.isatty(fd)
        except (AttributeError, OSError):
            is_tty = False
            fd = -1
        if is_tty:
            self._saved_attributes = termios.tcgetattr(fd)
            tty.setcbreak(fd)
            self._tty_active = True
        return self

    def __exit__(
        self,
        _exc_type: Optional[Type[BaseException]],
        _exc: Optional[BaseException],
        _traceback: Optional[TracebackType],
    ) -> None:
        self._restore()

    def read_key(self, timeout: float) -> Optional[str]:
        """Read one key within timeout, returning None on normal timeout."""
        if not self._tty_active:
            return None
        ready, _, _ = select.select([self.stdin], [], [], max(0.0, timeout))
        return self.stdin.read(1) if ready else None

    def prompt(self, message: str) -> str:
        """Temporarily restore canonical input and read one line."""
        was_active = self._tty_active
        if was_active:
            self._restore()
        try:
            self.stdout.write(message)
            self.stdout.flush()
            return self.stdin.readline().rstrip("\r\n")
        finally:
            if was_active:
                fd = self.stdin.fileno()
                if self._saved_attributes is None:
                    self._saved_attributes = termios.tcgetattr(fd)
                tty.setcbreak(fd)
                self._tty_active = True

    def size(self) -> Tuple[int, int]:
        """Return terminal dimensions with the Bash monitor's width floor."""
        columns, lines = shutil.get_terminal_size(fallback=(130, 24))
        if columns < 110:
            columns = 130
        self.geometry_dirty = False
        return columns, lines

    def clear(self) -> None:
        self.stdout.write("\x1b[H\x1b[2J")
        self.stdout.flush()

    def mark_geometry_dirty(self) -> None:
        self.geometry_dirty = True

    def _restore(self) -> None:
        if self._tty_active and self._saved_attributes is not None:
            termios.tcsetattr(self.stdin.fileno(), termios.TCSADRAIN, self._saved_attributes)
        self._tty_active = False
