from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Optional, Tuple


class View(str, Enum):
    CONN = "CONN"
    QUERY = "QUERY"
    DIGEST = "DIGEST"
    BACKEND = "BACKEND"


class SortMode(str, Enum):
    CONN = "CONN"
    USER = "USER"


@dataclass(frozen=True)
class Config:
    login_paths: Tuple[str, ...]
    refresh_time: float = 5.0
    user_filter: str = ""
    threshold: int = 0
    output_file: Optional[Path] = None
    smoke_test: bool = False
    query_timeout: float = 5.0


@dataclass(frozen=True)
class ConnectionRow:
    user: str
    client_host: str
    server_host: str
    schema: str
    connections: int


@dataclass(frozen=True)
class QueryRow:
    session_id: str
    hostgroup: str
    user: str
    client_host: str
    server_host: str
    time_ms: int
    query: str


@dataclass(frozen=True)
class DigestRow:
    digest: str
    count: int
    sum_time: int
    min_time: int
    max_time: int
    query: str


@dataclass(frozen=True)
class PoolRow:
    hostgroup: str
    server_host: str
    status: str
    conn_used: int
    conn_free: int
    conn_ok: int
    conn_err: int


@dataclass(frozen=True)
class PingRow:
    hostname: str
    last_ping: str
    success_us: Optional[int]
    error: str


@dataclass(frozen=True)
class BackendRows:
    pool: Tuple[PoolRow, ...]
    ping: Tuple[PingRow, ...]


@dataclass
class MonitorState:
    view: View = View.CONN
    sort_mode: SortMode = SortMode.CONN
    paused: bool = False
    stale: bool = False
    last_error: str = ""
    previous_connections: Tuple[ConnectionRow, ...] = field(default_factory=tuple)
    last_rendered: str = ""


@dataclass(frozen=True)
class SmokeResult:
    login_path: str
    view: View
    rows: int
    elapsed_seconds: float
    success: bool
    error: str = ""
