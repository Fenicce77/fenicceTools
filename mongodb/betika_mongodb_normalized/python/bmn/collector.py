"""Schema snapshot collection with pymongo (read-only, secondaryPreferred).

Snapshots contain metadata, statistics and field-path/type histograms only:
no document values are persisted.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import uuid
from typing import Any, Dict, List, Optional, Tuple

from .common import SNAPSHOT_FORMAT, SYSTEM_DBS, TOOL_NAME, TOOL_VERSION
from .config import InstanceConfig, redact_uri

MAX_ARRAY_ELEMENTS = 100
MAX_FIELD_PATHS = 1000


def _lazy_bson():
    try:
        import bson  # noqa: F401  (provided by pymongo)
        from bson import json_util
        return bson, json_util
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("pymongo is required for collection: pip3 install -r requirements.txt") from exc


def to_plain(value: Any) -> Any:
    """BSON -> relaxed Extended JSON -> plain Python structures."""
    _, json_util = _lazy_bson()
    return json.loads(json_util.dumps(value, json_options=json_util.RELAXED_JSON_OPTIONS))


def bson_type(value: Any) -> str:
    import bson
    from bson.code import Code
    from bson.dbref import DBRef
    from bson.int64 import Int64
    from bson.max_key import MaxKey
    from bson.min_key import MinKey
    from bson.regex import Regex
    from bson.timestamp import Timestamp

    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, Int64):
        return "long"
    if isinstance(value, int):
        return "int" if -2 ** 31 <= value < 2 ** 31 else "long"
    if isinstance(value, float):
        return "double"
    if isinstance(value, str):
        return "string"
    if isinstance(value, DBRef):
        return "object"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    if isinstance(value, bson.ObjectId):
        return "objectId"
    if isinstance(value, dt.datetime):
        return "date"
    if isinstance(value, bson.Decimal128):
        return "decimal"
    if isinstance(value, (bytes, bson.Binary, uuid.UUID)):
        return "binData"
    if isinstance(value, (Regex, re.Pattern)):
        return "regex"
    if isinstance(value, Timestamp):
        return "timestamp"
    if isinstance(value, Code):
        return "javascript"
    if isinstance(value, MinKey):
        return "minKey"
    if isinstance(value, MaxKey):
        return "maxKey"
    return type(value).__name__


def _walk(doc: dict, prefix: str, depth: int, max_depth: int, seen: Dict[Tuple[str, str], None]) -> None:
    for key, value in doc.items():
        path = f"{prefix}.{key}" if prefix else key
        vtype = bson_type(value)
        seen[(path, vtype)] = None
        if vtype == "object" and isinstance(value, dict) and depth < max_depth:
            _walk(value, path, depth + 1, max_depth, seen)
        elif vtype == "array":
            apath = f"{path}[]"
            for elem in value[:MAX_ARRAY_ELEMENTS]:
                etype = bson_type(elem)
                seen[(apath, etype)] = None
                if etype == "object" and isinstance(elem, dict) and depth < max_depth:
                    _walk(elem, apath, depth + 1, max_depth, seen)


def infer_schema(docs: List[dict], max_depth: int) -> dict:
    fields: Dict[str, dict] = {}
    truncated = False
    for doc in docs:
        seen: Dict[Tuple[str, str], None] = {}
        _walk(doc, "", 1, max_depth, seen)
        counted = set()
        for path, vtype in seen:
            if path not in fields:
                if len(fields) >= MAX_FIELD_PATHS:
                    truncated = True
                    continue
                fields[path] = {"count": 0, "types": {}}
            entry = fields[path]
            entry["types"][vtype] = entry["types"].get(vtype, 0) + 1
            if path not in counted:
                entry["count"] += 1
                counted.add(path)
    ordered = {p: {"count": fields[p]["count"], "types": dict(sorted(fields[p]["types"].items()))}
               for p in sorted(fields)}
    return {"sampled": len(docs), "truncated": truncated, "fields": ordered}


class CollectOptions:
    def __init__(self, sample_size: int = 100, max_depth: int = 5, timeout: int = 15, op_timeout: int = 120,
                 include_dbs: Optional[str] = None, exclude_dbs: Optional[str] = None,
                 include_security: bool = False) -> None:
        self.sample_size = sample_size
        self.max_depth = max_depth
        self.timeout = timeout
        self.op_timeout_ms = op_timeout * 1000
        self.include_re = re.compile(include_dbs) if include_dbs else None
        self.exclude_re = re.compile(exclude_dbs) if exclude_dbs else None
        self.include_security = include_security


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _err(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}".splitlines()[0][:500]


def base_snapshot(cfg: InstanceConfig, uri: str, collector: str, opts: CollectOptions) -> dict:
    return {
        "tool": TOOL_NAME, "tool_version": TOOL_VERSION, "snapshot_format": SNAPSHOT_FORMAT,
        "collector": collector,
        "instance": {"name": cfg.name, "alias": cfg.alias, "role": cfg.role, "conf_file": str(cfg.path),
                     "uri": redact_uri(uri)},
        "collected_at": _now(), "status": "error", "error": None,
        "params": {"sample_size": opts.sample_size, "max_depth": opts.max_depth},
        "server": {}, "databases": [], "security": None,
    }


def collect_instance(cfg: InstanceConfig, opts: CollectOptions) -> dict:
    uri = cfg.uri(opts.timeout)
    snap = base_snapshot(cfg, uri, "python", opts)
    try:
        from pymongo import MongoClient
        from pymongo.errors import OperationFailure, PyMongoError
    except ImportError:
        snap["error"] = "pymongo is not installed (pip3 install -r requirements.txt)"
        return snap
    try:
        password = cfg.resolve_password()
        client = MongoClient(uri, username=cfg.user or None, password=password)
        try:
            _collect(client, snap, opts, OperationFailure)
            snap["status"] = "ok"
        finally:
            client.close()
    except (PyMongoError, OSError, ValueError, RuntimeError) as exc:
        snap["error"] = _err(exc)
    except Exception as exc:  # noqa: BLE001 - config errors and unexpected failures end in the snapshot
        snap["error"] = _err(exc)
    return snap


def _collect(client, snap: dict, opts: CollectOptions, OperationFailure) -> None:  # noqa: N803
    admin = client.admin
    try:
        hello = admin.command("hello")
    except OperationFailure:
        hello = admin.command("isMaster")
    build = admin.command("buildInfo")
    server: Dict[str, Any] = {"version": build.get("version"), "fcv": None, "set_name": hello.get("setName"),
                              "storage_engine": None}
    if hello.get("msg") == "isdbgrid":
        server["topology"] = "sharded"
    elif hello.get("setName"):
        server["topology"] = "replicaset"
    else:
        server["topology"] = "standalone"
    try:
        fcv = admin.command({"getParameter": 1, "featureCompatibilityVersion": 1})
        server["fcv"] = (fcv.get("featureCompatibilityVersion") or {}).get("version")
    except OperationFailure:
        pass
    try:
        status = admin.command({"serverStatus": 1, "repl": 0, "metrics": 0, "locks": 0})
        server["storage_engine"] = (status.get("storageEngine") or {}).get("name")
    except OperationFailure:
        pass
    snap["server"] = server

    shard_keys: Dict[str, Tuple[Any, bool]] = {}
    if server["topology"] == "sharded":
        for doc in client.config.collections.find({"dropped": {"$ne": True}}):
            shard_keys[doc["_id"]] = (to_plain(doc.get("key")), bool(doc.get("unique")))

    listing = admin.command({"listDatabases": 1, "nameOnly": False})
    databases = []
    for info in sorted(listing.get("databases", []), key=lambda d: d["name"]):
        name = info["name"]
        if name in SYSTEM_DBS:
            continue
        if opts.include_re and not opts.include_re.search(name):
            continue
        if opts.exclude_re and opts.exclude_re.search(name):
            continue
        databases.append(_collect_db(client[name], info, shard_keys, opts, OperationFailure))
    snap["databases"] = databases

    if opts.include_security:
        snap["security"] = _collect_security(client, ["admin"] + [d["name"] for d in databases])


def _collect_db(db, info: dict, shard_keys: dict, opts: CollectOptions, OperationFailure) -> dict:  # noqa: N803
    out = {"name": db.name, "size_on_disk": int(info.get("sizeOnDisk") or 0), "empty": bool(info.get("empty")),
           "collections": []}
    for cinfo in sorted(db.list_collections(), key=lambda c: c["name"]):
        cname = cinfo["name"]
        if cname.startswith("system."):
            continue
        raw_type = cinfo.get("type", "collection")
        ctype = raw_type if raw_type in ("view", "timeseries") else "collection"
        coll = db[cname]
        entry: Dict[str, Any] = {"name": cname, "type": ctype, "options": to_plain(cinfo.get("options") or {}),
                                 "stats": None, "stats_error": None, "indexes": [], "shard_key": None,
                                 "shard_key_unique": False, "schema": None, "schema_error": None}
        ns = f"{db.name}.{cname}"
        if ns in shard_keys:
            entry["shard_key"], entry["shard_key_unique"] = shard_keys[ns]
        if ctype != "view":
            try:
                specs = [to_plain({k: v for k, v in ix.items() if k not in ("v", "ns")})
                         for ix in coll.list_indexes()]
                entry["indexes"] = sorted(specs, key=lambda x: x.get("name", ""))
            except OperationFailure as exc:
                entry["stats_error"] = f"listIndexes: {_err(exc)}"
            try:
                total = {"count": 0, "size": 0, "storage_size": 0, "total_index_size": 0}
                for doc in coll.aggregate([{"$collStats": {"storageStats": {}}}], maxTimeMS=opts.op_timeout_ms):
                    st = doc.get("storageStats") or {}
                    total["count"] += int(st.get("count") or 0)
                    total["size"] += int(st.get("size") or 0)
                    total["storage_size"] += int(st.get("storageSize") or 0)
                    total["total_index_size"] += int(st.get("totalIndexSize") or 0)
                total["avg_obj_size"] = total["size"] // total["count"] if total["count"] else 0
                entry["stats"] = total
            except OperationFailure as exc:
                entry["stats_error"] = _err(exc)
            if opts.sample_size > 0:
                try:
                    docs = list(coll.aggregate([{"$sample": {"size": opts.sample_size}}],
                                               maxTimeMS=opts.op_timeout_ms))
                    entry["schema"] = infer_schema(docs, opts.max_depth)
                except OperationFailure as exc:
                    entry["schema_error"] = _err(exc)
        out["collections"].append(entry)
    return out


def _collect_security(client, db_names: List[str]) -> dict:
    users: List[dict] = []
    roles: List[dict] = []
    errors: List[str] = []
    for name in db_names:
        db = client[name]
        try:
            for u in db.command({"usersInfo": 1}).get("users", []):
                users.append({"user": u["user"], "db": u["db"],
                              "roles": [{"role": r["role"], "db": r["db"]} for r in u.get("roles", [])]})
        except Exception as exc:  # noqa: BLE001
            errors.append(f"usersInfo@{name}: {_err(exc)}")
        try:
            res = db.command({"rolesInfo": 1, "showPrivileges": True, "showBuiltinRoles": False})
            for r in res.get("roles", []):
                roles.append(to_plain({"role": r["role"], "db": r["db"], "privileges": r.get("privileges", []),
                                       "roles": [{"role": x["role"], "db": x["db"]} for x in r.get("roles", [])]}))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"rolesInfo@{name}: {_err(exc)}")
    return {"users": users, "roles": roles, "errors": errors}
