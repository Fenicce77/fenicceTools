# ProxySQL Monitor Resource Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-refresh MySQL client startup and avoidable subprocesses with one resilient persistent session while preserving the existing ProxySQL monitor interface and output.

**Architecture:** Refactor the existing single Bash script into sourceable functions without splitting the deployable artifact. A named-pipe transport owns one unbuffered MySQL client and frames requests with sequence-specific sentinels; view sampling and rendering consume the transport through a narrow function interface. Dependency-free Bash tests inject a fake MySQL executable and directly exercise sourceable functions.

**Tech Stack:** Bash 3.2, ProxySQL admin SQL, POSIX named pipes, AWK, BSD/GNU-compatible `sed`.

## Global Constraints

- Support Bash 3.2 and newer on macOS and Linux.
- Run under `set -euo pipefail`.
- Preserve every existing CLI flag and interactive key.
- Keep comments, help text, logs, and runtime messages in English.
- Keep AWK programs in shell variables before invocation.
- Pass ANSI colors as separate AWK `printf` arguments outside padded fields.
- Preserve escaped and literal newline, carriage-return, and tab sanitization.
- Do not add dependencies, a daemon, or background sampling of inactive views.
- Use one five-second internal query-response timeout and retry a failed sample once.
- Query only the active view at the user-selected refresh interval.

---

### Task 1: Sourceable Script and Dependency-Free Test Harness

**Files:**
- Create: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh:1-100,192-358`

**Interfaces:**
- Produces: `initialize_defaults()`, `initialize_colors()`, `parse_arguments()`, `validate_arguments()`, and `main()`.
- Produces: a source guard using `[[ "${BASH_SOURCE[0]}" == "$0" ]]`.
- Consumes: no new interfaces.

- [ ] **Step 1: Write a failing test for safe sourcing and argument validation**

Create the test runner with an assertion library and initial tests:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_connections_monitor.sh"
TEST_COUNT=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$actual" == "$expected" ]] || fail "$message: expected [$expected], got [$actual]"
}

PROXYSQL_MONITOR_TESTING=1
# shellcheck source=../proxysql_connections_monitor.sh
source "$SCRIPT_PATH"

assert_eq "CONN" "$VIEW_MODE" "sourcing initializes the default view"

initialize_defaults
parse_arguments --login-path=proxysql_admin --refresh-time=0.5 --user-filter=app --threshold=12
assert_eq "proxysql_admin" "$LOGIN_PATH" "login path parsing"
assert_eq "0.5" "$REFRESH_TIME" "floating refresh parsing"
assert_eq "app" "$USER_FILTER" "user filter parsing"
assert_eq "12" "$THRESHOLD" "threshold parsing"

printf 'PASS: %s assertions\n' "$TEST_COUNT"
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: FAIL because sourcing executes the current mandatory-login-path path or because `initialize_defaults` is undefined.

- [ ] **Step 3: Refactor startup into sourceable functions**

Move global initialization and argument parsing into functions. The main
structure must be:

```bash
initialize_defaults() {
    LOGIN_PATH=""
    REFRESH_TIME=5
    USER_FILTER=""
    OUTPUT_FILE=""
    VIEW_MODE="CONN"
    SORT_MODE="CONN"
    THRESHOLD=0
    PAUSED=false
    QUERY_TIMEOUT=5
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --login-path=*) LOGIN_PATH="${1#*=}" ;;
            --login-path) require_option_value "$1" "${2-}"; LOGIN_PATH=$2; shift ;;
            -r|--refresh-time) require_option_value "$1" "${2-}"; REFRESH_TIME=$2; shift ;;
            --refresh-time=*) REFRESH_TIME="${1#*=}" ;;
            -u|--user-filter) require_option_value "$1" "${2-}"; USER_FILTER=$2; shift ;;
            --user-filter=*) USER_FILTER="${1#*=}" ;;
            -t|--threshold) require_option_value "$1" "${2-}"; THRESHOLD=$2; shift ;;
            --threshold=*) THRESHOLD="${1#*=}" ;;
            -o|--output-file) require_option_value "$1" "${2-}"; OUTPUT_FILE=$2; shift ;;
            --output-file=*) OUTPUT_FILE="${1#*=}" ;;
            -h|--help) usage 0 ;;
            *) print_error "Unknown parameter: $1"; usage 1 ;;
        esac
        shift
    done
}

