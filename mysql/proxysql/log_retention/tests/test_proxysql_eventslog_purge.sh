#!/usr/bin/env bash
#
# Test suite for proxysql_eventslog_purge.sh.
# Uses temporary fixture directories only; never touches real ProxySQL files.
#
# Usage: bash mysql/proxysql/log_retention/tests/test_proxysql_eventslog_purge.sh

set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_eventslog_purge.sh"
TEST_COUNT=0
WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/eventslog_purge_test.XXXXXX")
trap 'rm -rf "$WORK_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$actual" == "$expected" ]] ||
        fail "$message: expected [$expected], got [$actual]"
}

assert_exists() {
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ -e "$1" ]] || fail "expected file to exist: ${1##*/}"
}

assert_missing() {
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ ! -e "$1" ]] || fail "expected file to be removed: ${1##*/}"
}

assert_contains() {
    local haystack=$1 needle=$2 message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$haystack" == *"$needle"* ]] || fail "$message: [$needle] not found"
}

# new_fixture PREFIX COUNT -> prints directory with PREFIX.00000001..COUNT
new_fixture() {
    local prefix=$1 count=$2 dir i
    dir=$(mktemp -d "$WORK_ROOT/fx.XXXXXX")
    for ((i = 1; i <= count; i++)); do
        printf 'payload %d\n%.0s' "$i" {1..200} >"$dir/$(printf '%s.%08d' "$prefix" "$i")"
    done
    printf '%s\n' "$dir"
}

count_files() {
    local dir=$1 prefix=$2
    find "$dir" -maxdepth 1 -type f -name "${prefix}.*" | wc -l | tr -d ' '
}

test_syntax_and_help() {
    bash -n "$SCRIPT_PATH" || fail "syntax check"
    local out
    out=$("$SCRIPT_PATH" --help)
    assert_contains "$out" "USAGE" "help shows usage"
    assert_contains "$out" "--max-age" "help documents --max-age"
    assert_contains "$out" "audit.log" "help documents audit log usage"
}

test_invalid_arguments() {
    local rc
    set +e
    "$SCRIPT_PATH" --keep abc -d "$WORK_ROOT" >/dev/null 2>&1; rc=$?
    set -e
    assert_eq 1 "$rc" "non-numeric --keep is rejected"

    set +e
    "$SCRIPT_PATH" -d "$WORK_ROOT/does-not-exist" >/dev/null 2>&1; rc=$?
    set -e
    assert_eq 1 "$rc" "missing directory is rejected"

    set +e
    "$SCRIPT_PATH" --bogus >/dev/null 2>&1; rc=$?
    set -e
    assert_eq 1 "$rc" "unknown option is rejected"
}

test_dry_run_changes_nothing() {
    local dir
    dir=$(new_fixture query.log 6)
    "$SCRIPT_PATH" -d "$dir" -k 1 -c -n >/dev/null 2>&1
    assert_eq 6 "$(count_files "$dir" query.log)" "dry-run keeps all files"
    assert_missing "$dir/query.log.00000002.gz"
}

test_keep_by_count_protects_active() {
    local dir
    dir=$(new_fixture query.log 6)
    "$SCRIPT_PATH" -d "$dir" -k 2 >/dev/null 2>&1
    assert_missing "$dir/query.log.00000001"
    assert_missing "$dir/query.log.00000003"
    assert_exists  "$dir/query.log.00000004"
    assert_exists  "$dir/query.log.00000005"
    assert_exists  "$dir/query.log.00000006"
}

test_keep_zero_leaves_only_active() {
    local dir
    dir=$(new_fixture query.log 4)
    "$SCRIPT_PATH" -d "$dir" -k 0 >/dev/null 2>&1
    assert_eq 1 "$(count_files "$dir" query.log)" "only the active file remains"
    assert_exists "$dir/query.log.00000004"
}

test_max_age() {
    local dir
    dir=$(new_fixture query.log 4)
    touch -t 202001010000 "$dir/query.log.00000002"
    "$SCRIPT_PATH" -d "$dir" -k 100 -a 7 >/dev/null 2>&1
    assert_missing "$dir/query.log.00000002"
    assert_exists  "$dir/query.log.00000001"
    assert_exists  "$dir/query.log.00000003"
}

test_max_age_never_touches_active() {
    local dir
    dir=$(new_fixture query.log 2)
    touch -t 202001010000 "$dir/query.log.00000002"
    "$SCRIPT_PATH" -d "$dir" -k 100 -a 1 >/dev/null 2>&1
    assert_exists "$dir/query.log.00000002"
}

test_compress_and_rerun_idempotent() {
    local dir
    dir=$(new_fixture query.log 4)
    "$SCRIPT_PATH" -d "$dir" -k 10 -c >/dev/null 2>&1
    assert_exists "$dir/query.log.00000001.gz"
    assert_exists "$dir/query.log.00000003.gz"
    assert_exists "$dir/query.log.00000004"
    assert_missing "$dir/query.log.00000004.gz"

    # Second run: .gz files count towards retention and are purged in order
    "$SCRIPT_PATH" -d "$dir" -k 1 -c >/dev/null 2>&1
    assert_missing "$dir/query.log.00000001.gz"
    assert_missing "$dir/query.log.00000002.gz"
    assert_exists  "$dir/query.log.00000003.gz"
    assert_exists  "$dir/query.log.00000004"
}

test_numeric_ordering() {
    local dir
    dir=$(mktemp -d "$WORK_ROOT/fx.XXXXXX")
    : >"$dir/query.log.9"
    : >"$dir/query.log.10"
    : >"$dir/query.log.11"
    "$SCRIPT_PATH" -d "$dir" -k 1 >/dev/null 2>&1
    assert_missing "$dir/query.log.9"
    assert_exists  "$dir/query.log.10"
    assert_exists  "$dir/query.log.11"
}

test_prefix_isolation() {
    local dir
    dir=$(new_fixture query.log 3)
    local i
    for i in 1 2 3; do
        : >"$dir/$(printf 'audit.log.%08d' "$i")"
    done
    : >"$dir/query.log.notes"
    "$SCRIPT_PATH" -d "$dir" -p audit.log -k 0 >/dev/null 2>&1
    assert_eq 1 "$(count_files "$dir" audit.log)" "audit rotated files purged"
    assert_exists "$dir/audit.log.00000003"
    assert_eq 4 "$(count_files "$dir" query.log)" "query.log files untouched"
}

test_no_matching_files() {
    local dir out
    dir=$(mktemp -d "$WORK_ROOT/fx.XXXXXX")
    out=$("$SCRIPT_PATH" -d "$dir" 2>&1)
    assert_contains "$out" "No files matching" "empty directory warning"
}

test_no_color_when_not_tty() {
    local dir out
    dir=$(new_fixture query.log 3)
    out=$("$SCRIPT_PATH" -d "$dir" -k 1 2>&1)
    TEST_COUNT=$((TEST_COUNT + 1))
    case "$out" in
        *$'\033'*) fail "ANSI colors emitted to a non-TTY" ;;
    esac
}

main() {
    test_syntax_and_help
    test_invalid_arguments
    test_dry_run_changes_nothing
    test_keep_by_count_protects_active
    test_keep_zero_leaves_only_active
    test_max_age
    test_max_age_never_touches_active
    test_compress_and_rerun_idempotent
    test_numeric_ordering
    test_prefix_isolation
    test_no_matching_files
    test_no_color_when_not_tty
    printf 'OK: %d assertions passed\n' "$TEST_COUNT"
}

main "$@"
