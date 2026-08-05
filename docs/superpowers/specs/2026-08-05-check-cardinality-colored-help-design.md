# Check Cardinality Colored Help Design

## Objective

Make `mysql/estimations/check_cardinality.sh` help output friendly, structured,
and always colored whenever help is requested.

## Scope

This change affects only the help renderer and its automated tests. Runtime
report colors, SQL behavior, analysis modes, exports, and exit codes remain
unchanged.

## Behavior

All three help paths must render the same colored content and exit with code 0:

- no arguments;
- `-h`;
- `--help`.

Help colors are unconditional. They do not depend on whether stdout is a TTY,
whether `TERM` is set, or whether output is redirected. `--no-color --help` and
`--help --no-color` also remain colored because `--no-color` applies to runtime
reports, not the explicitly requested help screen.

## Presentation

The help renderer owns a dedicated ANSI palette rather than reusing the
terminal-aware runtime palette:

- title: bold cyan;
- section headers: bold yellow;
- option names and flags: green;
- metavariables and defaults: cyan;
- safety statements: yellow, with the production refusal highlighted in red;
- examples: readable cyan command lines.

ANSI sequences must wrap text without changing spacing. The underlying help
content retains the complete usage, option reference, examples, and safety
contract already documented by the script.

## Implementation

`show_help` will declare its own local ANSI values using `printf`, then render
the screen through ANSI-aware `printf` calls. It must not depend on
`initialize_colors`, so it remains safe when called during early argument
parsing or before runtime defaults are fully processed.

The implementation must remain compatible with macOS Bash 3.2 and Linux Bash,
use no GNU-only text-processing behavior, and preserve `set -euo pipefail`.

## Tests

Integration tests execute the real script and verify:

- no arguments, `-h`, and `--help` return status 0;
- each path contains real ANSI escape bytes;
- each path retains the title, usage, analysis, output/runtime, examples, and
  safety sections;
- `--no-color --help` and `--help --no-color` remain colored;
- ordinary runtime output with `--no-color` remains free of ANSI sequences;
- the complete existing test suite stays green under macOS Bash 3.2.
