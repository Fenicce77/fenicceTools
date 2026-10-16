#!/usr/bin/env bash
#
# Test suite for the service management actions of proxysql_eventslog_purge.sh
# (--install, --uninstall, --list).
# Every run uses --root with a temporary directory or --dry-run, so no system
# file is touched and no systemctl command is executed.
#
# Usage: bash proxysql/log_retention/tests/test_service_management.sh

set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$TEST_DIR/../proxysql_eventslog_purge.sh"
TEST_COUNT=0
WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/plr_service_test.XXXXXX")
trap 'rm -rf "$WORK_ROOT"' EXIT

readonly UNITS="etc/systemd/system"
readonly ROTATE="etc/logrotate.d"
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

exit_code() {
    set +e
    "$@" >/dev/null 2>&1
    local rc=$?
    set -e
    printf '%s' "$rc"
}

# install_y ROOT NAME [ARGS...] -> non-interactive install under ROOT
install_y() {
    local root=$1 name=$2
    shift 2
    "$SCRIPT_PATH" --install "$name" --root "$root" -y --systemd-version 252 "$@" >/dev/null 2>&1
}

# Run with a pseudo-terminal on stdin, feeding ANSWER to the confirmation.
run_with_tty() {
    local answer=$1 output_file=$2
    shift 2
    case "$(uname -s)" in
        Darwin)
            { sleep 0.5; printf '%s\n' "$answer"; } | script -q /dev/null "$@" >"$output_file" 2>&1
            ;;
        Linux)
            local cmd
            printf -v cmd '%q ' "$@"
            { sleep 0.5; printf '%s\n' "$answer"; } | script -q -e -c "$cmd" /dev/null >"$output_file" 2>&1
            ;;
        *)
            fail "unsupported platform: $(uname -s)"
            ;;
    esac
}

test_help_documents_service_management() {
    local out
    out=$(NO_COLOR=1 "$SCRIPT_PATH" --help)
    assert_contains "$out" "SERVICE MANAGEMENT" "help has service section"
    assert_contains "$out" "--install NAME" "help documents --install"
    assert_contains "$out" "--uninstall NAME" "help documents --uninstall"
    assert_contains "$out" "--list" "help documents --list"
    assert_contains "$out" "--schedule SPEC" "help documents --schedule"
}

test_invalid_values() {
    local r
    r=$(new_root)
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install 'bad name' --root "$r" -y)" "rotation name with space"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install 'a.b' --root "$r" -y)" "rotation name with dot"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x -d relative --root "$r" -y)" "relative data dir"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x --log-dir '/my logs' --root "$r" -y)" "log dir with space"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x --schedule '%H' --root "$r" -y)" "percent in schedule"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x -k abc --root "$r" -y)" "non-numeric keep"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x --list --root "$r")" "mutually exclusive actions"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install x --systemd-version v2 --root "$r" -y)" "bad systemd version"
}

test_install_defaults() {
    local r svc timer rot
    r=$(new_root)
    install_y "$r" proxysql1-events -d /data/proxysql1 -p query.log -k 200 -a 3 -c
    assert_file "$r/$BIN"
    TEST_COUNT=$((TEST_COUNT + 1))
    [[ -x "$r/$BIN" ]] || fail "installed script is not executable"
    cmp -s "$SCRIPT_PATH" "$r/$BIN" || fail "installed script differs from source"

    svc=$(cat "$r/$UNITS/proxysql-log-retention-proxysql1-events.service")
    assert_contains "$svc" "ExecStart=/usr/local/bin/proxysql_eventslog_purge.sh -d /data/proxysql1 -p query.log -k 200 -a 3 -c" "purge command"
    assert_contains "$svc" "StandardOutput=append:/data/log/purge_proxysql_eventslog/proxysql1-events.log" "per-rotation log file"
    assert_contains "$svc" "ReadWritePaths=/data/proxysql1 /data/log/purge_proxysql_eventslog" "hardening paths"
    assert_contains "$svc" "RequiresMountsFor=/data/proxysql1 /data/log/purge_proxysql_eventslog" "mount dependencies"
    assert_contains "$svc" "ExecStartPre=/bin/date '+=== %%Y-%%m-%%d %%H:%%M:%%S run start ==='" "escaped date header"
    assert_contains "$svc" "# plr.name=proxysql1-events" "metadata name"
    assert_not_contains "$svc" "User=" "root service has no User="

    timer=$(cat "$r/$UNITS/proxysql-log-retention-proxysql1-events.timer")
    assert_contains "$timer" "OnCalendar=*-*-* 00:00:00" "default daily schedule"
    assert_contains "$timer" "Persistent=true" "persistent timer"

    rot=$(cat "$r/$ROTATE/proxysql-log-retention-proxysql1-events")
    assert_contains "$rot" "/data/log/purge_proxysql_eventslog/proxysql1-events.log {" "logrotate targets the exact file"
    assert_not_contains "$rot" "*.log" "logrotate has no wildcard"
    assert_file "$r/data/log/purge_proxysql_eventslog/proxysql1-events.log"
}

