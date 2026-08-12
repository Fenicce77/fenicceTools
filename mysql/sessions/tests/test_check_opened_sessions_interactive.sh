#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/check_opened_sessions_interactive.sh"
FAKE="$ROOT/tests/fake_mysql_open_sessions.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/open-sessions-cli-test.XXXXXX")
CLAIM_PID=''
cleanup() {
    local exit_status=$?

    set +e
    if [[ -n "$CLAIM_PID" ]]; then
        : > "$TMP/claim.release"
        if kill -0 "$CLAIM_PID" 2>/dev/null; then
            kill "$CLAIM_PID" 2>/dev/null || true
        fi
        wait "$CLAIM_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
    return "$exit_status"
}
trap cleanup EXIT
export FAKE_MYSQL_SQL_LOG="$TMP/sql.log"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_status() {
    local expected=$1
    [[ "$STATUS" -eq "$expected" ]] || fail "expected exit status $expected, got $STATUS"
}

assert_contains() {
    local file=$1 expected=$2
    grep -F -- "$expected" "$file" >/dev/null || fail "missing '$expected' in $file"
}

assert_not_contains() {
    local file=$1 unexpected=$2
    if grep -F -- "$unexpected" "$file" >/dev/null; then
        fail "unexpected '$unexpected' in $file"
    fi
}

assert_occurrences() {
    local file=$1 expected=$2 count=$3 actual
    actual=$(grep -F -c -- "$expected" "$file" || true)
    [[ "$actual" -eq "$count" ]] || fail "expected $count occurrences of '$expected' in $file, got $actual"
}

assert_at_least_occurrences() {
    local file=$1 expected=$2 minimum=$3 actual
    actual=$(grep -F -c -- "$expected" "$file" || true)
    [[ "$actual" -ge "$minimum" ]] || fail "expected at least $minimum occurrences of '$expected' in $file, got $actual"
}

run_case() {
    local name=$1
    shift

    set +e
    "$SCRIPT" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
}

run_pseudo_tty_program() {
    local output_file=$1
    local input_command=$2
    local program=$3
    shift 3
    local command=''
    local argument

    if [[ "$(uname -s)" == Darwin ]]; then
        for argument in "$program" "$@"; do
            printf -v command '%s%q ' "$command" "$argument"
        done
        printf -v command 'cd %q && %s' "$TMP" "$command"
        set +e
        /bin/bash -c "$input_command" | TERM=xterm script -q "$output_file" /bin/bash -c "$command" \
            >"$output_file.console" 2>"$output_file.err"
        STATUS=${PIPESTATUS[1]}
        set -e
        return
    fi

    for argument in "$program" "$@"; do
        printf -v command '%s%q ' "$command" "$argument"
    done
    printf -v command 'cd %q && %s' "$TMP" "$command"
    set +e
    /bin/bash -c "$input_command" | TERM=xterm script -q -e -c "$command" "$output_file" \
        >"$output_file.console" 2>"$output_file.err"
    STATUS=${PIPESTATUS[1]}
    set -e
}

run_pseudo_tty() {
    local output_file=$1
    local input_command=$2
    shift 2

    run_pseudo_tty_program "$output_file" "$input_command" "$SCRIPT" "$@"
}

run_tty_case() {
    local name=$1
    shift

    run_pseudo_tty "$TMP/$name.out" '{ sleep 0.2; printf q; }' "$@"
}

strip_frame_ansi() {
    LC_ALL=C sed $'s/\033\\[[0-9;]*m//g; s/\033\\[?25[hl]//g; s/\004\010\010//g' "$1" | tr -d '\r' | \
        sed 's/^Timestamp: .*/Timestamp: <normalized>/'
}

strip_refresh_sequence() {
    LC_ALL=C sed $'s/\033\\[H\033\\[2J//g' "$1"
}

assert_final_cursor_action_show() {
    local file=$1
    local final_action

    final_action=$(LC_ALL=C sed $'s/\033\\[?25h/|h|/g; s/\033\\[?25l/|l|/g' "$file" | \
        tr '|' '\n' | sed -n '/^[hl]$/p' | tail -n 1)
    [[ "$final_action" == h ]] || fail "final cursor action is not show in $file"
}

# A monitor without connection credentials must stop before terminal setup.
run_case no_args
assert_status 2
assert_contains "$TMP/no_args.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/no_args.err" 'Usage:'
assert_not_contains "$TMP/no_args.err" $'\033['

