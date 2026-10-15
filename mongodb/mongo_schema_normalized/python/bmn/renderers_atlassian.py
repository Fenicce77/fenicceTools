"""Atlassian renderers: Jira wiki markup (issue description) and Confluence storage format (page body).

Output must stay byte-identical to the equivalent functions in bash/lib/analyzer.js.

- report.jira.txt        Jira wiki markup. Paste into an issue description (Jira Data Center / Server)
                         or send it as `fields.description` through the REST API v2 (Jira Cloud and DC).
                         Kept below the 32,767 character description limit (compact mode, then truncation).
- report.confluence.xml  Confluence storage format (XHTML + ac: macros). Publish it as `body.storage`
                         through the REST API (Cloud and Data Center).
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from .activity_analysis import top_users
from .common import canon, classify_types, human_bytes
from .renderers import (
    CROSS_INSTANCE, SEVERITY_TITLES, _dash, _limit, _modified_cell, _modified_field_cell, code_counts, group_by_code,
    group_by_instance,
)

JIRA_LIMIT = 32767
JIRA_SAFE_LIMIT = 32000
JIRA_SPECIAL = set("[]{}|*_+^~?-!#")
JIRA_COLORS = {"ERROR": "#DE350B", "WARN": "#FF8B00", "INFO": "#0052CC", "READY": "#00875A", "BLOCKED": "#DE350B"}
CONFLUENCE_COLOURS = {"ERROR": "Red", "WARN": "Yellow", "INFO": "Blue", "READY": "Green", "BLOCKED": "Red"}
RECOMMENDATIONS = (("Users to migrate (activity observed)", "migrate"),
                   ("Users to review (access granted, no activity observed)", "review"),
                   ("Users without activity data (no oplog window or sampling)", "unknown"))
# Items listed per section in compact mode (the rest is summarized): keeps every section in the description.
COMPACT_CAPS = {"ERROR": 40, "WARN": 25, "rows": 60, "items": 30}
RUNBOOK = (
    "Resolve every blocking issue and re-run the analysis until the status is READY.",
    "Create the database-tools YAML files referenced by migration_commands.sh (chmod 600).",
    "Freeze writes on the source databases: mongodump without --oplog is not point-in-time.",
    "BMN_PHASE=collections mongosh <target> --file target_bootstrap.js (dry-run), then with BMN_APPLY=1.",
    "./migration_commands.sh --list, then ./migration_commands.sh --apply.",
    "BMN_PHASE=indexes, then BMN_PHASE=views, then BMN_PHASE=security with BMN_APPLY=1.",
    "Review and optionally apply normalization_suggestions.js.",
    "BMN_PHASE=verify to compare document counts, then switch application connection strings.",
)


def utf16_len(text: str) -> int:
    """Length as Jira (Java) counts it: UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


def _status(an: dict) -> str:
    return "BLOCKED" if an["summary"]["errors"] else "READY"


def _target_text(an: dict) -> str:
    t = an["target"]
    return f"{t['name']} (MongoDB {t['version']}, {t['topology']})" if t else "not defined"


def _finding_counts(an: dict) -> List[Tuple[str, str, int]]:
    seen: Dict[str, int] = {}
    order: List[str] = []
    for f in an["findings"]:
        key = f"{f['severity']}|{f['code']}"
        if key not in seen:
            order.append(key)
            seen[key] = 0
        seen[key] += 1
    return [(k.split("|")[0], k.split("|")[1], seen[k]) for k in order]


def _user_name(u: dict) -> str:
    return f"{u['user']}@{u['db']}" if u["db"] else u["user"]


def _sorted_keys(counts: Dict[str, int]) -> List[str]:
    return [k for k, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]


# =============================================================================================== Jira
def jesc(text: object) -> str:
    """Escape plain text for Jira wiki markup (single line)."""
    out = []
    for ch in str(text).replace("\r", " ").replace("\n", " "):
        if ch == "\\":
            out.append("&#92;")
        elif ch in JIRA_SPECIAL:
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)


def jmono(text: object) -> str:
    return "{{" + jesc(text) + "}}"


def jcolor(sev: str, text: Optional[str] = None) -> str:
    return "{color:" + JIRA_COLORS[sev] + "}*" + jesc(text if text is not None else sev) + "*{color}"


