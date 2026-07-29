# Go Terminal Mode Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate staircase rendering and transient `/dev/stdout` `EAGAIN` failures in the interactive Go ProxySQL monitor.

**Architecture:** Keep the existing single-owner input goroutine, but wait for input readiness with `golang.org/x/sys/unix.Poll` instead of changing terminal descriptor flags with `O_NONBLOCK`. Continue using `golang.org/x/term` to capture and restore the original terminal state, then apply a small Darwin/Linux-specific adjustment that restores output post-processing and signal handling while retaining immediate, non-echoed key input.

**Tech Stack:** Go 1.22+, `golang.org/x/term`, `golang.org/x/sys/unix`, Darwin termios, Linux termios.

## Global Constraints

- Preserve macOS and Linux compatibility.
- Do not change the monitor CLI, view model, refresh behavior, prompt ownership, or cleanup lifecycle.
- Never set `O_NONBLOCK` on the terminal file description.
- Interactive mode must retain `OPOST`, `ONLCR`, and `ISIG`.
- Restore the exact original terminal state on prompts and shutdown.
- Use test-driven development and run the race detector before completion.

---

### Task 1: Cancellable Input Without Descriptor Mutation

**Files:**
- Modify: `mysql/proxysql/go/internal/terminal/terminal_test.go`
- Modify: `mysql/proxysql/go/internal/terminal/terminal.go`
- Modify: `mysql/proxysql/go/go.mod`
- Modify: `mysql/proxysql/go/go.sum`

**Interfaces:**
- Consumes: `Controller.Keys(context.Context) <-chan rune` and the existing single-owner input goroutine.
- Produces: `readInput` backed by `unix.Poll` and `unix.Read`, with no file-status flag mutation.

- [x] **Step 1: Write the failing descriptor regression test**

Add `TestKeyReaderDoesNotEnableNonblockingMode`. Create an `os.Pipe`, record `F_GETFL`, start `Controller.Keys`, write and receive one byte, then assert `O_NONBLOCK` remains identical while the reader is active.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
go test ./internal/terminal -run TestKeyReaderDoesNotEnableNonblockingMode -count=1
```

Expected: FAIL because the current `syscall.SetNonblock(fd, true)` changes the pipe's file-status flags.

- [x] **Step 3: Replace nonblocking mode with readiness polling**

Import `golang.org/x/sys/unix` directly. Replace `syscall.SetNonblock`, timer allocation, and `syscall.Read` with a 25 ms `unix.Poll` loop followed by `unix.Read`. Handle `EINTR`, `POLLERR`, `POLLHUP`, and context cancellation without mutating descriptor flags.

- [x] **Step 4: Run the focused and package tests and verify GREEN**

Run:

```bash
go test ./internal/terminal -run TestKeyReaderDoesNotEnableNonblockingMode -count=1
go test ./internal/terminal -count=1
```

Expected: PASS.

### Task 2: Terminal Output Processing on Darwin and Linux

**Files:**
- Create: `mysql/proxysql/go/internal/terminal/termios.go`
- Create: `mysql/proxysql/go/internal/terminal/termios_darwin.go`
- Create: `mysql/proxysql/go/internal/terminal/termios_linux.go`
- Create: `mysql/proxysql/go/internal/terminal/termios_test.go`
- Modify: `mysql/proxysql/go/internal/terminal/terminal.go`

**Interfaces:**
- Consumes: the raw terminal state established by `term.MakeRaw(fd)`.
- Produces: `configureInteractiveTermios(*unix.Termios)` and `enableInteractiveOutput(fd int) error`.

- [x] **Step 1: Write the failing termios flag test**

Add `TestConfigureInteractiveTermios`. Start with zeroed `unix.Termios`, call `configureInteractiveTermios`, and assert `OPOST`, `ONLCR`, and `ISIG` are set.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
go test ./internal/terminal -run TestConfigureInteractiveTermios -count=1
```

Expected: compilation fails because `configureInteractiveTermios` does not exist.

- [x] **Step 3: Add portable configuration and OS-specific ioctl adapters**

Implement the shared bit configuration in `termios.go`. On Darwin, read/write termios with `TIOCGETA` and `TIOCSETA`; on Linux, use `TCGETS` and `TCSETS`. In `Controller.Enter`, call `enableInteractiveOutput` after `term.MakeRaw`; if it fails, immediately restore the captured state and return the error.

- [x] **Step 4: Run the focused and package tests and verify GREEN**

Run:

```bash
go test ./internal/terminal -run TestConfigureInteractiveTermios -count=1
go test ./internal/terminal -count=1
```

Expected: PASS.

### Task 3: Cross-Platform and Interactive Verification

**Files:**
- Verify: `mysql/proxysql/go/...`

**Interfaces:**
- Consumes: the corrected terminal controller.
- Produces: verified Darwin and Linux binaries with unchanged CLI behavior.

- [x] **Step 1: Format and synchronize module metadata**

Run:

```bash
gofmt -w internal/terminal/terminal.go internal/terminal/terminal_test.go internal/terminal/termios.go internal/terminal/termios_darwin.go internal/terminal/termios_linux.go internal/terminal/termios_test.go
go mod tidy
```

- [x] **Step 2: Run full static and race verification**

Run:

```bash
go test ./...
go test -race ./...
go vet ./...
```

Expected: all packages pass with no race reports or vet findings.

- [x] **Step 3: Cross-compile both supported operating systems**

Run:

```bash
GOOS=darwin GOARCH=arm64 go build ./cmd/proxysql-monitor
GOOS=linux GOARCH=amd64 go build ./cmd/proxysql-monitor
```

Expected: both builds succeed.

- [x] **Step 4: Run an interactive PTY smoke test**

Build a temporary Darwin binary, run it in a PTY with `--login-path=devel-proxysql01-node01`, observe at least two refreshes, then send `q`.

Expected: every line begins at column 1, refreshes complete without `/dev/stdout` `EAGAIN`, and terminal state is restored on exit.
