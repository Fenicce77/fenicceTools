"""Mock Jira + Confluence Data Center REST API for tests/publish_check.sh.

Usage: python3 mock_atlassian.py <port> <log.jsonl> <token>
Logs every request (method, path, query, auth, content type, JSON body) as JSON lines.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3]
issues = {"DBA-7": {"summary": "existing"}}
pages = {"5001": {"title": "Existing page", "space": "DBA", "version": 3}}
seq = {"issue": 100, "page": 9000}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        u = urlparse(self.path)
        entry = {"method": method, "path": u.path, "query": parse_qs(u.query), "auth": self.headers.get("Authorization"),
                 "ctype": (self.headers.get("Content-Type") or "").split(";")[0], "xtoken": self.headers.get("X-Atlassian-Token")}
        try:
            entry["json"] = json.loads(raw) if entry["ctype"] == "application/json" and raw else None
        except ValueError:
            entry["json"] = "INVALID"
        if entry["ctype"] == "multipart/form-data":
            m = re.search(rb'filename="([^"]+)"', raw)
            entry["file"] = m.group(1).decode() if m else None
        with open(LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")
        if entry["auth"] not in (f"Bearer {TOKEN}",):
            return self._send(401, {"message": "Unauthorized"})
        p = u.path
        if method == "POST" and p == "/rest/api/2/issue":
            f = entry["json"]["fields"]
            if not f.get("project", {}).get("key"):
                return self._send(400, {"errorMessages": [], "errors": {"project": "project is required"}})
            seq["issue"] += 1
            key = f"{f['project']['key']}-{seq['issue']}"
            issues[key] = {"summary": f["summary"]}
            return self._send(201, {"id": str(seq["issue"]), "key": key})
        m = re.fullmatch(r"/rest/api/2/issue/([A-Z]+-\d+)", p)
        if m:
            if m.group(1) not in issues:
                return self._send(404, {"errorMessages": ["Issue does not exist or you do not have permission to see it."], "errors": {}})
            if method == "GET":
                return self._send(200, {"key": m.group(1), "fields": issues[m.group(1)]})
            if method == "PUT":
                issues[m.group(1)].update(summary=entry["json"]["fields"]["summary"])
                return self._send(204)
        m = re.fullmatch(r"/rest/api/2/issue/([A-Z]+-\d+)/comment", p)
        if m and method == "POST":
            if m.group(1) not in issues:
                return self._send(404, {"errorMessages": ["Issue does not exist"], "errors": {}})
            vis = (entry["json"] or {}).get("visibility")
            if vis and (vis.get("type") not in ("role", "group") or not vis.get("value")):
                return self._send(400, {"errorMessages": [], "errors": {"visibility": "invalid"}})
            seq["comment"] = seq.get("comment", 20000) + 1
            return self._send(201, {"id": str(seq["comment"]), "body": "..."})
        m = re.fullmatch(r"/rest/api/2/issue/([A-Z]+-\d+)/attachments", p)
        if m and method == "POST":
            if entry["xtoken"] != "no-check":
                return self._send(403, {"message": "XSRF check failed"})
            return self._send(200, [{"filename": entry.get("file")}])
        if p == "/rest/api/content" and method == "GET":
            q = {k: v[0] for k, v in entry["query"].items()}
            res = [{"id": pid, "title": pg["title"], "version": {"number": pg["version"]}}
                   for pid, pg in pages.items() if pg["title"] == q.get("title") and pg["space"] == q.get("spaceKey")]
            return self._send(200, {"results": res, "size": len(res)})
        if p == "/rest/api/content" and method == "POST":
            j = entry["json"]
            seq["page"] += 1
            pid = str(seq["page"])
            pages[pid] = {"title": j["title"], "space": j["space"]["key"], "version": 1}
            return self._send(200, {"id": pid, "version": {"number": 1}})
        m = re.fullmatch(r"/rest/api/content/(\d+)", p)
        if m and method == "PUT":
            pg = pages.get(m.group(1))
            j = entry["json"]
            if pg is None:
                return self._send(404, {"message": "No content found"})
            if j["version"]["number"] != pg["version"] + 1:
                return self._send(409, {"message": f"Version must be incremented on update. Current version is: {pg['version']}"})
            pg["version"] = j["version"]["number"]
            return self._send(200, {"id": m.group(1), "version": {"number": pg["version"]}})
        return self._send(404, {"message": f"no mock route {method} {p}"})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
