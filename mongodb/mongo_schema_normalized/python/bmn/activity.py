"""Activity collection (read-only): estimated insert dates, per-member counters,
oplog write activity and live $currentOp sampling.

Mirrored 1:1 in bash/lib/collector.js. Snapshot structures:

snapshot["activity"] = {
  "members":  [{"host", "state", "started_at", "error"}],
  "oplog":    None | {"member", "window_hours", "requested_from", "oplog_first", "oplog_last", "from", "error"},
  "sampling": None | {"samples", "interval_s", "members", "started_at", "finished_at", "error"},
  "uid_map":  None | {"resolved", "error"},
  "users":    {"user@db": {"sampled_ops", "namespaces": {}, "apps": {}, "clients": {}}},
}
collection["activity"] = {
  "first_insert", "last_insert", "id_type",
  "modified": [{"path", "types", "method", "index", "value", "error"}],  # method: index|scan|sample|none|ignored
  "last_modified", "last_modified_field", "last_modified_method",
  "top":     None | {"reads", "writes", "since"},
  "oplog":   None | {"inserts", "updates", "deletes", "commands", "first", "last", "created_at", "users": {}},
  "sampled": None | {"ops", "users": {}},
}
"""
from __future__ import annotations

import datetime as dt
import hashlib
import re
import time
from typing import Any, Dict, List, Optional, Tuple

from .common import SYSTEM_DBS, TOOL_NAME, fmt_utc

NO_SESSION = "(no session)"
NO_AUTH = "(no auth)"


def iso(value: Any) -> Optional[str]:
    if value is None:
        return None
    if hasattr(value, "time") and not isinstance(value, dt.datetime):  # bson.Timestamp
        value = value.time
    if isinstance(value, (int, float)):
        value = dt.datetime.fromtimestamp(int(value), tz=dt.timezone.utc)
    return fmt_utc(value)


def _err(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}".splitlines()[0][:500]


def is_unauthorized(exc: BaseException) -> bool:
    code = getattr(exc, "code", None)
    return code == 13 or "not authorized" in str(exc).lower() or "unauthorized" in str(exc).lower()


def auth_err(exc: BaseException, privilege: str) -> str:
    """Short, actionable message for authorization failures (the raw one echoes the whole command)."""
    if is_unauthorized(exc):
        return f"Unauthorized: missing privilege {privilege}"
    return _err(exc)


PRIV_MEMBER = "'serverStatus' and 'top' actions on {cluster: true} (member stats)"
PRIV_OPLOG = "'find' on {db: 'local', collection: 'oplog.rs'} (oplog window)"
PRIV_SAMPLING = "'inprog' action on {cluster: true} ($currentOp with allUsers)"
PRIV_USERS = "'viewUser' action on every database (session user resolution)"


def member_uri(uri: str, host: str) -> str:
    """Direct connection string to one replica set member, keeping auth/TLS options."""
    head, _, query = uri.partition("?")
    scheme, _, rest = head.partition("://")
    path = rest.split("/", 1)[1] if "/" in rest else ""
    params = [p for p in query.split("&")
              if p and p.split("=", 1)[0].lower() not in ("replicaset", "directconnection")]
    names = {p.split("=", 1)[0].lower() for p in params}
    if scheme == "mongodb+srv" and not names & {"tls", "ssl"}:
        params.append("tls=true")
    params.append("directConnection=true")
    return f"mongodb://{host}/{path}?{'&'.join(params)}"


def id_bounds(coll, timeout_ms: int) -> Dict[str, Any]:
    """First/last insert estimated from the ObjectId _id bounds (two _id index seeks)."""
    from bson import ObjectId

    out: Dict[str, Any] = {"first_insert": None, "last_insert": None, "id_type": "empty"}
    lo = list(coll.find({}, {"_id": 1}).sort("_id", 1).limit(1).max_time_ms(timeout_ms))
    if not lo:
        return out
    hi = list(coll.find({}, {"_id": 1}).sort("_id", -1).limit(1).max_time_ms(timeout_ms))
    lo_id, hi_id = lo[0].get("_id"), hi[0].get("_id") if hi else None
    lo_ok, hi_ok = isinstance(lo_id, ObjectId), isinstance(hi_id, ObjectId)
    if lo_ok:
        out["first_insert"] = iso(lo_id.generation_time)
    if hi_ok:
        out["last_insert"] = iso(hi_id.generation_time)
    out["id_type"] = "objectId" if lo_ok and hi_ok else ("mixed" if lo_ok or hi_ok else "other")
    return out