# Help must be available without a connection and document the interactive key contract.
run_case help --help
assert_status 0
assert_contains "$TMP/help.out" 'Runtime keys:'
assert_contains "$TMP/help.out" '[q] Quit'

run_case no_color_help --help --no-color
assert_status 0
assert_contains "$TMP/no_color_help.out" 'Runtime keys:'
if LC_ALL=C grep "$(printf '\033')" "$TMP/no_color_help.out" >/dev/null; then
    fail '--no-color help contains ANSI escape sequences'
fi

# Parser errors consistently print an error and the full help contract.
run_case unknown_option --unknown
assert_status 2
assert_contains "$TMP/unknown_option.err" 'ERROR: Unknown option: --unknown'
assert_contains "$TMP/unknown_option.err" 'Usage:'

run_case missing_value --login-path
assert_status 2
assert_contains "$TMP/missing_value.err" 'ERROR: Option --login-path requires a value.'
assert_contains "$TMP/missing_value.err" 'Usage:'

run_case missing_short_value -l -t 5
assert_status 2
assert_contains "$TMP/missing_short_value.err" 'ERROR: Option -l requires a value.'
assert_contains "$TMP/missing_short_value.err" 'Usage:'

run_case required_login_path --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/required_login_path.err" 'ERROR: --login-path is required.'
assert_contains "$TMP/required_login_path.err" 'Usage:'

# Legacy getopts accepted attached values for every retained value-taking short option.
run_case attached_short_options -lreporting -t10 -uapp -dbilling -hhost -o \
    --log-file "$TMP/attached.log" --mysql-bin "$FAKE"
assert_status 0

run_case equals_options --login-path=reporting --refresh-time=10 --user=app \
    --database=billing --host=api --logging --diff --log-file="$TMP/new.log" \
    --mysql-bin="$FAKE" --no-color
assert_status 0

# Query filters must be escaped as SQL literals and collected in one client call.
: > "$TMP/sql.log"
run_case escaped_filters --login-path reporting --user "alice,o\\'connor" \
    --database "billing\\'archive" --host 'api%_west\\node' --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/sql.log" "USER IN (CONVERT(0x616c696365 USING utf8mb4), CONVERT(0x6f5c27636f6e6e6f72 USING utf8mb4))"
assert_contains "$TMP/sql.log" "DB = CONVERT(0x62696c6c696e675c2761726368697665 USING utf8mb4)"
assert_not_contains "$TMP/sql.log" "o\\'connor"
assert_not_contains "$TMP/sql.log" "billing\\'archive"
assert_contains "$TMP/sql.log" "HOST LIKE CONVERT(0x256170695c255c5f776573745c5c5c5c6e6f646525 USING utf8mb4) ESCAPE CONVERT(0x5c USING utf8mb4)"
assert_contains "$TMP/sql.log" 'UNION ALL'
assert_occurrences "$TMP/sql.log" 'UNION ALL' 1

# Grouping removes only the PROCESSLIST client port. IPv4/hostnames retain the
# legacy normalization, while bracketed and unbracketed IPv6 remain intact.
: > "$TMP/sql.log"
export FAKE_MYSQL_EMULATE_HOST_NORMALIZATION=true
run_case normalized_hosts --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_occurrences "$TMP/normalized_hosts.out" '10.0.0.5' 1
assert_occurrences "$TMP/normalized_hosts.out" '2001:db8::1' 1
assert_contains "$TMP/normalized_hosts.out" 'Total matching connections: 4'
assert_not_contains "$TMP/normalized_hosts.out" '10.0.0.5:41001'
assert_not_contains "$TMP/normalized_hosts.out" '[2001:db8::1]:41003'
assert_contains "$TMP/sql.log" "SUBSTRING_INDEX(SUBSTRING_INDEX(HOST, ':', 1), '.', 4)"
assert_contains "$TMP/sql.log" "LOCATE(']:', HOST)"
assert_contains "$TMP/sql.log" "LEFT(HOST, LENGTH(HOST) - LENGTH(SUBSTRING_INDEX(HOST, ':', -1)) - 1)"
assert_contains "$TMP/sql.log" 'ORDER BY record_type, USER, DB, normalized_host'
unset FAKE_MYSQL_EMULATE_HOST_NORMALIZATION

