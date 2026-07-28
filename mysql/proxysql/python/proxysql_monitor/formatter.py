from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, List, Optional, Pattern, Sequence, Tuple

from .models import BackendRows, ConnectionRow, DigestRow, PingRow, PoolRow, QueryRow
from .queries import BACKEND_PING_MARKER, BACKEND_POOL_MARKER

BOLD = "\x1b[1m"
RED = "\x1b[1;31m"
GREEN = "\x1b[1;32m"
YELLOW = "\x1b[1;33m"
CYAN = "\x1b[1;36m"
RESET = "\x1b[0m"


@dataclass(frozen=True)
class RenderedView:
    colored: str
    clean: str
    row_count: int


def _parse_int(value: str, field_name: str) -> int:
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"Invalid {field_name}: {value!r}") from exc


def sanitize_text(value: str) -> str:
    """Flatten escaped and literal controls so every record stays on one line."""
    value = re.sub(r"\\[nrt]", " ", value)
    value = re.sub(r"[\r\n\t]+", " ", value)
    return value.strip()


def truncate(value: str, width: int) -> str:
    """Truncate a string to a non-negative display width."""
    return value[: max(0, width)]


def compile_user_filter(value: str) -> Pattern[str]:
    """Compile the monitor's comma-as-regex-alternation user filter."""
    expression = value.replace(",", "|") if value else ".*"
    try:
        return re.compile(expression, re.IGNORECASE)
    except re.error as exc:
        raise ValueError(f"Invalid user filter regex: {exc}") from exc


def parse_connections(lines: Sequence[str]) -> Tuple[ConnectionRow, ...]:
    rows: List[ConnectionRow] = []
    for line in lines:
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 5:
            raise ValueError(f"Malformed CONN row: {line!r}")
        rows.append(
            ConnectionRow(
                fields[0], fields[1], fields[2], fields[3],
                _parse_int(fields[4], "connections"),
            )
        )
    return tuple(rows)


def parse_queries(lines: Sequence[str]) -> Tuple[QueryRow, ...]:
    rows: List[QueryRow] = []
    for line in lines:
        if not line:
            continue
        fields = line.split("\t", 6)
        if len(fields) != 7:
            raise ValueError(f"Malformed QUERY row: {line!r}")
        rows.append(
            QueryRow(
                fields[0], fields[1], fields[2], fields[3], fields[4],
                _parse_int(fields[5], "time_ms"), sanitize_text(fields[6]),
            )
        )
    return tuple(rows)


def parse_digests(lines: Sequence[str]) -> Tuple[DigestRow, ...]:
    rows: List[DigestRow] = []
    for line in lines:
        if not line:
            continue
        fields = line.split("\t", 5)
        if len(fields) != 6:
            raise ValueError(f"Malformed DIGEST row: {line!r}")
        rows.append(
            DigestRow(
                fields[0],
                _parse_int(fields[1], "count_star"),
                _parse_int(fields[2], "sum_time"),
                _parse_int(fields[3], "min_time"),
                _parse_int(fields[4], "max_time"),
                sanitize_text(fields[5]),
            )
        )
    return tuple(rows)


def parse_backend(lines: Sequence[str]) -> BackendRows:
    if not lines:
        return BackendRows((), ())
    try:
        pool_index = lines.index(BACKEND_POOL_MARKER)
        ping_index = lines.index(BACKEND_PING_MARKER)
    except ValueError as exc:
        raise ValueError("BACKEND payload is missing section markers.") from exc
    if pool_index >= ping_index:
        raise ValueError("BACKEND section markers are out of order.")

    pool: List[PoolRow] = []
    for line in lines[pool_index + 1 : ping_index]:
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 7:
            raise ValueError(f"Malformed BACKEND pool row: {line!r}")
        pool.append(
            PoolRow(
                fields[0], fields[1], fields[2],
                _parse_int(fields[3], "ConnUsed"),
                _parse_int(fields[4], "ConnFree"),
                _parse_int(fields[5], "ConnOK"),
                _parse_int(fields[6], "ConnERR"),
            )
        )

    ping: List[PingRow] = []
    for line in lines[ping_index + 1 :]:
        if not line:
            continue
        fields = line.split("\t", 3)
        if len(fields) != 4:
            raise ValueError(f"Malformed BACKEND ping row: {line!r}")
        success: Optional[int] = (
            _parse_int(fields[2], "ping_success_time_us") if fields[2] else None
        )
        ping.append(PingRow(fields[0], fields[1], success, sanitize_text(fields[3])))
    return BackendRows(tuple(pool), tuple(ping))


def _render(lines: Iterable[Tuple[str, str]], row_count: int) -> RenderedView:
    pairs = list(lines)
    return RenderedView(
        colored="\n".join(colored for colored, _clean in pairs),
        clean="\n".join(clean for _colored, clean in pairs),
        row_count=row_count,
    )