def oplog_pipeline(from_ts) -> List[dict]:
    """Groups oplog entries (incl. transaction applyOps) by namespace, op, session user and command."""
    return [
        {"$match": {"ts": {"$gte": from_ts}, "op": {"$in": ["i", "u", "d", "c"]}}},
        {"$project": {"ts": 1, "uid": "$lsid.uid", "entries": {"$cond": [
            {"$isArray": "$o.applyOps"}, "$o.applyOps", [{"op": "$op", "ns": "$ns", "o": "$o"}]]}}},
        {"$unwind": "$entries"},
        {"$project": {"ts": 1, "uid": 1, "op": "$entries.op", "ns": "$entries.ns", "cmd": {"$cond": [
            {"$eq": ["$entries.op", "c"]}, {"$arrayElemAt": [{"$objectToArray": "$entries.o"}, 0]}, None]}}},
        {"$group": {"_id": {"ns": "$ns", "op": "$op", "uid": "$uid", "cmd": "$cmd.k", "target": "$cmd.v"},
                    "n": {"$sum": 1}, "first": {"$min": "$ts"}, "last": {"$max": "$ts"}}},
    ]


def uid_hash(name: str) -> str:
    return hashlib.sha256(name.encode("utf-8")).hexdigest()


def resolve_uid(uid: Any, uid_map: Dict[str, str]) -> str:
    if uid is None:
        return NO_SESSION
    hexed = bytes(uid).hex()
    return uid_map.get(hexed, f"uid:{hexed[:12]}")


def fold_oplog_rows(rows: List[dict], uid_map: Dict[str, str]) -> Dict[str, dict]:
    per_ns: Dict[str, dict] = {}
    for row in rows:
        key = row["_id"]
        op = key.get("op")
        if op in ("i", "u", "d"):
            ns = key.get("ns") or ""
        elif op == "c":
            target, cmd = key.get("target"), key.get("cmd")
            if not isinstance(target, str):
                continue
            ns = target if cmd == "renameCollection" else f"{(key.get('ns') or '').split('.', 1)[0]}.{target}"
        else:
            continue
        if not ns or ns.split(".", 1)[0] in SYSTEM_DBS:
            continue
        entry = per_ns.setdefault(ns, empty_oplog_entry())
        n = int(row.get("n") or 0)
        field = {"i": "inserts", "u": "updates", "d": "deletes", "c": "commands"}[op]
        entry[field] += n
        first, last = iso(row.get("first")), iso(row.get("last"))
        if first and (entry["first"] is None or first < entry["first"]):
            entry["first"] = first
        if last and (entry["last"] is None or last > entry["last"]):
            entry["last"] = last
        if op == "c" and key.get("cmd") == "create" and last and (entry["created_at"] is None or last > entry["created_at"]):
            entry["created_at"] = last
        user = resolve_uid(key.get("uid"), uid_map)
        entry["users"][user] = entry["users"].get(user, 0) + n
    for entry in per_ns.values():
        entry["users"] = {k: entry["users"][k] for k in sorted(entry["users"])}
    return per_ns


def empty_oplog_entry() -> dict:
    return {"inserts": 0, "updates": 0, "deletes": 0, "commands": 0, "first": None, "last": None,
            "created_at": None, "users": {}}


def _bump(d: Dict[str, int], key: str, n: int = 1) -> None:
    d[key] = d.get(key, 0) + n