# Grouped rows and the total independently apply the canonical system/monitoring
# exclusion set, so excluded sessions affect neither the table nor its total.
: > "$TMP/sql.log"
EXCLUSION_PREDICATE="USER NOT IN ('root','gsancliment','pmm_monitor','proxysql-monitor','coms_rpl_gh_primary','cloudsqlreplica','devel-migration-job','event_scheduler')"
export FAKE_MYSQL_REQUIRED_EXCLUSION_PREDICATE=$EXCLUSION_PREDICATE
run_case excluded_users --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/excluded_users.out" 'app'
assert_not_contains "$TMP/excluded_users.out" 'root'
assert_not_contains "$TMP/excluded_users.out" 'pmm_monitor'
assert_contains "$TMP/excluded_users.out" 'Total matching connections: 3'
assert_occurrences "$TMP/sql.log" "$EXCLUSION_PREDICATE" 2
unset FAKE_MYSQL_REQUIRED_EXCLUSION_PREDICATE

: > "$TMP/sql.log"
run_case repeated_user --login-path reporting --user 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/sql.log" 'USER IN (CONVERT(0x787878787878787878787878787878787878787878787878787878787878787878 USING utf8mb4))'

for invalid_user in ',alice' 'alice,' 'alice,,bob'; do
    run_case "empty_user_component_${invalid_user//,/x}" --login-path reporting --user "$invalid_user" --mysql-bin "$FAKE"
    assert_status 2
    assert_contains "$TMP/empty_user_component_${invalid_user//,/x}.err" 'ERROR: --user must not contain empty components.'
    assert_contains "$TMP/empty_user_component_${invalid_user//,/x}.err" 'Usage:'
done

run_case invalid_refresh --login-path reporting --refresh-time 0 --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/invalid_refresh.err" 'ERROR: --refresh-time must be a positive integer.'
assert_contains "$TMP/invalid_refresh.err" 'Usage:'

run_case invalid_mysql_bin --login-path reporting --mysql-bin "$TMP/missing-mysql"
assert_status 2
assert_contains "$TMP/invalid_mysql_bin.err" 'ERROR: --mysql-bin must reference an executable file.'
assert_contains "$TMP/invalid_mysql_bin.err" 'Usage:'

run_case mysql_bin_directory --login-path reporting --mysql-bin "$TMP"
assert_status 2
assert_contains "$TMP/mysql_bin_directory.err" 'ERROR: --mysql-bin must reference an executable file.'
assert_contains "$TMP/mysql_bin_directory.err" 'Usage:'

touch "$TMP/existing-validation.log"
run_case existing_log_validation --login-path reporting --log-file "$TMP/existing-validation.log" --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/existing_log_validation.err" 'ERROR: --log-file must not already exist.'
assert_contains "$TMP/existing_log_validation.err" 'Usage:'

# Redirected execution is one ANSI-free sample and must omit interactive-only UI.
export FAKE_MYSQL_OUTPUT=$'ROW\tapp\tbilling\tapi\t3\nTOTAL\t\t\t\t3'
run_case redirected --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/redirected.out" 'Open MySQL Sessions'
assert_contains "$TMP/redirected.out" 'Total matching connections: 3'
assert_not_contains "$TMP/redirected.out" $'\033['
assert_not_contains "$TMP/redirected.out" $'\033[H\033[2J'
assert_not_contains "$TMP/redirected.out" 'Interactive options:'

# An initial diff-enabled frame has no prior sample and must not invent increases.
run_case initial_diff --login-path reporting --diff --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/initial_diff.out" 'Delta'
assert_contains "$TMP/initial_diff.out" '+0'
assert_not_contains "$TMP/initial_diff.out" '+3'

# A usable pseudo-TTY clears the frame. --no-color keeps refresh but removes styling.
run_tty_case tty_color --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty_color.out" $'\033[H\033[2J'
assert_contains "$TMP/tty_color.out" $'\033[0;36m'
assert_contains "$TMP/tty_color.out" 'Interactive options:'
assert_contains "$TMP/tty_color.out" $'\033[0;33m[q]\033[0m'
assert_contains "$TMP/tty_color.out" $'\033[?25l'
assert_contains "$TMP/tty_color.out" $'\033[?25h'
assert_final_cursor_action_show "$TMP/tty_color.out"