main() {
    initialize_defaults
    initialize_colors
    parse_arguments "$@"
    validate_arguments
    initialize_monitor
    monitor_loop
}

initialize_defaults
initialize_colors

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

Make `usage()` accept an exit status, replace its external `clear` with
`printf '\033[H\033[2J'`, and retain all existing options and examples.

- [ ] **Step 4: Run the test and verify GREEN**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/proxysql_connections_monitor.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests/test_proxysql_connections_monitor.sh
git commit -m "refactor: make ProxySQL monitor testable"
```

---

### Task 2: Persistent Framed MySQL Transport

**Files:**
- Create: `mysql/proxysql/tests/fake_mysql.sh`
- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh`

**Interfaces:**
- Consumes: `LOGIN_PATH` and `QUERY_TIMEOUT`.
- Produces: `start_mysql_session() -> 0|1`, `stop_mysql_session() -> 0`,
  `mysql_session_alive() -> 0|1`, `execute_query(sql) -> 0|1`,
  and `execute_query_with_retry(sql) -> 0|1`.
- Produces globals: `MYSQL_PID`, `MYSQL_INPUT_FD`, `MYSQL_OUTPUT_FD`,
  `MYSQL_SESSION_DIR`, `MYSQL_REQUEST_SEQUENCE`, `QUERY_RESULT`, and
  `LAST_DB_ERROR`.

- [ ] **Step 1: Write a fake persistent client**

Create an executable fake that records one launch and responds to sentinel and
fixture queries:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_MYSQL_STATE_DIR:?FAKE_MYSQL_STATE_DIR is required}"
printf '%s\n' "$$" >> "$FAKE_MYSQL_STATE_DIR/launches"

while IFS= read -r sql; do
    case "$sql" in
        *PXMON_BEGIN_*)
            marker=${sql#*\'}
            marker=${marker%%\'*}
            printf '%s\n' "$marker"
            ;;
        *PXMON_END_*)
            marker=${sql#*\'}
            marker=${marker%%\'*}
            printf '%s\n' "$marker"
            ;;
        *TEST_CONNECTIONS*)
            printf 'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t4\n'
            ;;
        *TEST_SECOND_SAMPLE*)
            printf 'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t6\n'
            ;;
    esac
done
```

- [ ] **Step 2: Write failing transport tests**

Append tests that create a private state directory, override `MYSQL_BIN`, start
one session, execute two requests, and assert one launch:

```bash
TRANSPORT_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pxmon-test.XXXXXX")
FAKE_MYSQL_STATE_DIR="$TRANSPORT_TEST_DIR/state"
mkdir "$FAKE_MYSQL_STATE_DIR"
export FAKE_MYSQL_STATE_DIR
MYSQL_BIN="$TEST_DIR/fake_mysql.sh"
LOGIN_PATH="proxysql_admin"
QUERY_TIMEOUT=2

start_mysql_session
execute_query "SELECT 'TEST_CONNECTIONS';"
first_result=$QUERY_RESULT
execute_query "SELECT 'TEST_SECOND_SAMPLE';"
second_result=$QUERY_RESULT
stop_mysql_session

assert_eq $'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t4' "$first_result" "first framed result"
assert_eq $'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t6' "$second_result" "second framed result"
assert_eq "1" "$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches" | tr -d ' ')" "one persistent client launch"
[[ ! -e "$MYSQL_SESSION_DIR" ]] || fail "transport directory was not removed"
rm -rf "$TRANSPORT_TEST_DIR"
```

- [ ] **Step 3: Run the tests and verify RED**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: FAIL with `start_mysql_session: command not found`.

- [ ] **Step 4: Implement the minimal framed transport**

Use private FIFOs, reserved descriptors valid in Bash 3.2, an unbuffered client,
and exact request markers:

```bash
start_mysql_session() {
    MYSQL_SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxysql-monitor.XXXXXX") || return 1
    MYSQL_INPUT_PIPE="$MYSQL_SESSION_DIR/input"
    MYSQL_OUTPUT_PIPE="$MYSQL_SESSION_DIR/output"
    MYSQL_ERROR_FILE="$MYSQL_SESSION_DIR/mysql.stderr"
    mkfifo "$MYSQL_INPUT_PIPE" "$MYSQL_OUTPUT_PIPE" || {
        stop_mysql_session
        return 1
    }

    "$MYSQL_BIN" "--login-path=$LOGIN_PATH" --batch --raw \
        --skip-column-names --unbuffered --force \
        < "$MYSQL_INPUT_PIPE" > "$MYSQL_OUTPUT_PIPE" 2> "$MYSQL_ERROR_FILE" &
    MYSQL_PID=$!

    exec 7> "$MYSQL_INPUT_PIPE"
    exec 8< "$MYSQL_OUTPUT_PIPE"
    MYSQL_INPUT_FD=7
    MYSQL_OUTPUT_FD=8
    MYSQL_REQUEST_SEQUENCE=0
    mysql_session_alive
}

