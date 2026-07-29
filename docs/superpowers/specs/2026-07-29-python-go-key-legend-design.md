# Python and Go Monitor Key Legend Design

## Goal

Add an always-visible interactive key legend to the Python and Go ProxySQL monitors so their terminal interfaces expose the same controls as the Bash monitor.

## Scope

The change applies only to normal interactive mode. Smoke-test output and clean file logging remain unchanged.

Both interactive monitors will append this footer after the current view body:

```text

Interactive Options:
 [v] Toggle View (Conn/Query/Digest/Backend) | [r] Refresh | [s] Sort | [p] Pause
 [u] Filter | [t] Threshold | [q] Quit
```

The leading blank line separates monitor data from controls. The two bounded option lines prevent the long Bash legend from wrapping at the monitors' supported minimum display width.

## Color Contract

The legend will reproduce the Bash color semantics:

- `Interactive Options:` uses bold text.
- Key letters use bold magenta.
- `Toggle View` uses bold blue.
- `Refresh`, `Sort`, and `Filter` use bold green.
- `Pause` uses bold yellow.
- `Threshold` and `Quit` use bold red.
- Separators and explanatory text use the terminal default color.
- Every colored segment ends with an explicit reset sequence.

Python and Go will each own a small render-level legend helper. Query/view formatters remain responsible only for sampled data, avoiding coupling UI chrome to database formatting.

## Rendering and Data Flow

The interactive render path will concatenate header, optional filters, separator, sampled body, and the colored legend into one terminal frame. No additional terminal-size lookup, SQL execution, child process, goroutine, timer, or refresh cycle is introduced.

Logging continues to receive the existing clean `RenderedView` value before screen rendering. The legend therefore cannot enter `-o` output files and cannot change the `HAS_DATA`/row-count behavior.

The Python `render()` return value and Go output writer will include the legend because both represent the full interactive screen.

## Generated Go Binary

The repository currently tracks `mysql/proxysql/go/proxysql-monitor` as a Darwin arm64 build. After source verification, it will be rebuilt from the updated Go source so the checked-in executable matches the interactive behavior. Linux deployments continue to build from source; Linux amd64 compilation remains part of verification.

## Error Handling

Legend construction is deterministic and performs no I/O. Existing Python writer/flush behavior and Go `fmt.Fprintf` error propagation remain unchanged.

## Testing

Python and Go render regression tests will independently verify:

- the heading is present;
- all seven keys and labels are present;
- the options occupy two explicit lines;
- ANSI color sequences are present in interactive output;
- sampled clean logging remains ANSI-free and contains no legend.

The final verification includes:

- complete Python test suite;
- complete Go test suite;
- Go race detector and `go vet`;
- Darwin arm64 and Linux amd64 Go builds;
- live PTY smoke tests for both ports against `devel-proxysql01-node01`.

## Non-Goals

- Changing key behavior or adding new shortcuts.
- Adding a runtime legend toggle.
- Dynamically packing controls according to terminal width.
- Adding the legend to smoke-test or log-file output.
- Changing view formatting, SQL queries, refresh cadence, or transport lifecycle.

## Acceptance Criteria

- Python and Go display the approved two-line colored legend on every interactive refresh.
- Existing keys continue to behave unchanged.
- Log files remain clean and legend-free.
- The footer does not wrap at the supported minimum terminal width.
- Test, static-analysis, cross-build, and live PTY verification pass.