run_tty_case tty_no_color --login-path reporting --mysql-bin "$FAKE" --no-color
assert_status 0
assert_contains "$TMP/tty_no_color.out" $'\033[H\033[2J'
assert_contains "$TMP/tty_no_color.out" 'Interactive options:'
strip_refresh_sequence "$TMP/tty_no_color.out" > "$TMP/tty_no_color.without_refresh"
LC_ALL=C sed $'s/\033\[?25[hl]//g' "$TMP/tty_no_color.without_refresh" > "$TMP/tty_no_color.without_terminal"
assert_not_contains "$TMP/tty_no_color.without_terminal" $'\033'

# Removing style bytes from a colored frame must preserve every table column position.
strip_frame_ansi "$TMP/tty_color.out" > "$TMP/tty_color.plain"
strip_frame_ansi "$TMP/tty_no_color.out" > "$TMP/tty_no_color.plain"
cmp -s "$TMP/tty_color.plain" "$TMP/tty_no_color.plain" || fail 'colored and no-color frame layouts differ'

# Runtime controls must remain responsive in a real pseudo-TTY and report state
# through the compact legend after each toggle.
run_pseudo_tty "$TMP/runtime_controls.out" \
    '{ sleep 0.3; printf d; sleep 0.3; printf l; sleep 0.3; printf q; }' \
    --login-path reporting --refresh-time 1 --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/runtime_controls.out" 'Interactive options:'
assert_contains "$TMP/runtime_controls.out" '[q]'
assert_contains "$TMP/runtime_controls.out" '[m]'
assert_contains "$TMP/runtime_controls.out" 'Diff: ON'
assert_contains "$TMP/runtime_controls.out" 'Logging: ON'
assert_contains "$TMP/runtime_controls.out" $'\033[H\033[2J'
runtime_logs=("$TMP"/open_sessions_*.log)
[[ -f "${runtime_logs[0]}" ]] || fail 'runtime logging did not create a timestamped log'
[[ "${#runtime_logs[@]}" -eq 1 ]] || fail 'runtime logging created more than one log file'
assert_contains "${runtime_logs[0]}" 'Diff: ON'
assert_not_contains "${runtime_logs[0]}" $'\033'

# Blank prompt values retain filters; accepted values traverse the same safe SQL
# serializer used by startup options.
: > "$TMP/sql.log"
run_pseudo_tty "$TMP/runtime_filters.out" \
    "{ sleep 0.3; printf 'm\\n\\n\\n'; sleep 0.3; printf 'm'; printf '%s\\n' \"alice,o'connor\"; printf '%s\\n' \"billing'archive\"; printf '%s\\n' 'api%_west\\node'; sleep 0.3; printf q; }" \
    --login-path reporting --refresh-time 1 --user app --database billing --host api --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/runtime_filters.out" 'Modify filters (blank keeps current value)'
assert_contains "$TMP/runtime_filters.out" 'Filters: user=app database=billing host=api'
assert_contains "$TMP/runtime_filters.out" "Filters: user=alice,o'connor database=billing'archive host=api%_west\\node"
assert_contains "$TMP/sql.log" 'USER IN (CONVERT(0x616c696365 USING utf8mb4), CONVERT(0x6f27636f6e6e6f72 USING utf8mb4))'
assert_contains "$TMP/sql.log" 'DB = CONVERT(0x62696c6c696e672761726368697665 USING utf8mb4)'
assert_contains "$TMP/sql.log" 'HOST LIKE CONVERT(0x256170695c255c5f776573745c5c6e6f646525 USING utf8mb4)'

# Invalid interactive filters leave the complete prior filter set active.
: > "$TMP/sql.log"
run_pseudo_tty "$TMP/runtime_invalid_filter.out" \
    "{ sleep 0.3; printf 'm%s\\n%s\\n%s\\n' 'alice,,bob' 'changed_db' 'changed_host'; sleep 0.3; printf q; }" \
    --login-path reporting --refresh-time 1 --user app --database billing --host api --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/runtime_invalid_filter.out" 'ERROR: --user must not contain empty components. Filters unchanged.'
