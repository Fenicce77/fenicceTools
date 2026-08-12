# Open Sessions Monitor Design

## Purpose

Standardize `mysql/sessions/check_opened_sessions_interactive.sh` as the canonical
continuous MySQL sessions monitor. It must retain the existing short-option
workflow while providing a safe, testable, macOS/Linux-compatible interface.

The other session-monitor scripts remain unchanged. This work does not deprecate
or remove them.

## Command-Line Interface

The monitor retains `-l`, `-t`, `-u`, `-d`, `-h`, and `-o`, and provides their
long forms. It adds:

- `--diff` to start with sample deltas enabled.
- `--log-file PATH` to select a new output file explicitly.
- `--mysql-bin PATH` to select the local MySQL client.
- `--no-color` to disable ANSI styling.
- `--help` to show complete help and exit successfully.

`-l` / `--login-path` is mandatory. No argument, an unknown option, a missing
option value, or an invalid value emits a colored `ERROR` followed by the
complete help text and exits non-zero. Help is based on the repository standard
established by `mysql/estimations/check_cardinality.sh` and includes purpose,
syntax, options, runtime keys, and examples.

## Runtime Behavior

When attached to an interactive terminal with a usable terminal type, each
sample replaces the prior frame. Output is not cleared when redirected or when
the terminal is unsuitable; that mode emits one sample and terminates without
ANSI sequences.

The header shows timestamp, refresh interval, current filters, total matching
connections, diff mode, and logging state. Connection rows aggregate by MySQL
user, schema, and normalized host, remain aligned, and use color only for the
terminal presentation.

The persistent reduced legend is:

`Interactive options: [q] Quit [m] Modify filters [d] Toggle diff [l] Toggle logging`

`q` exits cleanly. `m` opens a prompt to change user list, schema, and host;
empty answers retain the current values. `d` enables or disables delta display.
`l` enables or disables plain-text logging. Interactive prompts redraw a fresh
frame after a successful change.

## Query Safety and Data Handling

Filter values are SQL-escaped before they are placed in a query. A comma-
separated user value is parsed into independently quoted values for `IN (...)`.
The host filter is treated as a literal substring: `%`, `_`, and the escape
character are escaped before use in `LIKE ... ESCAPE`. The monitor preserves
the current explicit exclusion set for system and monitoring users.

One aggregation query returns both grouped rows and the matching total when
possible; the implementation avoids an additional unfiltered PROCESSLIST scan
per frame. The output log is plain text and never receives ANSI escape
sequences. An existing requested `--log-file` destination is rejected unless a
future explicit overwrite option is designed and approved.

## Testing

Automated Bash tests with a fake MySQL client cover complete colored help,
all CLI errors, option compatibility, generated SQL escaping, non-TTY output,
TTY refresh and the colored runtime legend, live key controls, diff calculation,
and logging safety. They run on macOS and Linux without requiring a database.
