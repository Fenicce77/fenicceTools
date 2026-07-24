# GCP Cloud SQL General Log Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the supplied monitor script generate accurate inserts for all source-backed Cloud SQL MySQL command types while logging malformed payloads verbatim and excluding them from SQL.

**Architecture:** Keep the deliverable as one portable Bash script with its Python parser embedded. Replace the permissive positional regex with one anchored named-group regex whose command alternation is generated from an explicit 36-label whitelist. Unit tests extract the marked Python block without running the shell workflow; a narrow shell test exercises only `--fetch-only --dry-run`, which cannot call GCP or MySQL.

**Tech Stack:** Bash, Python 3 standard library (`json`, `re`, `io`, `unittest`), ShellCheck.

## Global Constraints

- Do not run `gcloud`, `mysql`, or the normal monitor workflow during development or verification.
- Do not run `git` or initialize a repository; this workspace is intentionally not Git-backed.
- Modify only `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh` and the new parser test files named below.
- Keep the runtime deliverable self-contained in the existing Bash script.
- Use one compiled, anchored regular expression with named capture groups.
- Recognize exactly the 36 source-backed command labels in the approved design.
- Use the bracketed username to construct `username@host`.
- A rejected payload must generate no insert and must be written to the monitor log verbatim, without sanitization, redaction, truncation, or console output.
- Mixed batches retain valid events; wholly rejected batches produce no SQL and cannot reach MySQL.
- The monitor log must have mode `0600`.
- Parser standard output is SQL only; diagnostics use the monitor log.
- Because Git is prohibited, replace commit checkpoints with SHA-256 checkpoints for the changed files.

## File Structure

- Modify: `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh`
  - Retains the complete runtime workflow.
  - Contains a marked, import-safe Python parser block.
  - Creates the monitor log with user-only permissions.
- Create: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py`
  - Extracts the marked Python block and tests parsing, normalization, command coverage, rejection behavior, and SQL output without invoking the Bash workflow.
- Create: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh`
  - Runs only the `--fetch-only --dry-run` path to verify log permissions and absence of external execution.

---

### Task 1: Add a Failing Parser Contract Test

**Files:**
- Create: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py`
- Read: `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh`

**Interfaces:**
- Consumes: marked source between `# PARSER_PYTHON_BEGIN` and `# PARSER_PYTHON_END`.
- Produces: extracted `COMMAND_TYPES`, `GENERAL_LOG_PATTERN`, and `parse_mysql_general_log(json_input: str, target_schema: str, rejection_log: TextIO) -> str`.

- [ ] **Step 1: Create the test directory and parser test**

Use `apply_patch` to add this complete file:

```python
import io
import json
import os
import re
import unittest
from pathlib import Path


SCRIPT = Path(
    os.environ.get(
        "GCP_GENERAL_LOG_MONITOR_SCRIPT",
        "/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh",
    )
)

EXPECTED_COMMAND_TYPES = (
    "Sleep",
    "Quit",
    "Init DB",
    "Query",
    "Field List",
    "Create DB",
    "Drop DB",
    "Refresh",
    "Shutdown",
    "Statistics",
    "Processlist",
    "Connect",
    "Kill",
    "Debug",
    "Ping",
    "Time",
    "Delayed insert",
    "Change user",
    "Binlog Dump",
    "Table Dump",
    "Connect Out",
    "Register Replica",
    "Register Slave",
    "Prepare",
    "Execute",
    "Long Data",
    "Close stmt",
    "Reset stmt",
    "Set option",
    "Fetch",
    "Daemon",
    "Binlog Dump GTID",
    "Reset Connection",
    "clone",
    "Group Replication Data Stream subscription",
    "Error",
)


def load_parser_namespace():
    source = SCRIPT.read_text(encoding="utf-8")
    start_marker = "# PARSER_PYTHON_BEGIN\n"
    end_marker = "# PARSER_PYTHON_END"
    start = source.index(start_marker) + len(start_marker)
    end = source.index(end_marker, start)
    namespace = {"__name__": "embedded_general_log_parser"}
    exec(compile(source[start:end], str(SCRIPT), "exec"), namespace)
    return namespace


class ParserContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.namespace = load_parser_namespace()
        cls.parse = staticmethod(cls.namespace["parse_mysql_general_log"])

    def parse_payloads(self, payloads):
        logs = [
            {
                "textPayload": payload,
                "timestamp": "2026-07-23T12:01:55.896580Z",
            }
            for payload in payloads
        ]
        rejection_log = io.StringIO()
        sql = self.parse(json.dumps(logs), "rmc_betika", rejection_log)
        return sql, rejection_log.getvalue()

    def test_command_whitelist_is_complete_and_exact(self):
        self.assertEqual(
            tuple(self.namespace["COMMAND_TYPES"]),
            EXPECTED_COMMAND_TYPES,
        )

    def test_supplied_change_user_payload(self):
        payload = (
            "2026-07-23T12:01:55.896580Z\t"
            "dev-userapp[dev-userapp] @  [XX.XX.XXX.XXX]"
            "15397 4226757038 Change user\t"
            "dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP"
        )
        sql, log = self.parse_payloads([payload])
        expected_values = (
            "(15397, 'dev-userapp@XX.XX.XXX.XXX', 4226757038, "
            "'Change user', "
            "'dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP', "
            "'2026-07-23 12:01:55.896580')"
        )
        self.assertIn(expected_values, sql)
        self.assertIn("[PARSER SUMMARY] accepted=1 rejected=0", log)
        self.assertNotIn("unknown", sql)

    def test_all_source_backed_commands_match_without_prefix_collision(self):
        for command in EXPECTED_COMMAND_TYPES:
            with self.subTest(command=command):
                payload = (
                    "2026-07-23T12:01:55.896580Z "
                    "user[user] @ [127.0.0.1]"
                    f"99 1 {command} payload"
                )
                sql, log = self.parse_payloads([payload])
                self.assertIn(f", '{command}', 'payload', ", sql)
                self.assertIn("accepted=1 rejected=0", log)

    def test_whitespace_ipv6_and_argumentless_command(self):
        payloads = [
            (
                "2026-07-23T12:01:55Z   user[user]\t@\t"
                "[2001:db8::1]  99   1   Query   SELECT 1"
            ),
            "2026-07-23T12:01:56Z user[user] @ [db.internal]100 1 Quit",
        ]
        sql, log = self.parse_payloads(payloads)
        self.assertIn("'user@2001:db8::1'", sql)
        self.assertIn("'Query', 'SELECT 1'", sql)
        self.assertIn("'user@db.internal'", sql)
        self.assertIn("'Quit', ''", sql)
        self.assertIn("accepted=2 rejected=0", log)

    def test_unknown_command_is_logged_verbatim_and_not_inserted(self):
        payload = (
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]"
            "99 1 Unsupported command secret argument"
        )
        sql, log = self.parse_payloads([payload])
        self.assertEqual(sql, "")
        self.assertIn("[PARSER REJECT] payload format mismatch", log)
        self.assertIn(payload, log)
        self.assertIn("[PARSER SUMMARY] accepted=0 rejected=1", log)
        self.assertNotIn("INSERT INTO", sql)
        self.assertNotIn("(0, 'unknown', 1, 'Query'", sql)

    def test_mixed_batch_keeps_only_valid_payload(self):
        valid = (
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]"
            "99 1 Ping"
        )
        rejected = (
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]"
            "not-a-thread 1 Query SELECT 1"
        )
        sql, log = self.parse_payloads([valid, rejected])
        self.assertEqual(sql.count("INSERT INTO"), 1)
        self.assertIn("'Ping', ''", sql)
        self.assertNotIn(rejected, sql)
        self.assertIn(rejected, log)
        self.assertIn("accepted=1 rejected=1", log)

    def test_malformed_structures_are_rejected(self):
        payloads = (
            "   ",
            "2026-07-23 12:01:55Z user[user] @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55.1234567Z user[user] @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55Z user[user @ [127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55Z user[user] @ 127.0.0.1]99 1 Query x",
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]x 1 Query x",
            "2026-07-23T12:01:55Z user[user] @ [127.0.0.1]99 x Query x",
        )
        sql, log = self.parse_payloads(payloads)
        self.assertEqual(sql, "")
        self.assertEqual(log.count("[PARSER RAW PAYLOAD BEGIN]"), len(payloads))
        for payload in payloads:
            self.assertIn(payload, log)

    def test_invalid_json_produces_no_sql(self):
        rejection_log = io.StringIO()
        sql = self.parse("{not-json", "rmc_betika", rejection_log)
        self.assertEqual(sql, "")
        self.assertIn("[PARSER ERROR] invalid JSON", rejection_log.getvalue())

    def test_pattern_is_anchored_and_uses_named_groups(self):
        pattern = self.namespace["GENERAL_LOG_PATTERN"]
        self.assertIsInstance(pattern, re.Pattern)
        self.assertEqual(
            set(pattern.groupindex),
            {
                "event_time",
                "outer_username",
                "username",
                "host",
                "thread_id",
                "server_id",
                "command_type",
                "argument",
            },
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the parser tests and confirm RED**

Run:

```bash
python3 -m unittest discover \
  -s /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
