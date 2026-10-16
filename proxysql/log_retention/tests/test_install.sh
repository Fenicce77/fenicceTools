#!/usr/bin/env bash
#
# Test suite for install.sh.
# Every run uses --root with a temporary directory or --dry-run, so no system
# file is touched and no systemctl command is executed.
#
# Usage: bash proxysql/log_retention/tests/test_install.sh

set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$TEST_DIR/../install.sh"
TEST_COUNT=0
WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/plr_install_test.XXXXXX")
trap 'rm -rf "$WORK_ROOT"' EXIT

readonly SERVICE="etc/systemd/system/proxysql-log-retention.service"
readonly TIMER="etc/systemd/system/proxysql-log-retention.timer"
readonly TMPFILES="etc/tmpfiles.d/purge_proxysql_eventslog.conf"
readonly LOGROTATE="etc/logrotate.d/purge_proxysql_eventslog"
readonly BIN="usr/local/bin/proxysql_eventslog_purge.sh"

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

assert_contains() {
    local haystack=$1 needle=$2 message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$haystack" == *"$needle"* ]] || fail "$message: [$needle] not found"
}

assert_not_contains() {
    local haystack=$1 needle=$2 message=$3
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ "$haystack" != *"$needle"* ]] || fail "$message: [$needle] unexpectedly found"
}

assert_file() {
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_no_file() {
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

new_root() { mktemp -d "$WORK_ROOT/root.XXXXXX"; }

# exit_code CMD... -> prints the exit status without tripping set -e
exit_code() {
    set +e
    "$@" >/dev/null 2>&1
    local rc=$?
    set -e
    printf '%s' "$rc"
}

test_syntax_and_help() {
    bash -n "$INSTALLER" || fail "syntax check"
    local out
    out=$("$INSTALLER" --help | cat)
    assert_contains "$out" $'\033[1;33mMODE' "help is colored when piped"
    assert_contains "$out" "--systemd" "help documents --systemd"
    assert_contains "$out" "--schedule" "help documents --schedule"
    assert_contains "$out" "EXIT STATUS" "help shows exit status"
    out=$(NO_COLOR=1 "$INSTALLER" --help)
    assert_not_contains "$out" $'\033' "NO_COLOR disables help colors"
}

test_invalid_values() {
    local r
    r=$(new_root)
    assert_eq 1 "$(exit_code "$INSTALLER" --bogus)" "unknown option"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --events-keep x)" "non-numeric keep"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir relative/dir)" "relative path"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir '/data/my logs')" "path with spaces"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --no-events --no-audit)" "nothing to schedule"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --audit-prefix query.log)" "same prefixes"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --schedule '%H')" "percent in schedule"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --systemd-version abc)" "bad systemd version"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir /data/proxysql)" "log dir equals data dir"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir /var/log)" "system log dir refused"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir /etc/plr)" "log dir under /etc refused"
    assert_eq 1 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir /data)" "top-level log dir refused"
    assert_eq 0 "$(exit_code "$INSTALLER" --systemd -y --root "$r" --log-dir /var/log/plr)" "dedicated /var/log subdir accepted"
}

test_script_only() {
    local r
    r=$(new_root)
    "$INSTALLER" --script-only -y --root "$r" >/dev/null 2>&1
    assert_file "$r/$BIN"
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ -x "$r/$BIN" ]] || fail "installed script is not executable"
    assert_no_file "$r/$SERVICE"
    assert_no_file "$r/$TIMER"
}

test_non_interactive_without_mode_is_script_only() {
    local r
    r=$(new_root)
    "$INSTALLER" -y --root "$r" >/dev/null 2>&1
    assert_file "$r/$BIN"
    assert_no_file "$r/$SERVICE"
}

