from __future__ import annotations

import queue
import subprocess
import threading
import time
from collections import deque
from typing import Deque, List, Optional, TextIO, Tuple


class TransportError(RuntimeError):
    """Raised when the persistent MySQL client cannot complete a request."""


_EOF = object()


class PersistentMySQLSession:
    """Serialize framed SQL requests over one persistent MySQL CLI process."""

    def __init__(
        self,
        login_path: str,
        *,
        mysql_bin: str = "mysql",
        queue_size: int = 4096,
        stderr_lines: int = 100,
    ) -> None:
        self.login_path = login_path
        self.mysql_bin = mysql_bin
        self.queue_size = queue_size
        self.stderr_lines = stderr_lines
        self.process: Optional[subprocess.Popen[str]] = None
        self._sequence = 0
        self._closed = False
        self._execute_lock = threading.Lock()
        self._stdout_queue: "queue.Queue[object]" = queue.Queue(maxsize=queue_size)
        self._stderr: Deque[str] = deque(maxlen=stderr_lines)
        self._overflow = threading.Event()
        self._threads: List[threading.Thread] = []

    @property
    def recent_stderr(self) -> Tuple[str, ...]:
        """Return the bounded diagnostic tail from the current generation."""
        return tuple(self._stderr)

    def __enter__(self) -> "PersistentMySQLSession":
        self.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def start(self) -> None:
        """Start the MySQL child if it is not already alive."""
        if self._closed:
            raise TransportError("MySQL session is closed.")
        if self.is_alive():
            return
        self._stdout_queue = queue.Queue(maxsize=self.queue_size)
        self._stderr = deque(maxlen=self.stderr_lines)
        self._overflow.clear()
        try:
            process = subprocess.Popen(
                [
                    self.mysql_bin,
                    f"--login-path={self.login_path}",
                    "--batch",
                    "--raw",
                    "--skip-column-names",
                    "--unbuffered",
                    "--force",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                shell=False,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            raise TransportError(f"Cannot start MySQL client: {exc}") from exc
        self.process = process
        assert process.stdout is not None
        assert process.stderr is not None
        stdout_queue = self._stdout_queue
        stderr_buffer = self._stderr
        overflow = self._overflow
        self._threads = [
            threading.Thread(
                target=self._read_stdout,
                args=(process.stdout, stdout_queue, overflow),
                name=f"pxmon-stdout-{process.pid}",
                daemon=True,
            ),
            threading.Thread(
                target=self._read_stderr,
                args=(process.stderr, stderr_buffer),
                name=f"pxmon-stderr-{process.pid}",
                daemon=True,
            ),
        ]
        for thread in self._threads:
            thread.start()

    def is_alive(self) -> bool:
        """Return whether the current child process is running."""
        return self.process is not None and self.process.poll() is None

    def execute(self, sql: str, timeout: float = 5.0) -> List[str]:
        """Execute one framed SQL payload and return its tab-separated rows."""
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")
        with self._execute_lock:
            self.start()
            process = self.process
            assert process is not None
            if process.stdin is None:
                raise TransportError("MySQL client stdin is unavailable.")
            self._sequence += 1
            begin = f"__PXMON_BEGIN_{self._sequence}__"
            end = f"__PXMON_END_{self._sequence}__"
            payload = f"SELECT '{begin}';\n{sql.rstrip()}\nSELECT '{end}';\n"
            try:
                process.stdin.write(payload)
                process.stdin.flush()
            except (BrokenPipeError, OSError, ValueError) as exc:
                raise TransportError(self._error_message("MySQL write failed", exc)) from exc

            deadline = time.monotonic() + timeout
            collecting = False
            rows: List[str] = []
            while True:
                if self._overflow.is_set():
                    raise TransportError("MySQL stdout queue overflow.")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TransportError(self._error_message("MySQL query timed out"))
                try:
                    item = self._stdout_queue.get(timeout=remaining)
                except queue.Empty as exc:
                    raise TransportError(self._error_message("MySQL query timed out")) from exc
                if item is _EOF:
                    raise TransportError(self._error_message("MySQL client exited"))
                line = str(item)
                if line == begin:
                    collecting = True
                    rows.clear()
                elif line == end and collecting:
                    return rows
                elif collecting:
                    rows.append(line)

    def execute_with_retry(self, sql: str, timeout: float = 5.0) -> List[str]:
        """Execute a request, reconnecting and retrying exactly once on failure."""
        try:
            return self.execute(sql, timeout)
        except TransportError:
            self.reconnect()
            return self.execute(sql, timeout)

    def reconnect(self) -> None:
        """Replace the current process generation."""
        if self._closed:
            raise TransportError("MySQL session is closed.")
        self._stop_process()
        self.start()

    def close(self) -> None:
        """Close and reap the child process; safe to call repeatedly."""
        if self._closed:
            return
        self._closed = True
        self._stop_process()

    def _stop_process(self) -> None:
        process = self.process
        self.process = None
        if process is None:
            return
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1.0)
        else:
            process.wait()
        for thread in self._threads:
            thread.join(timeout=1.0)
        self._threads.clear()
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        self._stdout_queue = queue.Queue(maxsize=self.queue_size)

    def _error_message(self, prefix: str, exc: Optional[BaseException] = None) -> str:
        parts = [prefix]
        if exc is not None:
            parts.append(str(exc))
        if self._stderr:
            parts.append(self._stderr[-1])
        return ": ".join(part for part in parts if part)

    @staticmethod
    def _read_stdout(
        stream: TextIO,
        output: "queue.Queue[object]",
        overflow: threading.Event,
    ) -> None:
        try:
            for raw_line in stream:
                try:
                    output.put_nowait(raw_line.rstrip("\r\n"))
                except queue.Full:
                    overflow.set()
                    return
        finally:
            try:
                output.put_nowait(_EOF)
            except queue.Full:
                overflow.set()

    @staticmethod
    def _read_stderr(stream: TextIO, output: Deque[str]) -> None:
        for raw_line in stream:
            output.append(raw_line.rstrip("\r\n"))