def jrow(cells: List[str], header: bool = False) -> str:
    sep = "||" if header else "|"
    return sep + sep.join(c if c != "" else " " for c in cells) + sep


def jnoformat(lines: List[str]) -> List[str]:
    body = [ln.replace("{noformat}", "{ noformat}") for ln in lines]
    return ["{noformat}"] + body + ["{noformat}"]


def _jira_finding(f: dict, max_details: int) -> List[str]:
    where = f" {jmono(f['namespace'])}" if f["namespace"] else ""
    inst = f" ({jesc(f['instance'])})" if f["instance"] else ""
    lines = [f"* {jcolor(f['severity'])} *{jesc(f['code'])}*{where}{inst}: {jesc(f['message'])}"]
    details = f["details"]
    if details and max_details > 0:
        shown = details[:max_details]
        if len(details) > max_details:
            shown = shown + [f"... {len(details) - max_details} more (see report.md / analysis.json)"]
        lines += jnoformat(shown)
    return lines


def _cap(items: list, compact: bool, key: str) -> Tuple[list, int]:
    """(items to list, number omitted) according to the compact caps."""
    if not compact or len(items) <= COMPACT_CAPS[key]:
        return items, 0
    return items[:COMPACT_CAPS[key]], len(items) - COMPACT_CAPS[key]


def _omitted(n: int, what: str) -> List[str]:
    return [f"_... {n} more {what} (see report.md)_"] if n else []