assert_contains "$TMP/runtime_invalid_filter.out" 'Filters: user=app database=billing host=api'
assert_not_contains "$TMP/sql.log" 'CONVERT(0x616c696365 USING utf8mb4)'
assert_not_contains "$TMP/sql.log" 'CONVERT(0x626f62 USING utf8mb4)'
assert_not_contains "$TMP/sql.log" 'CONVERT(0x6368616e6765645f6462 USING utf8mb4)'
assert_not_contains "$TMP/sql.log" 'CONVERT(0x256368616e6765645c5f686f737425 USING utf8mb4)'
assert_at_least_occurrences "$TMP/runtime_invalid_filter.out" 'Filters: user=app database=billing host=api' 2
assert_at_least_occurrences "$TMP/sql.log" 'USER IN (CONVERT(0x617070 USING utf8mb4))' 2
assert_at_least_occurrences "$TMP/sql.log" 'DB = CONVERT(0x62696c6c696e67 USING utf8mb4)' 2
assert_at_least_occurrences "$TMP/sql.log" 'HOST LIKE CONVERT(0x2561706925 USING utf8mb4)' 2

# Delta values must use the immediately prior sample and the full row key.
DYNAMIC_FAKE="$TMP/dynamic_mysql.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'call=0' \
    '[[ ! -f "$DYNAMIC_MYSQL_STATE" ]] || read -r call < "$DYNAMIC_MYSQL_STATE"' \
    'call=$((call + 1))' \
    'printf "%s\\n" "$call" > "$DYNAMIC_MYSQL_STATE"' \
    'if [[ "$call" -eq 1 ]]; then' \
    "    output=\$'ROW\\tapp\\tbilling\\tapi\\t3\\nROW\\tapp\\tbilling\\tworker\\t10\\nROW\\treport\\tanalytics\\tshared\\t7\\nROW\\treport\\tarchive\\tshared\\t20\\nROW\\treader\\twarehouse\\tbatch\\t4\\nROW\\twriter\\twarehouse\\tbatch\\t12\\nTOTAL\\t\\t\\t\\t56'" \
    'else' \
    "    output=\$'ROW\\tapp\\tbilling\\tapi\\t5\\nROW\\tapp\\tbilling\\tworker\\t11\\nROW\\treport\\tanalytics\\tshared\\t6\\nROW\\treport\\tarchive\\tshared\\t22\\nROW\\treader\\twarehouse\\tbatch\\t4\\nROW\\twriter\\twarehouse\\tbatch\\t9\\nTOTAL\\t\\t\\t\\t57'" \
    'fi' \
    'FAKE_MYSQL_OUTPUT="$output" exec "$DYNAMIC_MYSQL_BASE" "$@"' > "$DYNAMIC_FAKE"
chmod +x "$DYNAMIC_FAKE"
export DYNAMIC_MYSQL_STATE="$TMP/dynamic.state"
export DYNAMIC_MYSQL_BASE="$FAKE"
run_pseudo_tty "$TMP/runtime_diff.out" \
    '{ sleep 0.3; printf d; sleep 0.3; printf q; }' \
    --login-path reporting --refresh-time 1 --mysql-bin "$DYNAMIC_FAKE"
assert_status 0
assert_contains "$TMP/runtime_diff.out" 'Delta'
strip_frame_ansi "$TMP/runtime_diff.out" > "$TMP/runtime_diff.plain"
assert_contains "$TMP/runtime_diff.plain" 'app     billing    api            5     +2'
assert_contains "$TMP/runtime_diff.plain" 'app     billing    worker        11     +1'
assert_contains "$TMP/runtime_diff.plain" 'report  analytics  shared         6     -1'
assert_contains "$TMP/runtime_diff.plain" 'report  archive    shared        22     +2'
assert_contains "$TMP/runtime_diff.plain" 'reader  warehouse  batch          4     +0'
assert_contains "$TMP/runtime_diff.plain" 'writer  warehouse  batch          9     -3'
unset DYNAMIC_MYSQL_STATE DYNAMIC_MYSQL_BASE

# Runtime timestamp collisions are rejected atomically without replacing content.
DATE_WRAPPER="$TMP/date"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${1-}" == +%Y%m%d_%H%M%S ]]; then' \
    "    printf '%s\\n' '20260812_120000'" \
    'else' \
    '    /bin/date "$@"' \
    'fi' > "$DATE_WRAPPER"
chmod +x "$DATE_WRAPPER"
printf 'preserve runtime log\n' > "$TMP/open_sessions_20260812_120000.log"
saved_path=$PATH
PATH="$TMP:$PATH"
export PATH
run_pseudo_tty "$TMP/runtime_log_collision.out" \
    '{ sleep 0.3; printf l; sleep 0.3; printf q; }' \
    --login-path reporting --refresh-time 1 --mysql-bin "$FAKE"
