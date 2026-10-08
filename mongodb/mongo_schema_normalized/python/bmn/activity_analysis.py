"""Activity and user analysis over snapshots (pure function, mirrored in bash/lib/analyzer.js)."""
from __future__ import annotations

import datetime as dt
from typing import Any, Dict, List, Optional, Set, Tuple

ANY_DB_ROLES = frozenset({"readAnyDatabase", "readWriteAnyDatabase", "dbAdminAnyDatabase",
                          "userAdminAnyDatabase", "root", "__system", "backup", "restore"})
DB_ROLES = frozenset({"read", "readWrite", "dbAdmin", "dbOwner", "userAdmin"})


def effective_access(role_refs: List[dict], custom: Dict[str, dict]) -> List[str]:
    """Databases reachable through the user's roles ('*' = any database)."""
    out: Set[str] = set()
    seen: Set[str] = set()
    stack = list(role_refs)
    while stack:
        ref = stack.pop()
        key = f"{ref.get('role')}@{ref.get('db')}"
        if key in seen:
            continue
        seen.add(key)
        role = ref.get("role")
        if role in ANY_DB_ROLES:
            out.add("*")
        elif role in DB_ROLES:
            out.add(ref.get("db") or "*")
        elif key in custom:
            for priv in custom[key].get("privileges") or []:
                res = priv.get("resource") or {}
                if "db" in res:
                    out.add(res.get("db") or "*")
                elif res.get("anyResource"):
                    out.add("*")
            stack.extend(custom[key].get("roles") or [])
    return sorted(out)


def top_users(users: Dict[str, int], limit: int = 3) -> List[str]:
    ordered = sorted(users.items(), key=lambda kv: (-kv[1], kv[0]))
    return [f"{u} ({n})" for u, n in ordered[:limit]]


def _merge_counts(target: Dict[str, int], source: Dict[str, int]) -> None:
    for k, v in source.items():
        target[k] = target.get(k, 0) + int(v or 0)