mysql_session_alive() {
    [[ -n "${MYSQL_PID:-}" ]] &&
        [[ "$MYSQL_PID" =~ ^[0-9]+$ ]] &&
        kill -0 "$MYSQL_PID" 2>/dev/null
}

execute_query() {
    local sql=$1
    local line=""
    local result=""
    local begin_marker=""
    local end_marker=""
    local collecting=false

    QUERY_RESULT=""
    mysql_session_alive || return 1
    MYSQL_REQUEST_SEQUENCE=$((MYSQL_REQUEST_SEQUENCE + 1))
    begin_marker="__PXMON_BEGIN_${$}_${MYSQL_REQUEST_SEQUENCE}__"
    end_marker="__PXMON_END_${$}_${MYSQL_REQUEST_SEQUENCE}__"

    printf "SELECT '%s';\n%s\nSELECT '%s';\n" \
        "$begin_marker" "$sql" "$end_marker" >&"$MYSQL_INPUT_FD" || return 1

    while IFS= read -r -t "$QUERY_TIMEOUT" -u "$MYSQL_OUTPUT_FD" line; do
        if [[ "$line" == "$begin_marker" ]]; then
            collecting=true
        elif [[ "$line" == "$end_marker" ]]; then
            QUERY_RESULT=$result
            LAST_DB_ERROR=""
            return 0
        elif [[ "$collecting" == true ]]; then
            if [[ -n "$result" ]]; then
                result="${result}"$'\n'"${line}"
            else
                result=$line
            fi
        fi
    done

    LAST_DB_ERROR="Timed out waiting for ProxySQL response"
    return 1
}

stop_mysql_session() {
    if [[ -n "${MYSQL_INPUT_FD:-}" ]]; then
        exec 7>&- || true
        MYSQL_INPUT_FD=""
    fi
    if [[ -n "${MYSQL_OUTPUT_FD:-}" ]]; then
        exec 8<&- || true
        MYSQL_OUTPUT_FD=""
    fi
    if mysql_session_alive; then
        kill "$MYSQL_PID" 2>/dev/null || true
        wait "$MYSQL_PID" 2>/dev/null || true
    fi
    MYSQL_PID=""
    case "${MYSQL_SESSION_DIR:-}" in
        "${TMPDIR:-/tmp}"/proxysql-monitor.*)
            rm -rf "$MYSQL_SESSION_DIR"
            ;;
    esac
    MYSQL_SESSION_DIR=""
}