test_multiple_instances() {
    local r out
    r=$(new_root)
    install_y "$r" proxysql1-events -d /data/proxysql1 -p query.log -k 200 -a 3 -c
    install_y "$r" proxysql1-audit  -d /data/proxysql1 -p audit.log -k 1000 -a 30 -c
    install_y "$r" proxysql2-events -d /data/proxysql2 -p query.log -k 100 -a 2 \
        --schedule '*-*-* 00/6:00:00' --log-dir /data/log/proxysql2

    assert_eq 3 "$(find "$r/$UNITS" -name '*.timer' | wc -l | tr -d ' ')" "three timers"
    assert_contains "$(cat "$r/$UNITS/proxysql-log-retention-proxysql2-events.timer")" \
        "OnCalendar=*-*-* 00/6:00:00" "own schedule per rotation"
    assert_contains "$(cat "$r/$UNITS/proxysql-log-retention-proxysql2-events.service")" \
        "append:/data/log/proxysql2/proxysql2-events.log" "own log dir per rotation"

    out=$("$SCRIPT_PATH" --list --root "$r")
    assert_contains "$out" "proxysql1-audit" "list shows audit rotation"
    assert_contains "$out" "proxysql1-events" "list shows events rotation"
    assert_contains "$out" "proxysql2-events" "list shows second instance"
    assert_contains "$out" "/data/proxysql2" "list shows directory"
    assert_contains "$out" "00/6:00:00" "list shows schedule"
}

test_conflict_same_dir_and_prefix() {
    local r out rc
    r=$(new_root)
    install_y "$r" proxysql1-events -d /data/proxysql1 -p query.log
    set +e
    out=$("$SCRIPT_PATH" --install other -d /data/proxysql1/ -p query.log --root "$r" -y 2>&1)
    rc=$?
    set -e
    assert_eq 1 "$rc" "same dir + prefix is refused"
    assert_contains "$out" "Rotation 'proxysql1-events' already manages /data/proxysql1/query.log" "conflict message"
    assert_no_file "$r/$UNITS/proxysql-log-retention-other.service"
    assert_eq 0 "$(exit_code install_y "$r" proxysql1-events -d /data/proxysql1 -p query.log -k 50)" "same name updates in place"
}

test_reinstall_unchanged_and_backup() {
    local r out
    r=$(new_root)
    install_y "$r" p1 -d /data/p1
    out=$("$SCRIPT_PATH" --install p1 -d /data/p1 --root "$r" -y --systemd-version 252 2>&1)
    assert_contains "$out" "Unchanged" "identical reinstall is a no-op"
    assert_contains "$out" "(update existing)" "plan says update"
    assert_eq 0 "$(find "$r" -name '*.bak.*' | wc -l | tr -d ' ')" "no backups on identical reinstall"

    install_y "$r" p1 -d /data/p1 -k 77
    assert_eq 1 "$(find "$r/$UNITS" -name 'proxysql-log-retention-p1.service.bak.*' | wc -l | tr -d ' ')" "changed service backed up"
    assert_contains "$(cat "$r/$UNITS/proxysql-log-retention-p1.service")" "-k 77" "service updated"
}

