# Check Cardinality Terminal Width Detection Design

## Objective

Make the terminal report in `mysql/estimations/check_cardinality.sh` use the
actual available terminal width on macOS and Linux, while providing an explicit
override for terminals, IDE panes, SSH wrappers, and redirected execution where
geometry cannot be detected reliably.

## Root Cause

The current `refresh_terminal_width` function captures `tput cols` in command
substitution. On macOS this can return the static terminfo width instead of the
active pseudo-terminal geometry. A reproduced 180-column pseudo-terminal
returned `80` from `tput cols`; the script rejected that value and selected its
120-column fallback. The formatter then assigned only its 12-character minimum
to `INDEXES`, producing many narrow continuation lines despite substantial
unused screen space.

The report width allocator and multiline renderer are functioning according to
their inputs. The correction belongs in terminal-width acquisition.

## CLI Contract

Add this optional long parameter:

```text
--terminal-width N    Override detected terminal width; minimum: 120
```

`N` must be an integer greater than or equal to 120. Missing, non-numeric, and
smaller values are CLI errors, use exit status 2, and retain the existing
`Try --help for usage.` guidance.

The always-colored help includes the option under `Output and runtime` and adds
an example showing `--terminal-width 180`. No short form is added, avoiding new
single-letter conflicts.

## Detection Precedence

For each table report, width selection follows this order:

1. A validated `--terminal-width N` value.
2. Active terminal geometry reported by `stty size`.
3. A numeric exported `COLUMNS` value.
4. A numeric value reported by `tput cols`.
5. The existing 120-column fallback.

Automatic candidates are accepted only when they are integers greater than or
equal to 120. Zero, malformed, unavailable, and narrower results are ignored
and detection continues to the next source. The explicit override is validated
during argument parsing and therefore fails instead of being silently ignored.

When standard input is a TTY, `stty size` reads it directly. When standard
output is a TTY but input is redirected, the detector attempts to read
`/dev/tty`. Expected failures are suppressed and safely handled under
`set -euo pipefail`. No GNU-specific `stty` flags are used.

The selected width is not capped: a 180-column terminal produces 180-character
table lines and gives the surplus to the existing adaptive `INDEXES` allocation.
The 120-column minimum remains necessary to preserve complete numeric cells,
the existing text-field floors, and `INDEXES_WIDTH >= 12`.

## Rendering and Data Behavior

Only width acquisition and CLI/help handling change. The existing allocator
continues to distribute the selected width, and the existing multiline renderer
continues to wrap complete `TYPE` and `INDEXES` values.

The change does not affect:

- MySQL queries or exact/metadata mode selection;
- cardinality calculations or warning thresholds;
- terminal color selection or TTY color policy;
- `ENUM` display normalization;
- CSV/TSV fields or values;
- status handling, error ordering, or exit codes other than invalid new CLI
  input.

## Compatibility

The implementation remains compatible with macOS Bash 3.2 and Linux Bash. It
uses portable shell parameter expansion and `stty size`, declares any nontrivial
`awk` source before invocation, and wraps expected detection failures with
`|| true`.

The conventional exported `COLUMNS` variable remains a supported fallback and
can still be used by automation. `--terminal-width` is the deterministic option
when the process has no controlling TTY.

## Tests

The shell integration suite will verify:

- help documents `--terminal-width` and its minimum;
- `--terminal-width 160` produces exactly 160-character header, primary, and
  continuation lines;
- the explicit override takes precedence over `stty`, `COLUMNS`, and `tput`;
- missing, non-numeric, and values below 120 return exit status 2;
- a 180-column pseudo-terminal with no exported `COLUMNS` selects 180 through
  `stty`, including on the macOS path where captured `tput` reports its default;
- a numeric exported `COLUMNS` value is used when active TTY geometry is
  unavailable;
- invalid automatic candidates fall through to the next source;
- non-TTY execution with no valid candidate retains the 120-column fallback;
- wrapped values remain lossless and separators remain aligned at detected and
  overridden widths;
- all existing CLI, SQL, analysis, color, wrapping, and export tests remain
  green on macOS Bash 3.2 and Linux-compatible syntax.
