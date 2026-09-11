#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$TEST_DIR/../innodb_engine_status.sampler.sh"
FAKE_MYSQL="$TEST_DIR/fake_mysql_innodb_sampler.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/innodb-sampler-test.XXXXXX")
TEST_COUNT=0

cleanup() {
    local exit_code=$?

    if [[ -n "${CAPTURE_PID:-}" ]] && kill -0 "$CAPTURE_PID" 2>/dev/null; then
        kill -TERM "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
    if [[ -n "${LEGACY_LOCK_PID:-}" ]] && kill -0 "$LEGACY_LOCK_PID" 2>/dev/null; then
        kill -TERM "$LEGACY_LOCK_PID" 2>/dev/null || true
        wait "$LEGACY_LOCK_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

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

assert_contains() {
    local file=$1
    local text=$2
    local message=$3

    TEST_COUNT=$((TEST_COUNT + 1))
    grep -F -- "$text" "$file" >/dev/null || fail "$message: missing [$text]"
}

assert_not_contains() {
    local file=$1
    local text=$2
    local message=$3

    TEST_COUNT=$((TEST_COUNT + 1))
    if grep -F -- "$text" "$file" >/dev/null; then
        fail "$message: unexpected [$text]"
    fi
}

assert_status() {
    local expected=$1

    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$RUN_STATUS" -eq "$expected" ]] || fail "unexpected exit status: expected [$expected], got [$RUN_STATUS]"
}

prepare_sampler_copy() {
    SAMPLER_DIR="$TMP_DIR/sampler"
    mkdir -p "$SAMPLER_DIR/.conf"
    cp "$SOURCE_SCRIPT" "$SAMPLER_DIR/innodb_engine_status.sampler.sh"
    chmod +x "$SAMPLER_DIR/innodb_engine_status.sampler.sh"
    printf '%s\n' '[client]' 'host=remote-db.example' 'port=3307' > "$SAMPLER_DIR/.conf/reporting.cnf"
}

run_case() {
    local name=$1
    shift

    set +e
    FAKE_MYSQL_LOG="$TMP_DIR/$name.mysql.log" \
        perl -e '
            my $limit = shift @ARGV;
            my $pid = fork();
            die "fork failed: $!\n" unless defined $pid;
            if ($pid == 0) { exec @ARGV; die "exec failed: $!\n"; }
            local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
            alarm $limit;
            waitpid $pid, 0;
            exit($? >> 8);
        ' 2 "$SAMPLER_DIR/innodb_engine_status.sampler.sh" "$@" >"$TMP_DIR/$name.out" 2>"$TMP_DIR/$name.err"
    RUN_STATUS=$?
    set -e
}

run_tty_help() {
    local output_file=$1
    shift

    case "$(uname -s)" in
        Darwin)
            TERM=xterm script -q /dev/null "$SAMPLER_DIR/innodb_engine_status.sampler.sh" --help "$@" >"$output_file" 2>&1
            ;;
        Linux)
            local command=''
            local argument
            for argument in "$SAMPLER_DIR/innodb_engine_status.sampler.sh" --help "$@"; do
                printf -v command '%s%q ' "$command" "$argument"
            done
            TERM=xterm script -q -e -c "$command" /dev/null >"$output_file" 2>&1
            ;;
        *)
            fail "unsupported pseudo-terminal platform: $(uname -s)"
            ;;
    esac
}

prepare_sampler_copy

# The public help must return without treating --help as an instance name.
run_case help --help
assert_status 0
assert_contains "$TMP_DIR/help.out" 'Usage:' 'help output'
assert_contains "$TMP_DIR/help.out" '--display' 'help documents display mode'
assert_not_contains "$TMP_DIR/help.out" $'\033[' 'redirected help is ANSI-free'

run_tty_help "$TMP_DIR/help_tty.out"
assert_contains "$TMP_DIR/help_tty.out" $'\033[' 'TTY help is colored'
run_tty_help "$TMP_DIR/help_tty_no_color.out" --no-color
assert_not_contains "$TMP_DIR/help_tty_no_color.out" $'\033[' 'no-color TTY help is ANSI-free'

# The standard option separator must preserve an instance name beginning after it.
run_case separator --display --mysql-bin "$FAKE_MYSQL" -- reporting
assert_status 0
assert_contains "$TMP_DIR/separator.out" 'INNODB MONITOR OUTPUT' 'separator display output'