PATH=$saved_path
export PATH
assert_status 0
assert_contains "$TMP/runtime_log_collision.out" 'ERROR: Log file already exists; logging remains OFF.'
assert_contains "$TMP/runtime_log_collision.out" 'Logging: OFF'
assert_contains "$TMP/open_sessions_20260812_120000.log" 'preserve runtime log'
assert_occurrences "$TMP/open_sessions_20260812_120000.log" 'preserve runtime log' 1

# Logging failures and signals must restore the cursor based on immutable terminal
# ownership, even while log rendering has temporarily disabled screen refresh.
FAILURE_HARNESS="$TMP/runtime_failure_harness.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'source <(sed '\''/^setup_colors$/,$d'\'' "$MONITOR_SCRIPT")' \
    'setup_colors' \
    'TERMINAL_OWNED=true' \
    'CURSOR_HIDDEN=true' \
    'SCREEN_REFRESH_ENABLED=true' \
    'LOGGING_ENABLED=true' \
    'LOG_FILE=forced-failure.log' \
    "SAMPLE_ROWS=(\$'app\\tbilling\\tapi\\t3')" \
    'SAMPLE_TOTAL=3' \
    'render_frame() { return 73; }' \
    'exec 3>"$LOG_FILE"' \
    'trap restore_terminal EXIT' \
    "printf '\\033[?25l'" \
    'append_log' \
    "printf 'UNEXPECTED: continued after log render failure\\n'" > "$FAILURE_HARNESS"
chmod +x "$FAILURE_HARNESS"
export MONITOR_SCRIPT="$SCRIPT"
run_pseudo_tty_program "$TMP/runtime_log_failure.out" ':' "$FAILURE_HARNESS"
assert_not_contains "$TMP/runtime_log_failure.out" 'UNEXPECTED:'
assert_final_cursor_action_show "$TMP/runtime_log_failure.out"

SIGNAL_HARNESS="$TMP/runtime_signal_harness.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'source <(sed '\''/^setup_colors$/,$d'\'' "$MONITOR_SCRIPT")' \
    'TERMINAL_OWNED=true' \
    'CURSOR_HIDDEN=true' \
    'SCREEN_REFRESH_ENABLED=false' \
    'LOGGING_ENABLED=true' \
    'LOG_FILE=signal.log' \
    'exec 3>"$LOG_FILE"' \
    'trap restore_terminal EXIT' \
    "trap 'exit 130' HUP INT TERM" \
    "printf '\\033[?25l'" \
    'kill -TERM "$$"' > "$SIGNAL_HARNESS"
chmod +x "$SIGNAL_HARNESS"
run_pseudo_tty_program "$TMP/runtime_signal.out" ':' "$SIGNAL_HARNESS"
assert_final_cursor_action_show "$TMP/runtime_signal.out"
unset MONITOR_SCRIPT

# Snapshot logs are plain text and their requested destination is created once.
run_case new_log --login-path reporting --logging --log-file "$TMP/new-snapshot.log" --mysql-bin "$FAKE"
assert_status 0
[[ -f "$TMP/new-snapshot.log" ]] || fail 'logging did not create the requested log file'
assert_contains "$TMP/new-snapshot.log" 'Open MySQL Sessions'
assert_contains "$TMP/new-snapshot.log" 'Total matching connections: 3'
assert_not_contains "$TMP/new-snapshot.log" $'\033['

# Retained -o/--logging reserves a timestamped default before sampling and
# writes the first plain snapshot when no explicit --log-file is supplied.
START_LOG_BIN="$TMP/start-log-bin"
START_LOG_DIR="$TMP/start-log-dir"
mkdir "$START_LOG_BIN" "$START_LOG_DIR"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${1-}" == +%Y%m%d_%H%M%S ]]; then' \
    "    printf '%s\\n' '20260812_121314'" \
    'else' \
    '    /bin/date "$@"' \
    'fi' > "$START_LOG_BIN/date"
