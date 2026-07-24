# GCP Cloud SQL General-Log Parser Handoff

**Prepared:** 2026-07-24  
**Audience:** Human engineer or LLM coding agent  
**Status:** Analysis, design, and implementation plan are complete and approved. The supplied script has not been modified.

## Start Here

This handoff is for improving the query-generation section of:

```text
gcp_general_log_monitor.3.sh
```

The original file on the preparing machine is:

```text
/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh
```

Its approved parser design and test-first implementation plan are:

```text
docs/superpowers/specs/2026-07-24-gcp-general-log-parser-design.md
docs/superpowers/plans/2026-07-24-gcp-general-log-parser.md
```

If this handoff is copied to another machine, place the original script
wherever is convenient and set:

```bash
export GCP_GENERAL_LOG_MONITOR_SCRIPT="/absolute/path/to/gcp_general_log_monitor.3.sh"
```

The implementation plan uses the original absolute path because that was the
location supplied during analysis. Adapt paths, not behavior.

## Executive Summary

The parser currently has two independent problems:

1. When its regex does not match, it silently creates a plausible but false
   database row using `thread_id=0`, `user_host=unknown`, `server_id=1`, and
   `command_type=Query`.
2. When the regex does match the supplied username format, it uses the entire
   `outer[bracketed]` value as the username instead of the canonical username
   inside brackets.

The approved correction is:

- Use one strict, anchored regular expression with named groups.
- Capture the bracketed username and build `username@host`.
- Recognize the union of all source-backed MySQL command labels relevant to
  currently supported Cloud SQL MySQL versions.
- Generate SQL only for fully parsed events.
- Write every rejected raw payload verbatim to the monitor log only.
- Never generate fallback insert values.
- Keep valid events from mixed batches.
- Produce no SQL and never invoke MySQL when all events are rejected.
- Restrict the monitor log to mode `0600`.

## Critical Safety Boundary

The supplied script is operational. In its normal modes it can:

- inspect and patch Cloud SQL flags;
- enable or disable `general_log`;
- read Cloud Logging;
- invoke MySQL and insert rows.

Do not run the normal workflow merely to test the parser.

Also note this non-obvious behavior:

```text
--dry-run by itself still executes `gcloud sql instances describe`.
```

The only existing shell path approved for a local smoke test is the combined:

```text
--fetch-only --dry-run
```

That combination bypasses flag inspection and exits before log retrieval or
database loading. The implementation plan further restricts `PATH` during the
test so an accidental external call fails visibly.

Parser unit tests must extract and execute only the marked embedded Python
block. They must not run the operational shell workflow.

## What Has Already Been Done

Completed:

- Read and analyzed the full supplied script.
- Reproduced the current regex against the pasted example.
- Identified the mismatch between the reported fallback row and the supplied
  script/sample combination.
- Confirmed the current successful-match `user_host` formatting is still
  wrong.
- Agreed that malformed events must be logged and excluded from inserts.
- Agreed that rejected payloads are logged completely and without
  sanitization.
- Compared three parsing strategies.
- Selected the single-regex strategy.
- Designed a named-group regex.
- Sourced and tested the complete command whitelist.
- Wrote and approved the design specification.
- Wrote and self-reviewed a detailed test-first implementation plan.

Not completed:

- No parser code has been changed.
- No tests have been created.
- No GCP command has been run.
- No database command has been run.
- No Git repository has been created.
- No commit exists for this work.

## Baseline Checksums

These hashes identify the exact analyzed inputs before implementation:

```text
9430b1cfb2e5f597d5470570bbf5bfe7beff90183d4ed0506d78952e3e4828ee  gcp_general_log_monitor.3.sh
2140bb938c7b2a78f0d75190ae2b438524a44408eb8b116d665088984587dff5  2026-07-24-gcp-general-log-parser-design.md
0eada8ee0307e134cc43ef252c715376fbd7d680da38306100bf0b2d91c23c6d  2026-07-24-gcp-general-log-parser.md
```

Before implementation, verify the script:

```bash
shasum -a 256 "${GCP_GENERAL_LOG_MONITOR_SCRIPT}"
```

If the script hash differs, do not blindly apply line-based instructions.
Compare the parser section and reconcile the newer version first.

## Original Report

The payload format was described as:

```text
event_time user_host thread_id server_id command_type argument
```

Ordinary fields are separated by one or more spaces. The special `user_host`
field contains spaces around `@` and has this form:

```text
outer_username[canonical_username] @  [IP]
```

