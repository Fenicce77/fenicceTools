# Buffer Pool Tracker Interactive Legend Design

## Objective

Display the repository-standard reduced interactive help at the bottom of each eligible TTY snapshot rendered by `mysql/monitoring/bp_tracker.sh`.

## Behaviour

- The legend is rendered after the dashboard sections in interactive TTY mode.
- It documents only implemented controls: `Interactive options: [q] Quit`.
- The label uses bold style; the key uses option color and Quit uses error color.
- `--no-color` retains the legend without styling.
- Redirected output, `TERM=dumb`, and output-file logs do not include the legend or ANSI control sequences.
- No keyboard behaviour changes; `q` remains the sole interactive control.

## Validation

Extend the Buffer Pool tracker test suite with pseudo-TTY assertions for the legend and its color/no-color parity. Preserve one-shot non-TTY output and plain logs. Run focused tests, Bash syntax validation, and diff check.
