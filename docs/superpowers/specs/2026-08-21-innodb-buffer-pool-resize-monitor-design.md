# InnoDB Buffer Pool Resize Monitor Design

## Purpose

Modernize `mysql/Innodb_buffer_pool_status.check.sh` as a specialized monitor
for online changes to `innodb_buffer_pool_size`. It remains separate from
`mysql/monitoring/bp_tracker.sh`, whose purpose is buffer pool activity and
pressure monitoring.

The existing script currently monitors buffer pool loading with a hard-coded
login path and an invalid inferred percentage. This design replaces that logic
with MySQL's resize status variables.

## Command-Line Interface

The monitor accepts:

- `-l`, `--login-path NAME` (required): MySQL login path.
- `-i`, `--interval SECONDS` (optional, default `5`): positive integer polling
  interval.
- `--mysql-bin PATH` (optional): regular executable MySQL client.
- `--no-color`: disable ANSI styling while retaining eligible TTY refresh.
- `-h`, `--help`: show complete help and exit successfully.

No arguments, invalid options, missing values, invalid intervals, or an
invalid client path emit a colored `ERROR` followed by full help and exit
non-zero. Help follows the repository standard: purpose, syntax, options,
runtime key, semantics, and examples.

## Data Collection

Each sample is a read-only query against `performance_schema.global_status`
for these variables:

- `Innodb_buffer_pool_resize_status`
- `Innodb_buffer_pool_resize_status_code`
- `Innodb_buffer_pool_resize_status_progress`

The same query retrieves `@@GLOBAL.innodb_buffer_pool_size` as the configured
target size. The monitor must not modify server variables, consume buffer pool
page metadata, or infer progress from page counts.

`Innodb_buffer_pool_resize_status_progress` is the percentage for the current
resize stage, not a global resize percentage: MySQL resets it to zero when the
status code changes. The UI labels it explicitly as `Stage progress` and never
claims it represents total operation completion.

When numeric status variables are unavailable, the monitor renders the textual
status with `Stage progress: N/A` and a clear compatibility note. It must not
invent a percentage.

## Terminal Behavior

In an eligible interactive terminal, each sample replaces the previous frame.
The view contains title, timestamp, login path, target buffer pool size,
refresh interval, stage/code, an ASCII progress bar, stage percentage, and the
server status message. It ends with:

`Interactive options: [q] Quit`

Colors provide an operational guide:

- Green: no resize in progress or successfully completed.
- Cyan: resize starting.
- Yellow: AHI work, block withdrawal, pool resize, or hash resize.
- Red: resize failure, unavailable required data, or query error.

`q` terminates cleanly. A status code of `0` exits successfully after rendering
the completed/no-resize snapshot; code `7` exits non-zero after rendering the
failure. Other stages continue at the configured interval.

When output is redirected or the terminal is unusable, the tool produces one
ANSI-free sample and exits. The runtime legend and clear-screen sequences are
TTY-only. `--no-color` removes styling but retains refresh in eligible TTYs.

## Testing

Introduce a fake MySQL client and Bash integration tests. Cover colored help,
all CLI failures, interval validation, exact read-only SQL, numeric stage
rendering, progress bar boundaries, status colors, unavailable numeric
variables, completion, failure, pseudo-TTY refresh and `q`, `--no-color`, and
one-shot redirected output. Run Bash syntax and relevant monitor regressions.