execute_query_with_retry() {
    local sql=$1
    if execute_query "$sql"; then
        return 0
    fi
    stop_mysql_session
    if ! start_mysql_session; then
        LAST_DB_ERROR="Unable to reconnect to ProxySQL admin"
        return 1
    fi
    execute_query "$sql"
}
```

Descriptors 7 and 8 are reserved by this script and are always closed
directly. Do not use `eval` for descriptors, commands, paths, SQL, or user
input.

- [ ] **Step 5: Run the tests and verify GREEN**

Run:

```bash
chmod +x mysql/proxysql/tests/fake_mysql.sh
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/proxysql_connections_monitor.sh
```

Expected: all commands exit 0 and the launch assertion reports one client.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests
git commit -m "feat: add persistent ProxySQL admin transport"
```

---

### Task 3: View Sampling and Formatting Without Input Subprocesses

**Files:**
- Modify: `mysql/proxysql/tests/fake_mysql.sh`
- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh:101-240`

**Interfaces:**
- Consumes: `execute_query_with_retry(sql)`.
- Produces: `sample_current_view() -> 0|1`, `format_conn_data(previous,current)`,
  `format_query_data(data)`, `format_digest_data(data)`, and
  `format_backend_data(data)`.
- Produces globals: `FORMATTED_OUTPUT`, `F_POOL`, `F_PING`, `LAST_SAMPLE_STALE`,
  and `LAST_DB_ERROR`.

- [ ] **Step 1: Write failing formatting and BACKEND multiplexing tests**

Add assertions that call formatters directly:

```bash
PREV_DATA=$'app\tclient\tbackend:3306\tappdb\t4'
CURR_DATA=$'app\tclient\tbackend:3306\tappdb\t6'
USER_FILTER=""
THRESHOLD=0
format_conn_data "$PREV_DATA" "$CURR_DATA"
case "$FORMATTED_OUTPUT" in
    *"+2"*) : ;;
    *) fail "CONN formatter did not preserve delta semantics" ;;
esac

format_query_data $'11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n*\\tFROM t'
case "$FORMATTED_OUTPUT" in
    *$'SELECT * FROM t'*) : ;;
    *) fail "QUERY formatter did not sanitize escaped controls" ;;
esac

backend_payload=$'__PXMON_POOL__\n10\tbackend:3306\tONLINE\t2\t3\t50\t1\n__PXMON_PING__\nbackend\t2026-07-28 12:00:00\t500\t'
format_backend_data "$backend_payload"
case "$F_POOL:$F_PING" in
    *"ONLINE"*"500us"*) : ;;
    *) fail "BACKEND formatter did not split both sections" ;;
