"""Artifact renderers. Output must stay byte-identical to bash/lib/analyzer.js."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Tuple

from .activity_analysis import top_users
from .common import (
    INDEX_STRIP_KEYS, TEMPLATES_DIR, canon, classify_types, dump_pretty, human_bytes, md, sh_single_quote,
)

SEVERITY_TITLES = (("ERROR", "Errors"), ("WARN", "Warnings"), ("INFO", "Informational"))


CROSS_INSTANCE = "Cross-instance"


def group_by_instance(an: dict, items: List[dict]) -> List[Tuple[str, List[dict]]]:
    """Findings grouped by instance, in the order of the instances table; findings on
    several instances (or global ones) go last under an empty key (cross-instance)."""
    names = [i["name"] for i in an["instances"]]
    groups: Dict[str, List[dict]] = {}
    for f in items:
        key = f["instance"] if f["instance"] and "," not in f["instance"] else ""
        groups.setdefault(key, []).append(f)
    order = [n for n in names if n in groups] + sorted(k for k in groups if k and k not in names)
    if "" in groups:
        order.append("")
    return [(k, groups[k]) for k in order]


def group_by_code(items: List[dict]) -> List[Tuple[str, List[dict]]]:
    """(Already code-sorted) findings grouped by code, keeping their order."""
    groups: Dict[str, List[dict]] = {}
    for f in items:
        groups.setdefault(f["code"], []).append(f)
    return list(groups.items())


def code_counts(items: List[dict]) -> str:
    return ", ".join(f"{code} ({len(lst)})" for code, lst in group_by_code(items))


# ---- per-code Informational tables: short cells, the explanation goes in one note per code.
# A cell is (text, is_code); each renderer escapes/formats it (markdown, Jira, Confluence).
Cell = Tuple[str, bool]


def icell(v: Any, code: bool = False) -> Cell:
    empty = v is None or v == ""
    return ("-" if empty else (str(v) if not isinstance(v, bool) else str(v).lower()), code and not empty)


def _last_update(d: dict) -> str:
    if not d.get("last_modified"):
        return "-"
    return f">= {d['last_modified']}" if d.get("modified_method") == "sample" else d["last_modified"]


def _ns(f: dict) -> Cell:
    return icell(f["namespace"], True)


def _stale_rows(f: dict) -> List[List[Cell]]:
    d = f["data"]
    parts = []
    if d.get("last_insert"):
        parts.append("_id")
    if d.get("modified_field"):
        parts.append(f"{d['modified_field']} ({d['modified_method']})")
    how = " + ".join(parts) + ("" if d.get("modified_field") else " (updates not visible)")
    return [[_ns(f), icell(d.get("last_insert")), icell(_last_update(d)), icell(d["idle_days"]), icell(how.strip())]]


def _no_activity_rows(f: dict) -> List[List[Cell]]:
    d = f["data"]
    checked = " + ".join(["oplog"] + (["top"] if d.get("top_since") else []) + (["$currentOp"] if d.get("sampled") else []))
    return [[_ns(f), icell(d.get("last_insert")), icell(_last_update(d)), icell(d.get("oplog_from")), icell(checked)]]


_NO_DB_REASONS = {"excluded": "all excluded by --include-dbs/--exclude-dbs", "no_user_databases": "no user databases",
                  "unverified": "listDatabases privilege not verified"}

INFO_SPECS: Dict[str, Dict[str, Any]] = {
    "STALE_COLLECTION": {
        "note": lambda lst: (f"No inserts or updates for at least {lst[0]['data']['stale_days']} days (--stale-days) before "
                             "the collection date. Last insert ~ comes from the ObjectId _id; updates are only visible "
                             "through an exact (index/scan) modified date field."),
        "cols": ["Namespace", "Last insert ~", "Last update", "Idle days", "Obtained from"],
        "rows": _stale_rows,
    },
    "NO_RECENT_ACTIVITY": {
        "note": lambda lst: ("No writes in the oplog window and no reads/writes in top or $currentOp sampling: candidate for "
                             "archiving instead of migrating. Last insert ~ comes from the ObjectId _id; Last update from a "
                             "modified date field (>= = lower bound from the sample)."),
        "cols": ["Namespace", "Last insert ~", "Last update", "No writes since (oplog)", "Checked"],
        "rows": _no_activity_rows,
    },
    "MODIFIED_FROM_SAMPLE": {
        "note": lambda lst: ("Last update is a lower bound taken from the sampled documents (field not indexed): index the "
                             "field or run with --modified-scan for an exact value."),
        "cols": ["Namespace", "Field", "Last update >="],
        "rows": lambda f: [[_ns(f), icell(f["data"].get("field"), True), icell(f["data"].get("last_modified"))]],
    },
    "OPLOG_WINDOW_SHORT": {
        "note": lambda lst: "The oplog does not cover the whole requested window: older write activity is not visible.",
        "cols": ["Oplog first entry", "Requested from"],
        "rows": lambda f: [[icell(f["data"]["oplog_first"]), icell(f["data"]["requested_from"])]],
    },
    "USER_NO_ACTIVITY": {
        "note": lambda lst: ("User with access but no activity observed (oplog writes / $currentOp sampling): review before "
                             "migrating."),
        "cols": ["User", "Access (databases)"],
        "rows": lambda f: [[_ns(f), icell(", ".join(f["data"]["access"]))]],
    },
    "USER_UNRESOLVED": {
        "note": lambda lst: ("Session user from the oplog that could not be resolved (dropped user or missing viewUser "
                             "privilege)."),
        "cols": ["Session user", "Oplog writes"],
        "rows": lambda f: [[_ns(f), icell(f["data"]["oplog_writes"])]],
    },
    "ARRAY_TYPES_POLYMORPHIC": {
        "note": lambda lst: ("Arrays mixing BSON types inside the same document (key/value pattern, usually by design): not "
                             "a normalization candidate."),
        "cols": ["Namespace", "Field", "Types", "Docs"],
        "rows": lambda f: [[_ns(f), icell(x["path"], True), icell(x["types"]), icell(x["docs"])] for x in f["data"]["fields"]],
    },
    "NUMERIC_TYPE_MIXED": {
        "note": lambda lst: "Numeric fields mixing widths (int/long/double/decimal) in the sample.",
        "cols": ["Namespace", "Field", "Types", "Sampled docs"],
        "rows": lambda f: [[_ns(f), icell(x["path"], True), icell(x["types"]), icell(f["data"]["sampled"])]
                           for x in f["data"]["fields"]],
    },
    "SCHEMA_TRUNCATED": {
        "note": lambda lst: "Field path limit reached while sampling (dynamic keys?): the inferred schema is partial.",
        "cols": ["Namespace", "Sampled docs"],
        "rows": lambda f: [[_ns(f), icell(f["data"]["sampled"])]],
    },
    "INDEX_LEGACY_OPTION": {
        "note": lambda lst: "Legacy index options are stripped in the target bootstrap.",
        "cols": ["Namespace", "Index", "Option"],
        "rows": lambda f: [[_ns(f), icell(x["index"], True), icell(x["option"], True)] for x in f["data"]["options"]],
    },
    "CAPPED": {
        "note": lambda lst: "Capped collections are recreated with the same size and max.",
        "cols": ["Namespace", "Size (bytes)", "Max docs"],
        "rows": lambda f: [[_ns(f), icell(f["data"]["size"]), icell(f["data"]["max"])]],
    },
    "TTL_INDEX": {
        "note": lambda lst: "Expired documents are purged as soon as the TTL index exists on the target.",
        "cols": ["Namespace", "Index", "expireAfterSeconds"],
        "rows": lambda f: [[_ns(f), icell(x["index"], True), icell(x["expire_after_seconds"])]
                           for x in f["data"]["indexes"]],
    },
    "VIEW": {
        "note": lambda lst: "Views must be created after their source collections.",
        "cols": ["Namespace", "View on"],
        "rows": lambda f: [[_ns(f), icell(f["data"]["view_on"], True)]],
    },
    "SHARD_KEY": {
        "note": lambda lst: "shardCollection is included in the target bootstrap.",
        "cols": ["Namespace", "Shard key"],
        "rows": lambda f: [[_ns(f), icell(f["data"]["shard_key"], True)]],
    },
    "DB_MERGE": {
        "note": lambda lst: "Target database receives collections from several sources.",
        "cols": ["Target DB", "Sources"],
        "rows": lambda f: [[_ns(f), icell(", ".join(f["details"]))]],
    },
    "NO_TARGET": {
        "note": lambda lst: "No target instance defined: the central instance should run at least this MongoDB version.",
        "cols": ["Minimum version"],
        "rows": lambda f: [[icell(f["data"]["min_version"])]],
    },
    "MIXED_VERSIONS": {
        "note": lambda lst: "Source instances run different major versions.",
        "cols": ["Instance", "Version"],
        "rows": lambda f: [[icell(x["instance"]), icell(x["version"])] for x in f["data"]["versions"]],
    },
    "NO_USER_DATABASES": {
        "note": lambda lst: "Nothing to migrate from this instance.",
        "cols": ["Reason", "Databases"],
        "rows": lambda f: [[icell(_NO_DB_REASONS.get(f["data"]["reason"], f["data"]["reason"])),
                            icell(", ".join(f["data"]["databases"]))]],
    },
    "USER_DUPLICATE": {
        "note": lambda lst: "Same user and roles defined in several sources: created once in the bootstrap.",
        "cols": ["User"],
        "rows": lambda f: [[_ns(f)]],
    },
    "ROLE_DUPLICATE": {
        "note": lambda lst: "Same custom role defined in several sources: created once in the bootstrap.",
        "cols": ["Role"],
        "rows": lambda f: [[_ns(f)]],
    },
}
_NEEDS_DATA_EXEMPT = {"DB_MERGE", "USER_DUPLICATE", "ROLE_DUPLICATE"}
FALLBACK_SPEC: Dict[str, Any] = {
    "note": lambda lst: "",
    "cols": ["Namespace", "Finding", "Details"],
    "rows": lambda f: [[_ns(f), icell(f["message"]), icell("; ".join(f["details"]))]],
}


def info_code_tables(items: List[dict]) -> List[Dict[str, Any]]:
    """Tables of one instance group: code, count, note, head, rows. The cross-instance group
    gets an Instances column when any finding of the code spans several instances."""
    out = []
    for code, by_code in group_by_code(items):
        spec = INFO_SPECS.get(code, FALLBACK_SPEC)
        if spec is not FALLBACK_SPEC and code not in _NEEDS_DATA_EXEMPT and any("data" not in f for f in by_code):
            spec = FALLBACK_SPEC
        with_inst = any(f["instance"] and "," in f["instance"] for f in by_code)
        head = [spec["cols"][0], "Instances"] + spec["cols"][1:] if with_inst else list(spec["cols"])
        rows = []
        for f in by_code:
            for r in spec["rows"](f):
                rows.append([r[0], icell(f["instance"])] + r[1:] if with_inst else r)
        out.append({"code": code, "count": len(by_code), "note": spec["note"](by_code), "head": head, "rows": rows})
    return out


def _info_table_lines(items: List[dict]) -> List[str]:
    L: List[str] = []
    for t in info_code_tables(items):
        L += ["", f"#### {t['code']} ({t['count']})", ""]
        if t["note"]:
            L += [f"> {md(t['note'])}", ""]
        L += [f"| {' | '.join(t['head'])} |", "|" + "|".join("---" for _ in t["head"]) + "|"]
        for r in t["rows"]:
            L.append("| " + " | ".join(f"`{md(v)}`" if c else md(v) for v, c in r) + " |")
    return L


def _info_section_lines(an: dict, items: List[dict], num: int) -> List[str]:
    if not items:
        return ["_None._"]
    groups = group_by_instance(an, items)
    L = ["| Instance | Findings | Codes |", "|---|---:|---|"]
    for inst, lst in groups:
        label = md(inst) if inst else f"_{CROSS_INSTANCE.lower()}_"
        L.append(f"| {label} | {len(lst)} | {code_counts(lst)} |")
    for idx, (inst, lst) in enumerate(groups, start=1):
        title = f"Instance `{md(inst)}`" if inst else CROSS_INSTANCE
        L.append("")
        L.append(f"### {num}.{idx} {title} ({len(lst)})")
        L += _info_table_lines(lst)
    return L


def _finding_lines(f: dict) -> List[str]:
    where = f" `{md(f['namespace'])}`" if f["namespace"] else ""
    inst = f" ({md(f['instance'])})" if f["instance"] else ""
    lines = [f"- **[{f['severity']}] {f['code']}**{where}{inst}: {md(f['message'])}"]
    lines.extend(f"  - `{md(d)}`" for d in f["details"])
    return lines


def _header(an: dict, title: str) -> List[str]:
    t = an["target"]
    target = (f"`{t['name']}` (MongoDB {t['version']}, {t['topology']})" if t else "_not defined_")
    s = an["summary"]
    return [
        f"# {title}",
        "",
        f"- Generated at: `{an['generated_at']}` ({an['implementation']} implementation)",
        f"- Naming strategy: `{an['params']['naming_strategy']}` (separator `{an['params']['prefix_sep']}`,"
        f" mapping entries: {an['params']['mapping_entries']})",
        f"- Target instance: {target}",
        f"- Findings: **{s['errors']}** errors, **{s['warnings']}** warnings, **{s['info']}** info",
        "",
    ]


def render_report(an: dict, snapshots: List[dict]) -> str:
    L = _header(an, "MongoDB Schema Analysis Report")
    L += ["## 1. Instances", "",
          "| Instance | Alias | Role | Status | Version | FCV | Topology | DBs | Collections | Views | Documents"
          " | Data | Storage | Indexes |",
          "|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for i in an["instances"]:
        L.append(f"| {md(i['name'])} | {md(i['alias'])} | {i['role']} | {i['status']} | {i['version'] or '-'}"
                 f" | {i['fcv'] or '-'} | {i['topology'] or '-'} | {i['databases']} | {i['collections']}"
                 f" | {i['views']} | {i['documents']} | {human_bytes(i['data_size'])}"
                 f" | {human_bytes(i['storage_size'])} | {human_bytes(i['index_size'])} |")
    L += ["", "## 2. Findings summary", ""]
    if an["findings"]:
        L += ["| Severity | Code | Count |", "|---|---|---:|"]
        seen: Dict[str, int] = {}
        order: List[str] = []
        for f in an["findings"]:
            key = f"{f['severity']}|{f['code']}"
            if key not in seen:
                order.append(key)
                seen[key] = 0
            seen[key] += 1
        for key in order:
            sev, code = key.split("|")
            L.append(f"| {sev} | {code} | {seen[key]} |")
    else:
        L.append("_No findings._")
    for num, (sev, title) in enumerate(SEVERITY_TITLES, start=3):
        L += ["", f"## {num}. {title}", ""]
        items = [f for f in an["findings"] if f["severity"] == sev]
        if sev == "INFO":
            L += _info_section_lines(an, items, num)
            continue
        if not items:
            L.append("_None._")
        for f in items:
            L += _finding_lines(f)

    L += ["", "## 6. Inventory", ""]
    for snap in sorted(snapshots, key=lambda s: s["instance"]["name"]):
        name = snap["instance"]["name"]
        L += [f"### Instance `{name}`", ""]
        if snap.get("status") != "ok":
            L += [f"_Collection failed: {md(snap.get('error') or 'unknown error')}_", ""]
            continue
        rows = []
        for db in sorted(snap.get("databases") or [], key=lambda d: d["name"]):
            for c in sorted(db.get("collections") or [], key=lambda x: x["name"]):
                ctype = c.get("type") or "collection"
                opts = c.get("options") or {}
                st = c.get("stats") or {}
                idx = c.get("indexes") or []
                fields = (c.get("schema") or {}).get("fields") or {}
                mixed = sum(1 for f in fields.values() if classify_types(f.get("types") or {}) == "mixed")
                if ctype == "view":
                    rows.append(f"| {md(db['name'])} | {md(c['name'])} | view | - | - | - | - | - | - | - | - |")
                    continue
                rows.append(
                    f"| {md(db['name'])} | {md(c['name'])} | {ctype} | {int(st.get('count') or 0)}"
                    f" | {human_bytes(st.get('size') or 0)} | {human_bytes(st.get('storage_size') or 0)}"
                    f" | {len(idx)} | {human_bytes(st.get('total_index_size') or 0)}"
                    f" | {'yes' if opts.get('validator') else 'no'}"
                    f" | {md(canon(c['shard_key'], False)) if c.get('shard_key') else '-'} | {mixed} |")
        if not rows:
            L += ["_No user databases._", ""]
            continue
        L += ["| Database | Collection | Type | Documents | Data | Storage | Indexes | Index size | Validator"
              " | Shard key | Mixed-type fields |",
              "|---|---|---|---:|---:|---:|---:|---:|---|---|---:|"]
        L += rows
        L.append("")

    L += ["## 7. Cross-instance comparison", "", "### 7.1 Database name overlap", ""]
    overlap: Dict[str, List[str]] = {}
    for e in an["db_mapping"]:
        overlap.setdefault(e["source_db"], []).append(e["instance"])
    shared = [d for d in sorted(overlap) if len(overlap[d]) > 1]
    if shared:
        L += ["| Database | Instances |", "|---|---|"]
        L += [f"| {md(d)} | {md(', '.join(overlap[d]))} |" for d in shared]
    else:
        L.append("_No overlapping database names._")
    L += ["", "### 7.2 Shared namespaces (drift)", ""]
    if not an["drift"]:
        L.append("_No namespaces shared across instances._")
    for d in an["drift"]:
        L += [f"#### `{md(d['namespace'])}` - {md(', '.join(d['instances']))}", ""]
        if d["index_diff"]:
            L.append(f"- Indexes: **{len(d['index_diff'])} difference(s)**")
            for x in d["index_diff"]:
                L.append(f"  - `{md(x['signature'])}` present in: {', '.join(x['present_in'])};"
                         f" missing in: {', '.join(x['missing_in'])}")
        else:
            L.append("- Indexes: identical")
        if d["options_equal"]:
            L.append("- Options: identical")
        else:
            L.append("- Options: **differ**")
            L += [f"  - {md(i)}: `{md(v)}`" for i, v in d["options"].items()]
        if d["type_conflicts"]:
            L.append(f"- Field types: **{len(d['type_conflicts'])} conflict(s)**")
            for t in d["type_conflicts"]:
                L.append(f"  - `{md(t['path'])}`: " + "; ".join(f"{i}=[{','.join(v)}]" for i, v in t["types"].items()))
        else:
            L.append("- Field types: consistent")
        L.append("")
    L += _activity_section(an)
    L += _users_section(an)
    return "\n".join(L).rstrip("\n") + "\n"


def _dash(value) -> str:
    return "-" if value is None else str(value)


def _limit(items: List[str], limit: int) -> str:
    if not items:
        return "-"
    extra = f" +{len(items) - limit}" if len(items) > limit else ""
    return ", ".join(items[:limit]) + extra


def _modified_cell(c: dict) -> str:
    if not c["last_modified"]:
        return "-"
    return ("≥ " if c["last_modified_method"] == "sample" else "") + c["last_modified"]


def _modified_field_cell(c: dict) -> str:
    if not c["last_modified_field"]:
        return "-"
    others = sum(1 for m in c["modified_fields"] if m["value"] and m["path"] != c["last_modified_field"])
    return f"{c['last_modified_field']} ({c['last_modified_method']})" + (f" +{others}" if others else "")


def _activity_section(an: dict) -> List[str]:
    L = ["## 8. Activity", ""]
    if not an["activity"]:
        L += ["_Activity not collected._", ""]
        return L
    L += ["`~` dates come from ObjectId `_id` values (inserts only, client clock). *Last modified* comes from"
          " date fields matching the modified pattern: exact through an index or `--modified-scan`; `≥` is a"
          " lower bound taken from the sampled documents.", ""]
    for a in an["activity"]:
        L += [f"### Instance `{a['instance']}`", ""]
        o, sp = a["oplog"], a["sampling"]
        has_top = any(c["top"] for c in a["collections"])
        has_oplog = o is not None and not o.get("error")
        has_users = has_oplog or sp is not None
        notes = []
        if a["members"]:
            members = [f"{m['host']} ({m['state'] or 'unreachable'}"
                       + (f", up since {m['started_at']}" if m["started_at"] else "") + ")" for m in a["members"]]
            notes.append(f"- Members: {md(', '.join(members))}")
        if o is not None:
            notes.append(f"- Oplog: **error** {md(o['error'])}" if o.get("error") else
                         f"- Oplog: {o['window_hours']} h requested on {md(_dash(o['member']))};"
                         f" analyzed from {o['from']} to {o['oplog_last']}")
        if sp is not None:
            notes.append(f"- Live sampling: {sp['samples']} round(s) every {sp['interval_s']} s on {sp['members']}"
                         f" member(s), {sp['started_at']} - {_dash(sp['finished_at'])}")
        if notes:
            L += notes + [""]
        if not a["collections"]:
            L += ["_No collections._", ""]
            continue
        head = ["Namespace", "_id", "First insert ~", "Last insert ~", "Last modified", "Modified field"]
        align = ["---", "---", "---", "---", "---", "---"]
        if has_top:
            head += ["Reads since restart", "Writes since restart"]
            align += ["---:", "---:"]
        if has_oplog:
            head += ["Created (oplog)", "Last write (oplog)", "Oplog i/u/d/c"]
            align += ["---", "---", "---"]
        if sp is not None:
            head += ["Sampled ops"]
            align += ["---:"]
        if has_users:
            head += ["Users"]
            align += ["---"]
        L += ["| " + " | ".join(head) + " |", "|" + "|".join(align) + "|"]
        for c in a["collections"]:
            row = [md(c["namespace"]), _dash(c["id_type"]), _dash(c["first_insert"]), _dash(c["last_insert"]),
                   _modified_cell(c), md(_modified_field_cell(c))]
            t = c["top"]
            if has_top:
                row += [_dash(t["reads"] if t else None), _dash(t["writes"] if t else None)]
            op = c["oplog"]
            if has_oplog:
                row += [_dash(c["created_at"]), _dash(c["last_write"]),
                        f"{op['inserts']}/{op['updates']}/{op['deletes']}/{op['commands']}" if op else "-"]
            if sp is not None:
                row += [_dash(c["sampled_ops"])]
            if has_users:
                users = {u["user"]: u["oplog"] + u["sampled"] for u in c["users"]}
                row += [md(_limit(top_users(users, 3), 3))]
            L.append("| " + " | ".join(row) + " |")
        L.append("")
    return L


def _users_section(an: dict) -> List[str]:
    L = ["## 9. Users", ""]
    if not an["users"]:
        L += ["_No user information (collect with --include-security and/or --oplog-window / --activity-samples)._", ""]
        return L
    L += ["| Instance | User | Defined | Access (source DBs) | Observed via | Oplog writes | Sampled ops"
          " | Namespaces | Applications | Clients | Recommendation |",
          "|---|---|---|---|---|---:|---:|---|---|---|---|"]
    for u in an["users"]:
        name = f"{u['user']}@{u['db']}" if u["db"] else u["user"]
        apps = [k for k, _ in sorted(u["apps"].items(), key=lambda kv: (-kv[1], kv[0]))]
        clients = [k for k, _ in sorted(u["clients"].items(), key=lambda kv: (-kv[1], kv[0]))]
        L.append(f"| {md(u['instance'])} | {md(name)} | {'yes' if u['defined'] else 'no'}"
                 f" | {md(', '.join(u['access']) or '-')} | {', '.join(u['sources']) or '-'}"
                 f" | {u['oplog_writes']} | {u['sampled_ops']} | {md(_limit(u['namespaces'], 5))}"
                 f" | {md(_limit(apps, 3))} | {md(_limit(clients, 3))} | **{u['recommendation']}** |")
    L.append("")
    return L


def render_plan(an: dict) -> str:
    s = an["summary"]
    L = _header(an, "MongoDB Centralization Plan")
    if s["errors"]:
        L.append(f"**Status: BLOCKED** - {s['errors']} blocking error(s) must be resolved before migrating.")
    else:
        L.append("**Status: READY** - no blocking errors (review the warnings).")
    L += ["", "## 1. Capacity", "", "| Instance | Documents | Data | Storage | Indexes |", "|---|---:|---:|---:|---:|"]
    for r in an["capacity"]["per_instance"]:
        L.append(f"| {md(r['instance'])} | {r['documents']} | {human_bytes(r['data_size'])}"
                 f" | {human_bytes(r['storage_size'])} | {human_bytes(r['index_size'])} |")
    t = an["capacity"]["total"]
    L.append(f"| **Total** | **{t['documents']}** | **{human_bytes(t['data_size'])}**"
             f" | **{human_bytes(t['storage_size'])}** | **{human_bytes(t['index_size'])}** |")
    te = an["capacity"]["target_existing"]
    if te:
        L += ["", f"Target already holds {te['documents']} document(s), {human_bytes(te['storage_size'])} storage"
                  f" and {human_bytes(te['index_size'])} of indexes. Required free space (storage + indexes of"
                  f" sources, without compression gains): {human_bytes(t['storage_size'] + t['index_size'])}."]

    L += ["", "## 2. Database mapping", "",
          "| Instance | Source DB | Target DB | Reason | Collections | Views | Documents | Storage |",
          "|---|---|---|---|---:|---:|---:|---:|"]
    for e in an["db_mapping"]:
        L.append(f"| {md(e['instance'])} | {md(e['source_db'])} | {md(e['target_db'])} | {e['reason']}"
                 f" | {e['collections']} | {e['views']} | {e['documents']} | {human_bytes(e['storage_size'])} |")
    if not an["db_mapping"]:
        L.append("| - | - | - | - | 0 | 0 | 0 | 0 B |")

    L += ["", "## 3. Required modifications", "", "### 3.1 Blocking issues", ""]
    errs = [f for f in an["findings"] if f["severity"] == "ERROR"]
    if not errs:
        L.append("_None._")
    for f in errs:
        L += _finding_lines(f)

    L += ["", "### 3.2 Database renames (application impact)", ""]
    renames = [e for e in an["db_mapping"] if e["source_db"] != e["target_db"]]
    if not renames:
        L.append("_No database renames required._")
    for e in renames:
        L.append(f"- `{md(e['instance'])}`: `{md(e['source_db'])}` -> `{md(e['target_db'])}` - update connection"
                 " strings, application database names, and any cross-database $lookup/$merge/$out references.")

    L += ["", "### 3.3 Index harmonization", ""]
    idx_drift = [d for d in an["drift"] if d["index_diff"]]
    if not idx_drift:
        L.append("_No index drift between instances._")
    for d in idx_drift:
        L.append(f"- `{md(d['namespace'])}`: agree on a single index set before consolidating"
                 f" ({len(d['index_diff'])} difference(s)):")
        for x in d["index_diff"]:
            L.append(f"  - `{md(x['signature'])}` only in {', '.join(x['present_in'])}")

    L += ["", "### 3.4 Data type normalization", ""]
    if not an["normalization"]:
        L.append("_No scalar type normalization candidates._")
    else:
        L.append("Candidates executed by `normalization_suggestions.js` (dry-run by default) after the data load:")
        L.append("")
        for n in an["normalization"]:
            types = ", ".join(f"{k}={v}" for k, v in n["types"].items())
            L.append(f"- `{md(n['target_ns'])}` field `{md(n['path'])}` -> **{n['dominant_type']}** ({types};"
                     f" source {md(n['instance'])})")

    L += ["", "### 3.5 Sharding", ""]
    shard = [f for f in an["findings"] if f["code"] in ("SHARD_KEY", "SHARD_KEY_LOST")]
    if not shard:
        L.append("_No sharded source collections._")
    for f in shard:
        L += _finding_lines(f)

    L += ["", "### 3.6 Security", ""]
    sp = an["security_plan"]
    if sp is None:
        L.append("_Security objects not collected (run the collection with --include-security)._")
    else:
        L.append(f"{len(sp['users'])} user(s) and {len(sp['roles'])} custom role(s) will be created by the"
                 " `security` bootstrap phase (passwords are prompted, never exported).")
        for f in an["findings"]:
            if f["code"] in ("USER_CONFLICT", "ROLE_CONFLICT"):
                L += _finding_lines(f)
    if an["users"]:
        for title, rec in (("Users to migrate (activity observed)", "migrate"),
                           ("Users to review (access granted, no activity observed)", "review"),
                           ("Users without activity data (no oplog window or sampling)", "unknown")):
            items = [u for u in an["users"] if u["recommendation"] == rec]
            L += ["", f"**{title}:** {len(items)}"]
            for u in items:
                name = f"{u['user']}@{u['db']}" if u["db"] else u["user"]
                L.append(f"- `{md(u['instance'])}` `{md(name)}` - access: {md(', '.join(u['access']) or '-')}"
                         f"; namespaces: {md(_limit(u['namespaces'], 5))}")

    L += ["", "## 4. Execution runbook", "",
          "1. Resolve every blocking issue and re-run the analysis until the status is READY.",
          "2. Create the database-tools YAML files referenced by `migration_commands.sh` (chmod 600).",
          "3. Freeze writes on the source databases: `mongodump` without `--oplog` is not point-in-time.",
          "4. `BMN_PHASE=collections mongosh <target> --file target_bootstrap.js` (dry-run), then with `BMN_APPLY=1`.",
          "5. `./migration_commands.sh --list`, then `./migration_commands.sh --apply`.",
          "6. `BMN_PHASE=indexes`, then `BMN_PHASE=views`, then `BMN_PHASE=security` with `BMN_APPLY=1`.",
          "7. Review and optionally apply `normalization_suggestions.js`.",
          "8. `BMN_PHASE=verify` to compare document counts, then switch application connection strings.",
          "", "## 5. Generated artifacts", "",
          "- `analysis.json`: machine-readable analysis (mapping, drift, findings).",
          "- `report.md`: inventory and cross-instance comparison.",
          "- `report.jira.txt`: Jira wiki markup summary for an issue description (REST API v2 or Data Center).",
          "- `report.confluence.xml`: full report in Confluence storage format (REST API `body.storage`).",
          "- `target_bootstrap.js`: idempotent mongosh bootstrap for the target (phased).",
          "- `migration_commands.sh`: mongodump/mongorestore jobs with namespace remapping.",
          "- `normalization_suggestions.js`: type normalization candidates.",
          "- `snapshots/`: raw per-instance schema snapshots (no document values)."]
    return "\n".join(L) + "\n"


def _strip_collection_options(opts: dict) -> dict:
    out = {}
    for k, v in opts.items():
        if k in ("autoIndexId", "viewOn", "pipeline"):
            continue
        if k == "clusteredIndex" and isinstance(v, dict):
            v = {kk: vv for kk, vv in v.items() if kk != "v"}
        out[k] = v
    return out


def build_bootstrap_plan(an: dict, snapshots: List[dict]) -> dict:
    tmap = {(e["instance"], e["source_db"]): e["target_db"] for e in an["db_mapping"]}
    seen = set()
    collections: List[dict] = []
    indexes: List[dict] = []
    views: List[dict] = []
    for snap in sorted(snapshots, key=lambda s: s["instance"]["name"]):
        iname = snap["instance"]["name"]
        for db in sorted(snap.get("databases") or [], key=lambda d: d["name"]):
            tdb = tmap.get((iname, db["name"]))
            if tdb is None:
                continue
            for c in sorted(db.get("collections") or [], key=lambda x: x["name"]):
                tns = f"{tdb}.{c['name']}"
                if tns in seen:
                    continue
                seen.add(tns)
                src = f"{iname}:{db['name']}.{c['name']}"
                opts = c.get("options") or {}
                ctype = c.get("type") or "collection"
                if ctype == "view":
                    view = {"db": tdb, "name": c["name"], "viewOn": opts.get("viewOn"),
                            "pipeline": opts.get("pipeline") or []}
                    if opts.get("collation"):
                        view["collation"] = opts["collation"]
                    view["source"] = src
                    views.append(view)
                    continue
                collections.append({
                    "db": tdb, "name": c["name"], "type": ctype, "options": _strip_collection_options(opts),
                    "shard_key": c.get("shard_key") or None, "shard_unique": bool(c.get("shard_key_unique")),
                    "expected_documents": int((c.get("stats") or {}).get("count") or 0), "source": src,
                })
                specs = [{k: v for k, v in ix.items() if k not in INDEX_STRIP_KEYS}
                         for ix in c.get("indexes") or [] if ix.get("name") != "_id_" and not ix.get("clustered")]
                if specs:
                    indexes.append({"db": tdb, "collection": c["name"], "specs": specs, "source": src})
    sec = an["security_plan"] or {"users": [], "roles": []}
    return {
        "generated_at": an["generated_at"],
        "target": an["params"]["target"],
        "target_sharded": bool(an["target"] and an["target"]["topology"] == "sharded"),
        "collections": collections, "indexes": indexes, "views": views,
        "roles": sec["roles"], "users": sec["users"],
    }


def _template(name: str) -> str:
    return (TEMPLATES_DIR / name).read_text(encoding="utf-8")


def render_bootstrap(an: dict, snapshots: List[dict]) -> str:
    return (_template("bootstrap.js.tpl")
            .replace("@@GENERATED_AT@@", an["generated_at"])
            .replace("@@PLAN_JSON@@", dump_pretty(build_bootstrap_plan(an, snapshots))))


def render_normalization(an: dict) -> str:
    return (_template("normalization.js.tpl")
            .replace("@@GENERATED_AT@@", an["generated_at"])
            .replace("@@FIXES_JSON@@", dump_pretty(an["normalization"])))


def render_migration(an: dict) -> str:
    cfg_lines: List[str] = []
    seen = set()
    for i in an["instances"]:
        if i["role"] != "source" or i["status"] != "ok" or i["alias"] in seen:
            continue
        seen.add(i["alias"])
        var = f"CFG_{i['alias'].upper()}"
        cfg_lines.append(f"# {i['name']}: {i['uri'] or 'uri unknown'}")
        cfg_lines.append(f'{var}="${{{var}:-${{BMN_TOOLS_CFG_DIR}}/{i["alias"]}.yaml}}"')
    jobs = [f"  {sh_single_quote(e['alias'] + '|' + e['source_db'] + '|' + e['target_db'])}" for e in an["db_mapping"]]
    return (_template("migration_commands.sh.tpl")
            .replace("@@GENERATED_AT@@", an["generated_at"])
            .replace("@@BLOCKING_ERRORS@@", str(an["summary"]["errors"]))
            .replace("@@SOURCE_CONFIGS@@", "\n".join(cfg_lines) if cfg_lines else "# (no source instances)")
            .replace("@@JOBS@@", "\n".join(jobs)))


def write_artifacts(an: dict, snapshots: List[dict], out_dir: Path) -> List[Path]:
    from .renderers_atlassian import render_confluence, render_jira  # late import: avoids a circular import

    out_dir.mkdir(parents=True, exist_ok=True)
    files = {
        "analysis.json": dump_pretty(an) + "\n",
        "report.md": render_report(an, snapshots),
        "centralization_plan.md": render_plan(an),
        "report.jira.txt": render_jira(an),
        "report.confluence.xml": render_confluence(an, snapshots),
        "target_bootstrap.js": render_bootstrap(an, snapshots),
        "migration_commands.sh": render_migration(an),
        "normalization_suggestions.js": render_normalization(an),
    }
    written = []
    for name, content in files.items():
        path = out_dir / name
        path.write_text(content, encoding="utf-8")
        if name.endswith(".sh"):
            path.chmod(0o750)
        written.append(path)
    return written
