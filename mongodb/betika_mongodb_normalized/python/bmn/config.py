"""Instance configuration files (conf/*.conf).

The files are parsed as KEY=VALUE data and are NEVER executed/sourced.
Legacy keys (MONGOHOST, MONGOADMINUSR, MONGOADMINPAS, ADMINDB) are accepted.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import quote

from .common import TOOL_NAME

KEY_RE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
LEGACY_KEYS = {
    "MONGOHOST": "MONGO_HOSTS",
    "MONGOADMINUSR": "MONGO_USER",
    "MONGOADMINPAS": "MONGO_PASSWORD",
    "ADMINDB": "MONGO_AUTH_SOURCE",
}
IGNORED_KEYS = {"MONGOSHBINPATH"}
KNOWN_KEYS = {
    "INSTANCE_ALIAS", "MONGO_ROLE", "MONGO_URI", "MONGO_HOSTS", "MONGO_USER", "MONGO_AUTH_SOURCE",
    "MONGO_PASSWORD_ENV", "MONGO_PASSWORD_FILE", "MONGO_PASSWORD_CMD", "MONGO_PASSWORD", "MONGO_TLS",
    "MONGO_TLS_CA_FILE", "MONGO_TLS_CERT_KEY_FILE", "MONGO_TLS_ALLOW_INVALID_HOSTNAMES", "MONGO_READ_PREFERENCE",
}


class ConfigError(Exception):
    """Invalid or incomplete instance configuration."""


@dataclass
class InstanceConfig:
    name: str
    path: Path
    values: Dict[str, str] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)

    def get(self, key: str, default: str = "") -> str:
        return self.values.get(key, default)

    @property
    def alias(self) -> str:
        return sanitize_alias(self.get("INSTANCE_ALIAS") or self.name)

    @property
    def role(self) -> str:
        return (self.get("MONGO_ROLE") or "source").lower()

    @property
    def user(self) -> str:
        return self.get("MONGO_USER")

    def base_uri(self) -> str:
        if self.get("MONGO_URI"):
            return self.get("MONGO_URI")
        hosts = self.get("MONGO_HOSTS")
        if not hosts:
            raise ConfigError(f"{self.path}: MONGO_URI or MONGO_HOSTS (legacy MONGOHOST) is required")
        if "/" in hosts:
            rs, members = hosts.split("/", 1)
            return f"mongodb://{members}/?replicaSet={quote(rs, safe='')}"
        return f"mongodb://{hosts}/"

    def uri(self, timeout_s: int) -> str:
        """Connection string WITHOUT credentials (credentials are passed separately)."""
        base = self.base_uri()
        head, _, query = base.partition("?")
        scheme_end = head.find("://")
        if scheme_end < 0:
            raise ConfigError(f"{self.path}: invalid connection string")
        if "/" not in head[scheme_end + 3:]:
            head += "/"
        params = [p for p in query.split("&") if p]
        present = {p.split("=", 1)[0].lower() for p in params}

        def add(name: str, value: str) -> None:
            if name.lower() not in present:
                params.append(f"{name}={quote(value, safe='/~:.-_')}")
                present.add(name.lower())

        if self.user:
            add("authSource", self.get("MONGO_AUTH_SOURCE") or "admin")
        add("readPreference", self.get("MONGO_READ_PREFERENCE") or "secondaryPreferred")
        add("appName", TOOL_NAME)
        if truthy(self.get("MONGO_TLS")) and "ssl" not in present:
            add("tls", "true")
        if self.get("MONGO_TLS_CA_FILE"):
            add("tlsCAFile", expand(self.get("MONGO_TLS_CA_FILE")))
        if self.get("MONGO_TLS_CERT_KEY_FILE"):
            add("tlsCertificateKeyFile", expand(self.get("MONGO_TLS_CERT_KEY_FILE")))
        if truthy(self.get("MONGO_TLS_ALLOW_INVALID_HOSTNAMES")):
            add("tlsAllowInvalidHostnames", "true")
        add("serverSelectionTimeoutMS", str(timeout_s * 1000))
        add("connectTimeoutMS", str(timeout_s * 1000))
        return f"{head}?{'&'.join(params)}"

    def resolve_password(self) -> Optional[str]:
        """Resolution order: *_ENV, *_FILE, *_CMD, plain value (discouraged)."""
        if self.get("MONGO_PASSWORD_ENV"):
            var = self.get("MONGO_PASSWORD_ENV")
            value = os.environ.get(var)
            if not value:
                raise ConfigError(f"{self.path}: environment variable {var} is empty or not set")
            return value
        if self.get("MONGO_PASSWORD_FILE"):
            path = Path(expand(self.get("MONGO_PASSWORD_FILE")))
            if not path.is_file():
                raise ConfigError(f"{self.path}: password file {path} not found")
            if path.stat().st_mode & 0o077:
                self.warnings.append(f"password file {path} is accessible by group/others (chmod 600)")
            return path.read_text(encoding="utf-8").splitlines()[0].rstrip("\r") if path.stat().st_size else ""
        if self.get("MONGO_PASSWORD_CMD"):
            try:
                res = subprocess.run(self.get("MONGO_PASSWORD_CMD"), shell=True, check=True, capture_output=True,
                                     text=True, timeout=60)
            except (subprocess.SubprocessError, OSError) as exc:
                raise ConfigError(f"{self.path}: MONGO_PASSWORD_CMD failed: {exc}") from exc
            lines = res.stdout.splitlines()
            return lines[0] if lines else ""
        if self.get("MONGO_PASSWORD"):
            self.warnings.append("plaintext password in config file; prefer MONGO_PASSWORD_ENV/_FILE/_CMD")
            return self.get("MONGO_PASSWORD")
        if self.user:
            raise ConfigError(f"{self.path}: MONGO_USER is set but no password source is configured")
        return None


def truthy(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


def expand(path: str) -> str:
    return os.path.expanduser(path)


def sanitize_alias(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", value)


def redact_uri(uri: str) -> str:
    return re.sub(r"(://)[^@/]+@", r"\1***@", uri)


_DQ_RE = re.compile(r'^"((?:\\.|[^"\\])*)"\s*(?:#.*)?$')
_SQ_RE = re.compile(r"^'([^']*)'\s*(?:#.*)?$")


def _unquote(raw: str) -> str:
    raw = raw.strip()
    match = _DQ_RE.match(raw)
    if match:
        return re.sub(r'\\(["\\$`])', r"\1", match.group(1))
    match = _SQ_RE.match(raw)
    if match:
        return match.group(1)
    return re.sub(r"\s+#.*$", "", raw)


def parse_conf_file(path: Path) -> InstanceConfig:
    cfg = InstanceConfig(name=path.stem, path=path)
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = KEY_RE.match(line)
        if not match:
            cfg.warnings.append(f"line {lineno}: not a KEY=VALUE assignment, ignored")
            continue
        key, raw = match.group(1), match.group(2)
        if key in IGNORED_KEYS:
            continue
        value = _unquote(raw)
        if "`" in value or "$(" in value:
            cfg.warnings.append(f"line {lineno}: {key} contains command substitution; ignored (never executed)")
            continue
        key = LEGACY_KEYS.get(key, key)
        if key not in KNOWN_KEYS:
            cfg.warnings.append(f"line {lineno}: unknown key {key}")
            continue
        cfg.values[key] = value
    if cfg.get("MONGO_PASSWORD") and path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        cfg.warnings.append(f"{path} holds a plaintext password and is readable by group/others (chmod 600)")
    if cfg.role not in ("source", "target"):
        raise ConfigError(f"{path}: MONGO_ROLE must be 'source' or 'target'")
    return cfg


def load_configs(conf_dir: Path, only: Optional[List[str]] = None) -> List[InstanceConfig]:
    if not conf_dir.is_dir():
        raise ConfigError(f"configuration directory not found: {conf_dir}")
    files = sorted(conf_dir.glob("*.conf"))
    configs = [parse_conf_file(p) for p in files]
    if only:
        wanted = set(only)
        configs = [c for c in configs if c.name in wanted or c.alias in wanted]
        missing = wanted - {c.name for c in configs} - {c.alias for c in configs}
        if missing:
            raise ConfigError(f"unknown instance(s): {', '.join(sorted(missing))}")
    if not configs:
        raise ConfigError(f"no *.conf files found in {conf_dir}")
    aliases: Dict[str, str] = {}
    for c in configs:
        if c.alias in aliases:
            raise ConfigError(f"duplicate alias '{c.alias}' in {aliases[c.alias]} and {c.path.name}")
        aliases[c.alias] = c.path.name
    return configs


def load_mappings(path: Optional[Path]) -> List[Dict[str, str]]:
    """Mapping file lines: <instance|alias>:<source_db>=<target_db>  ('#' comments)."""
    if path is None:
        return []
    entries = []
    rx = re.compile(r"^([^:\s]+):([^=\s]+)=(\S+)$")
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        m = rx.match(line)
        if not m:
            raise ConfigError(f"{path}:{lineno}: expected '<instance>:<source_db>=<target_db>'")
        entries.append({"instance": m.group(1), "source_db": m.group(2), "target_db": m.group(3)})
    return entries
