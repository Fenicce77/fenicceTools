"""Colored, requirement-aware help screen (same layout as the bash implementation)."""
from __future__ import annotations

import os
import sys
from typing import List, Optional, Tuple

from .common import PROJECT_HOME, TOOL_VERSION

FLAGS_WIDTH = 31
DESC_WIDTH = 50

# (flags, argument, description, tag) - tag: ("req", cmd) | ("def", value) | ("opt", "") | None
Option = Tuple[str, str, str, Optional[Tuple[str, str]]]

SECTIONS: List[Tuple[str, str, List[Option]]] = [
    ("GENERAL OPTIONS", "all commands", [
        ("-c, --conf-dir", "DIR", "Instance configuration directory (*.conf)", ("def", "<project_root>/conf")),
        ("-i, --instances", "LIST", "Comma-separated instance names or aliases", ("def", "all *.conf")),
        ("-t, --target", "NAME", "Central (target) instance name or alias", ("def", "conf with MONGO_ROLE=target")),
        ("    --no-color", "", "Disable colored output", ("opt", "")),
        ("-v, --verbose", "", "Verbose output", ("opt", "")),
        ("-V, --version", "", "Show version and exit", None),
        ("-h, --help", "", "Show this help and exit", None),
    ]),
    ("OUTPUT OPTIONS", "run, collect, analyze", [
        ("-s, --snapshot-dir", "DIR", "Existing snapshot directory to analyze", ("req", "analyze")),
        ("-o, --output-dir", "DIR", "Output directory (analyze: snapshot parent)", ("def", "<project_root>/reports/<UTC ts>")),
    ]),
    ("ANALYSIS OPTIONS", "run, analyze", [
        ("-n, --naming-strategy", "S", "Target database naming: auto | keep | prefix", ("def", "auto")),
        ("    --prefix-sep", "SEP", "Separator between alias and database", ("def", "_")),
        ("-m, --mapping-file", "FILE", "Overrides <instance|alias>:<src_db>=<tgt_db>", ("opt", "")),
    ]),
    ("COLLECTION OPTIONS", "run, collect  (--timeout also applies to check --connect)", [
        ("    --sample-size", "N", "Documents sampled per collection; 0 = no reads", ("def", "100")),
        ("    --max-depth", "N", "Max nesting depth for field paths", ("def", "5")),
        ("    --include-dbs", "REGEX", "Only databases matching REGEX", ("opt", "")),
        ("    --exclude-dbs", "REGEX", "Skip databases matching REGEX", ("opt", "")),
        ("    --include-security", "", "Collect users and custom roles", ("opt", "")),
        ("-p, --parallel", "N", "Instances collected in parallel", ("def", "4")),
        ("    --timeout", "SEC", "Connection timeout", ("def", "15")),
        ("    --op-timeout", "SEC", "Per-operation maxTimeMS", ("def", "120")),
    ]),
    ("ACTIVITY OPTIONS", "run, collect  (--stale-days: run, analyze)", [
        ("    --no-activity", "", "Skip _id and *modified* field dates", ("opt", "")),
        ("    --modified-pattern", "REGEX", "Last-modification date fields (case-insens.)", ("def", "modif")),
        ("    --modified-scan", "", "Exact max of unindexed fields (COLLSCAN)", ("opt", "")),
        ("    --stale-days", "N", "Flag collections idle for N days, 0 disables", ("def", "180")),
        ("    --member-stats", "", "Per-member reads/writes since restart (top)", ("opt", "")),
        ("    --oplog-window", "HOURS", "Analyze the last HOURS of oplog (writes, users)", ("def", "0 = disabled")),
        ("    --oplog-timeout", "SEC", "maxTimeMS of the oplog aggregation", ("def", "600")),
        ("    --activity-samples", "N", "Live $currentOp sampling rounds", ("def", "0 = disabled")),
        ("    --activity-interval", "SEC", "Seconds between sampling rounds", ("def", "10")),
    ]),
    ("CHECK OPTIONS", "check", [
        ("    --connect", "", "Also test connectivity with every instance", ("opt", "")),
    ]),
]

EXAMPLES = [
    ("validate configuration files and connectivity", "check --connect"),
    ("preliminary report with low impact on the instances", "run --sample-size 100 --op-timeout 30 --parallel 2"),
    ("metadata only: no document reads", "run --sample-size 0 --parallel 1"),
    ("plan against the central instance, including users and roles", "run --target central01 --include-security"),
    ("users to migrate: 24 h of oplog + 30 live samples (5 min)",
     "run --include-security --oplog-window 24 --activity-samples 30 --activity-interval 10"),
    ("re-analyze existing snapshots with another strategy (no DB access)",
     "analyze -s ./reports/20260930T101500Z/snapshots -n prefix"),
]


