#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/check_opened_sessions_interactive.sh"
FAKE="$ROOT/tests/fake_mysql_open_sessions.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/open-sessions-cli-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
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

run_case() {
    local name=$1
    shift

    set +e
    "$SCRIPT" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
}

run_tty_case() {
    local name=$1
    shift
    local command=''
    local argument

    if [[ "$(uname -s)" == Darwin ]]; then
        set +e
        TERM=xterm script -q "$TMP/$name.out" "$SCRIPT" "$@" \
            >"$TMP/$name.console" 2>"$TMP/$name.err"
        STATUS=$?
        set -e
        return
    fi

    for argument in "$SCRIPT" "$@"; do
        printf -v command '%s%q ' "$command" "$argument"
    done
    set +e
    TERM=xterm script -q -c "$command" "$TMP/$name.out" \
        >"$TMP/$name.console" 2>"$TMP/$name.err"
    STATUS=$?
    set -e
}

strip_frame_ansi() {
    LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' "$1" | tr -d '\r' | \
        sed 's/^Timestamp: .*/Timestamp: <normalized>/'
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
run_case attached_short_options -lreporting -t10 -uapp -dbilling -hhost -o --mysql-bin "$FAKE"
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

# A usable pseudo-TTY clears the frame. --no-color keeps refresh but removes styling.
run_tty_case tty_color --login-path reporting --mysql-bin "$FAKE"
assert_status 0
assert_contains "$TMP/tty_color.out" $'\033[H\033[2J'
assert_contains "$TMP/tty_color.out" $'\033[0;36m'

run_tty_case tty_no_color --login-path reporting --mysql-bin "$FAKE" --no-color
assert_status 0
assert_contains "$TMP/tty_no_color.out" $'\033[H\033[2J'
assert_not_contains "$TMP/tty_no_color.out" $'\033[0;31m'
assert_not_contains "$TMP/tty_no_color.out" $'\033[0;33m'
assert_not_contains "$TMP/tty_no_color.out" $'\033[0;36m'

# Removing style bytes from a colored frame must preserve every table column position.
strip_frame_ansi "$TMP/tty_color.out" > "$TMP/tty_color.plain"
strip_frame_ansi "$TMP/tty_no_color.out" > "$TMP/tty_no_color.plain"
cmp -s "$TMP/tty_color.plain" "$TMP/tty_no_color.plain" || fail 'colored and no-color frame layouts differ'

# Snapshot logs are plain text and their requested destination is created once.
run_case new_log --login-path reporting --logging --log-file "$TMP/new-snapshot.log" --mysql-bin "$FAKE"
assert_status 0
[[ -f "$TMP/new-snapshot.log" ]] || fail 'logging did not create the requested log file'
assert_contains "$TMP/new-snapshot.log" 'Open MySQL Sessions'
assert_contains "$TMP/new-snapshot.log" 'Total matching connections: 3'
assert_not_contains "$TMP/new-snapshot.log" $'\033['

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
"$SCRIPT" --login-path reporting --log-file "$TMP/claimed.log" --mysql-bin "$FAKE" \
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
assert_status 0
[[ ! -s "$TMP/claimed.log" ]] || fail 'competing creator modified the claimed log path'
unset FAKE_MYSQL_READY_FILE FAKE_MYSQL_RELEASE_FILE
unset FAKE_MYSQL_OUTPUT

# The fake must record the SQL bound to -e even when later client options follow it.
FAKE_MYSQL_SQL_LOG="$TMP/fake.sql" FAKE_MYSQL_OUTPUT=$'ROW\tapp\tbilling\thost\t3' \
    "$FAKE" --login-path reporting -e 'SELECT 1' --batch >"$TMP/fake.out"
assert_contains "$TMP/fake.sql" 'SELECT 1'
assert_contains "$TMP/fake.out" $'ROW\tapp\tbilling\thost\t3'

printf 'PASS: check_opened_sessions_interactive CLI contract\n'
