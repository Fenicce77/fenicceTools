"""Publication of the generated reports to Jira and Confluence Data Center / Server (REST API).

Mirrored in bash (lib/publish.sh + lib/atlassian.js). Configuration: <conf-dir>/atlassian.conf,
parsed as KEY=VALUE data (never sourced). Authentication: Personal Access Token (Bearer) or,
when *_USER is set, HTTP basic with the token as password (servers without PAT support).

Results are written to <report-dir>/publish.json; the Jira issue key stored there is reused by
later publications of the same report directory.
"""
from __future__ import annotations

import base64
import json
import os
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .common import TOOL_NAME, TOOL_VERSION
from .config import KEY_RE, ConfigError, _unquote, expand
from .ui import Log

ATL_KEYS = {
    "JIRA_URL", "JIRA_USER", "JIRA_TOKEN_ENV", "JIRA_TOKEN_FILE", "JIRA_TOKEN_CMD", "JIRA_TOKEN", "JIRA_PROJECT",
    "JIRA_ISSUE_TYPE", "JIRA_ISSUE", "JIRA_SUMMARY", "JIRA_LABELS", "JIRA_COMPONENTS", "JIRA_ATTACH",
    "JIRA_COMMENT_VISIBILITY",
    "CONFLUENCE_URL", "CONFLUENCE_USER", "CONFLUENCE_TOKEN_ENV", "CONFLUENCE_TOKEN_FILE", "CONFLUENCE_TOKEN_CMD",
    "CONFLUENCE_TOKEN", "CONFLUENCE_SPACE", "CONFLUENCE_PARENT_ID", "CONFLUENCE_TITLE",
    "ATLASSIAN_CA_FILE", "ATLASSIAN_TIMEOUT",
}
DEFAULT_ATTACHMENTS = ("report.md", "centralization_plan.md", "analysis.json")
DEFAULT_TITLE = "MongoDB schema centralization analysis"


class PublishError(Exception):
    """Publication failure (configuration, HTTP or API error)."""


@dataclass
class AtlassianConfig:
    path: Optional[Path]
    values: Dict[str, str] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)

    def get(self, key: str, default: str = "") -> str:
        return self.values.get(key, default)


def load_atlassian_conf(path: Path) -> AtlassianConfig:
    cfg = AtlassianConfig(path=path)
    if not path.is_file():
        return cfg
    if path.stat().st_mode & 0o077:
        cfg.warnings.append(f"{path} is accessible by group/others (chmod 600)")
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = KEY_RE.match(line)
        if not m:
            cfg.warnings.append(f"{path.name}:{lineno}: not a KEY=VALUE assignment, ignored")
            continue
        key, value = m.group(1), _unquote(m.group(2))
        if "`" in value or "$(" in value:
            cfg.warnings.append(f"{path.name}:{lineno}: {key} contains command substitution; ignored")
            continue
        if key not in ATL_KEYS:
            cfg.warnings.append(f"{path.name}:{lineno}: unknown key {key}")
            continue
        cfg.values[key] = value
    return cfg


def resolve_token(cfg: AtlassianConfig, product: str) -> str:
    """Order: <P>_TOKEN_ENV, <P>_TOKEN_FILE, <P>_TOKEN_CMD, <P>_TOKEN (plaintext, warned)."""
    p = product.upper()
    if cfg.get(f"{p}_TOKEN_ENV"):
        var = cfg.get(f"{p}_TOKEN_ENV")
        value = os.environ.get(var, "")
        if not value:
            raise PublishError(f"{p}_TOKEN_ENV: environment variable {var} is empty or not set")
        return value
    if cfg.get(f"{p}_TOKEN_FILE"):
        tf = Path(expand(cfg.get(f"{p}_TOKEN_FILE")))
        if not tf.is_file():
            raise PublishError(f"{p}_TOKEN_FILE: {tf} not found")
        if tf.stat().st_mode & 0o077:
            cfg.warnings.append(f"token file {tf} is accessible by group/others (chmod 600)")
        lines = tf.read_text(encoding="utf-8").splitlines()
        return lines[0].strip() if lines else ""
    if cfg.get(f"{p}_TOKEN_CMD"):
        try:
            res = subprocess.run(cfg.get(f"{p}_TOKEN_CMD"), shell=True, check=True, capture_output=True, text=True,
                                 timeout=60)
        except (subprocess.SubprocessError, OSError) as exc:
            raise PublishError(f"{p}_TOKEN_CMD failed: {exc}") from exc
        lines = res.stdout.splitlines()
        return lines[0].strip() if lines else ""
    if cfg.get(f"{p}_TOKEN"):
        cfg.warnings.append(f"plaintext {p}_TOKEN in {cfg.path}; prefer {p}_TOKEN_ENV/_FILE/_CMD")
        return cfg.get(f"{p}_TOKEN")
    raise PublishError(f"no {p} token configured ({p}_TOKEN_ENV, {p}_TOKEN_FILE or {p}_TOKEN_CMD)")


