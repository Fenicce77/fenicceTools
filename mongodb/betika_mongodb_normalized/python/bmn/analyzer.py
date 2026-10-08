"""Offline analysis of instance snapshots: inventory, drift, mapping and findings.

Pure function over snapshot dicts, no database access. The output must stay
byte-identical to bash/lib/analyzer.js (see tests/parity_check.sh).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

from .activity_analysis import analyze_activity
from .common import (
    ANALYSIS_FORMAT, CONVERTIBLE_TYPES, NULLISH_TYPES, NUMERIC_TYPES, SEV_RANK, TOOL_NAME,
    canon, classify_types, fmt_types, fmt_value, index_signature, invalid_db_name, parse_version,
)


@dataclass
class AnalysisParams:
    naming_strategy: str = "auto"          # keep | prefix | auto
    prefix_sep: str = "_"
    target: str = ""
    mappings: List[Dict[str, str]] = field(default_factory=list)
    generated_at: str = ""
    implementation: str = "python"
    stale_days: int = 180


class Findings:
    def __init__(self) -> None:
        self.items: List[Dict[str, Any]] = []

    def add(self, severity: str, code: str, instance: str, namespace: str, message: str,
            details: Optional[List[str]] = None) -> None:
        self.items.append({
            "severity": severity, "code": code, "instance": instance or "", "namespace": namespace or "",
            "message": message, "details": list(details or []),
        })

    def sorted(self) -> List[Dict[str, Any]]:
        return sorted(self.items, key=lambda f: (SEV_RANK[f["severity"]], f["code"], f["instance"],
                                                 f["namespace"], f["message"]))


# --------------------------------------------------------------------------- helpers
def _name(snap: dict) -> str:
    return snap["instance"]["name"]


def _dbs(snap: dict) -> List[dict]:
    return sorted(snap.get("databases") or [], key=lambda d: d["name"])


def _colls(db: dict) -> List[dict]:
    return sorted(db.get("collections") or [], key=lambda c: c["name"])


def _stats(coll: dict) -> Tuple[int, int, int, int]:
    st = coll.get("stats") or {}
    return (int(st.get("count") or 0), int(st.get("size") or 0),
            int(st.get("storage_size") or 0), int(st.get("total_index_size") or 0))


def _fields(coll: dict) -> Dict[str, dict]:
    return (coll.get("schema") or {}).get("fields") or {}


def _totals(snap: dict) -> Dict[str, int]:
    tot = {"databases": 0, "collections": 0, "views": 0, "documents": 0,
           "data_size": 0, "storage_size": 0, "index_size": 0}
    for db in _dbs(snap):
        tot["databases"] += 1
        for coll in _colls(db):
            if coll.get("type") == "view":
                tot["views"] += 1
                continue
            tot["collections"] += 1
            cnt, size, storage, idx = _stats(coll)
            tot["documents"] += cnt
            tot["data_size"] += size
            tot["storage_size"] += storage
            tot["index_size"] += idx
    return tot


def _instance_summary(snap: dict, role: str) -> dict:
    server = snap.get("server") or {}
    ok = snap.get("status") == "ok"
    tot = _totals(snap) if ok else {"databases": 0, "collections": 0, "views": 0, "documents": 0,
                                    "data_size": 0, "storage_size": 0, "index_size": 0}
    return {
        "name": _name(snap),
        "alias": snap["instance"].get("alias") or _name(snap),
        "role": role,
        "status": snap.get("status") or "error",
        "error": snap.get("error") or None,
        "uri": snap["instance"].get("uri") or None,
        "version": server.get("version") or None,
        "fcv": server.get("fcv") or None,
        "topology": server.get("topology") or None,
        **tot,
    }


def _ver_str(v: Tuple[int, int, int]) -> str:
    return f"{v[0]}.{v[1]}"


# --------------------------------------------------------------------------- main
def analyze(snapshots: List[dict], params: AnalysisParams) -> dict:  # noqa: C901 (linear pipeline)
    F = Findings()
    snaps = sorted(snapshots, key=_name)
    by_name = {_name(s): s for s in snaps}

    target_name = params.target or ""
    for s in snaps:  # accept the alias as target reference
        if target_name and target_name == s["instance"].get("alias") and target_name not in by_name:
            target_name = _name(s)
            break
    if not target_name:
        for s in snaps:
            if s["instance"].get("role") == "target":
                target_name = _name(s)
                break
    target: Optional[dict] = None
    if target_name:
        cand = by_name.get(target_name)
        if cand is None:
            F.add("ERROR", "TARGET_NOT_FOUND", target_name, "", f"target instance '{target_name}' has no snapshot")
        elif cand.get("status") == "ok":
            target = cand

    for s in snaps:
        if s.get("status") != "ok":
            F.add("ERROR", "COLLECT_ERROR", _name(s), "",
                  f"snapshot collection failed: {s.get('error') or 'unknown error'}")

    sources = [s for s in snaps if s.get("status") == "ok" and _name(s) != target_name]
    for s in sources:
        _listing_findings(s, F)
    instances = [_instance_summary(s, "target" if _name(s) == target_name else "source") for s in snaps]

    tver = parse_version((target or {}).get("server", {}).get("version")) if target else (0, 0, 0)
    tver_str = ((target or {}).get("server") or {}).get("version") or ""
    target_sharded = bool(target and (target.get("server") or {}).get("topology") == "sharded")
    target_dbs: Dict[str, set] = {}
    if target:
        for db in _dbs(target):
            target_dbs[db["name"]] = {c["name"] for c in _colls(db)}

    db_instances: Dict[str, List[str]] = {}
    for s in sources:
        for db in _dbs(s):
            db_instances.setdefault(db["name"], []).append(_name(s))

    def lookup(iname: str, alias: str, sdb: str) -> Optional[str]:
        for m in params.mappings:
            if m["instance"] in (iname, alias) and m["source_db"] == sdb:
                return m["target_db"]
        return None

    db_mapping: List[dict] = []
    ns_mapping: List[dict] = []
    normalization: List[dict] = []

    for s in sources:
        iname = _name(s)
        alias = s["instance"].get("alias") or iname
        for db in _dbs(s):
            sdb = db["name"]
            mapped = lookup(iname, alias, sdb)
            if mapped is not None:
                tdb, reason = mapped, "mapping-file"
            elif params.naming_strategy == "keep":
                tdb, reason = sdb, "keep"
            elif params.naming_strategy == "prefix":
                tdb, reason = f"{alias}{params.prefix_sep}{sdb}", "prefix"
            elif len(db_instances.get(sdb, [])) > 1:
                tdb, reason = f"{alias}{params.prefix_sep}{sdb}", "auto:source-conflict"
            elif sdb in target_dbs:
                tdb, reason = f"{alias}{params.prefix_sep}{sdb}", "auto:target-conflict"
            else:
                tdb, reason = sdb, "keep"

            colls = _colls(db)
            entry = {"instance": iname, "alias": alias, "source_db": sdb, "target_db": tdb, "reason": reason,
                     "collections": 0, "views": 0, "documents": 0, "data_size": 0, "storage_size": 0,
                     "index_size": 0}
            for c in colls:
                if c.get("type") == "view":
                    entry["views"] += 1
                    continue
                entry["collections"] += 1
                cnt, size, storage, idx = _stats(c)
                entry["documents"] += cnt
                entry["data_size"] += size
                entry["storage_size"] += storage
                entry["index_size"] += idx
            db_mapping.append(entry)

            if invalid_db_name(tdb):
                F.add("ERROR", "DB_NAME_INVALID", iname, tdb,
                      f"target database name '{tdb}' is invalid (forbidden characters or >= 64 bytes)")
            if target and tdb in target_dbs:
                F.add("WARN", "TARGET_DB_EXISTS", iname, tdb,
                      f"target database '{tdb}' already exists on target '{target_name}'")

            for c in colls:
                ctype = c.get("type") or "collection"
                cname = c["name"]
                sns = f"{sdb}.{cname}"
                tns = f"{tdb}.{cname}"
                opts = c.get("options") or {}
                indexes = c.get("indexes") or []
                ns_mapping.append({"instance": iname, "source_ns": sns, "target_ns": tns, "type": ctype})

                if len(tns.encode("utf-8")) > 255:
                    F.add("ERROR", "NS_TOO_LONG", iname, sns, f"target namespace '{tns}' exceeds 255 bytes")
                if target and cname in target_dbs.get(tdb, set()):
                    F.add("ERROR", "TARGET_NS_EXISTS", iname, sns,
                          f"target namespace '{tns}' already exists on target '{target_name}'")
                if c.get("stats_error"):
                    F.add("WARN", "STATS_ERROR", iname, sns, f"$collStats failed: {c['stats_error']}")
                if c.get("schema_error"):
                    F.add("WARN", "SAMPLE_ERROR", iname, sns, f"schema sampling failed: {c['schema_error']}")
                schema = c.get("schema") or {}
                if schema.get("truncated"):
                    F.add("INFO", "SCHEMA_TRUNCATED", iname, sns,
                          "field path limit reached while sampling (dynamic keys?); schema is partial")

                mixed: List[str] = []
                numeric: List[str] = []
                polymorphic: List[str] = []
                fields = _fields(c)
                for path in sorted(fields):
                    types = fields[path].get("types") or {}
                    cls = classify_types(types)
                    if cls == "none":
                        continue
                    line = f"{path}: {fmt_types(types)}"
                    if cls == "numeric":
                        numeric.append(line)
                        continue
                    if is_polymorphic_array(path, fields[path]):
                        polymorphic.append(f"{line} (in {int(fields[path].get('count') or 0)} doc(s))")
                        continue
                    mixed.append(line)
                    non_null = {t: n for t, n in types.items() if t not in NULLISH_TYPES}
                    if ("[]" in path or "$" in path or not all(t in CONVERTIBLE_TYPES for t in non_null)):
                        continue
                    dominant = sorted(non_null.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
                    normalization.append({
                        "instance": iname, "source_ns": sns, "target_ns": tns, "db": tdb, "collection": cname,
                        "path": path, "dominant_type": dominant,
                        "types": {t: non_null[t] for t in sorted(non_null)},
                        "sampled": int(schema.get("sampled") or 0),
                    })
                if mixed:
                    F.add("WARN", "FIELD_TYPE_MIXED", iname, sns,
                          f"{len(mixed)} field(s) with inconsistent BSON types in a sample of "
                          f"{int(schema.get('sampled') or 0)} document(s)", mixed)
                if polymorphic:
                    F.add("INFO", "ARRAY_TYPES_POLYMORPHIC", iname, sns,
                          f"{len(polymorphic)} array field(s) mix BSON types inside the same document "
                          "(polymorphic / key-value pattern, usually by design; not a normalization candidate)",
                          polymorphic)
                if numeric:
                    F.add("INFO", "NUMERIC_TYPE_MIXED", iname, sns,
                          f"{len(numeric)} field(s) mix numeric widths (int/long/double/decimal)", numeric)

                features: List[Tuple[str, Tuple[int, int]]] = []
                if ctype == "timeseries":
                    features.append(("time-series collection", (5, 0)))
                if "clusteredIndex" in opts:
                    features.append(("clustered collection", (5, 3)))
                if "changeStreamPreAndPostImages" in opts:
                    features.append(("changeStreamPreAndPostImages", (6, 0)))
                if "encryptedFields" in opts:
                    features.append(("Queryable Encryption (encryptedFields)", (7, 0)))
                for label, req in features:
                    if target and tver[:2] < req:
                        F.add("ERROR", "FEATURE_UNSUPPORTED", iname, sns,
                              f"{label} requires MongoDB >= {req[0]}.{req[1]}; target '{target_name}' runs {tver_str}")

                for ix in indexes:
                    if any(v == "geoHaystack" for v in (ix.get("key") or {}).values()):
                        sev = "ERROR" if (target is None or tver[:2] >= (5, 0)) else "WARN"
                        F.add(sev, "INDEX_TYPE_REMOVED", iname, sns,
                              f"geoHaystack index '{ix.get('name')}' was removed in MongoDB 5.0; "
                              "replace it with a 2d index and $geoWithin queries")

                legacy = [f"{ix.get('name')}: {opt}" for ix in indexes for opt in ("background", "dropDups")
                          if opt in ix]
                if legacy:
                    F.add("INFO", "INDEX_LEGACY_OPTION", iname, sns,
                          f"{len(legacy)} legacy index option(s) will be stripped in bootstrap", legacy)
                if "autoIndexId" in opts:
                    F.add("WARN", "OPTION_LEGACY", iname, sns,
                          "autoIndexId collection option is not supported by modern MongoDB and will be stripped")
                if opts.get("capped"):
                    F.add("INFO", "CAPPED", iname, sns,
                          f"capped collection (size={fmt_value(opts.get('size'))}, max={fmt_value(opts.get('max'))})")
                ttl = [f"{ix.get('name')}: expireAfterSeconds={fmt_value(ix.get('expireAfterSeconds'))}"
                       for ix in indexes if "expireAfterSeconds" in ix and not ix.get("clustered")]
                if ttl:
                    F.add("INFO", "TTL_INDEX", iname, sns,
                          "TTL index(es): expired documents are purged as soon as the index exists on target", ttl)
                if ctype == "view":
                    F.add("INFO", "VIEW", iname, sns,
                          f"view on '{opts.get('viewOn') or '-'}' must be created after its source collections")
                if ctype == "timeseries" and tdb != sdb:
                    F.add("WARN", "TIMESERIES_RENAME", iname, sns,
                          "time-series collection remapped to another database: validate mongorestore "
                          "--nsFrom/--nsTo (system.buckets) on staging first")
                shard_key = c.get("shard_key")
                if shard_key:
                    if target_sharded:
                        F.add("INFO", "SHARD_KEY", iname, sns,
                              f"sharded on {canon(shard_key, False)}; shardCollection is included in bootstrap")
                    else:
                        state = "not sharded" if target else "undefined"
                        F.add("WARN", "SHARD_KEY_LOST", iname, sns,
                              f"sharded on {canon(shard_key, False)} but target is {state}; "
                              "the shard key will not be recreated")

    # --- collisions / merges
    by_tns: Dict[str, List[dict]] = {}
    for e in ns_mapping:
        by_tns.setdefault(e["target_ns"], []).append(e)
    for tns in sorted(by_tns):
        entries = by_tns[tns]
        if len(entries) > 1:
            F.add("ERROR", "NS_COLLISION", ",".join(sorted({e["instance"] for e in entries})), tns,
                  "multiple source namespaces map to the same target namespace",
                  sorted(f"{e['instance']}:{e['source_ns']}" for e in entries))
    by_tdb: Dict[str, List[dict]] = {}
    for e in db_mapping:
        by_tdb.setdefault(e["target_db"], []).append(e)
    for tdb in sorted(by_tdb):
        entries = by_tdb[tdb]
        if len(entries) > 1:
            F.add("INFO", "DB_MERGE", ",".join(sorted({e["instance"] for e in entries})), tdb,
                  "target database receives collections from multiple sources",
                  sorted(f"{e['instance']}:{e['source_db']}" for e in entries))

    # --- versions
    if target:
        for s in sources:
            sv = (s.get("server") or {}).get("version") or ""
            if parse_version(sv)[:2] > tver[:2]:
                F.add("WARN", "VERSION_DOWNGRADE", _name(s), "",
                      f"source runs {sv}, newer than target {tver_str}; newer features/formats may not restore")
    elif sources:
        best = sources[0]
        for s in sources[1:]:
            if parse_version(s["server"].get("version")) > parse_version(best["server"].get("version")):
                best = s
        F.add("INFO", "NO_TARGET", "", "",
              f"no target instance defined; the central instance should run MongoDB >= "
              f"{_ver_str(parse_version(best['server'].get('version')))}")
    majors = {parse_version((s.get("server") or {}).get("version"))[:2] for s in sources}
    if len(majors) > 1:
        F.add("INFO", "MIXED_VERSIONS", "", "", f"source instances run {len(majors)} different major versions",
              sorted(f"{_name(s)}: {(s.get('server') or {}).get('version')}" for s in sources))

    # --- drift across instances (same source namespace)
    groups: Dict[str, List[Tuple[str, dict]]] = {}
    for s in sources:
        for db in _dbs(s):
            for c in _colls(db):
                groups.setdefault(f"{db['name']}.{c['name']}", []).append((_name(s), c))
    drift: List[dict] = []
    for ns in sorted(groups):
        members = groups[ns]
        if len(members) < 2:
            continue
        insts = [m[0] for m in members]
        sigmap: Dict[str, Dict[str, str]] = {}
        for iname, c in members:
            sigs: Dict[str, str] = {}
            for ix in c.get("indexes") or []:
                if ix.get("name") == "_id_" or ix.get("clustered"):
                    continue
                sigs[index_signature(ix)] = ix.get("name")
            sigmap[iname] = sigs
        all_sigs = sorted({sig for sigs in sigmap.values() for sig in sigs})
        index_diff = []
        for sig in all_sigs:
            present = [i for i in insts if sig in sigmap[i]]
            if len(present) == len(insts):
                continue
            index_diff.append({"signature": sig, "present_in": present,
                               "missing_in": [i for i in insts if sig not in sigmap[i]],
                               "names": {i: sigmap[i][sig] for i in present}})
        opt_canon = {iname: canon(c.get("options") or {}) for iname, c in members}
        options_equal = len(set(opt_canon.values())) == 1
        per_path: Dict[str, Dict[str, List[str]]] = {}
        for iname, c in members:
            for path, f in _fields(c).items():
                ts = sorted(t for t in (f.get("types") or {}) if t not in NULLISH_TYPES)
                if ts:
                    per_path.setdefault(path, {})[iname] = ts
        type_conflicts = []
        for path in sorted(per_path):
            m = per_path[path]
            if len(m) < 2 or len({tuple(v) for v in m.values()}) == 1:
                continue
            union = {t for v in m.values() for t in v}
            if all(t in NUMERIC_TYPES for t in union):
                continue
            type_conflicts.append({"path": path, "types": {i: m[i] for i in insts if i in m}})
        drift.append({"namespace": ns, "instances": insts, "index_diff": index_diff,
                      "options_equal": options_equal, "options": {} if options_equal else opt_canon,
                      "type_conflicts": type_conflicts})
        who = ",".join(insts)
        if index_diff:
            F.add("WARN", "SCHEMA_DRIFT_INDEXES", who, ns,
                  f"{len(index_diff)} index definition(s) differ across instances",
                  [f"{d['signature']} present in [{','.join(d['present_in'])}] missing in [{','.join(d['missing_in'])}]"
                   for d in index_diff])
        if not options_equal:
            F.add("WARN", "SCHEMA_DRIFT_OPTIONS", who, ns, "collection options differ across instances",
                  [f"{i}: {opt_canon[i]}" for i in insts])
        if type_conflicts:
            F.add("WARN", "SCHEMA_DRIFT_TYPES", who, ns,
                  f"{len(type_conflicts)} field(s) with different BSON types across instances",
                  [f"{t['path']}: " + "; ".join(f"{i}=[{','.join(v)}]" for i, v in t["types"].items())
                   for t in type_conflicts])

    security_plan = _security(sources, db_mapping, F)
    activity, users = analyze_activity(sources, F, params.stale_days)

    capacity = {
        "per_instance": [], "total": {"documents": 0, "data_size": 0, "storage_size": 0, "index_size": 0},
        "target_existing": None,
    }
    for s in sources:
        tot = _totals(s)
        row = {"instance": _name(s), "documents": tot["documents"], "data_size": tot["data_size"],
               "storage_size": tot["storage_size"], "index_size": tot["index_size"]}
        capacity["per_instance"].append(row)
        for k in ("documents", "data_size", "storage_size", "index_size"):
            capacity["total"][k] += row[k]
    if target:
        tot = _totals(target)
        capacity["target_existing"] = {k: tot[k] for k in ("documents", "data_size", "storage_size", "index_size")}

    findings = F.sorted()
    by_code: Dict[str, int] = {}
    for f in findings:
        by_code[f["code"]] = by_code.get(f["code"], 0) + 1
    summary = {
        "errors": sum(1 for f in findings if f["severity"] == "ERROR"),
        "warnings": sum(1 for f in findings if f["severity"] == "WARN"),
        "info": sum(1 for f in findings if f["severity"] == "INFO"),
        "by_code": {k: by_code[k] for k in sorted(by_code)},
        "sources": len(sources),
        "source_databases": len(db_mapping),
        "source_collections": sum(1 for e in ns_mapping if e["type"] != "view"),
        "source_views": sum(1 for e in ns_mapping if e["type"] == "view"),
        "target_databases": len({e["target_db"] for e in db_mapping}),
    }
    target_info = None
    if target:
        srv = target.get("server") or {}
        target_info = {"name": target_name, "version": srv.get("version") or None, "fcv": srv.get("fcv") or None,
                       "topology": srv.get("topology") or None}

    return {
        "tool": TOOL_NAME,
        "analysis_format": ANALYSIS_FORMAT,
        "implementation": params.implementation,
        "generated_at": params.generated_at,
        "params": {"naming_strategy": params.naming_strategy, "prefix_sep": params.prefix_sep,
                   "target": target_name or None, "mapping_entries": len(params.mappings),
                   "stale_days": params.stale_days},
        "target": target_info,
        "instances": instances,
        "db_mapping": db_mapping,
        "ns_mapping": ns_mapping,
        "drift": drift,
        "findings": findings,
        "normalization": normalization,
        "activity": activity,
        "users": users,
        "security_plan": security_plan,
        "capacity": capacity,
        "summary": summary,
    }


def is_polymorphic_array(path: str, field: dict) -> bool:
    """Array element path whose types co-occur in the same documents (per-type counts exceed doc count)."""
    if "[]" not in path:
        return False
    non_null = [int(n) for t, n in (field.get("types") or {}).items() if t not in NULLISH_TYPES]
    return sum(non_null) > int(field.get("count") or 0)


def _listing_findings(s: dict, F: Findings) -> None:
    iname = _name(s)
    listing = s.get("database_listing")
    has_user_dbs = bool(s.get("databases"))
    if listing is None:
        if not has_user_dbs:
            F.add("WARN", "NO_USER_DATABASES", iname, "",
                  "no user databases collected and the snapshot has no listing details (older collector): "
                  "the instance may be empty or the user may lack privileges; re-collect to verify")
        return
    listed = ", ".join(listing.get("listed") or []) or "-"
    excluded = listing.get("excluded_by_filter") or []
    can_list = listing.get("can_list_all")
    if can_list is False:
        F.add("WARN", "DB_LISTING_PARTIAL", iname, "",
              "the user lacks the listDatabases privilege: only databases it is authorized on are listed, "
              f"other databases may exist (listed: {listed})")
    if has_user_dbs:
        return
    if excluded:
        F.add("INFO", "NO_USER_DATABASES", iname, "",
              f"all {len(excluded)} user database(s) were excluded by --include-dbs/--exclude-dbs", sorted(excluded))
    elif can_list is True:
        F.add("INFO", "NO_USER_DATABASES", iname, "",
              f"the instance has no user databases (listed: {listed}): nothing to migrate")
    elif can_list is None:
        F.add("INFO", "NO_USER_DATABASES", iname, "",
              f"no user databases listed (listed: {listed}); the listDatabases privilege could not be verified")


def _split_role(ref: str) -> Dict[str, str]:
    idx = ref.rfind("@")
    return {"role": ref[:idx], "db": ref[idx + 1:]}


def _security(sources: List[dict], db_mapping: List[dict], F: Findings) -> Optional[dict]:
    if not any(s.get("security") for s in sources):
        return None
    users: Dict[str, dict] = {}
    roles: Dict[str, dict] = {}
    for s in sources:
        sec = s.get("security")
        if not sec:
            continue
        iname = _name(s)
        dbmap = {e["source_db"]: e["target_db"] for e in db_mapping if e["instance"] == iname}
        for u in sorted(sec.get("users") or [], key=lambda x: (x.get("db", ""), x.get("user", ""))):
            udb = dbmap.get(u["db"], u["db"])
            refs = sorted({f"{r['role']}@{dbmap.get(r['db'], r['db'])}" for r in u.get("roles") or []})
            key = f"{u['user']}@{udb}"
            entry = users.setdefault(key, {"user": u["user"], "db": udb, "by_source": {}})
            entry["by_source"][iname] = refs
        for r in sorted(sec.get("roles") or [], key=lambda x: (x.get("db", ""), x.get("role", ""))):
            rdb = dbmap.get(r["db"], r["db"])
            privileges = []
            for p in r.get("privileges") or []:
                res = dict(p.get("resource") or {})
                if res.get("db") in dbmap:
                    res["db"] = dbmap[res["db"]]
                privileges.append({"resource": res, "actions": sorted(p.get("actions") or [])})
            inherited = sorted({f"{x['role']}@{dbmap.get(x['db'], x['db'])}" for x in r.get("roles") or []})
            key = f"{r['role']}@{rdb}"
            entry = roles.setdefault(key, {"role": r["role"], "db": rdb, "by_source": {}})
            entry["by_source"][iname] = {"privileges": privileges, "roles": inherited}

    plan_users = []
    for key in sorted(users, key=lambda k: (users[k]["db"], users[k]["user"])):
        e = users[key]
        srcs = sorted(e["by_source"])
        variants = {tuple(v) for v in e["by_source"].values()}
        if len(srcs) > 1:
            if len(variants) == 1:
                F.add("INFO", "USER_DUPLICATE", ",".join(srcs), key, "same user and roles defined in several sources")
            else:
                F.add("WARN", "USER_CONFLICT", ",".join(srcs), key,
                      "user defined in several sources with different roles; bootstrap uses the union",
                      [f"{i}: {','.join(e['by_source'][i])}" for i in srcs])
        union = sorted({r for v in e["by_source"].values() for r in v})
        plan_users.append({"user": e["user"], "db": e["db"], "roles": [_split_role(r) for r in union],
                           "sources": srcs})
    plan_roles = []
    for key in sorted(roles, key=lambda k: (roles[k]["db"], roles[k]["role"])):
        e = roles[key]
        srcs = sorted(e["by_source"])
        variants = {canon(v) for v in e["by_source"].values()}
        if len(srcs) > 1:
            if len(variants) == 1:
                F.add("INFO", "ROLE_DUPLICATE", ",".join(srcs), key, "same custom role defined in several sources")
            else:
                F.add("WARN", "ROLE_CONFLICT", ",".join(srcs), key,
                      f"custom role differs across sources; bootstrap uses the definition from '{srcs[0]}'")
        chosen = e["by_source"][srcs[0]]
        plan_roles.append({"role": e["role"], "db": e["db"], "privileges": chosen["privileges"],
                           "roles": [_split_role(r) for r in chosen["roles"]], "sources": srcs})
    return {"users": plan_users, "roles": plan_roles}