```

Expected: ERROR from `source.index(start_marker)` because the supplied script
does not yet contain the marked, import-safe parser block.

- [ ] **Step 3: Record the RED checkpoint**

Run:

```bash
shasum -a 256 \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py
```

Expected: one SHA-256 line for the new failing test. Save it in the execution
notes; do not initialize Git.

---

### Task 2: Implement the Strict Comprehensive Parser

**Files:**
- Modify: `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh:195-290`
- Test: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py`

**Interfaces:**
- Consumes: Cloud Logging JSON text, target schema, and an open text stream for parser diagnostics.
- Produces: `COMMAND_TYPES`, `GENERAL_LOG_PATTERN`, and `parse_mysql_general_log(json_input: str, target_schema: str, rejection_log: TextIO) -> str`.

- [ ] **Step 1: Mark the embedded Python block and make it import-safe**

Use `apply_patch` to place:

```python
# PARSER_PYTHON_BEGIN
```

immediately after the opening `python3 -c '` and:

```python
# PARSER_PYTHON_END
```

immediately before the closing shell quote.

Move stdin/argument handling under:

```python
if __name__ == "__main__":
    raw_data = sys.stdin.read()
    schema = sys.argv[1]
    log_path = sys.argv[2]
    with open(log_path, "a", encoding="utf-8", newline="") as parser_log:
        sql_output = parse_mysql_general_log(raw_data, schema, parser_log)
    if sql_output:
        print(sql_output, end="")
```

This prevents test extraction from reading test-runner stdin or requiring shell
arguments.

- [ ] **Step 2: Add the exact command vocabulary and generated alternation**

Replace the old `cmd_types` value with:

```python
COMMAND_TYPES = (
    "Sleep",
    "Quit",
    "Init DB",
    "Query",
    "Field List",
    "Create DB",
    "Drop DB",
    "Refresh",
    "Shutdown",
    "Statistics",
    "Processlist",
    "Connect",
    "Kill",
    "Debug",
    "Ping",
    "Time",
    "Delayed insert",
    "Change user",
    "Binlog Dump",
    "Table Dump",
    "Connect Out",
    "Register Replica",
    "Register Slave",
    "Prepare",
    "Execute",
    "Long Data",
    "Close stmt",
    "Reset stmt",
    "Set option",
    "Fetch",
    "Daemon",
    "Binlog Dump GTID",
    "Reset Connection",
    "clone",
    "Group Replication Data Stream subscription",
    "Error",
)

command_pattern = "|".join(
    re.escape(command).replace(r"\ ", r"\s+")
    for command in sorted(COMMAND_TYPES, key=len, reverse=True)
)
```

Do not add case-insensitive matching. Preserve official command spelling and
case, including lowercase `clone`.

- [ ] **Step 3: Compile the anchored named-group pattern**

Add:

```python
GENERAL_LOG_PATTERN = re.compile(
    rf"""
    \A
    (?P<event_time>
        \d{{4}}-\d{{2}}-\d{{2}}T
        \d{{2}}:\d{{2}}:\d{{2}}
        (?:\.\d{{1,6}})?Z
    )
    \s+
    (?P<outer_username>[^\s\[\]]+)
    \[(?P<username>[^\]\r\n]+)\]
    \s*@\s*
    \[(?P<host>[^\]\r\n]+)\]
    \s*
    (?P<thread_id>\d+)
    \s+
    (?P<server_id>\d+)
    \s+
    (?P<command_type>{command_pattern})
    (?:\s+(?P<argument>.*))?
    \Z
    """,
    re.VERBOSE | re.DOTALL,
)
```

- [ ] **Step 4: Add verbatim rejection logging**

Import `TextIO`:

```python
from typing import List, Dict, Any, TextIO
```

Add:

```python
def log_rejection(rejection_log: TextIO, reason: str, raw_payload: str) -> None:
    rejection_log.write(f"[PARSER REJECT] {reason}\n")
    rejection_log.write("[PARSER RAW PAYLOAD BEGIN]\n")
    rejection_log.write(raw_payload)
    if not raw_payload.endswith("\n"):
        rejection_log.write("\n")
    rejection_log.write("[PARSER RAW PAYLOAD END]\n")
```

This writes the raw string directly. Do not apply `repr()`, JSON encoding,
redaction, truncation, or shell logging to it.

- [ ] **Step 5: Replace fallback-row generation with strict parsing**

Change the signature to:

```python
def parse_mysql_general_log(
    json_input: str,
    target_schema: str,
    rejection_log: TextIO,
) -> str:
```

Initialize counters:

```python
accepted = 0
rejected = 0
```

For invalid JSON:

```python
try:
    logs: List[Dict[str, Any]] = json.loads(json_input)
except Exception as exc:
    rejection_log.write(
        f"[PARSER ERROR] invalid JSON: {type(exc).__name__}: {exc}\n"
    )
    return ""

if not isinstance(logs, list):
    rejection_log.write("[PARSER ERROR] top-level JSON value is not a list\n")
    return ""
```

Keep the existing payload-field selection, but retain the original string:

```python
raw_line = line
line = raw_line.strip()
if not line:
    rejected += 1
    log_rejection(rejection_log, "empty payload", raw_line)
    continue

match = GENERAL_LOG_PATTERN.fullmatch(line)
if not match:
    rejected += 1
    log_rejection(rejection_log, "payload format mismatch", raw_line)
    continue
```

Delete the entire old `else:` branch that assigned `thread_id = "0"`,
`user_host = "unknown"`, `server_id = "1"`, and `command_type = "Query"`.
Delete the metadata timestamp fallback because the event timestamp is now a
required payload field.

Normalize successful captures:

```python
raw_time = match.group("event_time")
username = match.group("username").strip()
host = match.group("host").strip()
thread_id = match.group("thread_id")
server_id = match.group("server_id")
command_type = re.sub(r"\s+", " ", match.group("command_type"))
argument = match.group("argument") or ""

current_time = raw_time[:-1].replace("T", " ", 1)
user_host = f"{username}@{host}"
accepted += 1
```

Retain the existing SQL escaping and batching around these normalized fields.

Before returning, always append:

```python
rejection_log.write(
    f"[PARSER SUMMARY] accepted={accepted} rejected={rejected}\n"
)
```

If `accepted == 0`, return an empty string. Otherwise retain the transaction
wrapper and `SET autocommit` behavior.

- [ ] **Step 6: Pass the monitor log path without contaminating SQL output**

Change the embedded Python invocation tail to:

```bash
' "${SCHEMA}" "${LOGFILE}" <<< "$RAW_LOGS" \
    > "${OUTFILE}" 2>>"${LOGFILE}"
```

The Python parser writes SQL only to stdout. Raw rejected payloads go directly
to the opened monitor log; unhandled Python stderr also goes to that log.

- [ ] **Step 7: Run the parser tests and confirm GREEN**

Run:

```bash
python3 -m unittest discover \
  -s /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
```

Expected: 9 tests pass. No GCP or MySQL command is executed.

- [ ] **Step 8: Record the parser checkpoint**

Run:

```bash
shasum -a 256 \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py
```

Expected: two SHA-256 lines. Save them in the execution notes; do not run Git.

---

### Task 3: Secure the Log and Add a Shell-Safety Test

**Files:**
- Modify: `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh:68-78`
- Create: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh`

**Interfaces:**
- Consumes: the monitor script's `--fetch-only --dry-run` path.
- Produces: a mode-`0600` monitor log and a test proving the safe dry-run path does not invoke external tools.

- [ ] **Step 1: Create the failing shell integration test**

Use `apply_patch` to add:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${GCP_GENERAL_LOG_MONITOR_SCRIPT:-/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh}"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP_DIR}"' EXIT

(
    cd "${TEST_TMP_DIR}"
    PATH="/usr/bin:/bin" bash "${SCRIPT}" \
        --project test-project \
        --instance test-instance \
        --login-path test-login \
        --schema test_schema \
        --fetch-only \
        --dry-run \
        >"${TEST_TMP_DIR}/stdout.log" \
        2>"${TEST_TMP_DIR}/stderr.log"
)

LOG_PATH="${TEST_TMP_DIR}/tmp/gcp_general_log_monitor.log"

python3 - "${LOG_PATH}" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
mode = stat.S_IMODE(os.stat(path).st_mode)
if mode != 0o600:
    raise SystemExit(f"expected mode 0600, got {mode:04o}")
PY

grep -q "Dry-run complete" "${TEST_TMP_DIR}/stdout.log"

if grep -qE "command not found|No such file or directory" \
    "${TEST_TMP_DIR}/stdout.log" "${TEST_TMP_DIR}/stderr.log"; then
    echo "dry-run attempted to execute an unavailable external command" >&2
    exit 1
fi
```