def _jira_body(an: dict, compact: bool) -> str:
    s = an["summary"]
    status = _status(an)
    p = an["params"]
    L: List[str] = []
    note = (f"{s['errors']} blocking error(s) must be resolved before migrating." if s["errors"]
            else "No blocking errors (review the warnings).")
    L += ["{panel:title=MongoDB Schema Centralization - " + status + "|borderColor=" + JIRA_COLORS[status]
          + "|titleBGColor=" + JIRA_COLORS[status] + "|titleColor=#FFFFFF}",
          f"*Status:* {jcolor(status)} - {jesc(note)}",
          f"*Findings:* {jcolor('ERROR', str(s['errors']) + ' errors')}, {jcolor('WARN', str(s['warnings']) + ' warnings')},"
          f" {jcolor('INFO', str(s['info']) + ' info')}",
          f"*Target instance:* {jesc(_target_text(an))}",
          f"*Scope:* {s['sources']} source instance(s), {s['source_databases']} database(s) -> {s['target_databases']},"
          f" {s['source_collections']} collection(s), {s['source_views']} view(s)",
          f"*Naming strategy:* {jmono(p['naming_strategy'])} (separator {jmono(p['prefix_sep'])},"
          f" mapping entries: {p['mapping_entries']})",
          f"*Generated at:* {jesc(an['generated_at'])} ({jesc(an['implementation'])} implementation)",
          "{panel}", ""]

    L += ["h2. Instances", "",
          jrow(["Instance", "Alias", "Role", "Status", "Version", "Topology", "DBs", "Collections", "Documents",
                "Storage", "Indexes"], header=True)]
    for i in an["instances"]:
        st = jcolor("READY", "ok") if i["status"] == "ok" else jcolor("ERROR", i["status"])
        L.append(jrow([jesc(i["name"]), jesc(i["alias"]), jesc(i["role"]), st, jesc(i["version"] or "-"),
                       jesc(i["topology"] or "-"), str(i["databases"]), str(i["collections"]), str(i["documents"]),
                       jesc(human_bytes(i["storage_size"])), jesc(human_bytes(i["index_size"]))]))
    tot = an["capacity"]["total"]
    L += ["", f"*Data to move:* {jesc(human_bytes(tot['storage_size'] + tot['index_size']))} (storage + indexes,"
              f" {tot['documents']} document(s))", ""]

    L += ["h2. Findings summary", ""]
    counts = _finding_counts(an)
    if counts:
        L.append(jrow(["Severity", "Code", "Count"], header=True))
        L += [jrow([jcolor(sev), jmono(code), str(n)]) for sev, code, n in counts]
    else:
        L.append("_No findings._")
    for sev, title in SEVERITY_TITLES[:2]:
        items = [f for f in an["findings"] if f["severity"] == sev]
        L += ["", f"h2. {title} ({len(items)})", ""]
        if not items:
            L.append("_None._")
        shown, omitted = _cap(items, compact, sev)
        for f in shown:
            L += _jira_finding(f, 0 if compact else (10 if sev == "ERROR" else 5))
        L += _omitted(omitted, title.lower())
    infos = [f for f in an["findings"] if f["severity"] == "INFO"]
    L += ["", f"h2. Informational ({len(infos)})", ""]
    if not infos:
        L.append("_None._")
    info_groups = group_by_instance(an, infos)
    if info_groups:
        L.append(jrow(["Instance", "Findings", "Codes"], header=True))
    for inst, lst in info_groups:
        label = jesc(inst) if inst else f"_{CROSS_INSTANCE.lower()}_"
        L.append(jrow([label, str(len(lst)), jesc(code_counts(lst))]))
    if not compact:
        for inst, lst in info_groups:
            title = f"Instance {jesc(inst)}" if inst else CROSS_INSTANCE
            L += ["", f"h3. {title} ({len(lst)})", ""]
            for code, by_code in group_by_code(lst):
                targets = [t for t in (f["namespace"] or ("" if inst else f["instance"]) for f in by_code) if t]
                L.append(f"* {jmono(code)}: {len(by_code)}" + (f" - {jesc(_limit(targets, 8))}" if targets else ""))

    L += ["", "h2. Database mapping", ""]
    if an["db_mapping"]:
        L.append(jrow(["Instance", "Source DB", "Target DB", "Reason", "Collections", "Documents", "Storage"],
                      header=True))
        shown, omitted = _cap(an["db_mapping"], compact, "rows")
        for e in shown:
            tgt = jmono(e["target_db"])
            if e["source_db"] != e["target_db"]:
                tgt = "*" + tgt + "*"
            L.append(jrow([jesc(e["instance"]), jmono(e["source_db"]), tgt, jesc(e["reason"]), str(e["collections"]),
                           str(e["documents"]), jesc(human_bytes(e["storage_size"]))]))
        L += _omitted(omitted, "database mapping(s)")
    else:
        L.append("_No source databases._")

    L += ["", "h2. Required modifications", ""]
    renames = [e for e in an["db_mapping"] if e["source_db"] != e["target_db"]]
    L.append(f"*Database renames (application impact):* {len(renames)}")
    shown, omitted = _cap(renames, compact, "items")
    for e in shown:
        L.append(f"* {jesc(e['instance'])}: {jmono(e['source_db'])} -> {jmono(e['target_db'])}")
    L += _omitted(omitted, "rename(s)")
    idx_drift = [d for d in an["drift"] if d["index_diff"]]
    L.append(f"*Index harmonization:* {len(idx_drift)} namespace(s)")
    shown, omitted = _cap(idx_drift, compact, "items")
    for d in shown:
        L.append(f"* {jmono(d['namespace'])}: {len(d['index_diff'])} index difference(s)")
    L += _omitted(omitted, "namespace(s)")
    L.append(f"*Data type normalization candidates:* {len(an['normalization'])}")
    shown, omitted = _cap(an["normalization"], compact, "items")
    for n in shown:
        L.append(f"* {jmono(n['target_ns'])} field {jmono(n['path'])} -> *{jesc(n['dominant_type'])}*")
    L += _omitted(omitted, "candidate(s)")
    if an["users"]:
        for title, rec in RECOMMENDATIONS:
            items = [u for u in an["users"] if u["recommendation"] == rec]
            L.append(f"*{jesc(title)}:* {len(items)}")
            if compact and rec != "migrate":
                continue
            shown, omitted = _cap(items, compact, "rows")
            for u in shown:
                L.append(f"* {jesc(u['instance'])}: {jmono(_user_name(u))} - access: "
                         f"{jesc(', '.join(u['access']) or '-')}")
            L += _omitted(omitted, "user(s)")
    else:
        L.append("*Users:* not collected (use --include-security and --oplog-window / --activity-samples)")

    L += ["", "h2. Next steps", ""]
    L += [f"# {jesc(step)}" for step in RUNBOOK]
    L += ["", "----",
          "_" + jesc("Full details: attach report.confluence.xml / report.md / centralization_plan.md / analysis.json."
                     " Generated by betika_mongodb_normalized.") + "_"]
    return "\n".join(L) + "\n"