The example payload was:

```text
2026-07-23T12:01:55.896580Z	dev-userapp[dev-userapp] @  [XX.XX.XXX.XXX]15397 4226757038 Change user	dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP
```

The reported bad insert was:

```sql
INSERT INTO rmc_betika.general_log_analysis
    (thread_id, user_host, server_id, command_type, argument, event_time)
VALUES
    (
        0,
        'unknown',
        1,
        'Query',
        '2026-07-23T12:01:55.896580Z        dev-userapp[dev-userapp] @  [XX.XX.XXX.XXX]15397 4226757038 Change user dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP',
        '2026-07-23 12:01:55.896580'
    );
```

The requested insert is:

```sql
INSERT INTO rmc_betika.general_log_analysis
    (thread_id, user_host, server_id, command_type, argument, event_time)
VALUES
    (
        15397,
        'dev-userapp@XX.XX.XXX.XXX',
        4226757038,
        'Change user',
        'dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP',
        '2026-07-23 12:01:55.896580'
    );
```

## Important Reproduction Finding

The exact pasted payload does match the regex in the supplied script.

The current expression extracts:

```text
event_time:   2026-07-23T12:01:55.896580Z
raw_user:     dev-userapp[dev-userapp]
host:         XX.XX.XXX.XXX
thread_id:    15397
server_id:    4226757038
command_type: Change user
argument:     dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP
```

Therefore, the reported fallback row cannot be reproduced from both:

- this exact script version; and
- this exact payload string.

Likely explanations include:

- the bad row came from an earlier script revision;
- the real payload contains an invisible structural difference not preserved
  in the pasted message;
- the executed script differs from the attached file.

This discrepancy does not invalidate the change. Even on a successful match,
the current script builds:

```text
dev-userapp[dev-userapp]@XX.XX.XXX.XXX
```

instead of:

```text
dev-userapp@XX.XX.XXX.XXX
```

The false fallback-row behavior is also independently unsafe and must be
removed.

If the original failing Cloud Logging JSON is available, preserve it as a test
fixture. Do not paste it into an external AI service if it contains sensitive
queries, tokens, credentials, or personal data.

## Approved Input Grammar

After stripping transport-level leading and trailing whitespace for matching,
an accepted payload has this structure:

```text
event_time outer_username[canonical_username] @ [host]thread_id server_id command_type argument
```

Rules:

1. `event_time` is:

   ```text
   YYYY-MM-DDTHH:MM:SS[.fraction]Z
   ```

   The fractional part is optional and contains one to six digits.

2. One or more whitespace characters separate ordinary fields.
3. Whitespace around `@` is flexible.
4. Whitespace after the closing host bracket is optional.
5. `thread_id` and `server_id` contain digits only.
6. The canonical username comes from inside the username brackets.
7. The bracketed host may be IPv4, IPv6, or hostname-like text.
8. `command_type` must be in the approved whitelist.
9. `argument` is the untouched remainder and may be absent.
10. The full payload must match. Partial matches are rejected.

The outer username is captured for structural validation but is not required to
equal the bracketed username.

## Approved Regex Shape

The implementation uses one regex, named groups, and `fullmatch()`:

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

Do not return to positional groups such as `match.group(4)`. Named groups are
part of the agreed design because they make field mapping auditable.

## Comprehensive Command Whitelist

The approved set is the union of official MySQL command-name mappings for the
Cloud SQL-supported MySQL generations, plus the official legacy terminology
alias:

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
```

There are 36 accepted labels:

- 35 current source labels;
- `Register Slave` as the official legacy alias.

Build the alternation rather than hand-writing it:

```python
command_pattern = "|".join(
    re.escape(command).replace(r"\ ", r"\s+")
    for command in sorted(COMMAND_TYPES, key=len, reverse=True)
)
```

Longest-first ordering is mandatory. Without it:

- `Binlog Dump GTID` can be captured as `Binlog Dump` with `GTID ...` treated
  as the argument;
- `Connect Out` can be captured as `Connect` with `Out ...` treated as the
  argument.

Do not enable case-insensitive matching. Preserve official source spelling,
including lowercase `clone`.

## Approved Field Normalization

For a successful match:

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
```

Timestamp handling is intentionally narrow:

- remove only the final `Z`;
- replace only the date/time separator `T`;
- do not globally remove every `T` or `Z`;
- do not fall back to the Cloud Logging metadata timestamp when the required
  payload timestamp is malformed or missing.