class HelpStyle:
    def __init__(self, enabled: bool) -> None:
        codes = {"title": "1;36", "opt": "32", "arg": "33", "req": "1;31", "dim": "2", "bold": "1"}
        self.enabled = enabled
        self.codes = codes

    def __call__(self, text: str, style: str) -> str:
        if not self.enabled or not text:
            return text
        return f"\033[{self.codes[style]}m{text}\033[0m"


def _tag(tag: Optional[Tuple[str, str]], c: HelpStyle) -> str:
    if tag is None:
        return ""
    kind, value = tag
    if kind == "req":
        return c(f"[required: {value}]", "req")
    if kind == "def":
        return c(f"(default: {value})", "dim")
    return c("(optional)", "dim")


def render_help(prog: str, colored: bool) -> str:
    c = HelpStyle(colored)
    lines: List[str] = [
        f"{c(prog, 'bold')} v{TOOL_VERSION}",
        "Analyze, compare and plan the centralization of MongoDB schemas across instances.",
        c("Read-only on the instances: nothing is migrated; generated scripts default to dry-run.", "dim"),
    ]

    def section(title: str, subtitle: str = "") -> None:
        lines.append("")
        lines.append(c(title, "title") + (f"  {c(subtitle, 'dim')}" if subtitle else ""))

    def option(flags: str, arg: str, desc: str, tag: Optional[Tuple[str, str]]) -> None:
        plain = flags + (f" {arg}" if arg else "")
        pad = " " * max(1, FLAGS_WIDTH - len(plain))
        head = f"  {c(flags, 'opt')}" + (f" {c(arg, 'arg')}" if arg else "") + pad
        rendered = _tag(tag, c)
        lines.append(head + (f"{desc:<{DESC_WIDTH}} {rendered}" if rendered else desc))

    def command(name: str, desc: str, tag: str = "") -> None:
        lines.append(f"  {c(f'{name:<9}', 'opt')} " + (f"{desc:<{DESC_WIDTH}} {tag}" if tag else desc))

    section("USAGE")
    lines.append(f"  {prog} {c('[COMMAND]', 'opt')} {c('[OPTIONS]', 'arg')}")

    section("LEGEND")
    lines.append(f"  {c('[required: cmd]'.ljust(18), 'req')} mandatory for the given command")
    lines.append(f"  {c('(default: value)'.ljust(18), 'dim')} optional; this value is used when omitted")
    lines.append(f"  {c('(optional)'.ljust(18), 'dim')} optional; feature disabled when omitted")

    section("COMMANDS")
    command("run", "Collect from every instance and analyze", c("(default command)", "dim"))
    command("collect", "Only collect snapshots into <output-dir>/snapshots")
    command("analyze", "Offline analysis of existing snapshots (no DB)", f"{_tag(('req', 'analyze'), c)} --snapshot-dir")
    command("check", "Validate configuration files and secrets")

    for title, subtitle, options in SECTIONS:
        section(title, subtitle)
        for opt in options:
            option(*opt)

    section("NAMING STRATEGIES")
    lines.append(f"  {c('auto'.ljust(7), 'opt')} keep the name; prefix <alias><sep><db> only when it conflicts")
    lines.append(f"  {c('keep'.ljust(7), 'opt')} never rename (collisions are reported as blocking errors)")
    lines.append(f"  {c('prefix'.ljust(7), 'opt')} always prefix with the instance alias")

    section("EXAMPLES")
    for comment, args in EXAMPLES:
        lines.append(f"  {c('# ' + comment, 'dim')}")
        lines.append(f"  {prog} {args}")

    section("CONFIGURATION")
    lines.append("  run, collect and check need at least one *.conf in --conf-dir (KEY=VALUE, never sourced).")
    lines.append(f"  Template: {PROJECT_HOME / 'conf.example' / 'instance.conf.example'}")

    section("ENVIRONMENT")
    lines.append(f"  {c('BMN_PROJECT_ROOT'.ljust(18), 'arg')} project root {_tag(('def', 'parent of betika_mongodb_normalized'), c)}")
    lines.append(f"  {c('BMN_GENERATED_AT'.ljust(18), 'arg')} fixed report timestamp (reproducible output) {_tag(('opt', ''), c)}")
    lines.append(f"  {c('NO_COLOR'.ljust(18), 'arg')} disable colors when set")

    section("EXIT CODES")
    lines.append(f"  {c('0', 'opt')} ok   {c('1', 'req')} blocking findings   {c('2', 'req')} usage/config error"
                 f"   {c('3', 'req')} collection errors")
    return "\n".join(lines) + "\n"


def wants_color(argv: List[str]) -> bool:
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR") and "--no-color" not in argv