def render_jira(an: dict) -> str:
    text = _jira_body(an, compact=False)
    if utf16_len(text) <= JIRA_SAFE_LIMIT:
        return text
    text = _jira_body(an, compact=True)
    if utf16_len(text) <= JIRA_SAFE_LIMIT:
        return text
    marker = "\n\n{color:#DE350B}*Truncated to fit the Jira description limit: see report.md.*{color}\n"
    budget = JIRA_SAFE_LIMIT - utf16_len(marker)
    lines = text.split("\n")
    kept: List[str] = []
    size = 0
    in_noformat = False
    for line in lines:
        cost = utf16_len(line) + 1
        if size + cost > budget:
            break
        kept.append(line)
        size += cost
        if line == "{noformat}":
            in_noformat = not in_noformat
    if in_noformat:
        kept.append("{noformat}")
    return "\n".join(kept) + marker


# ========================================================================================== Confluence
def xesc(text: object) -> str:
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def xcode(text: object) -> str:
    return "<code>" + xesc(text) + "</code>"


def xstatus(sev: str, title: Optional[str] = None) -> str:
    return ('<ac:structured-macro ac:name="status"><ac:parameter ac:name="colour">' + CONFLUENCE_COLOURS[sev]
            + '</ac:parameter><ac:parameter ac:name="title">' + xesc(title if title is not None else sev)
            + "</ac:parameter></ac:structured-macro>")


def xmacro(name: str, body: Optional[str], params: Optional[List[Tuple[str, str]]] = None) -> str:
    """Structured macro; body None renders a parameter-only macro (toc...)."""
    ps = "".join(f'<ac:parameter ac:name="{k}">{xesc(v)}</ac:parameter>' for k, v in (params or []))
    inner = "" if body is None else f"<ac:rich-text-body>{body}</ac:rich-text-body>"
    return f'<ac:structured-macro ac:name="{name}">{ps}{inner}</ac:structured-macro>'


def xcodeblock(lines: List[str]) -> str:
    body = "\n".join(lines).replace("]]>", "]]]]><![CDATA[>")
    return ('<ac:structured-macro ac:name="code"><ac:parameter ac:name="language">text</ac:parameter>'
            '<ac:plain-text-body><![CDATA[' + body + "]]></ac:plain-text-body></ac:structured-macro>")