def format_connections(
    rows: Sequence[ConnectionRow],
    previous: Sequence[ConnectionRow],
    *,
    threshold: int,
    user_filter: str,
) -> RenderedView:
    matcher = compile_user_filter(user_filter)
    selected = [row for row in rows if matcher.search(row.user)]
    old = {
        (row.user, row.client_host, row.server_host, row.schema): row.connections
        for row in previous
    }
    output: List[Tuple[str, str]] = []
    header = f"{'USER':<15} {'SOURCE (Cli)':<20} {'BACKEND (Srv)':<25} {'SCHEMA':<15} {'CONN':>6} {'DELTA':>7}"
    output.append((BOLD + header + RESET, header))
    for row in selected:
        key = (row.user, row.client_host, row.server_host, row.schema)
        delta = row.connections - old.get(key, row.connections)
        delta_text = f"{delta:+d}" if delta else "0"
        clean = (
            f"{truncate(row.user, 15):<15} {truncate(row.client_host, 20):<20} "
            f"{truncate(row.server_host, 25):<25} {truncate(row.schema, 15):<15} "
            f"{row.connections:>6} {delta_text:>7}"
        )
        color = RED if threshold > 0 and row.connections >= threshold else GREEN
        output.append((color + clean + RESET, clean))
    return _render(output, len(selected))


def format_queries(
    rows: Sequence[QueryRow],
    *,
    user_filter: str,
    terminal_width: int = 130,
) -> RenderedView:
    matcher = compile_user_filter(user_filter)
    selected = [row for row in rows if matcher.search(row.user)]
    query_width = max(20, terminal_width - 84)
    output: List[Tuple[str, str]] = []
    header = (
        f"{'PSID':<8} {'HG':<5} {'USER':<12} {'SOURCE':<16} {'BACKEND':<20} "
        f"{'TIME':>8} {'ACTIVE QUERY':<{query_width}}"
    )
    output.append((BOLD + header + RESET, header))
    for row in selected:
        clean = (
            f"{truncate(row.session_id, 8):<8} {truncate(row.hostgroup, 5):<5} "
            f"{truncate(row.user, 12):<12} {truncate(row.client_host, 16):<16} "
            f"{truncate(row.server_host, 20):<20} {row.time_ms:>8} "
            f"{truncate(sanitize_text(row.query), query_width):<{query_width}}"
        )
        color = RED if row.time_ms > 1000 else YELLOW if row.time_ms > 500 else CYAN
        output.append((color + clean + RESET, clean))
    return _render(output, len(selected))


def format_digests(
    rows: Sequence[DigestRow],
    *,
    user_filter: str,
    terminal_width: int = 130,
) -> RenderedView:
    del user_filter
    query_width = max(50, terminal_width - 60)
    output: List[Tuple[str, str]] = []
    header = (
        f"{'DIGEST':<14} {'COUNT':>6} {'SUM_TIME':>10} {'MIN_TIME':>10} "
        f"{'MAX_TIME':>10} {'QUERY TEXT':<{query_width}}"
    )
    output.append((BOLD + header + RESET, header))
    for row in rows:
        clean = (
            f"{truncate(row.digest, 14):<14} {row.count:>6} {row.sum_time:>10} "
            f"{row.min_time:>10} {row.max_time:>10} "
            f"{truncate(sanitize_text(row.query), query_width):<{query_width}}"
        )
        output.append((CYAN + clean + RESET, clean))
    return _render(output, len(rows))


def format_backend(rows: BackendRows, terminal_width: int = 130) -> RenderedView:
    del terminal_width
    output: List[Tuple[str, str]] = []
    pool_header = (
        f"{'HOSTGROUP':<10} {'BACKEND HOST':<30} {'STATUS':<12} "
        f"{'USED':>7} {'FREE':>7} {'OK':>10} {'ERR':>8}"
    )
    output.append((BOLD + pool_header + RESET, pool_header))
    for row in rows.pool:
        clean = (
            f"{truncate(row.hostgroup, 10):<10} {truncate(row.server_host, 30):<30} "
            f"{truncate(row.status, 12):<12} {row.conn_used:>7} {row.conn_free:>7} "
            f"{row.conn_ok:>10} {row.conn_err:>8}"
        )
        color = GREEN if row.status == "ONLINE" and row.conn_err == 0 else RED
        output.append((color + clean + RESET, clean))
    ping_header = f"{'PING HOST':<30} {'LAST PING':<20} {'SUCCESS_US':>12} ERROR"
    output.append((BOLD + ping_header + RESET, ping_header))
    for row in rows.ping:
        success = "" if row.success_us is None else str(row.success_us)
        clean = (
            f"{truncate(row.hostname, 30):<30} {truncate(row.last_ping, 20):<20} "
            f"{success:>12} {sanitize_text(row.error)}"
        )
        color = RED if row.error else GREEN
        output.append((color + clean + RESET, clean))
    return _render(output, len(rows.pool) + len(rows.ping))