The combination of `--fetch-only --dry-run` bypasses flag inspection and exits
before log retrieval, so neither `gcloud` nor `mysql` is executed. Restricting
`PATH` makes an accidental external call fail the test visibly.

- [ ] **Step 2: Run the shell test and confirm RED**

Run:

```bash
(
  umask 022
  bash \
    /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
)
```

Expected: FAIL with `expected mode 0600, got 0644`.

- [ ] **Step 3: Enforce monitor-log permissions**

Immediately before creating the local directory and truncating the log, use:

```bash
umask 077
mkdir -p "${LOCAL_TMP_DIR}"
: > "${LOGFILE}"
chmod 600 "${LOGFILE}"
```

Replace the existing bare:

```bash
> "${LOGFILE}"
```

Do not print the rejected payload via `log_msg`; that function uses `tee` and
would expose the raw payload on the console.

- [ ] **Step 4: Run the shell test and confirm GREEN**

Run:

```bash
(
  umask 022
  bash \
    /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
)
```

Expected: exit 0, with no `gcloud` or `mysql` execution.

- [ ] **Step 5: Run Bash syntax validation**

Run:

```bash
bash -n \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
```

Expected: exit 0 with no output.

- [ ] **Step 6: Inspect ShellCheck output**

Run:

```bash
shellcheck -x \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
```

Expected: no new warnings in the parser or test changes. The supplied script's
existing unrelated `SC2034` warning for `blk` and `SC2046` warning for the flag
parsing `eval` may remain; do not broaden this parser change to refactor them.

- [ ] **Step 7: Record the shell checkpoint**

Run:

```bash
shasum -a 256 \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
```

Expected: three SHA-256 lines. Save them in the execution notes; do not run Git.

---

### Task 4: Run the Complete Local Verification

**Files:**
- Verify: `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh`
- Verify: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py`
- Verify: `/Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh`

**Interfaces:**
- Consumes: completed implementation and tests from Tasks 1-3.
- Produces: local evidence that parser behavior is correct without cloud or database access.

- [ ] **Step 1: Run all parser unit tests**

Run:

```bash
python3 -m unittest discover \
  -s /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
```

Expected: all 9 tests pass, including all 36 command subtests.

- [ ] **Step 2: Run the safe shell integration test**

Run:

```bash
(
  umask 022
  bash \
    /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
)
```

Expected: exit 0. This path must not invoke GCP or MySQL.

- [ ] **Step 3: Validate shell syntax**

Run:

```bash
bash -n \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh
```

Expected: exit 0 with no output.

- [ ] **Step 4: Confirm fallback-row code is absent**

Run:

```bash
rg -n \
  'user_host = "unknown"|thread_id = "0"|server_id = "1"' \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh
```

Expected: no matches and `rg` exit status 1.

- [ ] **Step 5: Confirm the supplied payload produces the requested values**

The `test_supplied_change_user_payload` test is the executable proof. Re-run it
alone:

```bash
python3 \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py \
  ParserContractTest.test_supplied_change_user_payload -v
```

Expected: one test passes.

- [ ] **Step 6: Capture final checksums**

Run:

```bash
shasum -a 256 \
  /Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_parser.py \
  /Volumes/sysops/Jira-ticket-analysis/tests/gcp-general-log-parser/test_shell_integration.sh \
  /Volumes/sysops/Jira-ticket-analysis/docs/superpowers/specs/2026-07-24-gcp-general-log-parser-design.md \
  /Volumes/sysops/Jira-ticket-analysis/docs/superpowers/plans/2026-07-24-gcp-general-log-parser.md
```

Expected: five SHA-256 lines suitable for handoff. Do not commit or initialize
Git.

- [ ] **Step 7: Report the handoff**

Report:

- the changed script path;
- the parser and shell test paths;
- unit-test and shell-test results;
- Bash syntax result;
- any retained pre-existing ShellCheck warnings;
- the final SHA-256 values;
- explicit confirmation that no GCP or database operation was run.