# Display is a single remote sample and does not create a capture hierarchy.
DISPLAY_BASE="$TMP_DIR/display-samples"
run_case display reporting --display --sample-base-dir "$DISPLAY_BASE" --mysql-bin "$FAKE_MYSQL"
assert_status 0
assert_contains "$TMP_DIR/display.out" 'INNODB MONITOR OUTPUT' 'display output'
[[ ! -e "$DISPLAY_BASE" ]] || fail 'display mode created a sample directory'
assert_contains "$TMP_DIR/display.mysql.log" '--defaults-file=' 'display passes the instance defaults file'

# Capture preserves the server-organized hierarchy and removes its lock on TERM.
CAPTURE_BASE="$TMP_DIR/capture-samples"
FAKE_MYSQL_LOG="$TMP_DIR/capture.mysql.log" \
    "$SAMPLER_DIR/innodb_engine_status.sampler.sh" reporting --interval 1 \
    --sample-base-dir "$CAPTURE_BASE" --mysql-bin "$FAKE_MYSQL" >"$TMP_DIR/capture.out" 2>"$TMP_DIR/capture.err" &
CAPTURE_PID=$!

sample_file=''
for _ in $(seq 1 30); do
    sample_file=$(find "$CAPTURE_BASE" -type f -name '*.sample' -print -quit 2>/dev/null || true)
    [[ -n "$sample_file" ]] && break
    sleep 0.1
done
[[ -n "$sample_file" ]] || fail 'capture mode did not create a sample file'
assert_contains "$sample_file" 'INNODB MONITOR OUTPUT' 'captured sample content'

run_case active_lock reporting --interval 1 --sample-base-dir "$CAPTURE_BASE" --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$TMP_DIR/active_lock.err" 'capture is already running' 'active lock rejection'

kill -TERM "$CAPTURE_PID"
wait "$CAPTURE_PID" 2>/dev/null || true
CAPTURE_PID=''

expected_root="$CAPTURE_BASE/remote-db.example_3307"
case "$sample_file" in
    "$expected_root"/*) TEST_COUNT=$((TEST_COUNT + 1)) ;;
    *) fail "sample hierarchy is not server-organized: $sample_file" ;;
esac
[[ ! -e "$expected_root/lockfile.lock" ]] || fail 'capture lockfile remains after TERM'

# A live lockfile from the legacy sampler must remain authoritative during migration.
mkdir -p "$expected_root"
sleep 10 &
LEGACY_LOCK_PID=$!
printf '%s\n' "$LEGACY_LOCK_PID" > "$expected_root/lockfile.lock"
run_case legacy_lock reporting --interval 1 --sample-base-dir "$CAPTURE_BASE" --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$TMP_DIR/legacy_lock.err" 'capture is already running' 'legacy lock rejection'
kill -TERM "$LEGACY_LOCK_PID"
wait "$LEGACY_LOCK_PID" 2>/dev/null || true
LEGACY_LOCK_PID=''
rm -f "$expected_root/lockfile.lock"

# A failed connection must not create an empty or partial sample file.
FAILURE_BASE="$TMP_DIR/failure-samples"
FAKE_MYSQL_FAIL_CONNECTION=1 FAKE_MYSQL_LOG="$TMP_DIR/failure.mysql.log" \
    "$SAMPLER_DIR/innodb_engine_status.sampler.sh" reporting --interval 1 \
    --sample-base-dir "$FAILURE_BASE" --mysql-bin "$FAKE_MYSQL" >"$TMP_DIR/failure.out" 2>"$TMP_DIR/failure.err" &
CAPTURE_PID=$!
sleep 0.3
failed_sample=$(find "$FAILURE_BASE" -type f -name '*.sample' -print -quit 2>/dev/null || true)
[[ -z "$failed_sample" ]] || fail 'connection failure created a sample file'
assert_contains "$TMP_DIR/failure.err" 'connection check failed' 'connection failure warning'
kill -TERM "$CAPTURE_PID"
wait "$CAPTURE_PID" 2>/dev/null || true
CAPTURE_PID=''

# Argument errors must include the full help and return the standard usage status.
run_case missing_instance --display
assert_status 2
assert_contains "$TMP_DIR/missing_instance.err" 'ERROR:' 'argument error'
assert_contains "$TMP_DIR/missing_instance.err" 'Usage:' 'argument-error help'

# Invalid numeric input must be rejected before any connection attempt.
run_case invalid_interval reporting --display --interval 0 --mysql-bin "$FAKE_MYSQL"
assert_status 2
assert_contains "$TMP_DIR/invalid_interval.err" '--interval must be a positive integer.' 'interval validation'
assert_contains "$TMP_DIR/invalid_interval.err" 'Usage:' 'interval-error help'

printf 'PASS: %s assertions\n' "$TEST_COUNT"