def days_between(newer: str, older: str) -> int:
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    delta = dt.datetime.strptime(newer, fmt) - dt.datetime.strptime(older, fmt)
    return int(delta.total_seconds() // 86400)


def analyze_activity(sources: List[dict], F, stale_days: int = 180) -> Tuple[List[dict], List[dict]]:
    activity_out: List[dict] = []
    users_out: List[dict] = []
    for s in sources:
        iname = s["instance"]["name"]
        act = s.get("activity")
        sec = s.get("security")
        if not act and not sec:
            continue
        oplog = (act or {}).get("oplog")
        sampling = (act or {}).get("sampling")
        oplog_ok = bool(oplog) and not oplog.get("error")
        attributed = oplog_ok or bool(sampling)

        user_stats: Dict[str, Dict[str, Any]] = {}

        def ustat(name: str) -> Dict[str, Any]:
            return user_stats.setdefault(name, {"oplog_writes": 0, "sampled_ops": 0, "namespaces": set(),
                                                "sources": set(), "apps": {}, "clients": {}})

        collections: List[dict] = []
        if act:
            for m in act.get("members") or []:
                if m.get("error"):
                    F.add("WARN", "ACTIVITY_ERROR", iname, "", f"member {m.get('host')}: {m['error']}")
            if oplog and oplog.get("error"):
                F.add("WARN", "ACTIVITY_ERROR", iname, "", f"oplog: {oplog['error']}")
            if sampling and sampling.get("error"):
                F.add("WARN", "ACTIVITY_ERROR", iname, "", f"sampling: {sampling['error']}")
            uid_map = act.get("uid_map") or {}
            if uid_map.get("error"):
                F.add("WARN", "ACTIVITY_ERROR", iname, "", f"session user resolution: {uid_map['error']}")
            if oplog_ok and oplog.get("oplog_first") and oplog.get("requested_from") \
                    and oplog["oplog_first"] > oplog["requested_from"]:
                F.add("INFO", "OPLOG_WINDOW_SHORT", iname, "",
                      f"oplog only covers writes since {oplog['oplog_first']} "
                      f"(requested since {oplog['requested_from']})")

            for db in sorted(s.get("databases") or [], key=lambda d: d["name"]):
                for c in sorted(db.get("collections") or [], key=lambda x: x["name"]):
                    ca = c.get("activity")
                    if not ca:
                        continue
                    ns = f"{db['name']}.{c['name']}"
                    co = ca.get("oplog")
                    cs = ca.get("sampled")
                    ct = ca.get("top")
                    users: Dict[str, Dict[str, int]] = {}
                    if co:
                        for u, n in (co.get("users") or {}).items():
                            users.setdefault(u, {"oplog": 0, "sampled": 0})["oplog"] += int(n)
                            if not u.startswith("("):
                                st = ustat(u)
                                st["oplog_writes"] += int(n)
                                st["namespaces"].add(ns)
                                st["sources"].add("oplog")
                    if cs:
                        for u, n in (cs.get("users") or {}).items():
                            users.setdefault(u, {"oplog": 0, "sampled": 0})["sampled"] += int(n)
                    writes = (co["inserts"] + co["updates"] + co["deletes"] + co["commands"]) if co else None
                    last_write = co.get("last") if co else None
                    modified = ca.get("modified") or []
                    for m in modified:
                        if m.get("error"):
                            F.add("WARN", "ACTIVITY_ERROR", iname, ns, f"modified field {m.get('path')}: {m['error']}")
                    method = ca.get("last_modified_method")
                    if method == "sample":
                        F.add("INFO", "MODIFIED_FROM_SAMPLE", iname, ns,
                              f"last modification of '{ca.get('last_modified_field')}' is a lower bound taken from the "
                              f"sample ({ca.get('last_modified')}); index the field or use --modified-scan for an exact value")
                    exact_modified = ca.get("last_modified") if method in ("index", "scan") else None
                    uncertain = any(m.get("method") in ("sample", "none") or m.get("error") for m in modified)
                    newest = max([d for d in (ca.get("last_insert"), exact_modified) if d] or [""])
                    collected_at = s.get("collected_at") or ""
                    if stale_days > 0 and newest and collected_at and not uncertain \
                            and (c.get("type") or "collection") == "collection":
                        age = days_between(collected_at, newest)
                        if age >= stale_days:
                            scope = ("inserts or modifications" if exact_modified
                                     else "inserts (no *modified* date field: updates are not visible)")
                            F.add("INFO", "STALE_COLLECTION", iname, ns,
                                  f"no {scope} since {newest} ({age} days before the collection date)")
                    collections.append({
                        "namespace": ns, "type": c.get("type") or "collection",
                        "first_insert": ca.get("first_insert"), "last_insert": ca.get("last_insert"),
                        "id_type": ca.get("id_type"),
                        "last_modified": ca.get("last_modified"),
                        "last_modified_field": ca.get("last_modified_field"),
                        "last_modified_method": method,
                        "modified_fields": [{"path": m.get("path"), "method": m.get("method"), "value": m.get("value")}
                                            for m in modified],
                        "created_at": co.get("created_at") if co else None, "last_write": last_write,
                        "oplog": ({"inserts": co["inserts"], "updates": co["updates"], "deletes": co["deletes"],
                                   "commands": co["commands"]} if co else None),
                        "top": ct, "sampled_ops": cs.get("ops") if cs else None,
                        "users": [{"user": u, "oplog": users[u]["oplog"], "sampled": users[u]["sampled"]}
                                  for u in sorted(users)],
                    })
                    idle_top = ct is None or (ct.get("reads", 0) + ct.get("writes", 0)) == 0
                    idle_sample = cs is None or not cs.get("ops")
                    if oplog_ok and writes == 0 and idle_top and idle_sample:
                        F.add("INFO", "NO_RECENT_ACTIVITY", iname, ns,
                              f"no writes since {oplog.get('from')} (oplog) and no reads/writes since "
                              f"{(ct or {}).get('since') or '-'}: candidate for archiving instead of migrating")

            for u, data in (act.get("users") or {}).items():
                st = ustat(u)
                st["sampled_ops"] += int(data.get("sampled_ops") or 0)
                st["namespaces"].update(data.get("namespaces") or {})
                st["sources"].add("sampling")
                _merge_counts(st["apps"], data.get("apps") or {})
                _merge_counts(st["clients"], data.get("clients") or {})

            activity_out.append({
                "instance": iname, "members": act.get("members") or [], "oplog": oplog, "sampling": sampling,
                "collections": collections,
            })

        defined: Dict[str, List[dict]] = {}
        custom: Dict[str, dict] = {}
        if sec:
            for u in sec.get("users") or []:
                defined[f"{u['user']}@{u['db']}"] = u.get("roles") or []
            for r in sec.get("roles") or []:
                custom[f"{r['role']}@{r['db']}"] = r
        for name in sorted(set(defined) | set(user_stats)):
            st = user_stats.get(name) or {"oplog_writes": 0, "sampled_ops": 0, "namespaces": set(),
                                          "sources": set(), "apps": {}, "clients": {}}
            observed = bool(st["oplog_writes"] or st["sampled_ops"])
            recommendation = "migrate" if observed else ("review" if attributed else "unknown")
            at = name.rfind("@")
            users_out.append({
                "instance": iname, "user": name[:at] if at > 0 else name, "db": name[at + 1:] if at > 0 else "",
                "defined": name in defined, "access": effective_access(defined.get(name, []), custom),
                "observed": observed, "sources": sorted(st["sources"]),
                "oplog_writes": st["oplog_writes"], "sampled_ops": st["sampled_ops"],
                "namespaces": sorted(st["namespaces"]),
                "apps": {k: st["apps"][k] for k in sorted(st["apps"])},
                "clients": {k: st["clients"][k] for k in sorted(st["clients"])},
                "recommendation": recommendation,
            })
            if name.startswith("uid:"):
                F.add("INFO", "USER_UNRESOLVED", iname, name,
                      "oplog writes from a session user that could not be resolved "
                      "(dropped user or missing viewUser privilege)")
            elif recommendation == "review":
                F.add("INFO", "USER_NO_ACTIVITY", iname, name,
                      "user has access but no activity was observed (oplog/sampling)")
    return activity_out, users_out
