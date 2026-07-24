# GCP Cloud SQL General Log Parser Design

**Date:** 2026-07-24  
**Status:** Approved in conversation  
**Source script:** `/Users/jalvarez/Downloads/gcp_general_log_monitor.3.sh`

## Purpose

Correct the script's `textPayload` parsing so that valid MySQL general-log
events produce accurately populated insert statements and malformed events
never produce synthetic database rows.

The change is limited to payload parsing, rejection reporting, and the parser
tests needed to establish those behaviors. Cloud SQL flag management, log
retrieval, batching, and MySQL execution remain outside this design.

## Problem

The observed fallback insert used fabricated values:

- `thread_id=0`
- `user_host='unknown'`
- `server_id=1`
- `command_type='Query'`

and placed the complete payload in `argument`. This turns a parsing failure into
valid-looking but incorrect data.

The existing parser also constructs `user_host` from the complete text before
`@`. For a value such as `dev-userapp[dev-userapp]`, that would produce
`dev-userapp[dev-userapp]@IP` even when the rest of the payload matches.

## Input Grammar

After removing transport-level leading and trailing whitespace for matching,
each accepted payload must have this structure:

```text
event_time outer_username[canonical_username] @ [host]thread_id server_id command_type argument
```

Rules:

1. `event_time` is an ISO-like MySQL timestamp:
   `YYYY-MM-DDTHH:MM:SS`, an optional fractional part of one to six digits,
   and a required trailing `Z`.
2. One or more whitespace characters separate ordinary fields.
3. Whitespace around `@` is flexible.
4. Whitespace between the closing host bracket and `thread_id` is optional.
5. `thread_id` and `server_id` contain digits only.
6. `command_type` is one of the source-backed values in the command whitelist.
7. `argument` is the complete remaining text and is optional for commands such
   as `Quit`.
8. The canonical username is the value inside the username brackets. The outer
   username is parsed but is not required to equal the bracketed username.
9. The bracketed host accepts IPv4, IPv6, and hostname-like values without
   attempting network validation.

The parser retains the original payload separately from the stripped matching
value so a rejected payload can be logged verbatim.

## Single-Regex Parser

Use one compiled, anchored expression with named groups and `fullmatch()`.
Named groups replace positional group indexes.

Conceptually:

```python
pattern = re.compile(
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

`command_pattern` is generated from the explicit command whitelist. Command
names are sorted longest-first before the alternation is built. This prevents
prefix collisions such as:

- `Binlog Dump` versus `Binlog Dump GTID`
- `Connect` versus `Connect Out`

Spaces inside a known command name are represented by `\s+`, allowing tabs or
multiple spaces while retaining a strict command vocabulary.

## Command Whitelist

The whitelist is the union of official MySQL command-name mappings for the
MySQL versions supported by Cloud SQL, plus the official legacy terminology
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

`Register Slave` is retained for MySQL 5.x and compatibility terminology.
`Register Replica` is the current spelling. `clone` remains lowercase because
that is the server's mapped label.

The alternation is constructed as follows:

```python
command_pattern = "|".join(
    re.escape(command).replace(r"\ ", r"\s+")
    for command in sorted(COMMAND_TYPES, key=len, reverse=True)
)
```

Unknown command types are rejected and logged rather than interpreted
permissively.

## Field Normalization

For a successful match:

- `event_time`: remove only the final `Z`, then replace the single date/time
  separator `T` with a space.
- `user_host`: join the bracketed canonical username and bracketed host as
  `username@host`.
- `thread_id`: use the matched digit string.
- `server_id`: use the matched digit string.
- `command_type`: collapse internal whitespace to one ASCII space.
- `argument`: preserve the captured remainder; use an empty string when absent.

For the supplied example, the normalized record is:

```text
thread_id:    15397
user_host:    dev-userapp@XX.XX.XXX.XXX
server_id:    4226757038
command_type: Change user
argument:     dev-userapp@XX.XX.XXX.XXX on dev_betika_africa using TCP/IP
event_time:   2026-07-23 12:01:55.896580
```

## Rejection and Batch Behavior

When a payload does not fully match:

1. Do not add an insert statement.
2. Append a rejection marker, reason, and the complete original raw payload to
   the existing monitor log.
3. Do not sanitize, redact, truncate, or escape the raw payload in the log.
4. Do not send the raw payload through `log_msg`, because `log_msg` also prints
   to the console. Rejected raw payloads belong in the log only.
5. Keep the monitor log restricted to the invoking user with mode `0600`.

The parser records accepted and rejected counts:

- A mixed batch generates insert statements only for accepted events and
  reports the rejected count.
- A wholly rejected batch generates no SQL and must not invoke MySQL.
- No fallback values such as `0`, `unknown`, `1`, or `Query` are generated.
- Invalid top-level JSON also generates no SQL and is reported as a parser
  failure.

Parser diagnostics must use a channel separate from SQL standard output so raw
payloads and status text cannot contaminate the generated SQL file.

## Testing

The parser test set must cover:

1. The supplied `Change user` payload and its exact normalized fields.
2. Tabs and multiple spaces between fields.
3. No whitespace between `]` and `thread_id`.
4. IPv4-, IPv6-, and hostname-like bracketed hosts.
5. Argument-bearing and argumentless commands.
6. Every one of the 36 accepted command labels.
7. Prefix-collision commands, especially `Binlog Dump GTID` and `Connect Out`.
8. Legacy `Register Slave` and current `Register Replica`.
9. Malformed timestamps.
10. Malformed username/host brackets.
11. Nonnumeric thread or server IDs.
12. Unknown command types.
13. Mixed valid and rejected events.
14. An all-rejected batch.
15. Invalid JSON.
16. Verbatim raw-payload logging without SQL generation.
17. Accepted/rejected summary counts.
18. Monitor log mode `0600`.

Tests must explicitly assert that rejected input never produces an insert
containing the former fallback values.

## Acceptance Criteria

The change is complete when:

- The supplied example generates the requested insert values.
- All source-backed command labels are recognized without prefix
  misclassification.
- Malformed payloads are present verbatim in the monitor log and absent from
  generated SQL.
- Mixed batches retain valid events.
- All-invalid input cannot reach the MySQL import step.
- Parser tests and shell-level integration tests pass without invoking GCP or a
  database.

## Sources

- Google Cloud SQL supported database versions:
  <https://docs.cloud.google.com/sql/docs/mysql/db-versions>
- MySQL 5.6.51 `command_name` mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/mysql-5.6.51/sql/sql_parse.cc>
- MySQL 5.7 `command_name` mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/5.7/sql/sql_parse.cc>
- MySQL 8.4 `Command_names::m_names` mapping:
  <https://raw.githubusercontent.com/mysql/mysql-server/8.4/sql/sql_parse.cc>
- Current MySQL protocol command enumeration:
  <https://dev.mysql.com/doc/dev/mysql-server/latest/my__command_8h.html>
