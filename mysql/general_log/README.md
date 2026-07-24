# GCP Cloud SQL General-Log Monitor

`gcp_general_log_monitor.sh` captures Cloud SQL MySQL general-log entries from
Cloud Logging, translates complete valid payloads to SQL inserts, and can load
them into `general_log_analysis`.

## Implemented Parser Contract

The embedded Python parser accepts a complete payload with this structure:

```text
event_time outer_username[canonical_username] @ [host]thread_id server_id command_type argument
```

It uses the username inside brackets and the bracketed host:

```text
outer_user[canonical_user] @ [10.10.10.1] -> canonical_user@10.10.10.1
```

The parser validates the complete payload, recognizes the approved 36 MySQL
command labels, and generates SQL only for accepted entries. It does not
reconstruct Cloud Logging continuation fragments. A malformed or truncated
standalone entry is written verbatim to the monitor log and never becomes a
synthetic `unknown`/`Query` row.

Rejected raw payloads can contain sensitive SQL, credentials, tokens, or
business data. They are written only to the monitor log, which is created with
mode `0600`. Do not copy that log to public tickets or external services.

## Usage

```bash
./gcp_general_log_monitor.sh \
  --project my-gcp-project \
  --instance my-cloudsql-instance \
  --login-path monitoring-login \
  --schema rmc_betika \
  --duration 60
```

Generate the SQL artifact without importing it:

```bash
./gcp_general_log_monitor.sh \
  --project my-gcp-project \
  --instance my-cloudsql-instance \
  --login-path monitoring-login \
  --schema rmc_betika \
  --fetch-only \
  --generate-only
```

The generated file is:

```text
./tmp/gcp_general_log_capture.sql
```

`-G` and `--generate-only` skip only the final `mysql` import. They work with
normal capture and `--fetch-only`. They are intentionally incompatible with
`--dry-run`; the script exits with status `2` before executing an external
command for that combination.

## Flag Lifecycle

During normal capture, the script records the initial `general_log` state. If
it enables the flag, it restores it after the capture interval and before
Cloud Logging retrieval. If the process receives `SIGINT` or `SIGTERM` during
capture, it stops the capture sleep and attempts restoration before exit.

If `general_log` was already enabled, the script leaves it enabled.

## Local Verification

The test suite uses fixtures and local command stubs only. It does not invoke
real GCP or MySQL commands.

```bash
python3 -m unittest discover \
  -s tests/gcp-general-log-parser \
  -p 'test_parser.py' -v

bash tests/gcp-general-log-parser/test_shell_integration.sh

bash -n gcp_general_log_monitor.sh \
  tests/gcp-general-log-parser/test_shell_integration.sh
```

The shell integration test verifies strict parser output, `--generate-only`,
mode `0600` monitor logs, normal import control flow, and restoration after an
interruption.

## Design and Plan

- `2026-07-24-gcp-general-log-parser-design.md`
- `2026-07-24-gcp-general-log-parser.md`

These documents define the parser grammar, rejection policy, command
whitelist, flag lifecycle, and verification criteria.