The existing SQL escaping and transaction batching can remain, provided tests
show the requested output and rejected payloads never enter SQL.

## Rejection Contract

When a payload does not fully match:

1. Increment the rejected count.
2. Write a rejection reason to the monitor log.
3. Write a begin marker.
4. Write the original payload string directly and completely.
5. Add a separator newline only if needed for the following marker.
6. Write an end marker.
7. Continue to the next event.
8. Generate no insert for the rejected event.

Suggested format:

```text
[PARSER REJECT] payload format mismatch
[PARSER RAW PAYLOAD BEGIN]
<complete original payload>
[PARSER RAW PAYLOAD END]
```

For a whitespace-only payload, use a distinct `empty payload` reason but still
log the original whitespace payload between the markers.

The raw payload must not be:

- sanitized;
- redacted;
- truncated;
- encoded with `repr()`;
- JSON-escaped again;
- printed to the console.

The script's existing `log_msg` function uses `tee`, so it must not be used for
rejected raw payloads. The Python parser should write directly to the monitor
log or to a dedicated file descriptor that is not mirrored to stdout.

Always write a summary:

```text
[PARSER SUMMARY] accepted=<N> rejected=<N>
```

## Raw-Log Security Warning

The explicit product decision is to log rejected payloads without sanitization.
General-log arguments can contain sensitive SQL, credentials, tokens, personal
data, or business data.

Consequences:

- The monitor log must be mode `0600`.
- Do not paste the monitor log into public tickets or external AI tools.
- Do not upload it to shared storage without an explicit security decision.
- Do not print rejected payloads to the terminal.
- Treat copied logs as sensitive and delete them according to the team's
  retention policy.

Create or truncate the log safely:

```bash
umask 077
mkdir -p "${LOCAL_TMP_DIR}"
: > "${LOGFILE}"
chmod 600 "${LOGFILE}"
```

The explicit `chmod` also corrects a pre-existing log with broader
permissions.

## Batch Behavior

Valid-only batch:

- Generate inserts for every valid event.
- Log `accepted=N rejected=0`.

Mixed batch:

- Generate inserts only for valid events.
- Log each rejected payload verbatim.
- Log the final counts.
- Continue to the MySQL import only with the valid inserts.

All-rejected batch:

- Generate no SQL.
- Log every rejected payload.
- Log `accepted=0 rejected=N`.
- The shell's output-file guard must prevent MySQL execution.

Invalid top-level JSON:

- Generate no SQL.
- Log a parser error.
- Do not invoke MySQL.

Never generate:

```text
thread_id=0
user_host=unknown
server_id=1
command_type=Query
```

as a parsing fallback.

## Parser/Test Boundary

The final runtime artifact should remain a single Bash script. The embedded
Python block should be made import-safe and marked:

```python
# PARSER_PYTHON_BEGIN
...
# PARSER_PYTHON_END
```

Runtime entry code belongs under:

```python
if __name__ == "__main__":
    ...
```

The unit test reads the Bash script, extracts the text between those markers,
and executes it in a namespace whose `__name__` is not `__main__`.

This provides real unit coverage of the shipped parser while preserving the
one-file operational deliverable.

The parser interface is:

```python
parse_mysql_general_log(
    json_input: str,
    target_schema: str,
    rejection_log: TextIO,
) -> str
```

Standard output from the runtime parser is SQL only. Parser diagnostics and raw
payloads go to the monitor log.

## Required Tests

The approved plan creates:

```text
tests/gcp-general-log-parser/test_parser.py
tests/gcp-general-log-parser/test_shell_integration.sh
```

The unit suite must cover:

1. Exact supplied `Change user` payload and requested values.
2. Tabs and multiple spaces.
3. No whitespace between host bracket and thread ID.
4. IPv4-like, IPv6, and hostname-like hosts.
5. Argument-bearing commands.
6. Argumentless commands such as `Quit` and `Ping`.
7. All 36 command labels.
8. `Binlog Dump GTID` prefix collision.
9. `Connect Out` prefix collision.
10. `Register Slave`.
11. `Register Replica`.
12. Malformed timestamp separator.
13. More than six timestamp fractional digits.
14. Malformed username brackets.
15. Malformed host brackets.
16. Nonnumeric thread ID.
17. Nonnumeric server ID.
18. Unknown command type.
19. Whitespace-only payload.
20. Mixed valid and rejected events.
21. All-rejected input.
22. Invalid JSON.
23. Verbatim raw-payload logging.
24. Accepted/rejected summary counts.
25. Absence of all old fallback assignments.

