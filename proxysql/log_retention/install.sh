#!/usr/bin/env bash
#
# install.sh
#
# Installer for proxysql_eventslog_purge.sh. Installs the purge script and,
# optionally, a systemd service + timer, a tmpfiles.d entry for the log
# directory and a logrotate policy. Every setting can be given as an option
# or answered interactively.
#
# Compatible with Linux and macOS (bash >= 3.2). systemd components are only
# available on Linux hosts running systemd (or when --root is used to render
# files for another host or a package).

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.1.0"
readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PURGE_NAME="proxysql_eventslog_purge.sh"
readonly UNIT_NAME="proxysql-log-retention"
readonly LOG_FILE_NAME="purge_proxysql_eventslog.log"
readonly TMPFILES_NAME="purge_proxysql_eventslog.conf"
readonly LOGROTATE_NAME="purge_proxysql_eventslog"
readonly MIN_SYSTEMD_APPEND=240

# Defaults
readonly DEFAULT_BIN_DIR="/usr/local/bin"
readonly DEFAULT_DATA_DIR="/data/proxysql"
readonly DEFAULT_LOG_DIR="/data/log/purge_proxysql_eventslog"
readonly DEFAULT_RUN_USER="root"
readonly DEFAULT_SCHEDULE="*-*-* 00:00:00"
readonly DEFAULT_EVENTS_PREFIX="query.log"
readonly DEFAULT_EVENTS_KEEP=200
readonly DEFAULT_EVENTS_MAX_AGE=3
readonly DEFAULT_AUDIT_PREFIX="audit.log"
readonly DEFAULT_AUDIT_KEEP=1000
readonly DEFAULT_AUDIT_MAX_AGE=30

BIN_DIR="$DEFAULT_BIN_DIR"
DATA_DIR="$DEFAULT_DATA_DIR"
LOG_DIR="$DEFAULT_LOG_DIR"
RUN_USER="$DEFAULT_RUN_USER"
SCHEDULE="$DEFAULT_SCHEDULE"
EVENTS_ENABLED=1
EVENTS_PREFIX="$DEFAULT_EVENTS_PREFIX"
EVENTS_KEEP="$DEFAULT_EVENTS_KEEP"
EVENTS_MAX_AGE="$DEFAULT_EVENTS_MAX_AGE"
AUDIT_ENABLED=1
AUDIT_PREFIX="$DEFAULT_AUDIT_PREFIX"
AUDIT_KEEP="$DEFAULT_AUDIT_KEEP"
AUDIT_MAX_AGE="$DEFAULT_AUDIT_MAX_AGE"
COMPRESS=1
HARDENING=1
LOGROTATE=1
ENABLE_TIMER=1
INSTALL_SYSTEMD=""          # "", 1 or 0; "" = ask (interactive) / no (non-interactive)
INTERACTIVE=""              # "", 1 or 0; "" = auto (stdin is a TTY and no --yes)
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0
ROOT_DIR=""
SYSTEMD_VERSION=""
RUN_GROUP=""
ACCEPT_LOG_DIR=0

# Runtime colors (only when stderr is a TTY; prompts and messages go to stderr)
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; GRAY=$'\033[0;90m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GRAY=""; BOLD=""; NC=""
fi

