"""Command line interface."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List, Optional

from . import __version__
from .activity import ActivityOptions
from .analyzer import AnalysisParams, analyze
from .collector import CollectOptions, base_snapshot, collect_instance
from .common import PROJECT_HOME, TOOL_NAME, human_bytes
from .config import ConfigError, InstanceConfig, load_configs, load_mappings, redact_uri
from .renderers import write_artifacts
from .help import render_help, wants_color
from .ui import Log, Style

PROG = "mongo_schema_normalizer.py"
PROJECT_ROOT = Path(os.environ.get("BMN_PROJECT_ROOT") or PROJECT_HOME.parent)

class CliArgumentParser(argparse.ArgumentParser):
    """argparse with the custom colored help and short colored usage errors."""

    def print_help(self, file=None) -> None:  # noqa: D401
        (file or sys.stdout).write(render_help(PROG, wants_color(sys.argv[1:])))

    def error(self, message: str) -> None:  # type: ignore[override]
        Log.error(message)
        print(f"Run '{Style.paint(PROG + ' --help', 'bold')}' for usage.", file=sys.stderr)
        sys.exit(2)


def build_parser() -> argparse.ArgumentParser:
    p = CliArgumentParser(prog=PROG, add_help=False)
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("command", nargs="?", default="run", choices=("run", "collect", "analyze", "check"))
    p.add_argument("-c", "--conf-dir", type=Path, default=PROJECT_ROOT / "conf",
                   help="instance configuration directory (default: %(default)s)")
    p.add_argument("-o", "--output-dir", type=Path, help="output directory (default: <project_root>/reports/<UTC ts>)")
    p.add_argument("-s", "--snapshot-dir", type=Path, help="analyze: existing snapshot directory")
    p.add_argument("-i", "--instances", help="comma-separated subset of instance names or aliases")
    p.add_argument("-t", "--target", default="", help="instance acting as central target (or MONGO_ROLE=target)")
    p.add_argument("-n", "--naming-strategy", choices=("auto", "keep", "prefix"), default="auto",
                   help="auto: prefix only conflicting DBs | keep | prefix: always <alias><sep><db> (default: auto)")
    p.add_argument("--prefix-sep", default="_", help="separator between alias and database (default: '_')")
    p.add_argument("-m", "--mapping-file", type=Path, help="explicit database mapping overrides")
    p.add_argument("--sample-size", type=int, default=100, help="documents sampled per collection, 0 disables")
    p.add_argument("--max-depth", type=int, default=5, help="max nesting depth for field paths (default: 5)")
    p.add_argument("--include-dbs", help="regex of databases to include")
    p.add_argument("--exclude-dbs", help="regex of databases to exclude")
    p.add_argument("--include-security", action="store_true", help="collect users and custom roles")
    p.add_argument("-p", "--parallel", type=int, default=4, help="instances collected in parallel (default: 4)")
    p.add_argument("--timeout", type=int, default=15, help="connection timeout in seconds (default: 15)")
    p.add_argument("--op-timeout", type=int, default=120, help="per-operation maxTimeMS in seconds (default: 120)")
    p.add_argument("--connect", action="store_true", help="check: also test connectivity")
    p.add_argument("--no-activity", action="store_true", help="skip activity collection")
    p.add_argument("--oplog-window", type=int, default=0, help="hours of oplog to analyze, 0 disables")
    p.add_argument("--oplog-timeout", type=int, default=600, help="oplog aggregation maxTimeMS in seconds")
    p.add_argument("--activity-samples", type=int, default=0, help="$currentOp sampling rounds, 0 disables")
    p.add_argument("--activity-interval", type=int, default=10, help="seconds between sampling rounds")
    p.add_argument("--member-stats", action="store_true", help="per-member top counters")
    p.add_argument("--modified-pattern", default="modif", help="regex for last-modification date fields")
    p.add_argument("--modified-scan", action="store_true", help="exact max of unindexed modified fields")
    p.add_argument("--stale-days", type=int, default=180, help="STALE_COLLECTION threshold, 0 disables")
    p.add_argument("--no-color", action="store_true", help="disable colored output")
    p.add_argument("-v", "--verbose", action="store_true", help="verbose output")
    p.add_argument("-V", "--version", action="version", version=f"{TOOL_NAME} {__version__}")
    return p


def _utc_ts() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load(args: argparse.Namespace) -> List[InstanceConfig]:
    only = [x.strip() for x in args.instances.split(",") if x.strip()] if args.instances else None
    configs = load_configs(args.conf_dir, only)
    targets = [c for c in configs if c.role == "target"]
    if len(targets) > 1 and not args.target:
        raise ConfigError("more than one config declares MONGO_ROLE=target; use --target")
    if args.target and args.target not in {c.name for c in configs} | {c.alias for c in configs}:
        raise ConfigError(f"--target '{args.target}' does not match any configuration")
    if args.target:
        args.target = next(c.name for c in configs if args.target in (c.name, c.alias))
    return configs


def cmd_check(args: argparse.Namespace) -> int:
    configs = _load(args)
    failures = 0
    for cfg in configs:
        role = "target" if cfg.name == args.target or (not args.target and cfg.role == "target") else "source"
        Log.title(f"{cfg.name} (alias={cfg.alias}, role={role})")
        try:
            uri = cfg.uri(args.timeout)
            Log.info(f"uri: {redact_uri(uri)}")
            src = next((k for k in ("MONGO_PASSWORD_ENV", "MONGO_PASSWORD_FILE", "MONGO_PASSWORD_CMD", "MONGO_PASSWORD")
                        if cfg.get(k)), "none")
            Log.info(f"user: {cfg.user or '(no auth)'} | password source: {src}")
            if args.connect:
                from pymongo import MongoClient
                client = MongoClient(uri, username=cfg.user or None, password=cfg.resolve_password(),
                                     datetime_conversion="DATETIME_AUTO")
                version = client.admin.command("buildInfo")["version"]
                client.close()
                Log.ok(f"connected, MongoDB {version}")
            for w in cfg.warnings:
                Log.warn(w)
        except Exception as exc:  # noqa: BLE001
            failures += 1
            Log.error(str(exc))
    return 2 if failures else 0


def cmd_collect(args: argparse.Namespace, out_dir: Path) -> int:
    configs = _load(args)
    snap_dir = out_dir / "snapshots"
    snap_dir.mkdir(parents=True, exist_ok=True)
    for name in ("sample_size", "max_depth", "parallel", "timeout", "op_timeout", "oplog_window", "oplog_timeout",
                 "activity_samples", "activity_interval"):
        if getattr(args, name) < 0:
            raise ConfigError(f"--{name.replace('_', '-')} must be a non-negative integer")
    if args.no_activity and (args.oplog_window or args.activity_samples or args.member_stats or args.modified_scan):
        raise ConfigError("--no-activity cannot be combined with other activity options")
    try:
        activity = ActivityOptions(not args.no_activity, args.oplog_window, args.oplog_timeout,
                                   args.activity_samples, args.activity_interval, args.member_stats,
                                   args.modified_pattern, args.modified_scan)
    except re.error as exc:
        raise ConfigError(f"invalid --modified-pattern: {exc}") from exc
    opts = CollectOptions(args.sample_size, args.max_depth, args.timeout, args.op_timeout,
                          args.include_dbs, args.exclude_dbs, args.include_security, activity)
    Log.title(f"collecting {len(configs)} instance(s) -> {snap_dir}")
    failures = 0

    def job(cfg: InstanceConfig) -> dict:
        Log.info(f"{cfg.name}: collecting...")
        try:
            return collect_instance(cfg, opts)
        except ConfigError as exc:
            snap = base_snapshot(cfg, "", "python", opts)
            snap["error"] = str(exc)
            return snap

    with ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        futures = {pool.submit(job, cfg): cfg for cfg in configs}
        for fut in as_completed(futures):
            cfg = futures[fut]
            snap = fut.result()
            if cfg.name == args.target:
                snap["instance"]["role"] = "target"
            for w in cfg.warnings:
                Log.warn(f"{cfg.name}: {w}")
            (snap_dir / f"{cfg.name}.json").write_text(json.dumps(snap, indent=2, ensure_ascii=False) + "\n",
                                                        encoding="utf-8")
            if snap["status"] == "ok":
                dbs = len(snap["databases"])
                colls = sum(len(d["collections"]) for d in snap["databases"])
                Log.ok(f"{cfg.name}: MongoDB {snap['server'].get('version')} ({snap['server'].get('topology')}),"
                       f" {dbs} database(s), {colls} collection(s)")
            else:
                failures += 1
                Log.error(f"{cfg.name}: {snap['error']}")
    return 3 if failures else 0


def cmd_analyze(args: argparse.Namespace, snap_dir: Path, out_dir: Path) -> int:
    files = sorted(snap_dir.glob("*.json"))
    if not files:
        raise ConfigError(f"no snapshots found in {snap_dir}")
    snapshots = [json.loads(f.read_text(encoding="utf-8")) for f in files]
    params = AnalysisParams(
        naming_strategy=args.naming_strategy, prefix_sep=args.prefix_sep, target=args.target or "",
        mappings=load_mappings(args.mapping_file),
        generated_at=os.environ.get("BMN_GENERATED_AT") or _utc_iso(), implementation="python",
        stale_days=args.stale_days)
    if args.stale_days < 0:
        raise ConfigError("--stale-days must be a non-negative integer")
    Log.title(f"analyzing {len(snapshots)} snapshot(s) from {snap_dir}")
    an = analyze(snapshots, params)
    written = write_artifacts(an, snapshots, out_dir)
    print_summary(an, out_dir, [p.name for p in written])
    return 1 if an["summary"]["errors"] else 0


def print_summary(an: dict, out_dir: Path, files: List[str]) -> None:
    s = an["summary"]
    tot = an["capacity"]["total"]
    status = Style.paint("BLOCKED", "bold", "red") if s["errors"] else Style.paint("READY", "bold", "green")
    print(Style.paint("== Analysis summary ==", "bold", "cyan"))
    print(f"  Sources: {s['sources']} | databases: {s['source_databases']} -> {s['target_databases']}"
          f" | collections: {s['source_collections']} | views: {s['source_views']}")
    print(f"  Target : {an['params']['target'] or 'not defined'}"
          f" | data to move: {human_bytes(tot['storage_size'] + tot['index_size'])} (storage + indexes)")
    print(f"  Findings: {Style.paint(str(s['errors']) + ' errors', 'red')},"
          f" {Style.paint(str(s['warnings']) + ' warnings', 'yellow')}, {s['info']} info")
    print(f"  Status : {status}")
    print(f"  Output : {out_dir}")
    for name in files:
        print(f"    - {name}")


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if "--no-color" in argv:
        Style.enabled = False
    if "-h" in argv or "--help" in argv:
        sys.stdout.write(render_help(PROG, wants_color(argv)))
        return 0
    args = build_parser().parse_args(argv)
    Log.verbose = args.verbose
    try:
        if args.command == "check":
            return cmd_check(args)
        if args.command == "analyze":
            if not args.snapshot_dir:
                raise ConfigError("analyze requires --snapshot-dir")
            out_dir = args.output_dir or args.snapshot_dir.resolve().parent
            return cmd_analyze(args, args.snapshot_dir, out_dir)
        out_dir = args.output_dir or (PROJECT_ROOT / "reports" / _utc_ts())
        rc = cmd_collect(args, out_dir)
        if args.command == "collect":
            Log.info(f"snapshots written to {out_dir / 'snapshots'}")
            return rc
        rc_an = cmd_analyze(args, out_dir / "snapshots", out_dir)
        return rc_an or rc
    except ConfigError as exc:
        Log.error(str(exc))
        return 2
    except KeyboardInterrupt:
        Log.error("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
