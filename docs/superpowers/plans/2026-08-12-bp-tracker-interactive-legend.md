# Buffer Pool Tracker Interactive Legend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the standard reduced interactive-control legend to eligible tracker frames.

**Architecture:** Add one render-only helper after dashboard sections. It uses the existing screen-refresh flag and style variables and never writes to logs or non-TTY output.

**Tech Stack:** Bash 3.2, ANSI terminal escapes, macOS/Linux `script`, shell fake MySQL client.

## Global Constraints

- Preserve `set -euo pipefail`, Bash 3.2, macOS/Linux compatibility, and current keyboard behaviour.
- Render only `Interactive options: [q] Quit` in TTY frames.
- Preserve it with `--no-color`, exclude it from redirection, TERM=dumb, and logs.
- Preserve unrelated `lists/servers_login_list.hex.txt` changes.

### Task 1: Add RED pseudo-TTY coverage

Files: `mysql/monitoring/tests/test_bp_tracker.sh`.

- [ ] Add a Darwin/Linux pseudo-TTY helper sending q after a short delay. Capture normal and no-color xterm frames using the fake client. Require the literal legend in both, styling only in normal output, and no legend in redirected output/logs.
- [ ] Run `/bin/bash mysql/monitoring/tests/test_bp_tracker.sh`; expect failure because the legend is absent.
- [ ] Commit the test as `test(mysql): define buffer pool tracker interactive legend`.

### Task 2: Render the legend

Files: `mysql/monitoring/bp_tracker.sh`, `mysql/monitoring/tests/test_bp_tracker.sh`.

- [ ] Implement `render_interactive_legend()` to return successfully unless `SCREEN_REFRESH_ENABLED=true`; otherwise print a blank line and `Interactive options: [q] Quit` using bold label, green key, red action, and reset.
- [ ] Invoke it at the end of `render()` after optional sections. Do not call it from help, logging, or the one-shot non-TTY path.
- [ ] Run focused tests, Bash syntax validation, and `git diff --check`; commit as `feat(mysql): add buffer pool tracker interactive legend`.

### Task 3: Final verification

- [ ] Run the focused suite, syntax checks, `git diff --check HEAD~2..HEAD`, and status. Confirm only tracker/test changed.
- [ ] Report commits and verification evidence. Do not push without explicit authorization.