test_systemd_defaults_append() {
    local r svc timer
    r=$(new_root)
    "$INSTALLER" --systemd -y --root "$r" --systemd-version 252 >/dev/null 2>&1
    assert_file "$r/$SERVICE"
    assert_file "$r/$TIMER"
    assert_file "$r/$TMPFILES"
    assert_file "$r/$LOGROTATE"
    assert_file "$r/data/log/purge_proxysql_eventslog/purge_proxysql_eventslog.log"

    svc=$(cat "$r/$SERVICE")
    assert_contains "$svc" "StandardOutput=append:/data/log/purge_proxysql_eventslog/purge_proxysql_eventslog.log" "append output"
    assert_contains "$svc" "ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log -k 200 -a 3 -c" "events command"
    assert_contains "$svc" "ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p audit.log -k 1000 -a 30 -c" "audit command"
    assert_contains "$svc" "ReadWritePaths=/data/proxysql /data/log/purge_proxysql_eventslog" "hardening paths"
    assert_contains "$svc" "ExecStartPre=/bin/date '+=== %%Y-%%m-%%d %%H:%%M:%%S run start ==='" "escaped date header"
    assert_not_contains "$svc" "User=" "root service has no User="

    timer=$(cat "$r/$TIMER")
    assert_contains "$timer" "OnCalendar=*-*-* 00:00:00" "default daily schedule"
    assert_contains "$timer" "Persistent=true" "persistent timer"
    assert_contains "$(cat "$r/$TMPFILES")" "d /data/log/purge_proxysql_eventslog 0750 root root -" "tmpfiles entry"
    assert_not_contains "$(cat "$r/$LOGROTATE")" "su " "no su directive for root"
}

test_systemd_legacy_redirection() {
    local r svc
    r=$(new_root)
    "$INSTALLER" --systemd -y --root "$r" --systemd-version 239 >/dev/null 2>&1
    svc=$(cat "$r/$SERVICE")
    assert_not_contains "$svc" "StandardOutput=append" "no append: on systemd 239"
    assert_contains "$svc" "ExecStart=/bin/sh -c 'exec /usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql -p query.log" "sh -c events command"
    assert_contains "$svc" ">>/data/log/purge_proxysql_eventslog/purge_proxysql_eventslog.log 2>&1'" "sh -c redirection"
}

test_custom_options() {
    local r svc
    r=$(new_root)
    "$INSTALLER" --systemd -y --root "$r" --systemd-version 255 \
        --bin-dir /opt/dbre/bin --data-dir /srv/proxysql --log-dir /srv/log/plr \
        --schedule '*-*-* 00/6:00:00' --no-audit --events-keep 10 --events-max-age 7 \
        --no-compress --no-hardening --no-logrotate --user nobody >/dev/null 2>&1
    svc=$(cat "$r/$SERVICE")
    assert_file "$r/opt/dbre/bin/proxysql_eventslog_purge.sh"
    assert_contains "$svc" "ExecStart=/opt/dbre/bin/proxysql_eventslog_purge.sh -d /srv/proxysql -p query.log -k 10 -a 7" "custom command"
    assert_not_contains "$svc" " -c" "no compression flag"
    assert_not_contains "$svc" "audit.log" "audit disabled"
    assert_not_contains "$svc" "ProtectSystem" "hardening disabled"
    assert_contains "$svc" "User=nobody" "custom user"
    assert_contains "$svc" "RequiresMountsFor=/srv/proxysql /srv/log/plr" "mount dependencies"
    assert_contains "$(cat "$r/$TIMER")" "OnCalendar=*-*-* 00/6:00:00" "custom schedule"
    assert_no_file "$r/$LOGROTATE"
}

test_reinstall_unchanged_and_backup() {
    local r out backups
    r=$(new_root)
    "$INSTALLER" --systemd -y --root "$r" --systemd-version 255 >/dev/null 2>&1
    out=$("$INSTALLER" --systemd -y --root "$r" --systemd-version 255 2>&1)
    assert_contains "$out" "Unchanged" "identical reinstall is a no-op"
    backups=$(find "$r/etc" -name '*.bak.*' | wc -l | tr -d ' ')
    assert_eq 0 "$backups" "no backups on identical reinstall"

    "$INSTALLER" --systemd -y --root "$r" --systemd-version 255 --events-keep 99 >/dev/null 2>&1
    backups=$(find "$r/etc/systemd/system" -name 'proxysql-log-retention.service.bak.*' | wc -l | tr -d ' ')
    assert_eq 1 "$backups" "changed service is backed up"
    assert_contains "$(cat "$r/$SERVICE")" "-k 99" "service updated"
}