def xtable(head: List[str], rows: List[List[str]]) -> str:
    out = ["<table><tbody>", "<tr>" + "".join(f"<th>{h}</th>" for h in head) + "</tr>"]
    out += ["<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows]
    out.append("</tbody></table>")
    return "\n".join(out)


def xlist(items: List[str], ordered: bool = False) -> str:
    tag = "ol" if ordered else "ul"
    return f"<{tag}>" + "".join(f"<li>{i}</li>" for i in items) + f"</{tag}>"


def xp(html: str) -> str:
    return f"<p>{html}</p>"


def _xfinding(f: dict) -> str:
    where = f" {xcode(f['namespace'])}" if f["namespace"] else ""
    inst = f" ({xesc(f['instance'])})" if f["instance"] else ""
    head = f"{xstatus(f['severity'])} <strong>{xesc(f['code'])}</strong>{where}{inst}: {xesc(f['message'])}"
    if not f["details"]:
        return head
    return head + xmacro("expand", xcodeblock(f["details"]), [("title", f"{len(f['details'])} detail line(s)")])


def _x_grouped_finding(f: dict, with_instance: bool) -> str:
    parts = []
    if f["namespace"]:
        parts.append(xcode(f["namespace"]))
    if with_instance and f["instance"]:
        parts.append(f"({xesc(f['instance'])})")
    head = (f"{' '.join(parts)}: " if parts else "") + xesc(f["message"])
    if not f["details"]:
        return head
    return head + xmacro("expand", xcodeblock(f["details"]), [("title", f"{len(f['details'])} detail line(s)")])


def _x_info_section(an: dict, items: List[dict]) -> List[str]:
    if not items:
        return [xp("<em>None.</em>")]
    groups = group_by_instance(an, items)
    rows = [[xesc(inst) if inst else f"<em>{CROSS_INSTANCE.lower()}</em>", str(len(lst)), xesc(code_counts(lst))]
            for inst, lst in groups]
    B = [xtable(["Instance", "Findings", "Codes"], rows)]
    for inst, lst in groups:
        title = f"Instance {xesc(inst)}" if inst else CROSS_INSTANCE
        B.append(f"<h3>{title} ({len(lst)})</h3>")
        body = "".join(xp(f"<strong>{xesc(code)}</strong> ({len(by_code)})")
                       + xlist([_x_grouped_finding(f, not inst) for f in by_code])
                       for code, by_code in group_by_code(lst))
        B.append(xmacro("expand", body, [("title", f"Show {len(lst)} informational finding(s)")]))
    return B


def _x_findings_block(items: List[dict]) -> str:
    return xlist([_xfinding(f) for f in items]) if items else xp("<em>None.</em>")


def render_confluence(an: dict, snapshots: List[dict]) -> str:  # noqa: C901 - linear page layout
    s = an["summary"]
    status = _status(an)
    p = an["params"]
    B: List[str] = []

    B.append(xmacro("toc", None, [("maxLevel", "2")]))
    note = (f"{s['errors']} blocking error(s) must be resolved before migrating." if s["errors"]
            else "No blocking errors (review the warnings).")
    summary = "".join([
        xp(f"<strong>Status:</strong> {xstatus(status)} {xesc(note)}"),
        xp(f"<strong>Findings:</strong> {xstatus('ERROR', str(s['errors']) + ' errors')} "
           f"{xstatus('WARN', str(s['warnings']) + ' warnings')} {xstatus('INFO', str(s['info']) + ' info')}"),
        xp(f"<strong>Target instance:</strong> {xesc(_target_text(an))}"),
        xp(f"<strong>Scope:</strong> {s['sources']} source instance(s), {s['source_databases']} database(s) -&gt; "
           f"{s['target_databases']}, {s['source_collections']} collection(s), {s['source_views']} view(s)"),
        xp(f"<strong>Naming strategy:</strong> {xcode(p['naming_strategy'])} (separator {xcode(p['prefix_sep'])}, "
           f"mapping entries: {p['mapping_entries']})"),
        xp(f"<strong>Generated at:</strong> {xesc(an['generated_at'])} ({xesc(an['implementation'])} implementation)"),
    ])
    B.append("<h1>1. Summary</h1>")
    B.append(xmacro("warning" if s["errors"] else "tip", summary, [("title", f"Status: {status}")]))

    # ---------------------------------------------------------------- findings
    B.append("<h1>2. Findings</h1>")
    counts = _finding_counts(an)
    if counts:
        B.append(xtable(["Severity", "Code", "Count"], [[xstatus(sev), xcode(code), str(n)] for sev, code, n in counts]))
    else:
        B.append(xp("<em>No findings.</em>"))
    for sev, title in SEVERITY_TITLES:
        items = [f for f in an["findings"] if f["severity"] == sev]
        B.append(f"<h2>{xesc(title)} ({len(items)})</h2>")
        if sev == "INFO":
            B += _x_info_section(an, items)
        else:
            B.append(_x_findings_block(items))

    # ---------------------------------------------------------------- instances / capacity
    B.append("<h1>3. Instances and capacity</h1>")
    rows = []
    for i in an["instances"]:
        st = xstatus("READY", "ok") if i["status"] == "ok" else xstatus("ERROR", i["status"])
        rows.append([xesc(i["name"]), xesc(i["alias"]), xesc(i["role"]), st, xesc(i["version"] or "-"),
                     xesc(i["fcv"] or "-"), xesc(i["topology"] or "-"), str(i["databases"]), str(i["collections"]),
                     str(i["views"]), str(i["documents"]), xesc(human_bytes(i["data_size"])),
                     xesc(human_bytes(i["storage_size"])), xesc(human_bytes(i["index_size"]))])
    B.append(xtable(["Instance", "Alias", "Role", "Status", "Version", "FCV", "Topology", "DBs", "Collections", "Views",
                     "Documents", "Data", "Storage", "Indexes"], rows))
    cap = an["capacity"]
    rows = [[xesc(r["instance"]), str(r["documents"]), xesc(human_bytes(r["data_size"])),
             xesc(human_bytes(r["storage_size"])), xesc(human_bytes(r["index_size"]))] for r in cap["per_instance"]]
    t = cap["total"]
    rows.append(["<strong>Total</strong>", f"<strong>{t['documents']}</strong>",
                 f"<strong>{xesc(human_bytes(t['data_size']))}</strong>",
                 f"<strong>{xesc(human_bytes(t['storage_size']))}</strong>",
                 f"<strong>{xesc(human_bytes(t['index_size']))}</strong>"])
    B.append("<h2>Capacity (sources)</h2>")
    B.append(xtable(["Instance", "Documents", "Data", "Storage", "Indexes"], rows))
    te = cap["target_existing"]
    if te:
        B.append(xmacro("info", xp(
            f"Target already holds {te['documents']} document(s), {xesc(human_bytes(te['storage_size']))} storage and "
            f"{xesc(human_bytes(te['index_size']))} of indexes. Required free space (storage + indexes of sources, "
            f"without compression gains): <strong>{xesc(human_bytes(t['storage_size'] + t['index_size']))}</strong>.")))

    # ---------------------------------------------------------------- mapping / modifications
    B.append("<h1>4. Database mapping</h1>")
    if an["db_mapping"]:
        rows = []
        for e in an["db_mapping"]:
            tgt = xcode(e["target_db"])
            if e["source_db"] != e["target_db"]:
                tgt = f"<strong>{tgt}</strong>"
            rows.append([xesc(e["instance"]), xcode(e["source_db"]), tgt, xesc(e["reason"]), str(e["collections"]),
                         str(e["views"]), str(e["documents"]), xesc(human_bytes(e["storage_size"]))])
        B.append(xtable(["Instance", "Source DB", "Target DB", "Reason", "Collections", "Views", "Documents", "Storage"],
                        rows))
    else:
        B.append(xp("<em>No source databases.</em>"))

    B.append("<h1>5. Required modifications</h1>")
    B.append("<h2>Blocking issues</h2>")
    B.append(_x_findings_block([f for f in an["findings"] if f["severity"] == "ERROR"]))
    B.append("<h2>Database renames (application impact)</h2>")
    renames = [e for e in an["db_mapping"] if e["source_db"] != e["target_db"]]
    if renames:
        B.append(xp("Update connection strings, application database names and any cross-database "
                    "$lookup/$merge/$out references:"))
        B.append(xlist([f"{xesc(e['instance'])}: {xcode(e['source_db'])} -&gt; {xcode(e['target_db'])}"
                        for e in renames]))
    else:
        B.append(xp("<em>No database renames required.</em>"))
    B.append("<h2>Index harmonization</h2>")
    idx_drift = [d for d in an["drift"] if d["index_diff"]]
    if idx_drift:
        B.append(xlist([f"{xcode(d['namespace'])}: agree on a single index set before consolidating"
                        + xlist([f"{xcode(x['signature'])} only in {xesc(', '.join(x['present_in']))}"
                                 for x in d["index_diff"]]) for d in idx_drift]))
    else:
        B.append(xp("<em>No index drift between instances.</em>"))
    B.append("<h2>Data type normalization</h2>")
    if an["normalization"]:
        B.append(xp(f"Candidates executed by {xcode('normalization_suggestions.js')} (dry-run by default) after the "
                    "data load:"))
        B.append(xlist([f"{xcode(n['target_ns'])} field {xcode(n['path'])} -&gt; <strong>{xesc(n['dominant_type'])}"
                        f"</strong> ({xesc(', '.join(f'{k}={v}' for k, v in n['types'].items()))}; source "
                        f"{xesc(n['instance'])})" for n in an["normalization"]]))
    else:
        B.append(xp("<em>No scalar type normalization candidates.</em>"))
    B.append("<h2>Sharding</h2>")
    shard = [f for f in an["findings"] if f["code"] in ("SHARD_KEY", "SHARD_KEY_LOST")]
    B.append(_x_findings_block(shard) if shard else xp("<em>No sharded source collections.</em>"))
    B.append("<h2>Security</h2>")
    sp = an["security_plan"]
    if sp is None:
        B.append(xp("<em>Security objects not collected (run the collection with --include-security).</em>"))
    else:
        B.append(xp(f"{len(sp['users'])} user(s) and {len(sp['roles'])} custom role(s) will be created by the "
                    f"{xcode('security')} bootstrap phase (passwords are prompted, never exported)."))
        conflicts = [f for f in an["findings"] if f["code"] in ("USER_CONFLICT", "ROLE_CONFLICT")]
        if conflicts:
            B.append(_x_findings_block(conflicts))

    # ---------------------------------------------------------------- comparison
    B.append("<h1>6. Cross-instance comparison</h1>")
    overlap: Dict[str, List[str]] = {}
    for e in an["db_mapping"]:
        overlap.setdefault(e["source_db"], []).append(e["instance"])
    shared = [d for d in sorted(overlap) if len(overlap[d]) > 1]
    B.append("<h2>Database name overlap</h2>")
    B.append(xtable(["Database", "Instances"], [[xcode(d), xesc(", ".join(overlap[d]))] for d in shared])
             if shared else xp("<em>No overlapping database names.</em>"))
    B.append("<h2>Shared namespaces (drift)</h2>")
    if not an["drift"]:
        B.append(xp("<em>No namespaces shared across instances.</em>"))
    for d in an["drift"]:
        items = []
        if d["index_diff"]:
            items.append(f"Indexes: <strong>{len(d['index_diff'])} difference(s)</strong>" + xlist([
                f"{xcode(x['signature'])} present in: {xesc(', '.join(x['present_in']))}; missing in: "
                f"{xesc(', '.join(x['missing_in']))}" for x in d["index_diff"]]))
        else:
            items.append("Indexes: identical")
        if d["options_equal"]:
            items.append("Options: identical")
        else:
            items.append("Options: <strong>differ</strong>" + xlist([f"{xesc(i)}: {xcode(v)}"
                                                                      for i, v in d["options"].items()]))
        if d["type_conflicts"]:
            items.append(f"Field types: <strong>{len(d['type_conflicts'])} conflict(s)</strong>" + xlist([
                f"{xcode(tc['path'])}: " + xesc("; ".join(f"{i}=[{','.join(v)}]" for i, v in tc["types"].items()))
                for tc in d["type_conflicts"]]))
        else:
            items.append("Field types: consistent")
        B.append(f"<h3>{xcode(d['namespace'])} - {xesc(', '.join(d['instances']))}</h3>")
        B.append(xlist(items))

    # ---------------------------------------------------------------- activity / users
    B.append("<h1>7. Activity</h1>")
    if not an["activity"]:
        B.append(xp("<em>Activity not collected.</em>"))
    else:
        B.append(xmacro("info", xp(
            "~ dates come from ObjectId _id values (inserts only, client clock). Last modified comes from date fields "
            "matching the modified pattern: exact through an index or --modified-scan; ≥ is a lower bound taken from "
            "the sampled documents.")))
    for a in an["activity"]:
        B.append(f"<h2>Instance {xcode(a['instance'])}</h2>")
        o, smp = a["oplog"], a["sampling"]
        has_top = any(c["top"] for c in a["collections"])
        has_oplog = o is not None and not o.get("error")
        has_users = has_oplog or smp is not None
        notes = []
        if a["members"]:
            notes.append("Members: " + xesc(", ".join(
                f"{m['host']} ({m['state'] or 'unreachable'}" + (f", up since {m['started_at']}" if m["started_at"]
                                                                  else "") + ")" for m in a["members"])))
        if o is not None:
            notes.append(f"Oplog: {xstatus('ERROR', 'error')} {xesc(o['error'])}" if o.get("error") else
                         f"Oplog: {o['window_hours']} h requested on {xesc(_dash(o['member']))}; analyzed from "
                         f"{xesc(o['from'])} to {xesc(o['oplog_last'])}")
        if smp is not None:
            notes.append(f"Live sampling: {smp['samples']} round(s) every {smp['interval_s']} s on {smp['members']} "
                         f"member(s), {xesc(smp['started_at'])} - {xesc(_dash(smp['finished_at']))}")
        if notes:
            B.append(xlist(notes))
        if not a["collections"]:
            B.append(xp("<em>No collections.</em>"))
            continue
        head = ["Namespace", "_id", "First insert ~", "Last insert ~", "Last modified", "Modified field"]
        if has_top:
            head += ["Reads since restart", "Writes since restart"]
        if has_oplog:
            head += ["Created (oplog)", "Last write (oplog)", "Oplog i/u/d/c"]
        if smp is not None:
            head += ["Sampled ops"]
        if has_users:
            head += ["Users"]
        rows = []
        for c in a["collections"]:
            row = [xcode(c["namespace"]), xesc(_dash(c["id_type"])), xesc(_dash(c["first_insert"])),
                   xesc(_dash(c["last_insert"])), xesc(_modified_cell(c)), xesc(_modified_field_cell(c))]
            tt = c["top"]
            if has_top:
                row += [xesc(_dash(tt["reads"] if tt else None)), xesc(_dash(tt["writes"] if tt else None))]
            op = c["oplog"]
            if has_oplog:
                row += [xesc(_dash(c["created_at"])), xesc(_dash(c["last_write"])),
                        f"{op['inserts']}/{op['updates']}/{op['deletes']}/{op['commands']}" if op else "-"]
            if smp is not None:
                row += [xesc(_dash(c["sampled_ops"]))]
            if has_users:
                users = {u["user"]: u["oplog"] + u["sampled"] for u in c["users"]}
                row += [xesc(_limit(top_users(users, 3), 3))]
            rows.append(row)
        B.append(xtable(head, rows))

    B.append("<h1>8. Users</h1>")
    if not an["users"]:
        B.append(xp("<em>No user information (collect with --include-security and/or --oplog-window / "
                    "--activity-samples).</em>"))
    else:
        rec_colour = {"migrate": "READY", "review": "WARN", "unknown": "INFO"}
        rows = []
        for u in an["users"]:
            rows.append([xesc(u["instance"]), xcode(_user_name(u)), "yes" if u["defined"] else "no",
                         xesc(", ".join(u["access"]) or "-"), xesc(", ".join(u["sources"]) or "-"),
                         str(u["oplog_writes"]), str(u["sampled_ops"]), xesc(_limit(u["namespaces"], 5)),
                         xesc(_limit(_sorted_keys(u["apps"]), 3)), xesc(_limit(_sorted_keys(u["clients"]), 3)),
                         xstatus(rec_colour[u["recommendation"]], u["recommendation"])])
        B.append(xtable(["Instance", "User", "Defined", "Access (source DBs)", "Observed via", "Oplog writes",
                         "Sampled ops", "Namespaces", "Applications", "Clients", "Recommendation"], rows))
        for title, rec in RECOMMENDATIONS:
            items = [u for u in an["users"] if u["recommendation"] == rec]
            B.append(xp(f"<strong>{xesc(title)}:</strong> {len(items)}"))

    # ---------------------------------------------------------------- inventory
    B.append("<h1>9. Inventory</h1>")
    for snap in sorted(snapshots, key=lambda x: x["instance"]["name"]):
        name = snap["instance"]["name"]
        if snap.get("status") != "ok":
            B.append(f"<h2>Instance {xcode(name)}</h2>")
            B.append(xmacro("warning", xp(f"Collection failed: {xesc(snap.get('error') or 'unknown error')}")))
            continue
        rows = []
        for db in sorted(snap.get("databases") or [], key=lambda d: d["name"]):
            for c in sorted(db.get("collections") or [], key=lambda x: x["name"]):
                ctype = c.get("type") or "collection"
                if ctype == "view":
                    rows.append([xcode(db["name"]), xcode(c["name"]), "view"] + ["-"] * 8)
                    continue
                opts = c.get("options") or {}
                st = c.get("stats") or {}
                fields = (c.get("schema") or {}).get("fields") or {}
                mixed = sum(1 for f in fields.values() if classify_types(f.get("types") or {}) == "mixed")
                rows.append([xcode(db["name"]), xcode(c["name"]), xesc(ctype), str(int(st.get("count") or 0)),
                             xesc(human_bytes(st.get("size") or 0)), xesc(human_bytes(st.get("storage_size") or 0)),
                             str(len(c.get("indexes") or [])), xesc(human_bytes(st.get("total_index_size") or 0)),
                             "yes" if opts.get("validator") else "no",
                             xcode(canon(c["shard_key"], False)) if c.get("shard_key") else "-", str(mixed)])
        body = (xtable(["Database", "Collection", "Type", "Documents", "Data", "Storage", "Indexes", "Index size",
                        "Validator", "Shard key", "Mixed-type fields"], rows) if rows
                else xp("<em>No user databases.</em>"))
        B.append(f"<h2>Instance {xcode(name)}</h2>")
        B.append(xmacro("expand", body, [("title", f"{len(rows)} collection(s) / view(s)")]))

    # ---------------------------------------------------------------- runbook
    B.append("<h1>10. Execution runbook</h1>")
    B.append(xlist([xesc(step) for step in RUNBOOK], ordered=True))
    B.append(xmacro("note", xp("Generated by betika_mongodb_normalized. Machine-readable details: "
                               f"{xcode('analysis.json')}; raw snapshots: {xcode('snapshots/')}.")))
    return "\n".join(B) + "\n"