def sample_ops(ops: List[dict], sampled: Dict[str, dict], users: Dict[str, dict]) -> None:
    for op in ops:
        effective = op.get("effectiveUsers") or []
        if not effective:
            continue  # internal operations (replication, TTL monitor...)
        ns = op.get("ns") or ""
        db, _, coll = ns.partition(".")
        if not db or db in SYSTEM_DBS:
            continue
        if not coll or coll == "$cmd":
            command = op.get("command") or {}
            first = next(iter(command.values()), None) if command else None
            coll = first if isinstance(first, str) else ""
        full = f"{db}.{coll}" if coll else db
        user = f"{effective[0].get('user')}@{effective[0].get('db')}"
        entry = sampled.setdefault(full, {"ops": 0, "users": {}})
        entry["ops"] += 1
        _bump(entry["users"], user)
        u = users.setdefault(user, {"sampled_ops": 0, "namespaces": {}, "apps": {}, "clients": {}})
        u["sampled_ops"] += 1
        _bump(u["namespaces"], full)
        if op.get("appName"):
            _bump(u["apps"], str(op["appName"]))
        if op.get("client"):
            _bump(u["clients"], str(op["client"]).rsplit(":", 1)[0])


def sort_nested(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: sort_nested(value[k]) for k in sorted(value)}
    return value


class ActivityOptions:
    def __init__(self, enabled: bool = True, oplog_hours: int = 0, oplog_timeout: int = 600,
                 samples: int = 0, interval: int = 10, member_stats: bool = False,
                 modified_pattern: str = "modif", modified_scan: bool = False) -> None:
        self.enabled = enabled
        self.oplog_hours = oplog_hours
        self.oplog_timeout_ms = oplog_timeout * 1000
        self.samples = samples
        self.interval = interval
        self.member_stats = member_stats
        self.modified_pattern = modified_pattern
        self.modified_re = re.compile(modified_pattern, re.IGNORECASE) if modified_pattern else None
        self.modified_scan = modified_scan

    @property
    def needs_members(self) -> bool:
        return self.member_stats or self.oplog_hours > 0 or self.samples > 0


DATE_TYPES = ("date", "timestamp")


def _get_path(doc: Any, path: str) -> Any:
    for part in path.split("."):
        if not isinstance(doc, dict):
            return None
        doc = doc.get(part)
    return doc


def modified_dates(coll, schema: Optional[dict], indexes: List[dict], aopts: "ActivityOptions",
                   timeout_ms: int) -> List[dict]:
    """Last value of *modified* date fields: index seek (exact), full scan (opt-in) or sample max (lower bound)."""
    from pymongo.errors import OperationFailure

    from .collector import date_iso

    rx = aopts.modified_re
    if rx is None:
        return []
    schema = schema or {}
    candidates: Dict[str, List[str]] = {}
    for path, info in (schema.get("fields") or {}).items():
        if "[]" in path or not rx.search(path.rsplit(".", 1)[-1]):
            continue
        candidates[path] = sorted(t for t in (info.get("types") or {}) if t not in ("null", "undefined"))
    indexed: Dict[str, str] = {}
    for ix in indexes:
        if ix.get("partialFilterExpression") or ix.get("name") == "_id_":
            continue
        keys = list((ix.get("key") or {}).items())
        if keys and keys[0][1] in (1, -1) and not isinstance(keys[0][1], bool):
            indexed.setdefault(keys[0][0], ix.get("name"))
    for path in indexed:
        if "[]" not in path and rx.search(path.rsplit(".", 1)[-1]) and path not in candidates:
            candidates[path] = []
    sample_max = schema.get("modified_max") or {}
    out: List[dict] = []
    for path in sorted(candidates):
        types = candidates[path]
        entry: Dict[str, Any] = {"path": path, "types": types, "method": "none", "index": None, "value": None,
                                 "error": None}
        if types and not any(t in DATE_TYPES for t in types):
            entry["method"] = "ignored"
            out.append(entry)
            continue
        # BSON order puts every Timestamp above every Date: take the max per type, then compare as instants.
        try:
            if path in indexed:
                entry["method"], entry["index"] = "index", indexed[path]
                values = []
                for btype in DATE_TYPES:
                    docs = list(coll.find({path: {"$type": btype}}, {path: 1, "_id": 0}).sort(path, -1)
                                .hint(indexed[path]).limit(1).max_time_ms(timeout_ms))
                    if docs:
                        values.append(date_iso(_get_path(docs[0], path)))
                entry["value"] = max([v for v in values if v] or [None], key=lambda v: v or "")
            elif aopts.modified_scan:
                entry["method"] = "scan"
                rows = list(coll.aggregate([{"$match": {path: {"$type": list(DATE_TYPES)}}},
                                            {"$group": {"_id": {"$type": f"${path}"}, "m": {"$max": f"${path}"}}}],
                                           maxTimeMS=timeout_ms))
                values = [date_iso(r.get("m")) for r in rows]
                entry["value"] = max([v for v in values if v] or [None], key=lambda v: v or "")
            elif path in sample_max:
                entry["method"], entry["value"] = "sample", sample_max[path]
        except OperationFailure as exc:
            entry["error"] = _err(exc)
        out.append(entry)
    return out


