"""Credential resolution shared by the monitoringTools Python scripts.

Config files keep the legacy ``KEY="value"`` / ``export KEY="value"`` format
(they are parsed as data, never executed). Password sources, first defined wins:

    MONGOADMINPAS_ENV   name of an environment variable holding the password
    MONGOADMINPAS_FILE  file whose first line is the password (chmod 600)
    MONGOADMINPAS_CMD   command printing the password (Keychain, pass, vault...)
    MONGOADMINPAS       plaintext password (legacy, still accepted, warned)

The password is handed to MongoClient as a keyword argument, so it is never
embedded in a connection string that could end up in an error message or log.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
from typing import Any, Dict, Optional

RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"

_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class CredentialError(Exception):
    """Raised when the configured password source cannot be resolved."""


def warn(message: str) -> None:
    print(f"{YELLOW}Warning: {message}{RESET}", file=sys.stderr)


def die(message: str, code: int = 2) -> None:
    print(f"{RED}Error: {message}{RESET}", file=sys.stderr)
    sys.exit(code)


def parse_config(config_path: str) -> Dict[str, str]:
    """Parse a KEY=VALUE config file without executing it."""
    config: Dict[str, str] = {}
    with open(config_path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            config[key.strip()] = _config_value(value.strip())
    return config


def _config_value(value: str) -> str:
    """Quoted value up to its closing quote; unquoted value up to an inline ' #'."""
    if value[:1] in ("\"", "'", "`"):
        end = value.find(value[0], 1)
        return value[1:end] if end > 0 else value[1:]
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def _group_other_access(path: str) -> bool:
    return bool(os.stat(path).st_mode & (stat.S_IRWXG | stat.S_IRWXO))


def resolve_password(config: Dict[str, str]) -> Optional[str]:
    """Return the password from the first configured source (None if no auth)."""
    env_name = config.get("MONGOADMINPAS_ENV", "")
    pwd_file = config.get("MONGOADMINPAS_FILE", "")
    pwd_cmd = config.get("MONGOADMINPAS_CMD", "")
    plaintext = config.get("MONGOADMINPAS", "")

    if env_name:
        if not _ENV_NAME.match(env_name):
            raise CredentialError(f"invalid MONGOADMINPAS_ENV name '{env_name}'")
        value = os.environ.get(env_name, "")
        if not value:
            raise CredentialError(f"environment variable {env_name} (MONGOADMINPAS_ENV) is empty or not set")
        return value
    if pwd_file:
        path = os.path.expanduser(pwd_file)
        if not os.access(path, os.R_OK):
            raise CredentialError(f"password file {path} (MONGOADMINPAS_FILE) is not readable")
        if _group_other_access(path):
            warn(f"password file {path} is accessible by group/others (chmod 600 {path})")
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.readline().rstrip("\r\n")
        if not value:
            raise CredentialError(f"password file {path} is empty")
        return value
    if pwd_cmd:
        result = subprocess.run(["bash", "-c", pwd_cmd], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise CredentialError(f"MONGOADMINPAS_CMD failed (exit {result.returncode})")
        value = (result.stdout.splitlines() or [""])[0]
        if not value:
            raise CredentialError("MONGOADMINPAS_CMD returned an empty password")
        return value
    if plaintext:
        if not os.environ.get("MT_QUIET_PLAINTEXT_WARNING"):
            warn("plaintext MONGOADMINPAS in config; prefer MONGOADMINPAS_ENV/_FILE/_CMD")
        return plaintext
    if config.get("MONGOADMINUSR"):
        raise CredentialError("MONGOADMINUSR is set but no password source is configured (MONGOADMINPAS_ENV/_FILE/_CMD)")
    return None


def client_settings(config: Dict[str, str]) -> Dict[str, Any]:
    """Build MongoClient(**settings) from the config: host list + auth kwargs.

    MONGOHOST accepts "rsName/node1,node2" (replica set) or "host[:port][,host...]".
    """
    host = config.get("MONGOHOST", "")
    if not host:
        raise CredentialError("MONGOHOST is not defined in the config file")
    settings: Dict[str, Any] = {}
    if "/" in host:
        replset, nodes = host.split("/", 1)
        settings["replicaSet"] = replset
    else:
        nodes = host
    settings["host"] = [n.strip() for n in nodes.split(",") if n.strip()]
    password = resolve_password(config)
    user = config.get("MONGOADMINUSR", "")
    if user:
        settings["username"] = user
        settings["password"] = password
        settings["authSource"] = config.get("ADMINDB") or "admin"
    return settings
