"""Colored console output (stderr for logs, stdout for results). Honors NO_COLOR."""
from __future__ import annotations

import os
import sys
import threading

_LOCK = threading.Lock()


class Style:
    enabled: bool = sys.stderr.isatty() and not os.environ.get("NO_COLOR")
    CODES = {"red": "31", "green": "32", "yellow": "33", "blue": "34", "magenta": "35", "cyan": "36",
             "bold": "1", "dim": "2"}

    @classmethod
    def paint(cls, text: str, *styles: str) -> str:
        if not cls.enabled or not styles:
            return text
        codes = ";".join(cls.CODES[s] for s in styles)
        return f"\033[{codes}m{text}\033[0m"


class Log:
    verbose: bool = False

    @staticmethod
    def _emit(tag: str, color: str, msg: str, stream=sys.stderr) -> None:
        with _LOCK:
            print(f"{Style.paint(f'[{tag}]', color)} {msg}", file=stream, flush=True)

    @classmethod
    def info(cls, msg: str) -> None:
        cls._emit("INFO", "blue", msg)

    @classmethod
    def ok(cls, msg: str) -> None:
        cls._emit(" OK ", "green", msg)

    @classmethod
    def warn(cls, msg: str) -> None:
        cls._emit("WARN", "yellow", msg)

    @classmethod
    def error(cls, msg: str) -> None:
        cls._emit("FAIL", "red", msg)

    @classmethod
    def debug(cls, msg: str) -> None:
        if cls.verbose:
            cls._emit("DBG ", "dim", msg)

    @staticmethod
    def title(msg: str) -> None:
        with _LOCK:
            print(Style.paint(f"==> {msg}", "bold", "cyan"), file=sys.stderr, flush=True)