class Client:
    """Minimal REST client (stdlib only)."""

    def __init__(self, base_url: str, token: str, user: str, ca_file: str, timeout: int) -> None:
        self.base = base_url.rstrip("/")
        if user:
            creds = base64.b64encode(f"{user}:{token}".encode("utf-8")).decode("ascii")
            self.auth = f"Basic {creds}"
        else:
            self.auth = f"Bearer {token}"
        self.timeout = timeout
        self.ctx = ssl.create_default_context(cafile=expand(ca_file) if ca_file else None)

    def request(self, method: str, path: str, body: Optional[bytes] = None,
                headers: Optional[Dict[str, str]] = None) -> Tuple[int, Any]:
        req = urllib.request.Request(self.base + path, data=body, method=method)
        req.add_header("Authorization", self.auth)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", f"{TOOL_NAME}/{TOOL_VERSION}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self.ctx) as resp:
                raw = resp.read()
                code = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            code = exc.code
        except (urllib.error.URLError, OSError) as exc:
            raise PublishError(f"{method} {self.base}{path}: {getattr(exc, 'reason', exc)}") from exc
        try:
            data = json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            data = raw.decode("utf-8", "replace")[:300]
        return code, data

    def json(self, method: str, path: str, payload: Any) -> Tuple[int, Any]:
        return self.request(method, path, json.dumps(payload).encode("utf-8"), {"Content-Type": "application/json"})

    def attach(self, path: str, file_path: Path) -> Tuple[int, Any]:
        boundary = f"----bmn{uuid.uuid4().hex}"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_path.name}\"\r\n"
                "Content-Type: application/octet-stream\r\n\r\n").encode("utf-8")
        body += file_path.read_bytes() + f"\r\n--{boundary}--\r\n".encode("utf-8")
        return self.request("POST", path, body, {"Content-Type": f"multipart/form-data; boundary={boundary}",
                                                 "X-Atlassian-Token": "no-check"})


def api_error(code: int, data: Any) -> str:
    """Human readable error from a Jira / Confluence error payload."""
    if isinstance(data, dict):
        parts = list(data.get("errorMessages") or [])
        parts += [f"{k}: {v}" for k, v in sorted((data.get("errors") or {}).items())]
        if data.get("message"):
            parts.append(str(data["message"]))
        if parts:
            return f"HTTP {code}: " + "; ".join(parts)
    return f"HTTP {code}: {str(data)[:300] if data else 'no response body'}"


# ------------------------------------------------------------------------------------------- payloads
def jira_summary(an: dict, cfg: AtlassianConfig) -> str:
    if cfg.get("JIRA_SUMMARY"):
        return cfg.get("JIRA_SUMMARY")
    s = an["summary"]
    status = "BLOCKED" if s["errors"] else "READY"
    return (f"{DEFAULT_TITLE} - {status} ({s['errors']} errors, {s['warnings']} warnings) - "
            f"{an['generated_at'][:10]}")


def split_list(value: str) -> List[str]:
    return [x.strip() for x in value.split(",") if x.strip()]


def jira_create_payload(an: dict, cfg: AtlassianConfig, description: str) -> dict:
    fields: Dict[str, Any] = {
        "project": {"key": cfg.get("JIRA_PROJECT")},
        "issuetype": {"name": cfg.get("JIRA_ISSUE_TYPE") or "Task"},
        "summary": jira_summary(an, cfg),
        "description": description,
        "labels": split_list(cfg.get("JIRA_LABELS") or "mongodb,schema-centralization"),
    }
    components = split_list(cfg.get("JIRA_COMPONENTS"))
    if components:
        fields["components"] = [{"name": c} for c in components]
    return {"fields": fields}