The shell test must:

- use `--fetch-only --dry-run` together;
- run in a temporary directory;
- restrict `PATH`;
- assert the log exists with mode `0600`;
- assert the dry run completed;
- fail if an unavailable external command was attempted.

## Safe Verification Commands

Adapt the script path through the environment variable:

```bash
export GCP_GENERAL_LOG_MONITOR_SCRIPT="/absolute/path/to/gcp_general_log_monitor.3.sh"
```

Run parser unit tests:

```bash
python3 -m unittest discover \
  -s tests/gcp-general-log-parser \
  -p 'test_parser.py' -v
```

Run the safe shell test:

```bash
(
  umask 022
  bash tests/gcp-general-log-parser/test_shell_integration.sh
)
```

Validate syntax:

```bash
bash -n \
  "${GCP_GENERAL_LOG_MONITOR_SCRIPT}" \
  tests/gcp-general-log-parser/test_shell_integration.sh
```

Inspect ShellCheck:

```bash
shellcheck -x \
  "${GCP_GENERAL_LOG_MONITOR_SCRIPT}" \
  tests/gcp-general-log-parser/test_shell_integration.sh
```

Confirm fallback assignments are absent:

```bash
rg -n \
  'user_host = "unknown"|thread_id = "0"|server_id = "1"' \
  "${GCP_GENERAL_LOG_MONITOR_SCRIPT}"
```

Expected: no matches.

Do not use a real Cloud Logging response or database connection for local
parser verification.

## Known Unrelated Script Findings

Baseline syntax validation passed:

```text
bash -n: PASS
```

Baseline ShellCheck reported these pre-existing warnings:

```text
SC2034: blk appears unused
SC2188: bare redirection used to truncate LOGFILE
SC2046: unquoted command substitution around eval
```

The log-permission change naturally resolves `SC2188` by changing the bare
redirection to:

```bash
: > "${LOGFILE}"
```

`SC2034` and `SC2046` are outside the parser scope. Do not expand this change
into unrelated cleanup unless separately agreed.

Other out-of-scope observations:

- The schema identifier is interpolated into SQL and is not validated by this
  parser change.
- The operational script directly runs `gcloud` and `mysql`; this handoff does
  not redesign those integrations.
- Flag-management behavior and rollback semantics are not part of this change.
- The maximum batch size remains 500.
- SQL escaping remains the script's existing responsibility.

## Human Resume Procedure

1. Obtain these files:

   ```text
   gcp_general_log_monitor.3.sh
   README.md
   2026-07-24-gcp-general-log-parser-design.md
   2026-07-24-gcp-general-log-parser.md
   ```

2. Verify the script's baseline SHA-256.
3. Read the design specification.
4. Read the implementation plan.
5. Adapt absolute paths to the local machine.
6. Follow the plan in order, beginning with the failing unit test.
7. Do not run the normal monitor workflow.
8. Run only the safe local verification commands.
9. Review the generated diff manually, especially:

   - removal of the fallback row;
   - canonical bracketed username selection;
   - command ordering;
   - separation of SQL stdout and diagnostic logging;
   - mode `0600`;
   - absence of raw payloads on console output.

10. Record final hashes and test results.
11. If production testing is required, make that a separate, explicitly
    authorized activity with a test instance and disposable destination data.

## LLM Resume Procedure

An LLM should:

1. Read this handoff completely.
2. Read the approved design completely.
3. Read the implementation plan completely.
4. Inspect the supplied script and verify its hash.
5. State any path adaptation before editing.
6. Use test-driven development:

   - add the failing tests;
   - run them and record the expected failure;
   - make the smallest parser change;
   - rerun tests;
   - add the log-permission test;
   - run final verification.

7. Avoid cloud and database execution.
8. Preserve unrelated user changes.
9. Report exact verification evidence rather than claiming success from code
   inspection.
10. Stop and ask if the script has materially diverged from the analyzed
    baseline.

If the environment provides the Superpowers skills:

- Use `superpowers:executing-plans` for inline execution of the approved plan.
- Use `superpowers:test-driven-development` for implementation work.
- Use `superpowers:systematic-debugging` if a test fails unexpectedly.
- Use `superpowers:verification-before-completion` before claiming completion.

If those skills are unavailable, follow the same test-first checkpoints
manually.

## Copy-Paste Resume Prompt

Give the receiving LLM the original script, this handoff, the design, and the
plan, then use:

```text
We need to implement an approved fix for the embedded Python parser in
gcp_general_log_monitor.3.sh.

Read these files completely before editing:
1. The attached gcp_general_log_monitor.3.sh
2. The GCP Cloud SQL General-Log Parser Handoff README
3. 2026-07-24-gcp-general-log-parser-design.md
4. 2026-07-24-gcp-general-log-parser.md

Current state: analysis/design/planning are complete, but no implementation has
been made. Verify the script SHA-256 against the handoff. If it differs,
compare versions and explain the divergence before changing anything.

Execute the implementation plan test-first. Keep the runtime deliverable as one
Bash script with a marked, import-safe embedded Python parser. Use the approved
single anchored named-group regex and the exact 36-command whitelist. Build
user_host from the username inside brackets. Delete the synthetic fallback row.
Rejected payloads must generate no SQL and must be written verbatim to the
mode-0600 monitor log only, never to the console. Mixed batches keep valid
events; all-invalid input cannot reach MySQL.

Safety constraints:
- Do not run the normal monitor workflow.
- Do not run gcloud or mysql.
- Do not use --dry-run by itself because the current script still performs a
  gcloud describe.
- The only permitted shell smoke-test path is --fetch-only --dry-run with a
  restricted PATH, as specified in the plan.
- Unit-test the extracted embedded Python block.
- Preserve unrelated behavior and changes.

If Superpowers skills are available, use executing-plans,
test-driven-development, systematic-debugging when needed, and
verification-before-completion. Otherwise follow the plan's RED/GREEN
checkpoints manually.

At completion, report changed files, every verification command and result,
retained baseline warnings, final SHA-256 values, and explicit confirmation
that no GCP or database operation was executed.
```

## Decision Log

Decisions made with the requester:

1. Rejected payloads are logged and generate no insert.
2. Rejected payloads are logged in full without sanitization.
3. The raw rejected payload belongs in the log only, not console output.
4. The chosen parsing strategy is a single strict regex.
5. The parser uses named groups.
6. The bracketed username is canonical.
7. Command types use a strict source-backed whitelist.
8. The whitelist should be as comprehensive as presently supportable.
9. The source-backed union contains 36 accepted labels.
10. Unknown command types are rejected rather than guessed.
11. Mixed batches continue with valid events.
12. All-rejected batches produce no SQL and cannot reach MySQL.
13. The design and implementation plan were reviewed and approved.

## Authoritative Sources

- Cloud SQL database versions:
  <https://docs.cloud.google.com/sql/docs/mysql/db-versions>
- MySQL 5.6.51 command-name mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/mysql-5.6.51/sql/sql_parse.cc>
- MySQL 5.7 command-name mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/5.7/sql/sql_parse.cc>
- MySQL 8.4 command-name mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/8.4/sql/sql_parse.cc>
- Current MySQL protocol command enumeration:
  <https://dev.mysql.com/doc/dev/mysql-server/latest/my__command_8h.html>

## Completion Checklist

The implementation is ready for handoff only when every item is true:

- [ ] Original script divergence was checked.
- [ ] Parser contract tests were added first and observed failing.
- [ ] The exact 36-command whitelist is present.
- [ ] Command alternation is escaped and sorted longest-first.
- [ ] The regex is fully anchored and uses named groups.
- [ ] The supplied example produces the requested values.
- [ ] The canonical bracketed username is used.
- [ ] Timestamp normalization removes only the final `Z`.
- [ ] All old fallback assignments are absent.
- [ ] Rejected payloads produce no SQL.
- [ ] Rejected payloads appear verbatim in the log.
- [ ] Rejected payloads do not appear on console output.
- [ ] Mixed batches keep only valid inserts.
- [ ] All-invalid input cannot reach MySQL.
- [ ] The monitor log is mode `0600`.
- [ ] All 36 command labels have executable coverage.
- [ ] Prefix collisions have executable coverage.
- [ ] Parser tests pass.
- [ ] Safe shell integration test passes.
- [ ] Bash syntax validation passes.
- [ ] ShellCheck has no new warnings.
- [ ] Final hashes were recorded.
- [ ] No GCP operation was run during local verification.
- [ ] No database operation was run during local verification.

## Handoff Boundary

This handoff authorizes local parser implementation and local non-operational
verification only. It does not authorize:

- changing a Cloud SQL flag;
- enabling or disabling general logging;
- reading production logs;
- connecting to a production database;
- inserting test rows into a real schema;
- deploying the script;
- running it against production.

Those actions require separate, explicit authorization and fresh environment
review.
