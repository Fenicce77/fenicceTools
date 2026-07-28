from __future__ import annotations

import argparse
from pathlib import Path
from typing import Sequence

from .models import Config


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proxysql_connections_monitor.py",
        description="Low-overhead interactive monitor for ProxySQL admin statistics.",
        epilog=(
            "Examples:\n"
            "  %(prog)s --login-path=proxysql_admin -r 0.5\n"
            "  %(prog)s --login-path=proxysql_admin -u app,report -t 20\n"
            "  %(prog)s --smoke-test --login-path=node01 --login-path=node02"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--login-path", action="append", dest="login_paths", metavar="NAME")
    parser.add_argument("-r", "--refresh-time", type=float, default=5.0, metavar="SECONDS")
    parser.add_argument("-u", "--user-filter", default="", metavar="REGEX")
    parser.add_argument("-t", "--threshold", type=int, default=0, metavar="COUNT")
    parser.add_argument("-o", "--output-file", type=Path, metavar="FILE")
    parser.add_argument("--query-timeout", type=float, default=5.0, metavar="SECONDS")
    parser.add_argument(
        "--smoke-test",
        action="store_true",
        help="Query every view sequentially and exit; SELECT statements only.",
    )
    return parser


def parse_args(argv: Sequence[str]) -> Config:
    """Parse and semantically validate command-line arguments."""
    namespace = _parser().parse_args(list(argv))
    login_paths = tuple(namespace.login_paths or ())
    if not login_paths or any(not value.strip() for value in login_paths):
        raise ValueError("At least one nonempty --login-path is required.")
    if not namespace.smoke_test and len(login_paths) != 1:
        raise ValueError("Normal mode requires exactly one --login-path.")
    if namespace.refresh_time <= 0:
        raise ValueError("Refresh time must be greater than zero.")
    if namespace.query_timeout <= 0:
        raise ValueError("Query timeout must be greater than zero.")
    if namespace.threshold < 0:
        raise ValueError("Threshold must be non-negative.")

    smoke_incompatible = (
        "-r",
        "--refresh-time",
        "-u",
        "--user-filter",
        "-t",
        "--threshold",
        "-o",
        "--output-file",
    )
    if namespace.smoke_test and any(
        argument == option or argument.startswith(option + "=")
        for argument in argv
        for option in smoke_incompatible
    ):
        raise ValueError("Interactive display options cannot be used with --smoke-test.")

    return Config(
        login_paths=login_paths,
        refresh_time=namespace.refresh_time,
        user_filter=namespace.user_filter,
        threshold=namespace.threshold,
        output_file=namespace.output_file,
        smoke_test=namespace.smoke_test,
        query_timeout=namespace.query_timeout,
    )