def jira_update_payload(an: dict, cfg: AtlassianConfig, description: str) -> dict:
    return {"fields": {"summary": jira_summary(an, cfg), "description": description}}


def jira_comment_payload(cfg: AtlassianConfig, body: str) -> dict:
    """Comment body; JIRA_COMMENT_VISIBILITY="role:<project role>" or "group:<group>" restricts who sees it."""
    payload: Dict[str, Any] = {"body": body}
    vis = cfg.get("JIRA_COMMENT_VISIBILITY").strip()
    if vis:
        kind, _, value = vis.partition(":")
        if kind.strip() not in ("role", "group") or not value.strip():
            raise PublishError(f"JIRA_COMMENT_VISIBILITY must be 'role:<name>' or 'group:<name>' (got '{vis}')")
        payload["visibility"] = {"type": kind.strip(), "value": value.strip()}
    return payload


def confluence_payload(cfg: AtlassianConfig, title: str, body: str, page: Optional[dict], an: dict) -> dict:
    payload: Dict[str, Any] = {"type": "page", "title": title, "space": {"key": cfg.get("CONFLUENCE_SPACE")},
                               "body": {"storage": {"value": body, "representation": "storage"}}}
    if page is None:
        if cfg.get("CONFLUENCE_PARENT_ID"):
            payload["ancestors"] = [{"id": cfg.get("CONFLUENCE_PARENT_ID")}]
    else:
        payload["id"] = page["id"]
        payload["version"] = {"number": int(page["version"]) + 1,
                              "message": f"{TOOL_NAME} analysis {an['generated_at']}"}
    return payload


# ------------------------------------------------------------------------------------------- publishers
def _require(cfg: AtlassianConfig, keys: List[str], product: str) -> None:
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        where = cfg.path if cfg.path and cfg.path.is_file() else f"{cfg.path} (not found)"
        raise PublishError(f"{product}: missing {', '.join(missing)} in {where}")


def _client(cfg: AtlassianConfig, product: str) -> Client:
    p = product.upper()
    timeout = int(cfg.get("ATLASSIAN_TIMEOUT") or "60")
    return Client(cfg.get(f"{p}_URL"), resolve_token(cfg, product), cfg.get(f"{p}_USER"),
                  cfg.get("ATLASSIAN_CA_FILE"), timeout)


def publish_jira_comment(report_dir: Path, cfg: AtlassianConfig, issue: str, attach: bool, dry_run: bool,
                         state: dict) -> dict:
    """Adds report.jira.txt as a comment to an existing issue (summary and description untouched)."""
    if not issue:
        raise PublishError("--jira-comment requires an issue key (--jira-issue KEY or JIRA_ISSUE)")
    _require(cfg, ["JIRA_URL"], "Jira")
    body = (report_dir / "report.jira.txt").read_text(encoding="utf-8")
    payload = jira_comment_payload(cfg, body)
    client = _client(cfg, "jira")
    base = cfg.get("JIRA_URL").rstrip("/")
    key = urllib.parse.quote(issue)
    code, data = client.request("GET", f"/rest/api/2/issue/{key}?fields=summary")
    if code != 200:
        raise PublishError(f"Jira issue {issue}: {api_error(code, data)}")
    result: Dict[str, Any] = {"issue": issue, "comment_id": None, "url": f"{base}/browse/{issue}", "attachments": []}
    vis = payload.get("visibility")
    vis_text = f", visible to {vis['type']} {vis['value']}" if vis else ""
    if dry_run:
        Log.info(f"[dry-run] Jira: POST {base}/rest/api/2/issue/{issue}/comment ({len(body)} chars{vis_text})")
    else:
        code, data = client.json("POST", f"/rest/api/2/issue/{key}/comment", payload)
        if code not in (200, 201) or not isinstance(data, dict) or not data.get("id"):
            raise PublishError(f"Jira comment on {issue}: {api_error(code, data)}")
        cid = str(data["id"])
        result["comment_id"] = cid
        result["url"] = f"{base}/browse/{issue}?focusedCommentId={cid}#comment-{cid}"
        Log.ok(f"Jira: commented on {issue} (comment {cid}{vis_text})")
    if attach:
        result["attachments"] = _jira_attach(report_dir, cfg, client, issue, dry_run)
    state["jira_comment"] = result
    return result