test_dry_run_writes_nothing() {
    local r out
    r=$(new_root)
    out=$("$INSTALLER" --systemd -y -n --root "$r" --systemd-version 255 2>&1)
    assert_contains "$out" "[Service]" "dry-run prints the service"
    assert_contains "$out" "OnCalendar=" "dry-run prints the timer"
    assert_eq 0 "$(find "$r" -type f | wc -l | tr -d ' ')" "dry-run creates no files"
}

test_interactive_answers() {
    local r svc
    r=$(new_root)
    # bin, systemd?, data, logdir, user, schedule, events?, prefix, keep, age,
    # audit?, compress?, hardening?, logrotate?, enable?, apply?
    printf '%s\n' "" "y" "/data/proxysql" "/data/log/plr" "root" "*-*-* 03:30:00" \
        "y" "" "50" "7" "n" "n" "" "" "n" "y" |
        "$INSTALLER" -i --root "$r" --systemd-version 255 >/dev/null 2>&1
    svc=$(cat "$r/$SERVICE")
    assert_contains "$svc" "-p query.log -k 50 -a 7" "interactive retention"
    assert_not_contains "$svc" "audit.log" "interactive audit disabled"
    assert_not_contains "$svc" " -c" "interactive compression disabled"
    assert_contains "$svc" "append:/data/log/plr/purge_proxysql_eventslog.log" "interactive log dir"
    assert_contains "$(cat "$r/$TIMER")" "OnCalendar=*-*-* 03:30:00" "interactive schedule"
}

test_interactive_reprompts_invalid() {
    local r
    r=$(new_root)
    printf '%s\n' "not/abs" "/opt/bin" "n" "y" |
        "$INSTALLER" -i --root "$r" >/dev/null 2>&1
    assert_file "$r/opt/bin/proxysql_eventslog_purge.sh"
}

test_interactive_abort() {
    local r rc
    r=$(new_root)
    set +e
    printf '%s\n' "" "n" "n" | "$INSTALLER" -i --root "$r" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq 1 "$rc" "declining the plan aborts"
    assert_no_file "$r/$BIN"
}

test_uninstall() {
    local r
    r=$(new_root)
    "$INSTALLER" --systemd -y --root "$r" --systemd-version 255 >/dev/null 2>&1
    "$INSTALLER" --uninstall -y --root "$r" >/dev/null 2>&1
    assert_no_file "$r/$SERVICE"
    assert_no_file "$r/$TIMER"
    assert_no_file "$r/$TMPFILES"
    assert_no_file "$r/$LOGROTATE"
    assert_no_file "$r/$BIN"
    assert_file "$r/data/log/purge_proxysql_eventslog/purge_proxysql_eventslog.log"
}

test_requires_root_without_alt_root() {
    [[ "$(id -u)" -ne 0 ]] || return 0
    assert_eq 1 "$(exit_code "$INSTALLER" --script-only -y)" "non-root install is refused"
}

main() {
    test_syntax_and_help
    test_invalid_values
    test_script_only
    test_non_interactive_without_mode_is_script_only
    test_systemd_defaults_append
    test_systemd_legacy_redirection
    test_custom_options
    test_reinstall_unchanged_and_backup
    test_dry_run_writes_nothing
    test_interactive_answers
    test_interactive_reprompts_invalid
    test_interactive_abort
    test_uninstall
    test_requires_root_without_alt_root
    printf 'OK: %d assertions passed\n' "$TEST_COUNT"
}

main "$@"