test_legacy_systemd_and_options() {
    local r svc
    r=$(new_root)
    "$SCRIPT_PATH" --install p1 -d /srv/proxysql -p audit.log -k 5 --root "$r" -y \
        --systemd-version 239 --no-hardening --no-logrotate --user nobody \
        --bin-dir /opt/dbre/bin >/dev/null 2>&1
    svc=$(cat "$r/$UNITS/proxysql-log-retention-p1.service")
    assert_not_contains "$svc" "StandardOutput=append" "no append: on systemd 239"
    assert_contains "$svc" "ExecStart=/bin/sh -c 'exec /opt/dbre/bin/proxysql_eventslog_purge.sh -d /srv/proxysql -p audit.log -k 5 -a 0 >>/data/log/purge_proxysql_eventslog/p1.log 2>&1'" "sh -c redirection"
    assert_not_contains "$svc" "ProtectSystem" "hardening disabled"
    assert_contains "$svc" "User=nobody" "custom user"
    assert_file "$r/opt/dbre/bin/proxysql_eventslog_purge.sh"
    assert_no_file "$r/$ROTATE/proxysql-log-retention-p1"
}

test_dry_run_shows_files_writes_nothing() {
    local r out
    r=$(new_root)
    out=$("$SCRIPT_PATH" --install p1 -d /data/p1 -c --root "$r" -n --systemd-version 252 2>&1)
    assert_contains "$out" "[Service]" "plan prints the service"
    assert_contains "$out" "OnCalendar=" "plan prints the timer"
    assert_contains "$out" "/data/log/purge_proxysql_eventslog/p1.log {" "plan prints logrotate"
    assert_eq 0 "$(find "$r" -type f | wc -l | tr -d ' ')" "dry-run creates no files"
}

test_confirmation() {
    local r out
    r=$(new_root)
    set +e
    out=$("$SCRIPT_PATH" --install p1 -d /data/p1 --root "$r" </dev/null 2>&1)
    local rc=$?
    set -e
    assert_eq 1 "$rc" "no tty and no -y is refused"
    assert_contains "$out" "re-run with -y" "explains how to confirm"
    assert_no_file "$r/$UNITS/proxysql-log-retention-p1.service"

    command -v script >/dev/null 2>&1 || return 0
    run_with_tty "n" "$WORK_ROOT/tty.out" "$SCRIPT_PATH" --install p1 -d /data/p1 --root "$r" || true
    assert_contains "$(cat "$WORK_ROOT/tty.out")" "Aborted: nothing was changed" "declined confirmation"
    assert_no_file "$r/$UNITS/proxysql-log-retention-p1.service"

    run_with_tty "y" "$WORK_ROOT/tty.out" "$SCRIPT_PATH" --install p1 -d /data/p1 --root "$r" --systemd-version 252
    assert_file "$r/$UNITS/proxysql-log-retention-p1.service"
}

test_uninstall() {
    local r out
    r=$(new_root)
    install_y "$r" p1 -d /data/p1
    install_y "$r" p2 -d /data/p2
    "$SCRIPT_PATH" --uninstall p1 --root "$r" -y >/dev/null 2>&1
    assert_no_file "$r/$UNITS/proxysql-log-retention-p1.service"
    assert_no_file "$r/$UNITS/proxysql-log-retention-p1.timer"
    assert_no_file "$r/$ROTATE/proxysql-log-retention-p1"
    assert_file "$r/$UNITS/proxysql-log-retention-p2.service"
    assert_file "$r/$BIN"
    assert_file "$r/data/log/purge_proxysql_eventslog/p1.log"
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --uninstall p1 --root "$r" -y)" "unknown rotation"

    out=$("$SCRIPT_PATH" --list --root "$r")
    assert_not_contains "$out" "p1 " "removed rotation not listed"
    assert_contains "$out" "p2" "remaining rotation listed"
}

test_list_empty() {
    local out
    out=$("$SCRIPT_PATH" --list --root "$(new_root)" 2>&1)
    assert_contains "$out" "No rotations installed" "empty list message"
}

test_requires_root_on_host() {
    [[ "$(id -u)" -ne 0 ]] || return 0
    assert_eq 1 "$(exit_code "$SCRIPT_PATH" --install p1 -d /data/p1 -y)" "non-root install refused"
}

main() {
    test_help_documents_service_management
    test_invalid_values
    test_install_defaults
    test_multiple_instances
    test_conflict_same_dir_and_prefix
    test_reinstall_unchanged_and_backup
    test_legacy_systemd_and_options
    test_dry_run_shows_files_writes_nothing
    test_confirmation
    test_uninstall
    test_list_empty
    test_requires_root_on_host
    printf 'OK: %d assertions passed\n' "$TEST_COUNT"
}

main "$@"