info()  { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*" >&2; }
ok()    { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*" >&2; }
warn()  { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC" >&2; }

usage() {
    # Help has its own palette: always colored, unless NO_COLOR is set.
    local T="" H="" F="" M="" C="" X="" W="" R="" N=""
    if [[ -z "${NO_COLOR:-}" ]]; then
        T=$'\033[1;36m'; H=$'\033[1;33m'; F=$'\033[0;32m'; M=$'\033[0;36m'
        C=$'\033[0;90m'; X=$'\033[0;37m'; W=$'\033[0;33m'; R=$'\033[1;31m'
        N=$'\033[0m'
    fi

    cat <<EOF
${T}${SCRIPT_NAME}${N} ${M}v${VERSION}${N}
Installer for ${PURGE_NAME} with optional systemd service and timer

${H}DESCRIPTION${N}
    Installs ${PURGE_NAME} and, optionally:
      - ${M}${UNIT_NAME}.service${N} (oneshot) and ${M}${UNIT_NAME}.timer${N}
      - ${M}/etc/tmpfiles.d/${TMPFILES_NAME}${N} for the log directory
      - ${M}/etc/logrotate.d/${LOGROTATE_NAME}${N}
    Run from a terminal without options to configure everything interactively.
    Existing files that change are backed up as ${M}<file>.bak.<timestamp>${N}.

${H}USAGE${N}
    ${SCRIPT_NAME} ${F}[OPTIONS]${N}

${H}MODE${N}
    ${F}--systemd${N}                 Install service, timer, tmpfiles and logrotate
    ${F}--script-only${N}             Install only the purge script
    ${F}--uninstall${N}               Remove everything installed (log directory is kept)
    ${F}-y, --yes${N}                 Non-interactive: use options and defaults, no prompts
    ${F}-i, --interactive${N}         Force prompts even when stdin is not a terminal
    ${F}-n, --dry-run${N}             Print generated files and commands, change nothing
    ${F}-h, --help${N}                Show this help and exit
    ${F}-V, --version${N}             Show version and exit

${H}PATHS${N}
    ${F}--bin-dir${N} ${M}DIR${N}             Script destination (default: ${M}${DEFAULT_BIN_DIR}${N})
    ${F}--data-dir${N} ${M}DIR${N}            ProxySQL log directory (default: ${M}${DEFAULT_DATA_DIR}${N})
    ${F}--log-dir${N} ${M}DIR${N}             Execution log directory (default: ${M}${DEFAULT_LOG_DIR}${N})
                              Log file: ${M}<log-dir>/${LOG_FILE_NAME}${N}
    ${F}--root${N} ${M}DIR${N}                Install under an alternate root (packaging, tests);
                              no systemctl/tmpfiles commands are executed

${H}SERVICE${N}
    ${F}--user${N} ${M}NAME${N}               Run the service as NAME (default: ${M}${DEFAULT_RUN_USER}${N})
    ${F}--schedule${N} ${M}SPEC${N}           systemd OnCalendar expression (default: ${M}${DEFAULT_SCHEDULE}${N})
    ${F}--no-enable${N}               Install the timer but do not enable/start it
    ${F}--accept-log-dir${N}          Confirm a --log-dir flagged by the review (non-interactive)
    ${F}--no-hardening${N}            Omit ProtectSystem=strict and related sandboxing
    ${F}--no-logrotate${N}            Do not install the logrotate policy
    ${F}--systemd-version${N} ${M}N${N}       Override detection; append: output needs >= ${MIN_SYSTEMD_APPEND}

${H}RETENTION${N}
    ${F}--events-prefix${N} ${M}NAME${N}      Events log prefix (default: ${M}${DEFAULT_EVENTS_PREFIX}${N})
    ${F}--events-keep${N} ${M}N${N}           Rotated events log files to keep (default: ${M}${DEFAULT_EVENTS_KEEP}${N})
    ${F}--events-max-age${N} ${M}DAYS${N}     Max age of events log files (default: ${M}${DEFAULT_EVENTS_MAX_AGE}${N}, 0 = off)
    ${F}--no-events${N}               Do not purge the events log
    ${F}--audit-prefix${N} ${M}NAME${N}       Audit log prefix (default: ${M}${DEFAULT_AUDIT_PREFIX}${N})
    ${F}--audit-keep${N} ${M}N${N}            Rotated audit log files to keep (default: ${M}${DEFAULT_AUDIT_KEEP}${N})
    ${F}--audit-max-age${N} ${M}DAYS${N}      Max age of audit log files (default: ${M}${DEFAULT_AUDIT_MAX_AGE}${N}, 0 = off)
    ${F}--no-audit${N}                Do not purge the audit log
    ${F}--no-compress${N}             Do not gzip the rotated files that are kept

${H}SAFETY${N}
    Requires root unless ${F}--root${N} or ${F}--dry-run${N} is used.
    The service ${R}deletes files permanently${N}; review the plan shown before applying.
    With hardening, only ${M}--data-dir${N} and ${M}--log-dir${N} are writable by the service.
    tmpfiles.d sets the mode/owner of ${M}--log-dir${N} and logrotate rotates its ${M}*.log${N}
    files. A system/shared directory or ${M}--data-dir${N} is shown for review and needs
    confirmation (prompt, or ${F}--accept-log-dir${N} with ${F}-y${N}).
    ${W}Paths and the schedule must not contain spaces or '%'.${N}

${H}EXAMPLES${N}
    ${C}# Interactive installation (asks for every setting)${N}
    ${X}sudo ./${SCRIPT_NAME}${N}

    ${C}# Preview everything that would be installed with the defaults${N}
    ${X}./${SCRIPT_NAME}${N} ${F}--systemd -y -n${N}

    ${C}# Non-interactive: daily at 00:00, root, custom log directory${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--systemd -y${N} ${F}--log-dir${N} ${M}/data/log/purge_proxysql_eventslog${N}

    ${C}# Every 6 hours, events log only, 7 days retention${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--systemd -y --no-audit${N} ${F}--events-max-age${N} ${M}7${N} ${F}--schedule${N} ${M}'*-*-* 00/6:00:00'${N}

    ${C}# Script only, into another directory${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--script-only -y${N} ${F}--bin-dir${N} ${M}/opt/dbre/bin${N}

    ${C}# Remove service, timer, tmpfiles, logrotate and script${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--uninstall -y${N}

${H}EXIT STATUS${N}
    ${F}0${N}  Success
    ${R}1${N}  Invalid option or value, missing privileges, or a failed installation step
EOF
}

# ---------------------------------------------------------------- validation

is_uint()    { [[ "$1" =~ ^[0-9]+$ ]]; }
is_abspath() { [[ "$1" == /* && "$1" != *[[:space:]%]* ]]; }
is_name()    { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_calendar() {
    [[ -n "$1" && "$1" != *%* ]] || return 1
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze calendar "$1" >/dev/null 2>&1
    fi
}
is_dedicated_dir() {
    local d="${1%/}" depth
    case "$d" in
        ""|/bin|/boot|/data|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/log|/var/lib|/var/tmp)
            return 1 ;;
        /etc/*|/usr/*|/proc/*|/sys/*|/dev/*|/boot/*|/bin/*|/sbin/*|/lib/*|/lib64/*)
            return 1 ;;
    esac
    depth="$(printf '%s' "$d" | tr -cd '/' | wc -c | tr -d ' ')"
    [[ "$depth" -ge 2 ]]
}
user_exists() { id -u "$1" >/dev/null 2>&1; }

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --systemd)          INSTALL_SYSTEMD=1; shift ;;
            --script-only)      INSTALL_SYSTEMD=0; shift ;;
            --uninstall)        UNINSTALL=1; shift ;;
            -y|--yes)           ASSUME_YES=1; shift ;;
            -i|--interactive)   INTERACTIVE=1; shift ;;
            -n|--dry-run)       DRY_RUN=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            --bin-dir)          need_value "$@"; BIN_DIR="$2"; shift 2 ;;
            --data-dir)         need_value "$@"; DATA_DIR="$2"; shift 2 ;;
            --log-dir)          need_value "$@"; LOG_DIR="$2"; shift 2 ;;
            --root)             need_value "$@"; ROOT_DIR="${2%/}"; shift 2 ;;
            --user)             need_value "$@"; RUN_USER="$2"; shift 2 ;;
            --schedule)         need_value "$@"; SCHEDULE="$2"; shift 2 ;;
            --no-enable)        ENABLE_TIMER=0; shift ;;
            --accept-log-dir)   ACCEPT_LOG_DIR=1; shift ;;
            --no-hardening)     HARDENING=0; shift ;;
            --no-logrotate)     LOGROTATE=0; shift ;;
            --systemd-version)  need_value "$@"; SYSTEMD_VERSION="$2"; shift 2 ;;
            --events-prefix)    need_value "$@"; EVENTS_PREFIX="$2"; shift 2 ;;
            --events-keep)      need_value "$@"; EVENTS_KEEP="$2"; shift 2 ;;
            --events-max-age)   need_value "$@"; EVENTS_MAX_AGE="$2"; shift 2 ;;
            --no-events)        EVENTS_ENABLED=0; shift ;;
            --audit-prefix)     need_value "$@"; AUDIT_PREFIX="$2"; shift 2 ;;
            --audit-keep)       need_value "$@"; AUDIT_KEEP="$2"; shift 2 ;;
            --audit-max-age)    need_value "$@"; AUDIT_MAX_AGE="$2"; shift 2 ;;
            --no-audit)         AUDIT_ENABLED=0; shift ;;
            --no-compress)      COMPRESS=0; shift ;;
            *)                  usage >&2; die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$INTERACTIVE" ]]; then
        if [[ "$ASSUME_YES" -eq 0 && -t 0 ]]; then INTERACTIVE=1; else INTERACTIVE=0; fi
    fi
}

validate_config() {
    local p
    for p in "$BIN_DIR" "$DATA_DIR" "$LOG_DIR"; do
        is_abspath "$p" || die "Invalid path (absolute, no spaces or '%'): ${p}"
    done
    [[ -z "$ROOT_DIR" ]] || is_abspath "$ROOT_DIR" || die "Invalid --root: ${ROOT_DIR}"
    [[ -z "$SYSTEMD_VERSION" ]] || is_uint "$SYSTEMD_VERSION" || die "--systemd-version must be an integer"
    [[ -f "${SOURCE_DIR}/${PURGE_NAME}" ]] || die "Source script not found: ${SOURCE_DIR}/${PURGE_NAME}"

    [[ "$INSTALL_SYSTEMD" == "1" ]] || return 0

    is_name "$EVENTS_PREFIX" || die "Invalid events prefix: ${EVENTS_PREFIX}"
    is_name "$AUDIT_PREFIX"  || die "Invalid audit prefix: ${AUDIT_PREFIX}"
    for p in "$EVENTS_KEEP" "$EVENTS_MAX_AGE" "$AUDIT_KEEP" "$AUDIT_MAX_AGE"; do
        is_uint "$p" || die "Retention values must be non-negative integers: ${p}"
    done
    [[ "$EVENTS_ENABLED" -eq 1 || "$AUDIT_ENABLED" -eq 1 ]] ||
        die "Nothing to schedule: both --no-events and --no-audit were given"
    [[ "$EVENTS_ENABLED" -eq 0 || "$AUDIT_ENABLED" -eq 0 || "$EVENTS_PREFIX" != "$AUDIT_PREFIX" ]] ||
        die "Events and audit prefixes must differ"
    is_calendar "$SCHEDULE" || die "Invalid OnCalendar expression: ${SCHEDULE}"
    is_name "$RUN_USER" || die "Invalid user name: ${RUN_USER}"
    if [[ -z "$ROOT_DIR" ]]; then
        user_exists "$RUN_USER" || die "User does not exist: ${RUN_USER}"
        RUN_GROUP="$(id -gn "$RUN_USER")"
    else
        RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
    fi
}

# ---------------------------------------------------------------- prompts

# ask VAR "Question" VALIDATOR
ask() {
    local __var=$1 __question=$2 __validator=$3 __default __answer
    __default="${!__var}"
    while true; do
        printf '%s?%s %s %s[%s]%s: ' "$CYAN" "$NC" "$__question" "$GRAY" "$__default" "$NC" >&2
        IFS= read -r __answer || die "Input closed while waiting for an answer"
        __answer="${__answer:-$__default}"
        if "$__validator" "$__answer"; then
            printf -v "$__var" '%s' "$__answer"
            return 0
        fi
        warn "Invalid value: ${__answer}"
    done
}

# ask_yn VAR "Question"   (VAR holds 1/0, used as default)
ask_yn() {
    local __var=$1 __question=$2 __hint __answer
    if [[ "${!__var}" == "1" ]]; then __hint="Y/n"; else __hint="y/N"; fi
    while true; do
        printf '%s?%s %s %s[%s]%s: ' "$CYAN" "$NC" "$__question" "$GRAY" "$__hint" "$NC" >&2
        IFS= read -r __answer || die "Input closed while waiting for an answer"
        case "$__answer" in
            "")          return 0 ;;
            [Yy]|[Yy][Ee][Ss]) printf -v "$__var" '1'; return 0 ;;
            [Nn]|[Nn][Oo])     printf -v "$__var" '0'; return 0 ;;
            *)           warn "Answer y or n" ;;
        esac
    done
}

any_value() { [[ -n "$1" ]]; }
valid_user() { is_name "$1" && { [[ -n "$ROOT_DIR" ]] || user_exists "$1"; }; }

interactive_config() {
    step "Configuration"
    ask BIN_DIR "Install ${PURGE_NAME} into" is_abspath

    if [[ -z "$INSTALL_SYSTEMD" ]]; then
        INSTALL_SYSTEMD=1
        [[ "$SYSTEMD_AVAILABLE" -eq 1 ]] || INSTALL_SYSTEMD=0
        ask_yn INSTALL_SYSTEMD "Install systemd service and timer"
    fi
    [[ "$INSTALL_SYSTEMD" == "1" ]] || return 0

    ask DATA_DIR "ProxySQL log directory (--data-dir)" is_abspath
    ask LOG_DIR  "Execution log directory" is_abspath
    ask RUN_USER "Run the service as user" valid_user
    ask SCHEDULE "Schedule (systemd OnCalendar)" is_calendar

    ask_yn EVENTS_ENABLED "Purge the events log"
    if [[ "$EVENTS_ENABLED" -eq 1 ]]; then
        ask EVENTS_PREFIX  "  Events log prefix" is_name
        ask EVENTS_KEEP    "  Rotated events log files to keep" is_uint
        ask EVENTS_MAX_AGE "  Max age in days (0 = off)" is_uint
    fi
    ask_yn AUDIT_ENABLED "Purge the audit log"
    if [[ "$AUDIT_ENABLED" -eq 1 ]]; then
        ask AUDIT_PREFIX  "  Audit log prefix" is_name
        ask AUDIT_KEEP    "  Rotated audit log files to keep" is_uint
        ask AUDIT_MAX_AGE "  Max age in days (0 = off)" is_uint
    fi

    ask_yn COMPRESS     "Compress kept rotated files (gzip)"
    ask_yn HARDENING    "Enable service hardening (ProtectSystem=strict)"
    ask_yn LOGROTATE    "Install logrotate policy for the execution log"
    ask_yn ENABLE_TIMER "Enable and start the timer now"
}

# ---------------------------------------------------------------- environment

SYSTEMD_AVAILABLE=0

detect_systemd() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        SYSTEMD_AVAILABLE=1
    fi
    if [[ -z "$SYSTEMD_VERSION" ]] && command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_VERSION="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
        is_uint "${SYSTEMD_VERSION:-x}" || SYSTEMD_VERSION=""
    fi
}

check_privileges() {
    [[ "$DRY_RUN" -eq 1 || -n "$ROOT_DIR" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "Root privileges required. Run with sudo, or use --dry-run / --root."
}

dest() { printf '%s%s' "$ROOT_DIR" "$1"; }

use_append() { [[ -n "$SYSTEMD_VERSION" && "$SYSTEMD_VERSION" -ge "$MIN_SYSTEMD_APPEND" ]]; }

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s[DRY-RUN]%s %s\n' "$YELLOW" "$NC" "$*" >&2
    else
        "$@"
    fi
}

# write_file DEST MODE < content
write_file() {
    local target=$1 mode=$2 tmp backup
    tmp="$(mktemp "${TMPDIR:-/tmp}/plr_install.XXXXXX")"
    cat >"$tmp"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s----- %s (mode %s) -----%s\n' "$GRAY" "$target" "$mode" "$NC" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    if [[ -f "$target" ]]; then
        if cmp -s "$tmp" "$target"; then
            rm -f "$tmp"
            ok "Unchanged ${target}"
            return 0
        fi
        backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$target" "$backup"
        warn "Backed up existing file to ${backup}"
    fi
    install -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    ok "Wrote ${target}"
}

# ---------------------------------------------------------------- renderers

purge_cmd() {
    local prefix=$1 keep=$2 age=$3 cmd
    cmd="${BIN_DIR}/${PURGE_NAME} -d ${DATA_DIR} -p ${prefix} -k ${keep} -a ${age}"
    [[ "$COMPRESS" -eq 0 ]] || cmd="${cmd} -c"
    printf '%s' "$cmd"
}

exec_lines() {
    local log_file="${LOG_DIR}/${LOG_FILE_NAME}" cmd
    local stamp='=== %%Y-%%m-%%d %%H:%%M:%%S run start ==='
    if use_append; then
        printf "ExecStartPre=/bin/date '+%s'\n" "$stamp"
    else
        printf "ExecStartPre=/bin/sh -c 'date \"+%s\" >>%s'\n" "$stamp" "$log_file"
    fi
    for cmd in events audit; do
        if [[ "$cmd" == events ]]; then
            [[ "$EVENTS_ENABLED" -eq 1 ]] || continue
            cmd="$(purge_cmd "$EVENTS_PREFIX" "$EVENTS_KEEP" "$EVENTS_MAX_AGE")"
        else
            [[ "$AUDIT_ENABLED" -eq 1 ]] || continue
            cmd="$(purge_cmd "$AUDIT_PREFIX" "$AUDIT_KEEP" "$AUDIT_MAX_AGE")"
        fi
        if use_append; then
            printf 'ExecStart=%s\n' "$cmd"
        else
            printf "ExecStart=/bin/sh -c 'exec %s >>%s 2>&1'\n" "$cmd" "$log_file"
        fi
    done
}

render_service() {
    cat <<EOF
# Generated by ${SCRIPT_NAME} v${VERSION} (fenicceTools proxysql/log_retention).
# Re-run the installer to change it; manual edits are backed up on reinstall.
[Unit]
Description=ProxySQL events and audit log retention
Documentation=https://github.com/Fenicce77/fenicceTools/tree/main/proxysql/log_retention
After=proxysql.service
RequiresMountsFor=${DATA_DIR} ${LOG_DIR}

[Service]
Type=oneshot
EOF
    if [[ "$RUN_USER" != "root" ]]; then
        printf 'User=%s\nGroup=%s\n' "$RUN_USER" "$RUN_GROUP"
    fi
    printf 'Nice=10\nIOSchedulingClass=idle\n'
    if use_append; then
        printf '\nStandardOutput=append:%s/%s\nStandardError=inherit\n' "$LOG_DIR" "$LOG_FILE_NAME"
    fi
    if [[ "$HARDENING" -eq 1 ]]; then
        cat <<EOF

ProtectSystem=strict
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF
    fi
    printf '\n'
    exec_lines
}

render_timer() {
    cat <<EOF
# Generated by ${SCRIPT_NAME} v${VERSION} (fenicceTools proxysql/log_retention).
[Unit]
Description=Run ProxySQL log retention (${SCHEDULE})

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

render_tmpfiles() {
    printf '# Generated by %s v%s\nd %s 0750 %s %s -\n' \
        "$SCRIPT_NAME" "$VERSION" "$LOG_DIR" "$RUN_USER" "$RUN_GROUP"
}

render_logrotate() {
    printf '# Generated by %s v%s\n%s/*.log {\n' "$SCRIPT_NAME" "$VERSION" "$LOG_DIR"
    [[ "$RUN_USER" == "root" ]] || printf '    su %s %s\n' "$RUN_USER" "$RUN_GROUP"
    cat <<EOF
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${RUN_USER} ${RUN_GROUP}
}
EOF
}

# ---------------------------------------------------------------- actions

# ---------------------------------------------------------------- log dir review

log_dir_concerns() {
    if [[ "${LOG_DIR%/}" == "${DATA_DIR%/}" ]]; then
        printf '%s\n' "It is the ProxySQL data directory (--data-dir): logrotate would also rotate ProxySQL's own *.log files (e.g. proxysql.log)."
    fi
    if ! is_dedicated_dir "$LOG_DIR"; then
        printf '%s\n' "It looks like a system or shared directory, not one dedicated to this tool."
    fi
}

show_log_dir_impact() {
    local dir count reason
    dir="$(dest "$LOG_DIR")"
    while IFS= read -r reason; do
        [[ -n "$reason" ]] && warn "$reason"
    done <<<"$1"
    printf '\n  %sImpact of using %s:%s\n' "$BOLD" "$LOG_DIR" "$NC" >&2
    printf '    - Mode 0750 and owner %s:%s are applied now and enforced at every boot (tmpfiles.d)\n' \
        "$RUN_USER" "$RUN_GROUP" >&2
    if [[ "$LOGROTATE" -eq 1 ]]; then
        printf '    - logrotate rotates every %s/*.log monthly and keeps 12 copies\n' "$LOG_DIR" >&2
    fi
    if [[ "$HARDENING" -eq 1 ]]; then
        printf '    - The service gets write access to the whole directory (ReadWritePaths=)\n' >&2
    fi
    if [[ -d "$dir" ]]; then
        printf '\n  %sCurrent state:%s\n' "$BOLD" "$NC" >&2
        printf '    %s\n' "$(ls -ld "$dir")" >&2
        count="$(find "$dir" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
        printf '    %s existing *.log file(s) would be managed by logrotate\n' "$count" >&2
        find "$dir" -maxdepth 1 -type f -name '*.log' 2>/dev/null | sort | head -n 10 |
            while IFS= read -r reason; do printf '      %s\n' "${reason##*/}" >&2; done
        [[ "$count" -le 10 ]] || printf '      ... and %s more\n' "$((count - 10))" >&2
    else
        printf '\n  The directory does not exist yet and will be created.\n' >&2
    fi
    printf '\n' >&2
}

review_log_dir() {
    local concerns accept
    [[ "$INSTALL_SYSTEMD" == "1" ]] || return 0
    while true; do
        concerns="$(log_dir_concerns)"
        [[ -n "$concerns" ]] || return 0

        step "Log directory review: ${LOG_DIR}"
        show_log_dir_impact "$concerns"

        if [[ "$ACCEPT_LOG_DIR" -eq 1 ]]; then
            warn "Log directory accepted with --accept-log-dir"
            return 0
        fi
        if [[ "$INTERACTIVE" -eq 1 ]]; then
            accept=0
            ask_yn accept "Use ${LOG_DIR} anyway"
            [[ "$accept" -eq 0 ]] || return 0
            ask LOG_DIR "Execution log directory" is_abspath
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "Dry-run continues; a real run needs confirmation or --accept-log-dir"
            return 0
        fi
        die "Review the impact above, then re-run with --accept-log-dir to confirm or choose another --log-dir"
    done
}

retention_line() {
    local enabled=$1 prefix=$2 keep=$3 age=$4
    if [[ "$enabled" -eq 1 ]]; then
        printf '%s (keep %s, max-age %sd)' "$prefix" "$keep" "$age"
    else
        printf 'disabled'
    fi
}

show_plan() {
    local yn
    step "Installation plan"
    printf '  %-22s %s\n' "Script:" "$(dest "${BIN_DIR}/${PURGE_NAME}")" >&2
    if [[ "$INSTALL_SYSTEMD" != "1" ]]; then
        printf '  %-22s %s\n' "systemd units:" "not installed" >&2
        return 0
    fi
    printf '  %-22s %s\n' "Service:" "$(dest "/etc/systemd/system/${UNIT_NAME}.service")" >&2
    printf '  %-22s %s\n' "Timer:" "$(dest "/etc/systemd/system/${UNIT_NAME}.timer")" >&2
    printf '  %-22s %s\n' "Schedule:" "$SCHEDULE" >&2
    printf '  %-22s %s:%s\n' "Run as:" "$RUN_USER" "$RUN_GROUP" >&2
    printf '  %-22s %s\n' "ProxySQL log dir:" "$DATA_DIR" >&2
    printf '  %-22s %s\n' "Execution log:" "${LOG_DIR}/${LOG_FILE_NAME}" >&2
    printf '  %-22s %s\n' "Events log:" "$(retention_line "$EVENTS_ENABLED" "$EVENTS_PREFIX" "$EVENTS_KEEP" "$EVENTS_MAX_AGE")" >&2
    printf '  %-22s %s\n' "Audit log:" "$(retention_line "$AUDIT_ENABLED" "$AUDIT_PREFIX" "$AUDIT_KEEP" "$AUDIT_MAX_AGE")" >&2
    if [[ "$COMPRESS" -eq 1 ]]; then yn=yes; else yn=no; fi
    printf '  %-22s %s\n' "Compress:" "$yn" >&2
    if [[ "$HARDENING" -eq 1 ]]; then yn=yes; else yn=no; fi
    printf '  %-22s %s\n' "Hardening:" "$yn" >&2
    if [[ "$LOGROTATE" -eq 1 ]]; then yn=yes; else yn=no; fi
    printf '  %-22s %s\n' "Logrotate:" "$yn" >&2
    if [[ "$ENABLE_TIMER" -eq 1 && -z "$ROOT_DIR" ]]; then yn=yes; else yn=no; fi
    printf '  %-22s %s\n' "Enable timer now:" "$yn" >&2
    if use_append; then
        printf '  %-22s %s\n' "Output mode:" "StandardOutput=append: (systemd ${SYSTEMD_VERSION})" >&2
    else
        printf '  %-22s %s\n' "Output mode:" "sh -c redirection (systemd ${SYSTEMD_VERSION:-unknown} < ${MIN_SYSTEMD_APPEND})" >&2
    fi
}

confirm() {
    local proceed=1
    [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 ]] || return 0
    printf '\n' >&2
    ask_yn proceed "Apply this configuration"
    [[ "$proceed" -eq 1 ]] || die "Aborted by user"
}

install_script() {
    step "Installing ${PURGE_NAME}"
    local target
    target="$(dest "${BIN_DIR}/${PURGE_NAME}")"
    run mkdir -p "$(dirname "$target")"
    run install -m 0755 "${SOURCE_DIR}/${PURGE_NAME}" "$target"
    [[ "$DRY_RUN" -eq 1 ]] || ok "Installed ${target}"
}

prepare_log_dir() {
    local dir file
    dir="$(dest "$LOG_DIR")"
    file="${dir}/${LOG_FILE_NAME}"
    run mkdir -p "$dir"
    run chmod 0750 "$dir"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        run touch "$file"
    elif [[ ! -e "$file" ]]; then
        : >"$file"
        chmod 0640 "$file"
    fi
    if [[ "$(id -u)" -eq 0 ]] && id -u "$RUN_USER" >/dev/null 2>&1; then
        run chown "${RUN_USER}:${RUN_GROUP}" "$dir" "$file"
    fi
}

install_systemd() {
    step "Installing systemd units"
    render_service   | write_file "$(dest "/etc/systemd/system/${UNIT_NAME}.service")" 0644
    render_timer     | write_file "$(dest "/etc/systemd/system/${UNIT_NAME}.timer")" 0644
    render_tmpfiles  | write_file "$(dest "/etc/tmpfiles.d/${TMPFILES_NAME}")" 0644
    if [[ "$LOGROTATE" -eq 1 ]]; then
        render_logrotate | write_file "$(dest "/etc/logrotate.d/${LOGROTATE_NAME}")" 0644
    fi
    prepare_log_dir

    if [[ -n "$ROOT_DIR" ]]; then
        info "Alternate root: systemctl and systemd-tmpfiles were not executed"
        return 0
    fi
    if [[ "$SYSTEMD_AVAILABLE" -ne 1 && "$DRY_RUN" -eq 0 ]]; then
        warn "systemd is not running on this host: units written but not activated"
        return 0
    fi

    run systemd-tmpfiles --create "/etc/tmpfiles.d/${TMPFILES_NAME}"
    run systemctl daemon-reload
    if [[ "$DRY_RUN" -eq 1 ]]; then
        run systemd-analyze verify "/etc/systemd/system/${UNIT_NAME}.service" "/etc/systemd/system/${UNIT_NAME}.timer"
    else
        systemd-analyze verify "/etc/systemd/system/${UNIT_NAME}.service" \
            "/etc/systemd/system/${UNIT_NAME}.timer" >/dev/null 2>&1 ||
            warn "systemd-analyze verify reported issues; review: systemd-analyze verify ${UNIT_NAME}.service"
    fi
    if [[ "$ENABLE_TIMER" -eq 1 ]]; then
        run systemctl enable --now "${UNIT_NAME}.timer"
        [[ "$DRY_RUN" -eq 1 ]] || ok "Timer enabled: ${UNIT_NAME}.timer"
    else
        info "Timer not enabled. Enable later with: systemctl enable --now ${UNIT_NAME}.timer"
    fi
}

offer_preview() {
    local preview=1 bin
    [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 && -z "$ROOT_DIR" && "$INSTALL_SYSTEMD" == "1" ]] || return 0
    [[ -d "$DATA_DIR" ]] || { warn "ProxySQL log directory not found yet: ${DATA_DIR}"; return 0; }
    printf '\n' >&2
    ask_yn preview "Run a dry-run of the retention now to preview its effect"
    [[ "$preview" -eq 1 ]] || return 0
    bin="${BIN_DIR}/${PURGE_NAME}"
    if [[ "$EVENTS_ENABLED" -eq 1 ]]; then
        "$bin" -d "$DATA_DIR" -p "$EVENTS_PREFIX" -k "$EVENTS_KEEP" -a "$EVENTS_MAX_AGE" -n || true
    fi
    if [[ "$AUDIT_ENABLED" -eq 1 ]]; then
        "$bin" -d "$DATA_DIR" -p "$AUDIT_PREFIX" -k "$AUDIT_KEEP" -a "$AUDIT_MAX_AGE" -n || true
    fi
}

show_next_steps() {
    step "Done"
    [[ "$DRY_RUN" -eq 0 ]] || { info "Dry-run: nothing was changed"; return 0; }
    printf '  Help:          %s --help\n' "$(dest "${BIN_DIR}/${PURGE_NAME}")" >&2
    [[ "$INSTALL_SYSTEMD" == "1" ]] || return 0
    cat >&2 <<EOF
  Run now:       systemctl start ${UNIT_NAME}.service
  Status:        systemctl status ${UNIT_NAME}.service --no-pager
  Next run:      systemctl list-timers ${UNIT_NAME}.timer
  Execution log: tail -n 50 ${LOG_DIR}/${LOG_FILE_NAME}
  Reconfigure:   re-run ${SCRIPT_NAME}
EOF
}

uninstall() {
    local f proceed=1
    step "Uninstall"
    if [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
        ask_yn proceed "Remove ${UNIT_NAME} units, tmpfiles, logrotate and ${PURGE_NAME}"
        [[ "$proceed" -eq 1 ]] || die "Aborted by user"
    fi
    if [[ -z "$ROOT_DIR" && "$SYSTEMD_AVAILABLE" -eq 1 ]]; then
        run systemctl disable --now "${UNIT_NAME}.timer" 2>/dev/null || true
    fi
    for f in \
        "/etc/systemd/system/${UNIT_NAME}.timer" \
        "/etc/systemd/system/${UNIT_NAME}.service" \
        "/etc/tmpfiles.d/${TMPFILES_NAME}" \
        "/etc/logrotate.d/${LOGROTATE_NAME}" \
        "${BIN_DIR}/${PURGE_NAME}"; do
        f="$(dest "$f")"
        if [[ -e "$f" ]]; then
            run rm -f -- "$f"
            [[ "$DRY_RUN" -eq 1 ]] || ok "Removed ${f}"
        fi
    done
    if [[ -z "$ROOT_DIR" && "$SYSTEMD_AVAILABLE" -eq 1 ]]; then
        run systemctl daemon-reload
    fi
    info "Execution logs were kept in ${LOG_DIR}"
}

main() {
    parse_args "$@"
    detect_systemd
    validate_config

    if [[ "$UNINSTALL" -eq 1 ]]; then
        check_privileges
        uninstall
        exit 0
    fi

    [[ "$INTERACTIVE" -eq 0 ]] || interactive_config
    [[ -n "$INSTALL_SYSTEMD" ]] || INSTALL_SYSTEMD=0
    validate_config

    if [[ "$INSTALL_SYSTEMD" == "1" && "$SYSTEMD_AVAILABLE" -ne 1 && -z "$ROOT_DIR" && "$DRY_RUN" -eq 0 ]]; then
        die "systemd is not running on this host. Use --script-only, or --root DIR to render the units."
    fi

    review_log_dir
    check_privileges
    [[ "$DRY_RUN" -eq 0 ]] || warn "Dry-run mode: no changes will be made"
    show_plan
    confirm
    install_script
    [[ "$INSTALL_SYSTEMD" != "1" ]] || install_systemd
    offer_preview
    show_next_steps
}

main "$@"
