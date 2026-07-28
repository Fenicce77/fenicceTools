from __future__ import annotations

import signal
import sys
from typing import Optional, Sequence

from .app import MonitorApp, resolve_display_host, run_smoke
from .cli import parse_args
from .formatter import GREEN, RED, RESET, sanitize_text
from .terminal import TerminalController
from .transport import PersistentMySQLSession, TransportError
from .queries import VERSION_SQL


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Run interactive mode or the finite read-only smoke suite."""
    arguments = tuple(sys.argv[1:] if argv is None else argv)
    try:
        config = parse_args(arguments)
    except ValueError as exc:
        print(f"{RED}Error: {exc}{RESET}", file=sys.stderr)
        return 2

    if config.smoke_test:
        results = run_smoke(config)
        for result in results:
            status = "PASS" if result.success else "FAIL"
            color = GREEN if result.success else RED
            error = f" | {sanitize_text(result.error)}" if result.error else ""
            print(
                f"{color}{status}{RESET} | {sanitize_text(result.login_path):<28} | "
                f"{result.view.value:<7} | rows={result.rows:<5} | "
                f"{result.elapsed_seconds * 1000:>8.1f} ms{error}"
            )
        return 0 if results and all(result.success for result in results) else 1

    session = PersistentMySQLSession(config.login_paths[0])
    terminal = TerminalController()
    try:
        version_rows = session.execute_with_retry(
            VERSION_SQL, timeout=config.query_timeout
        )
        if not version_rows:
            raise TransportError("ProxySQL returned an empty version.")
        display_host = resolve_display_host(config.login_paths[0], session)
    except (TransportError, OSError, ValueError) as exc:
        session.close()
        print(f"{RED}Error: {exc}{RESET}", file=sys.stderr)
        return 1
    app = MonitorApp(config, session=session, terminal=terminal)
    app.proxy_version = version_rows[0]
    app.display_host = display_host

    def stop(_signum: int, _frame: object) -> None:
        app.running = False
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    if hasattr(signal, "SIGWINCH"):
        signal.signal(signal.SIGWINCH, lambda _signum, _frame: terminal.mark_geometry_dirty())
    try:
        with terminal:
            app.run()
    except KeyboardInterrupt:
        return 0
    except (TransportError, OSError) as exc:
        print(f"{RED}Error: {exc}{RESET}", file=sys.stderr)
        return 1
    finally:
        app.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