def collect_activity(client, uri: str, user: Optional[str], password: Optional[str], hello: dict,
                     db_names: List[str], aopts: ActivityOptions, op_timeout_ms: int) -> Tuple[dict, dict, dict, Optional[str]]:
    """Returns (activity, top_by_ns, oplog_by_ns, top_since)."""
    from bson.timestamp import Timestamp
    from pymongo import MongoClient

    activity: Dict[str, Any] = {"members": [], "oplog": None, "sampling": None, "uid_map": None, "users": {}}
    hosts = list(hello.get("hosts") or []) + list(hello.get("passives") or [])
    members: List[Tuple[str, Any, str]] = []
    top: Dict[str, List[int]] = {}
    starts: List[str] = []
    for host in (hosts or [hello.get("me") or "self"]) if aopts.needs_members else []:
        info: Dict[str, Any] = {"host": host, "state": None, "started_at": None, "error": None}
        try:
            mc = (MongoClient(member_uri(uri, host), username=user or None, password=password,
                              datetime_conversion="DATETIME_AUTO") if hosts else client)
            h = mc.admin.command("hello") if hosts else hello
            info["state"] = ("PRIMARY" if h.get("isWritablePrimary") or h.get("ismaster")
                             else "SECONDARY" if h.get("secondary") else "OTHER")
            if aopts.member_stats:
                status = mc.admin.command({"serverStatus": 1, "repl": 0, "metrics": 0, "locks": 0})
                info["started_at"] = iso(int(time.time()) - int(float(status.get("uptime") or 0)))
                starts.append(info["started_at"])
                for ns, counters in (mc.admin.command("top").get("totals") or {}).items():
                    if ns == "note" or not isinstance(counters, dict):
                        continue
                    reads = sum(int((counters.get(k) or {}).get("count") or 0) for k in ("queries", "getmore"))
                    writes = sum(int((counters.get(k) or {}).get("count") or 0)
                                 for k in ("insert", "update", "remove"))
                    agg = top.setdefault(ns, [0, 0])
                    agg[0] += reads
                    agg[1] += writes
            members.append((host, mc, info["state"]))
        except Exception as exc:  # noqa: BLE001 - reported as ACTIVITY_ERROR
            info["error"] = auth_err(exc, PRIV_MEMBER)
        activity["members"].append(info)
    top_since = max(starts) if starts else None

    uid_map: Dict[str, str] = {}
    oplog_by_ns: Dict[str, dict] = {}
    if aopts.oplog_hours > 0:
        uid_map[uid_hash("")] = NO_AUTH
        resolved, uid_err = 0, None
        for name in ["admin"] + db_names:
            try:
                for u in client[name].command({"usersInfo": 1}).get("users", []):
                    uid_map[uid_hash(f"{u['user']}@{u['db']}")] = f"{u['user']}@{u['db']}"
                    resolved += 1
            except Exception as exc:  # noqa: BLE001
                uid_err = uid_err or auth_err(exc, PRIV_USERS)
        activity["uid_map"] = {"resolved": resolved, "error": uid_err}
        chosen = next((m for m in members if m[2] == "SECONDARY"), None) or (members[0] if members else None)
        now = time.time()
        olog: Dict[str, Any] = {"member": chosen[0] if chosen else None, "window_hours": aopts.oplog_hours,
                                "requested_from": iso(int(now - aopts.oplog_hours * 3600)), "oplog_first": None,
                                "oplog_last": None, "from": None, "error": None}
        try:
            if chosen is None:
                raise RuntimeError("no reachable replica set member")
            oplog = chosen[1].local["oplog.rs"]
            first = next(iter(oplog.find({}, {"ts": 1}).sort("$natural", 1).limit(1)), None)
            last = next(iter(oplog.find({}, {"ts": 1}).sort("$natural", -1).limit(1)), None)
            if first is None:
                raise RuntimeError("oplog is empty or not readable")
            olog["oplog_first"], olog["oplog_last"] = iso(first["ts"].time), iso(last["ts"].time)
            from_secs = max(int(now - aopts.oplog_hours * 3600), first["ts"].time)
            olog["from"] = iso(from_secs)
            rows = list(oplog.aggregate(oplog_pipeline(Timestamp(from_secs, 0)), allowDiskUse=True,
                                        maxTimeMS=aopts.oplog_timeout_ms))
            oplog_by_ns = fold_oplog_rows(rows, uid_map)
        except Exception as exc:  # noqa: BLE001
            olog["error"] = auth_err(exc, PRIV_OPLOG)
        activity["oplog"] = olog

    sampled: Dict[str, dict] = {}
    if aopts.samples > 0:
        samp: Dict[str, Any] = {"samples": aopts.samples, "interval_s": aopts.interval, "members": len(members),
                                "started_at": iso(time.time()), "finished_at": None, "error": None}
        pipeline = [{"$currentOp": {"allUsers": True, "idleConnections": False}},
                    {"$match": {"active": True, "appName": {"$ne": TOOL_NAME}}},
                    {"$project": {"ns": 1, "op": 1, "command": 1, "effectiveUsers": 1, "appName": 1, "client": 1}}]
        for rnd in range(aopts.samples):
            for host, mc, _ in members:
                try:
                    sample_ops(list(mc.admin.aggregate(pipeline, maxTimeMS=op_timeout_ms)), sampled, activity["users"])
                except Exception as exc:  # noqa: BLE001
                    samp["error"] = samp["error"] or f"{host}: {auth_err(exc, PRIV_SAMPLING)}"
            if rnd < aopts.samples - 1:
                time.sleep(aopts.interval)
        samp["finished_at"] = iso(time.time())
        activity["sampling"] = samp
        activity["users"] = sort_nested(activity["users"])

    for host, mc, _ in members:
        if mc is not client:
            mc.close()
    activity["_sampled"] = {k: sort_nested(v) for k, v in sampled.items()}
    return activity, {k: v for k, v in top.items()}, oplog_by_ns, top_since


def collection_activity(ns: str, bounds: Dict[str, Any], modified: List[dict], activity: dict,
                        top: Dict[str, List[int]], oplog_by_ns: Dict[str, dict], top_since: Optional[str]) -> dict:
    t = top.get(ns)
    sampled = activity.get("_sampled") or {}
    oplog_ok = activity.get("oplog") is not None and not activity["oplog"].get("error")
    best: Optional[dict] = None
    for entry in modified:
        if entry.get("value") and (best is None or entry["value"] > best["value"]):
            best = entry
    return {
        "first_insert": bounds.get("first_insert"), "last_insert": bounds.get("last_insert"),
        "id_type": bounds.get("id_type"),
        "modified": modified,
        "last_modified": best["value"] if best else None,
        "last_modified_field": best["path"] if best else None,
        "last_modified_method": best["method"] if best else None,
        "top": ({"reads": t[0], "writes": t[1], "since": top_since} if t
                else ({"reads": 0, "writes": 0, "since": top_since} if top_since else None)),
        "oplog": (oplog_by_ns.get(ns) or empty_oplog_entry()) if oplog_ok else None,
        "sampled": (sampled.get(ns) or {"ops": 0, "users": {}}) if activity.get("sampling") else None,
    }
