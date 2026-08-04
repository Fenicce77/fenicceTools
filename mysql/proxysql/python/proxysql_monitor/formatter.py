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
ORANGE = "\x1b[1;38;5;208m"
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
    value = "".join(
        " " if ord(character) < 32 or 127 <= ord(character) <= 159 else character
        for character in value
    )
    return re.sub(r" +", " ", value).strip()


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
        success_value = fields[2].strip()
        success: Optional[int] = None
        if success_value and success_value.upper() != "NULL":
            success = _parse_int(success_value, "ping_success_time_us")
        ping.append(PingRow(fields[0], fields[1], success, sanitize_text(fields[3])))
    return BackendRows(tuple(pool), tuple(ping))


def _render(lines: Iterable[Tuple[str, str]], row_count: int) -> RenderedView:
    pairs = list(lines)
    return RenderedView(
        colored="\n".join(colored for colored, _clean in pairs),
        clean="\n".join(clean for _colored, clean in pairs),
        row_count=row_count,
    )


def _backend_status_color(status: str) -> str:
    return {
        "ONLINE": GREEN,
        "SHUNNED": YELLOW,
        "OFFLINE_SOFT": ORANGE,
        "OFFLINE_HARD": RED,
    }.get(status.strip().upper(), RED)


def format_connections(
    rows: Sequence[ConnectionRow],
    previous: Sequence[ConnectionRow],
    *,
    threshold: int,
    user_filter: str,
) -> RenderedView:
    matcher = compile_user_filter(user_filter)
    selected = [row for row in rows if matcher.search(sanitize_text(row.user))]
    old = {
        (row.user, row.client_host, row.server_host, row.schema): row.connections
        for row in previous
    }
    output: List[Tuple[str, str]] = []
    header = (
        f"{'USER':<20} | {'SOURCE (Cli)':<15} | {'BACKEND (Srv)':<28} | "
        f"{'SCHEMA':<20} | {'CONN':<10} | {'DELTA':<10}"
    )
    output.append((BOLD + header + RESET, header))
    total_connections = 0
    total_delta = 0
    for row in selected:
        key = (row.user, row.client_host, row.server_host, row.schema)
        delta = row.connections - old.get(key, row.connections)
        delta_text = f"{delta:+d}" if delta else "0"
        total_connections += row.connections
        total_delta += delta
        clean = (
            f"{truncate(sanitize_text(row.user), 20):<20} | "
            f"{truncate(sanitize_text(row.client_host), 15):<15} | "
            f"{truncate(sanitize_text(row.server_host), 28):<28} | "
            f"{truncate(sanitize_text(row.schema), 20):<20} | "
            f"{row.connections:<10} | {delta_text:<10}"
        )
        color = RED if threshold > 0 and row.connections >= threshold else GREEN
        output.append((color + clean + RESET, clean))
    if total_connections > 0:
        total_delta_text = f"{total_delta:+d}" if total_delta else "0"
        clean = (
            f"{'GLOBAL TOTALS':<20} | {'':<15} | {'':<28} | {'':<20} | "
            f"{total_connections:<10} | {total_delta_text:<10}"
        )
        output.append((CYAN + BOLD + clean + RESET, clean))
    return _render(output, len(selected))


def format_queries(
    rows: Sequence[QueryRow],
    *,
    user_filter: str,
    terminal_width: int = 130,
) -> RenderedView:
    matcher = compile_user_filter(user_filter)
    selected = [row for row in rows if matcher.search(sanitize_text(row.user))]
    query_width = max(20, terminal_width - 97)
    output: List[Tuple[str, str]] = []
    header = (
        f"{'PSID':<8} | {'HG':<4} | {'USER':<15} | {'SOURCE':<15} | "
        f"{'BACKEND':<28} | {'TIME':<9} | {'ACTIVE QUERY':<{query_width}}"
    )
    output.append((BOLD + header + RESET, header))
    for row in selected:
        clean = (
            f"{truncate(sanitize_text(row.session_id), 8):<8} | "
            f"{truncate(sanitize_text(row.hostgroup), 4):<4} | "
            f"{truncate(sanitize_text(row.user), 15):<15} | "
            f"{truncate(sanitize_text(row.client_host), 15):<15} | "
            f"{truncate(sanitize_text(row.server_host), 28):<28} | "
            f"{str(row.time_ms) + 'ms':<9} | "
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
    query_width = max(20, terminal_width - 73)
    output: List[Tuple[str, str]] = []
    header = (
        f"{'DIGEST':<18} | {'COUNT':<10} | {'SUM_TIME':<10} | "
        f"{'MIN_TIME':<10} | {'MAX_TIME':<10} | {'QUERY TEXT':<{query_width}}"
    )
    output.append((BOLD + header + RESET, header))
    for row in rows:
        clean = (
            f"{truncate(sanitize_text(row.digest), 18):<18} | {row.count:<10} | "
            f"{row.sum_time:<10} | {row.min_time:<10} | {row.max_time:<10} | "
            f"{truncate(sanitize_text(row.query), query_width):<{query_width}}"
        )
        output.append((CYAN + clean + RESET, clean))
    return _render(output, len(rows))


def format_backend(rows: BackendRows, terminal_width: int = 130) -> RenderedView:
    del terminal_width
    output: List[Tuple[str, str]] = []
    pool_header = (
        f"{'HOSTGROUP':<10} | {'BACKEND HOST':<35} | {'STATUS':<15} | "
        f"{'CONN USED':<11} | {'CONN FREE':<11} | {'CONN OK':<11} | {'CONN ERR':<11}"
    )
    output.append((BOLD + pool_header + RESET, pool_header))
    for row in rows.pool:
        clean = (
            f"{truncate(sanitize_text(row.hostgroup), 10):<10} | "
            f"{truncate(sanitize_text(row.server_host), 35):<35} | "
            f"{truncate(sanitize_text(row.status), 15):<15} | "
            f"{row.conn_used:<11} | {row.conn_free:<11} | "
            f"{row.conn_ok:<11} | {row.conn_err:<11}"
        )
        color = _backend_status_color(row.status)
        output.append((color + clean + RESET, clean))
    ping_header = (
        f"{'HOSTNAME':<35} | {'LAST PING DATETIME':<25} | "
        f"{'SUCCESS (us)':<15} | PING ERROR"
    )
    output.append((BOLD + ping_header + RESET, ping_header))
    for row in rows.ping:
        success = "" if row.success_us is None else str(row.success_us)
        clean = (
            f"{truncate(sanitize_text(row.hostname), 35):<35} | "
            f"{truncate(sanitize_text(row.last_ping), 25):<25} | "
            f"{success:<15} | {sanitize_text(row.error)}"
        )
        normalized_error = row.error.strip().upper()
        color = GREEN if normalized_error in ("", "NULL") else RED
        output.append((color + clean + RESET, clean))
    return _render(output, len(rows.pool) + len(rows.ping))