def _jira_attach(report_dir: Path, cfg: AtlassianConfig, client: Client, issue: str, dry_run: bool) -> List[str]:
    done: List[str] = []
    for name in split_list(cfg.get("JIRA_ATTACH")) or list(DEFAULT_ATTACHMENTS):
        fp = report_dir / name
        if not fp.is_file():
            Log.warn(f"Jira: attachment {name} not found in {report_dir}")
            continue
        if dry_run or not issue:
            Log.info(f"[dry-run] Jira: attach {name} ({fp.stat().st_size} bytes)")
            continue
        code, data = client.attach(f"/rest/api/2/issue/{urllib.parse.quote(issue)}/attachments", fp)
        if code not in (200, 201):
            raise PublishError(f"Jira attach {name}: {api_error(code, data)}")
        done.append(name)
        Log.ok(f"Jira: attached {name}")
    return done


def publish_jira(report_dir: Path, an: dict, cfg: AtlassianConfig, issue: str, attach: bool,
                 dry_run: bool, state: dict) -> dict:
    _require(cfg, ["JIRA_URL"] + ([] if issue else ["JIRA_PROJECT"]), "Jira")
    description = (report_dir / "report.jira.txt").read_text(encoding="utf-8")
    client = _client(cfg, "jira")
    base = cfg.get("JIRA_URL").rstrip("/")
    result: Dict[str, Any] = {"issue": issue or None, "action": None, "url": None, "attachments": []}
    if issue:
        code, data = client.request("GET", f"/rest/api/2/issue/{urllib.parse.quote(issue)}?fields=summary")
        if code != 200:
            raise PublishError(f"Jira issue {issue}: {api_error(code, data)}")
        result["action"] = "update"
        if dry_run:
            Log.info(f"[dry-run] Jira: PUT {base}/rest/api/2/issue/{issue} (summary + description, "
                     f"{len(description)} chars)")
        else:
            code, data = client.json("PUT", f"/rest/api/2/issue/{urllib.parse.quote(issue)}",
                                     jira_update_payload(an, cfg, description))
            if code not in (200, 204):
                raise PublishError(f"Jira update {issue}: {api_error(code, data)}")
            Log.ok(f"Jira: updated {issue}")
    else:
        result["action"] = "create"
        payload = jira_create_payload(an, cfg, description)
        if dry_run:
            Log.info(f"[dry-run] Jira: POST {base}/rest/api/2/issue (project {cfg.get('JIRA_PROJECT')}, type "
                     f"{payload['fields']['issuetype']['name']}, summary '{payload['fields']['summary']}', "
                     f"{len(description)} chars)")
        else:
            code, data = client.json("POST", "/rest/api/2/issue", payload)
            if code not in (200, 201) or not isinstance(data, dict) or not data.get("key"):
                raise PublishError(f"Jira create: {api_error(code, data)}")
            issue = data["key"]
            result["issue"] = issue
            Log.ok(f"Jira: created {issue}")
    if issue:
        result["url"] = f"{base}/browse/{issue}"
    if attach:
        result["attachments"] = _jira_attach(report_dir, cfg, client, issue, dry_run)
    state["jira"] = result
    return result