chmod +x "$START_LOG_BIN/date"
saved_path=$PATH
PATH="$START_LOG_BIN:$PATH"
export PATH
set +e
(
    cd "$START_LOG_DIR"
    "$SCRIPT" --login-path reporting -o --mysql-bin "$FAKE"
) >"$TMP/default_log.out" 2>"$TMP/default_log.err"
STATUS=$?
set -e
PATH=$saved_path
export PATH
assert_status 0
DEFAULT_LOG="$START_LOG_DIR/open_sessions_20260812_121314.log"
[[ -f "$DEFAULT_LOG" ]] || fail 'startup logging did not reserve the timestamped default log'
assert_contains "$DEFAULT_LOG" 'Open MySQL Sessions'
assert_contains "$DEFAULT_LOG" 'Total matching connections: 3'
assert_not_contains "$DEFAULT_LOG" $'\033'

printf 'preserve default log\n' > "$START_LOG_DIR/open_sessions_20260812_121315.log"
sed 's/20260812_121314/20260812_121315/' "$START_LOG_BIN/date" > "$START_LOG_BIN/date.next"
mv "$START_LOG_BIN/date.next" "$START_LOG_BIN/date"
chmod +x "$START_LOG_BIN/date"
PATH="$START_LOG_BIN:$PATH"
export PATH
set +e
(
    cd "$START_LOG_DIR"
    "$SCRIPT" --login-path reporting --logging --mysql-bin "$FAKE"
) >"$TMP/default_log_collision.out" 2>"$TMP/default_log_collision.err"
STATUS=$?
set -e
PATH=$saved_path
export PATH
assert_status 2
assert_contains "$TMP/default_log_collision.err" 'ERROR: --log-file must not already exist.'
assert_contains "$TMP/default_log_collision.err" 'Usage:'
assert_contains "$START_LOG_DIR/open_sessions_20260812_121315.log" 'preserve default log'
assert_occurrences "$START_LOG_DIR/open_sessions_20260812_121315.log" 'preserve default log' 1

# Existing destinations must be rejected and never overwritten.
printf 'preserve me\n' > "$TMP/existing.log"
run_case existing_log --login-path reporting --log-file "$TMP/existing.log" --mysql-bin "$FAKE"
assert_status 2
assert_contains "$TMP/existing_log.err" 'ERROR:'
assert_contains "$TMP/existing_log.err" 'Usage:'
assert_contains "$TMP/existing.log" 'preserve me'

# The process reserves the requested destination before sampling; a second exclusive
# creator cannot claim or overwrite it while the monitor still holds descriptor 3.
export FAKE_MYSQL_READY_FILE="$TMP/claim.ready"
export FAKE_MYSQL_RELEASE_FILE="$TMP/claim.release"
"$SCRIPT" --login-path reporting --logging --log-file "$TMP/claimed.log" --mysql-bin "$FAKE" \
    >"$TMP/claimed.out" 2>"$TMP/claimed.err" &
CLAIM_PID=$!
for _ in $(seq 1 100); do
    [[ -e "$FAKE_MYSQL_READY_FILE" ]] && break
    sleep 0.05
done
[[ -e "$FAKE_MYSQL_READY_FILE" ]] || fail 'monitor did not reach the blocked sampler'
set +e
(
    set -C
    printf 'competing writer\n' > "$TMP/claimed.log"
) 2>"$TMP/claimed_competitor.err"
COMPETITOR_STATUS=$?
set -e
[[ "$COMPETITOR_STATUS" -ne 0 ]] || fail 'competing exclusive creator overwrote claimed log path'
touch "$FAKE_MYSQL_RELEASE_FILE"
wait "$CLAIM_PID"
STATUS=$?
CLAIM_PID=''
assert_status 0
assert_contains "$TMP/claimed.log" 'Open MySQL Sessions'
assert_contains "$TMP/claimed.log" 'Total matching connections: 3'
assert_not_contains "$TMP/claimed.log" $'\033'
assert_not_contains "$TMP/claimed.log" 'competing writer'
unset FAKE_MYSQL_READY_FILE FAKE_MYSQL_RELEASE_FILE
unset FAKE_MYSQL_OUTPUT

# The fake must record the SQL bound to -e even when later client options follow it.
FAKE_MYSQL_SQL_LOG="$TMP/fake.sql" FAKE_MYSQL_OUTPUT=$'ROW\tapp\tbilling\thost\t3' \
    "$FAKE" --login-path reporting -e 'SELECT 1' --batch >"$TMP/fake.out"
assert_contains "$TMP/fake.sql" 'SELECT 1'
assert_contains "$TMP/fake.out" $'ROW\tapp\tbilling\thost\t3'

printf 'PASS: check_opened_sessions_interactive CLI contract\n'