esac
```

Extend the fake client to return pool and ping fixtures when their real table
names occur, then assert one session launch after sampling BACKEND twice.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: FAIL because the formatter functions are undefined.

- [ ] **Step 3: Adapt AWK input contracts**

For CONN, concatenate previous and current data with
`__PXMON_CURRENT__` and change the AWK state transition:

```awk
BEGIN {
    FS="\t";
    reading_current = 0;
    total_conn = 0;
    total_diff = 0;
    if (filter != "") gsub(",", "|", filter);
}
$0 == "__PXMON_CURRENT__" { reading_current = 1; next }
!reading_current {
    if (NF > 0) prev[$1"\t"$2"\t"$3"\t"$4] = $5;
    next;
}
```

Invoke AWK with a here-string, not `<(echo ...)`:

```bash
format_conn_data() {
    local previous=$1
    local current=$2
    local input="${previous}"$'\n__PXMON_CURRENT__\n'"${current}"
    FORMATTED_OUTPUT=$(awk -v filter="$USER_FILTER" -v threshold="$THRESHOLD" \
        -v color_alert="$red" -v color_up="$red" -v color_down="$grn" \
        -v color_st="$wht" -v color_info="$blu" -v color_off="$off" \
        -v bld="$bld" "$AWK_SCRIPT_CONN" <<< "$input")
}
```

QUERY and DIGEST formatters must also use here-strings. Replace the two BACKEND
AWK programs with one program that switches output sections at
`__PXMON_POOL__` and `__PXMON_PING__`, prefixes formatted lines with the same
internal markers, and split the single AWK result using Bash parameter
expansion.

- [ ] **Step 4: Implement active-view SQL sampling**

Build SQL with native conditionals and send one framed request:

```bash
sample_current_view() {
    local query=""
    local current_data=""

    case "$VIEW_MODE" in
        CONN)
            if [[ "$SORT_MODE" == "CONN" ]]; then
                ORDER_CLAUSE="ORDER BY COUNT(*) DESC"
            else
                ORDER_CLAUSE="ORDER BY user ASC"
            fi
            query="SELECT user, cli_host, COALESCE(srv_host, 'N/A'), COALESCE(db, 'N/A'), COUNT(*)
                   FROM stats.stats_mysql_processlist
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
                   GROUP BY user, cli_host, srv_host, db ${ORDER_CLAUSE};"
            ;;
        QUERY)
            query="SELECT SessionID, hostgroup, user, cli_host, COALESCE(srv_host, 'Pending'), time_ms, info
                   FROM stats.stats_mysql_processlist
                   WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
                     AND info IS NOT NULL AND info != ''
                   ORDER BY time_ms DESC;"
            ;;
        DIGEST)
            query="SELECT digest, count_star, sum_time, min_time, max_time, digest_text
                   FROM stats.stats_mysql_query_digest
                   ORDER BY sum_time DESC LIMIT 15;"
            ;;
        BACKEND)
            query="SELECT '__PXMON_POOL__';
                   SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
                   FROM stats.stats_mysql_connection_pool
                   ORDER BY hostgroup, srv_host;
                   SELECT '__PXMON_PING__';
                   SELECT hostname, from_unixtime(time_start_us/1000/1000), ping_success_time_us, ping_error
                   FROM monitor.mysql_server_ping_log
                   ORDER BY time_start_us DESC LIMIT 8;"
            ;;
    esac

    if ! execute_query_with_retry "$query"; then
        LAST_SAMPLE_STALE=true
        return 1
    fi

    current_data=$QUERY_RESULT
    LAST_SAMPLE_STALE=false
    case "$VIEW_MODE" in
        CONN)
            format_conn_data "$PREV_DATA" "$current_data"
            PREV_DATA=$current_data
            ;;
        QUERY)
            format_query_data "$current_data"
            ;;
        DIGEST)
            format_digest_data "$current_data"
            ;;
        BACKEND)
            format_backend_data "$current_data"
            ;;
    esac
}
```

- [ ] **Step 5: Run the tests and verify GREEN**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/proxysql_connections_monitor.sh
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests
git commit -m "refactor: sample ProxySQL views through persistent session"
```

---

### Task 4: Optimized Render Loop, Recovery State, and Cleanup

**Files:**
- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh:192-358`

**Interfaces:**
- Consumes: `sample_current_view()`, `stop_mysql_session()`, and existing
  formatter globals.
- Produces: `refresh_terminal_geometry()`, `refresh_timestamp()`,
  `render_screen()`, `handle_key(key)`, `cleanup()`, and `monitor_loop()`.

- [ ] **Step 1: Write failing cache and native-state tests**

Append direct function tests:

```bash
TERM_WIDTH=120
TERM_GEOMETRY_DIRTY=true
refresh_terminal_geometry
assert_eq "120" "${#SEP_LINE}" "wide separator length"
assert_eq "120" "${#SEP_THIN}" "thin separator length"

VIEW_MODE="CONN"
PAUSED=false
handle_key "v"
assert_eq "QUERY" "$VIEW_MODE" "view toggle"
handle_key "p"
assert_eq "true" "$PAUSED" "pause toggle"
handle_key "p"
assert_eq "false" "$PAUSED" "resume toggle"

