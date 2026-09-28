#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INNODB_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CANONICAL_SCRIPT="$INNODB_DIR/innodb_status_analyzer.sh"
LEGACY_DIR="$INNODB_DIR/innodb_analyzer/legacy"
FIXTURE="$SCRIPT_DIR/fixtures/innodb_status_analyzer/20260928_10.sample"
FIXTURE_11="$SCRIPT_DIR/fixtures/innodb_status_analyzer/20260928_11.sample"
SPACE_FIXTURE="$SCRIPT_DIR/fixtures/innodb_status_analyzer/space dir/20260928_12.sample"

assert_file_exists() {
    if [ ! -f "$1" ]; then
        printf 'FAIL: expected file to exist: %s\n' "$1" >&2
        exit 1
    fi
}

assert_file_absent() {
    if [ -e "$1" ]; then
        printf 'FAIL: expected path to be absent: %s\n' "$1" >&2
        exit 1
    fi
}

assert_executable() {
    if [ ! -x "$1" ]; then
        printf 'FAIL: expected executable file: %s\n' "$1" >&2
        exit 1
    fi
}

sample_digest() {
    shasum -a 256 "$1" | awk '{print $1}'
}

assert_status() {
    local expected=$1
    shift
    set +e
    "$@" >/tmp/innodb_status_analyzer_test.out 2>&1
    local actual=$?
    set -e
    if [ "$actual" -ne "$expected" ]; then
        printf 'FAIL: expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
        cat /tmp/innodb_status_analyzer_test.out >&2
        exit 1
    fi
}

assert_no_escape() {
    if LC_ALL=C grep -q "$(printf '\033')" "$1"; then
        printf 'FAIL: unexpected ANSI escape sequence in %s\n' "$1" >&2
        exit 1
    fi
}

assert_executable "$CANONICAL_SCRIPT"

for legacy_file in \
    innodb_status_analyzer.root.sh \
    innodb_status_analyzer.v2.sh \
    innodb_status_analyzer.v4.sh \
    innodb_analyzer.multiple.sh \
    innodb_analyzer_extended.sh \
    innodb_analyzer_extended.v2.sh; do
    assert_file_exists "$LEGACY_DIR/$legacy_file"
done

for active_file in \
    innodb_status_analyzer.v2.sh \
    innodb_status_analyzer.v4.sh \
    innodb_analyzer.multiple.sh \
    innodb_analyzer_extended.sh \
    innodb_analyzer_extended.v2.sh; do
    assert_file_absent "$INNODB_DIR/innodb_analyzer/$active_file"
done

assert_file_exists "$FIXTURE"
assert_file_exists "$FIXTURE_11"
assert_file_exists "$SPACE_FIXTURE"
assert_status 2 "$CANONICAL_SCRIPT"
grep -q '^ERROR:' /tmp/innodb_status_analyzer_test.out
grep -q '^Usage:' /tmp/innodb_status_analyzer_test.out
assert_status 0 "$CANONICAL_SCRIPT" --help
grep -q '^Usage:' /tmp/innodb_status_analyzer_test.out
assert_status 2 "$CANONICAL_SCRIPT" --mode invalid
grep -q '^ERROR:' /tmp/innodb_status_analyzer_test.out
assert_status 0 "$CANONICAL_SCRIPT" --no-color --file "$FIXTURE" "$FIXTURE_11" "$SPACE_FIXTURE" --report-mode screen
assert_no_escape /tmp/innodb_status_analyzer_test.out
grep -q '20260928_10.sample' /tmp/innodb_status_analyzer_test.out
grep -q '20260928_11.sample' /tmp/innodb_status_analyzer_test.out
grep -q '20260928_12.sample' /tmp/innodb_status_analyzer_test.out
before_digest=$(sample_digest "$FIXTURE")
"$CANONICAL_SCRIPT" --file "$FIXTURE" --report-mode screen >/dev/null
after_digest=$(sample_digest "$FIXTURE")

if [ "$before_digest" != "$after_digest" ]; then
    printf 'FAIL: analyzer modified source fixture: %s\n' "$FIXTURE" >&2
    exit 1
fi

printf 'PASS: canonical analyzer layout and source immutability\n'
