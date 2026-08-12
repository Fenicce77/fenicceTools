# ProxySQL Bash Monitor Terminal Contract Design

## Objective

Make `mysql/proxysql/proxysql_connections_monitor.sh` follow the terminal-output
contract used by the repository's interactive monitors. Interactive monitoring
must retain its current semantic colors and redraw behaviour, while redirected
output, help, errors, and logs remain free of terminal control sequences.

## Scope

- Add `--no-color` to disable ANSI styling without disabling interactive screen
  refresh.
- Detect an interactive terminal through standard output being a TTY and a
  usable `TERM` value (not unset or `dumb`).
- Emit color codes only when color is enabled for that terminal.
- Emit the home-and-clear sequence only for an eligible interactive terminal.
- Preserve the existing monitor views, keyboard controls, query transport,
  sampling, formatting, and plain-text log output.

## Behavioural Contract

| Invocation context | Colors | Screen refresh |
| --- | --- | --- |
| Eligible TTY | Enabled by default | Enabled |
| Eligible TTY with `--no-color` | Disabled | Enabled |
| Redirected stdout or `TERM=dumb` | Disabled | Disabled |

The option must be visible in the colored interactive help. When stdout is not
an eligible terminal, help and errors must be plain text and contain no ANSI
control sequences. `--no-color` must not alter data, logging, refresh timing,
or keyboard semantics.

## Design

Introduce a small terminal-capability layer initialized after arguments are
parsed. It derives independent `COLOR_ENABLED` and `SCREEN_REFRESH_ENABLED`
flags. The color initializer assigns empty style values when color is disabled;
otherwise it retains the existing `tput` values and orange fallback. A dedicated
screen-refresh function conditionally emits the clear sequence, used by both
the help renderer and monitor-frame renderer.

The current duplicate early color initialization will be removed so command-line
options can affect the terminal layer before any output. Sourcing the script
will continue to initialize safe plain defaults for its formatter tests.

## Validation

Extend the existing Bash test suite with deterministic assertions for:

- parsing `--no-color`;
- help redirected to a file containing no ANSI sequence;
- `--no-color` rendering containing no ANSI sequence;
- two pseudo-TTY monitor frames each starting with a clear sequence;
- the same pseudo-TTY frames retaining clear sequences with `--no-color`;
- output-file logging remaining ANSI-free.

Run the focused ProxySQL Bash suite, Bash syntax validation, and inspect the
working-tree diff before committing. No MySQL or ProxySQL server is required:
the existing fake client remains the test fixture.