def publish_confluence(report_dir: Path, an: dict, cfg: AtlassianConfig, title: str, dry_run: bool,
                       state: dict) -> dict:
    _require(cfg, ["CONFLUENCE_URL", "CONFLUENCE_SPACE"], "Confluence")
    body = (report_dir / "report.confluence.xml").read_text(encoding="utf-8")
    title = title or cfg.get("CONFLUENCE_TITLE") or DEFAULT_TITLE
    client = _client(cfg, "confluence")
    base = cfg.get("CONFLUENCE_URL").rstrip("/")
    query = urllib.parse.urlencode({"spaceKey": cfg.get("CONFLUENCE_SPACE"), "title": title, "type": "page",
                                    "expand": "version"})
    code, data = client.request("GET", f"/rest/api/content?{query}")
    if code != 200 or not isinstance(data, dict):
        raise PublishError(f"Confluence search: {api_error(code, data)}")
    results = data.get("results") or []
    page = ({"id": str(results[0]["id"]), "version": int((results[0].get("version") or {}).get("number") or 1)}
            if results else None)
    payload = confluence_payload(cfg, title, body, page, an)
    result: Dict[str, Any] = {"page_id": page["id"] if page else None, "title": title,
                              "action": "update" if page else "create", "version": None, "url": None}
    if dry_run:
        what = (f"PUT {base}/rest/api/content/{page['id']} (version {page['version']} -> {page['version'] + 1})"
                if page else f"POST {base}/rest/api/content (new page in space {cfg.get('CONFLUENCE_SPACE')}"
                + (f", parent {cfg.get('CONFLUENCE_PARENT_ID')})" if cfg.get("CONFLUENCE_PARENT_ID") else ")"))
        Log.info(f"[dry-run] Confluence: {what} '{title}', {len(body)} chars")
    else:
        if page:
            code, data = client.json("PUT", f"/rest/api/content/{page['id']}", payload)
        else:
            code, data = client.json("POST", "/rest/api/content", payload)
        if code not in (200, 201) or not isinstance(data, dict) or not data.get("id"):
            raise PublishError(f"Confluence {result['action']}: {api_error(code, data)}")
        result["page_id"] = str(data["id"])
        result["version"] = int((data.get("version") or {}).get("number") or 1)
        Log.ok(f"Confluence: {result['action']}d page {result['page_id']} '{title}' (version {result['version']})")
    if result["page_id"]:
        result["url"] = f"{base}/pages/viewpage.action?pageId={result['page_id']}"
    state["confluence"] = result
    return result


def publish(report_dir: Path, conf_path: Path, jira: bool, confluence: bool, dry_run: bool,
            jira_issue: str = "", jira_attach: bool = False, confluence_title: str = "",
            jira_comment: bool = False) -> int:
    """Returns 0 on success, 4 on any publication failure."""
    for name in ("analysis.json",) + (("report.jira.txt",) if jira else ()) + \
            (("report.confluence.xml",) if confluence else ()):
        if not (report_dir / name).is_file():
            raise ConfigError(f"{report_dir / name} not found: run 'analyze' first")
    an = json.loads((report_dir / "analysis.json").read_text(encoding="utf-8"))
    cfg = load_atlassian_conf(conf_path)
    state_file = report_dir / "publish.json"
    state: Dict[str, Any] = {}
    if state_file.is_file():
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except ValueError:
            state = {}
    failures = 0
    done: List[str] = []
    if jira and jira_comment:
        try:  # explicit key only: never comment on the issue remembered in publish.json by mistake
            publish_jira_comment(report_dir, cfg, jira_issue or cfg.get("JIRA_ISSUE"), jira_attach, dry_run, state)
            done.append("jira_comment")
        except PublishError as exc:
            failures += 1
            Log.error(f"Jira: {exc}")
    elif jira:
        issue = jira_issue or cfg.get("JIRA_ISSUE") or ((state.get("jira") or {}).get("issue") or "")
        try:
            publish_jira(report_dir, an, cfg, issue, attach=jira_attach, dry_run=dry_run, state=state)
            done.append("jira")
        except PublishError as exc:
            failures += 1
            Log.error(f"Jira: {exc}")
    if confluence:
        try:
            publish_confluence(report_dir, an, cfg, confluence_title, dry_run, state)
            done.append("confluence")
        except PublishError as exc:
            failures += 1
            Log.error(f"Confluence: {exc}")
    for w in cfg.warnings:
        Log.warn(w)
    if not dry_run and done:
        state["published_at_analysis"] = an["generated_at"]
        state_file.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        state_file.chmod(0o600)
        labels = {"jira": "Jira", "jira_comment": "Jira", "confluence": "Confluence"}
        for product in done:
            if (state.get(product) or {}).get("url"):
                print(f"  {labels[product]:10s}: {state[product]['url']}")
    return 4 if failures else 0
