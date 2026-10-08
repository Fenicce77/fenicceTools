"""Shared constants and deterministic helpers (mirrored 1:1 in bash/lib/analyzer.js)."""
from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Any, Tuple

TOOL_NAME = "betika_mongodb_normalized"
TOOL_VERSION = "1.0.0"
SNAPSHOT_FORMAT = 1
ANALYSIS_FORMAT = 1

SYSTEM_DBS = ("admin", "local", "config")
NUMERIC_TYPES = frozenset({"int", "long", "double", "decimal"})
NULLISH_TYPES = frozenset({"null", "undefined"})
CONVERTIBLE_TYPES = frozenset({"int", "long", "double", "decimal", "string", "date", "objectId"})
INVALID_DB_CHARS = frozenset('/\\. "$\x00')
SEV_RANK = {"ERROR": 0, "WARN": 1, "INFO": 2}

# Index options that define index semantics (name/version/build options excluded).
INDEX_SIG_OPTIONS = (
    "unique", "sparse", "hidden", "partialFilterExpression", "expireAfterSeconds", "collation",
    "weights", "default_language", "language_override", "wildcardProjection", "bits", "min", "max",
    "bucketSize",
)
INDEX_BOOL_OPTIONS = frozenset({"unique", "sparse", "hidden"})
INDEX_STRIP_KEYS = frozenset({"v", "ns", "background", "dropDups"})

PROJECT_HOME = Path(__file__).resolve().parents[2]
TEMPLATES_DIR = PROJECT_HOME / "share" / "templates"


def normalize_numbers(value: Any) -> Any:
    """Integral floats become ints so 1.0 and 1 produce the same canonical JSON."""
    if isinstance(value, bool):
        return value
    if isinstance(value, float) and value.is_integer() and abs(value) < 2 ** 53:
        return int(value)
    if isinstance(value, dict):
        return {k: normalize_numbers(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize_numbers(v) for v in value]
    return value


def canon(value: Any, sort_keys: bool = True) -> str:
    """Compact, deterministic JSON used for signatures and comparisons."""
    return json.dumps(normalize_numbers(value), sort_keys=sort_keys, separators=(",", ":"), ensure_ascii=False)


def fmt_value(value: Any) -> str:
    return "-" if value is None else canon(value)


def parse_version(version: Any) -> Tuple[int, int, int]:
    match = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?", str(version or ""))
    if not match:
        return (0, 0, 0)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))


def human_bytes(num: Any) -> str:
    n = float(num or 0)
    if n < 1024:
        return f"{int(n)} B"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    idx = 0
    while n >= 1024 and idx < len(units) - 1:
        n /= 1024
        idx += 1
    rounded = math.floor(n * 100 + 0.5) / 100
    return f"{rounded:.2f} {units[idx]}"


def md(text: Any) -> str:
    """Escape a value for a markdown table cell."""
    return str(text).replace("|", "\\|").replace("\n", " ")


def sh_single_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def dump_pretty(value: Any) -> str:
    return json.dumps(normalize_numbers(value), indent=2, ensure_ascii=False)


def index_signature(index: dict) -> str:
    """Name-independent signature: ordered key pattern + semantic options."""
    opts = {}
    for key in INDEX_SIG_OPTIONS:
        if key not in index:
            continue
        val = index[key]
        if key in INDEX_BOOL_OPTIONS:
            if not val:
                continue
            val = True
        opts[key] = val
    sig = canon(index.get("key") or {}, sort_keys=False)
    if opts:
        sig += " " + canon(opts)
    return sig


def invalid_db_name(name: str) -> bool:
    return not name or len(name.encode("utf-8")) >= 64 or any(ch in INVALID_DB_CHARS for ch in name)


def classify_types(types: dict) -> str:
    """'none' (consistent), 'numeric' (only numeric widths differ) or 'mixed'."""
    non_null = [t for t in types if t not in NULLISH_TYPES]
    if len(non_null) <= 1:
        return "none"
    if all(t in NUMERIC_TYPES for t in non_null):
        return "numeric"
    return "mixed"


def fmt_types(types: dict) -> str:
    ordered = sorted(types.items(), key=lambda kv: (-kv[1], kv[0]))
    return ", ".join(f"{t}={n}" for t, n in ordered)
