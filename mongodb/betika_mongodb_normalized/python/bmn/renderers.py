"""Artifact renderers. Output must stay byte-identical to bash/lib/analyzer.js."""
from __future__ import annotations

from pathlib import Path
from typing import Dict, List

from .common import (
    INDEX_STRIP_KEYS, TEMPLATES_DIR, canon, classify_types, dump_pretty, human_bytes, md, sh_single_quote,
)

SEVERITY_TITLES = (("ERROR", "Errors"), ("WARN", "Warnings"), ("INFO", "Informational"))


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
    return "\n".join(L).rstrip("\n") + "\n"


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
    out_dir.mkdir(parents=True, exist_ok=True)
    files = {
        "analysis.json": dump_pretty(an) + "\n",
        "report.md": render_report(an, snapshots),
        "centralization_plan.md": render_plan(an),
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