FORMATTED_OUTPUT="last valid row"
LAST_SAMPLE_STALE=false
LAST_DB_ERROR=""
execute_query_with_retry() { LAST_DB_ERROR="ProxySQL unavailable"; return 1; }
VIEW_MODE="QUERY"
sample_current_view || true
assert_eq "last valid row" "$FORMATTED_OUTPUT" "failed sample preserves last data"
assert_eq "true" "$LAST_SAMPLE_STALE" "failed sample marks output stale"
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
```

Expected: FAIL because geometry and key-handler functions are undefined.

- [ ] **Step 3: Implement terminal and timestamp caching**

Use only one `tput cols` call when dirty and no `tr`:

```bash
mark_terminal_geometry_dirty() {
    TERM_GEOMETRY_DIRTY=true
}

refresh_terminal_geometry() {
    local spaces=""
    if [[ "$TERM_GEOMETRY_DIRTY" != true ]]; then
        return 0
    fi
    if [[ -t 1 ]]; then
        TERM_WIDTH=$(tput cols 2>/dev/null || printf '130')
    fi
    [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]] || TERM_WIDTH=130
    [[ "$TERM_WIDTH" -ge 110 ]] || TERM_WIDTH=130
    printf -v spaces '%*s' "$TERM_WIDTH" ''
    SEP_LINE=${spaces// /=}
    SEP_THIN=${spaces// /-}
    TERM_GEOMETRY_DIRTY=false
}

refresh_timestamp() {
    if [[ "$TIMESTAMP_SECOND" != "$SECONDS" ]]; then
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        TIMESTAMP_SECOND=$SECONDS
    fi
}
```

Install `trap mark_terminal_geometry_dirty WINCH`. Use
`printf '\033[H\033[2J'` in rendering. Build mode and pause labels through
conditionals without command substitution.

- [ ] **Step 4: Implement cleanup, main loop, and native key state**

Install `trap cleanup EXIT INT TERM`, where `cleanup` calls
`stop_mysql_session` and restores `${off}`. The monitor loop must:

1. Refresh cached terminal geometry and timestamp.
2. Call `sample_current_view || true` only when not paused.
3. Render the last valid data and stale status.
4. Initialize `key=""` before guarded `read -t`.
5. Pass the key to `handle_key`.

Use direct state changes:

```bash
toggle_pause() {
    if [[ "$PAUSED" == true ]]; then
        PAUSED=false
    else
        PAUSED=true
    fi
}

toggle_sort() {
    [[ "$VIEW_MODE" == "CONN" ]] || return 0
    if [[ "$SORT_MODE" == "CONN" ]]; then
        SORT_MODE="USER"
    else
        SORT_MODE="CONN"
    fi
    PREV_DATA=""
}
```

Replace the `bc` refresh validation with a regex that rejects zero:

```bash
is_positive_refresh() {
    [[ "$1" =~ ^([0-9]*[1-9][0-9]*)(\.[0-9]+)?$|^0\.[0-9]*[1-9][0-9]*$ ]]
}
```

- [ ] **Step 5: Run the tests and verify GREEN**

Run:

```bash
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/proxysql_connections_monitor.sh
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests/test_proxysql_connections_monitor.sh
git commit -m "perf: reduce ProxySQL monitor refresh overhead"
```

---

### Task 5: Resource Regression Benchmark and Final Verification

**Files:**
- Create: `mysql/proxysql/tests/benchmark_process_count.sh`
- Modify: `mysql/proxysql/tests/test_proxysql_connections_monitor.sh`
- Modify: `mysql/proxysql/proxysql_connections_monitor.sh`

**Interfaces:**
- Consumes: all completed script functions and the fake MySQL client.
- Produces: a repeatable benchmark reporting requests, MySQL launches, and
  per-sample MySQL launch ratio.

- [ ] **Step 1: Write a failing process-count benchmark**

Create:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_connections_monitor.sh"
BENCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pxmon-bench.XXXXXX")
trap 'rm -rf "$BENCH_DIR"' EXIT INT TERM

export FAKE_MYSQL_STATE_DIR="$BENCH_DIR/state"
mkdir "$FAKE_MYSQL_STATE_DIR"
PROXYSQL_MONITOR_TESTING=1
# shellcheck source=../proxysql_connections_monitor.sh
source "$SCRIPT_PATH"

initialize_defaults
initialize_colors
LOGIN_PATH="benchmark"
MYSQL_BIN="$TEST_DIR/fake_mysql.sh"
QUERY_TIMEOUT=2
start_mysql_session

samples=20
i=0
while [[ "$i" -lt "$samples" ]]; do
    execute_query "SELECT 'TEST_CONNECTIONS';"
    i=$((i + 1))
done
stop_mysql_session

launches=$(wc -l < "$FAKE_MYSQL_STATE_DIR/launches" | tr -d ' ')
printf 'Samples: %s\nMySQL client launches: %s\n' "$samples" "$launches"
[[ "$launches" == "1" ]]
```

- [ ] **Step 2: Run the benchmark and verify its acceptance assertion**

Run:

```bash
chmod +x mysql/proxysql/tests/benchmark_process_count.sh
/bin/bash mysql/proxysql/tests/benchmark_process_count.sh
```

Expected: `Samples: 20`, `MySQL client launches: 1`, exit 0. If it fails, fix
transport lifecycle code rather than weakening the assertion.

- [ ] **Step 3: Add behavioral regression assertions for refresh rendering**

Append assertions that make removed per-refresh commands fail if the real
renderer attempts to invoke them:

```bash
clear() { fail "render invoked external clear"; }
tr() { fail "render invoked external tr"; }
sed() { fail "render invoked sed without -o"; }

TERM_WIDTH=130
TERM_GEOMETRY_DIRTY=false
SEP_LINE="=================================================================================================================================="
SEP_THIN="----------------------------------------------------------------------------------------------------------------------------------"
TIMESTAMP="2026-07-28 12:00:00"
PROXY_HOSTNAME="proxysql-test"
VIEW_MODE="QUERY"
FORMATTED_OUTPUT="No test rows"
OUTPUT_FILE=""
render_screen >/dev/null

help_output=$(usage_text)
case "$help_output" in
    *"--login-path=NAME"*"-r, --refresh-time=N"*"su - rmateos"*) : ;;
    *) fail "help text lost required options or example" ;;
esac
```

Expose `usage_text()` as a non-exiting help renderer and let `usage(status)`
call it before exiting. This test intentionally intercepts process boundaries
because process creation is the behavior under optimization; it does not grep
the implementation text.

- [ ] **Step 4: Run full verification**

Run:

```bash
/bin/bash -n mysql/proxysql/proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/tests/fake_mysql.sh
/bin/bash -n mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash -n mysql/proxysql/tests/benchmark_process_count.sh
/bin/bash mysql/proxysql/tests/test_proxysql_connections_monitor.sh
/bin/bash mysql/proxysql/tests/benchmark_process_count.sh
shellcheck -s bash mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests/*.sh
git diff --check
```

Expected: syntax checks, tests, benchmark, ShellCheck, and whitespace checks all
exit 0. If `shellcheck` is not installed, record that fact and run every other
command.

- [ ] **Step 5: Review the final diff for scope**

Run:

```bash
git diff --stat HEAD~4..HEAD
git diff HEAD~4..HEAD -- mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests
```

Confirm the diff changes only the monitor, its tests, and approved
documentation; keeps all four SQL views; retains the portable logging `sed`
expression; and adds no runtime dependency.

- [ ] **Step 6: Commit**

```bash
git add mysql/proxysql/proxysql_connections_monitor.sh mysql/proxysql/tests docs/superpowers/plans/2026-07-28-proxysql-monitor-resource-optimization.md
git commit -m "test: verify ProxySQL monitor resource usage"
```
