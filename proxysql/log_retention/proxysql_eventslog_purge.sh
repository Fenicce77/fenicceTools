#!/usr/bin/env bash
#
# proxysql_eventslog_purge.sh
#
# Retention manager for ProxySQL events log files (mysql-eventslog_filename)
# and audit log files (mysql-auditlog_filename). ProxySQL rotates both by size
# (mysql-eventslog_filesize / mysql-auditlog_filesize) but never purges old
# files. This script enforces retention by count and/or age, optionally
# compresses rotated files, and never touches the active file.
#
# It can also install, list and remove named systemd rotations
# (proxysql-log-retention-<name>.service/.timer), so several ProxySQL
# instances or log types on the same host get their own schedule and log.
#
# Compatible with Linux and macOS (bash >= 3.2). Service management needs
# systemd (Linux), except --root/--dry-run which only render files.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.0.0"
readonly PURGE_NAME="proxysql_eventslog_purge.sh"
readonly SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly UNIT_PREFIX="proxysql-log-retention"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOGROTATE_DIR="/etc/logrotate.d"
readonly MIN_SYSTEMD_APPEND=240

# Defaults (help always shows these, not values parsed so far)
readonly DEFAULT_LOG_DIR="/data/proxysql"
readonly DEFAULT_PREFIX="query.log"
readonly DEFAULT_KEEP=10
readonly DEFAULT_MAX_AGE_DAYS=0
readonly DEFAULT_BIN_DIR="/usr/local/bin"
readonly DEFAULT_SERVICE_LOG_DIR="/data/log/purge_proxysql_eventslog"
readonly DEFAULT_SCHEDULE="*-*-* 00:00:00"
readonly DEFAULT_RUN_USER="root"

# Purge settings
LOG_DIR="$DEFAULT_LOG_DIR"
PREFIX="$DEFAULT_PREFIX"
KEEP="$DEFAULT_KEEP"
MAX_AGE_DAYS="$DEFAULT_MAX_AGE_DAYS"
COMPRESS=0
DRY_RUN=0

# Service management settings
ACTION="purge"              # purge | install | uninstall | list
ROTATION=""
BIN_DIR="$DEFAULT_BIN_DIR"
SERVICE_LOG_DIR="$DEFAULT_SERVICE_LOG_DIR"
SCHEDULE="$DEFAULT_SCHEDULE"
RUN_USER="$DEFAULT_RUN_USER"
RUN_GROUP=""
HARDENING=1
LOGROTATE=1
ENABLE_TIMER=1
ASSUME_YES=0
ROOT_DIR=""
SYSTEMD_VERSION=""
SYSTEMD_AVAILABLE=0

# Runtime colors (only when stdout is a TTY)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; GRAY=$'\033[0;90m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; GRAY=""; BOLD=""; NC=""
fi

info()  { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()    { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; }

usage() {
    # Help has its own palette: always colored (repository convention for
    # explicitly requested help), unless NO_COLOR is set (https://no-color.org).
    local T="" H="" F="" M="" C="" X="" W="" R="" N=""
    if [[ -z "${NO_COLOR:-}" ]]; then
        T=$'\033[1;36m'   # title: bold cyan
        H=$'\033[1;33m'   # section headers: bold yellow
        F=$'\033[0;32m'   # flags: green
        M=$'\033[0;36m'   # metavariables and defaults: cyan
        C=$'\033[0;90m'   # comments: gray
        X=$'\033[0;37m'   # example commands: white
        W=$'\033[0;33m'   # warnings: yellow
        R=$'\033[1;31m'   # destructive actions: bold red
        N=$'\033[0m'
    fi

    cat <<EOF
${T}${SCRIPT_NAME}${N} ${M}v${VERSION}${N}
ProxySQL events log and audit log retention

${H}DESCRIPTION${N}
    Purge and/or compress rotated ProxySQL events log (${M}query.log.NNNNNNNN${N}) or
    audit log (${M}audit.log.NNNNNNNN${N}) files. One directory + prefix per run.

    It also manages named systemd rotations: ${F}--install${N} ${M}NAME${N} creates
    ${M}${UNIT_PREFIX}-NAME.service${N} and ${M}.timer${N} that run this script with the
    purge options given on the same command line. Install one rotation per
    ProxySQL instance and log type (e.g. ${M}proxysql1-events${N}, ${M}proxysql1-audit${N}).

${H}USAGE${N}
    ${SCRIPT_NAME} ${F}[PURGE OPTIONS]${N}
    ${SCRIPT_NAME} ${F}--install${N} ${M}NAME${N} ${F}[PURGE OPTIONS] [SERVICE OPTIONS]${N}
    ${SCRIPT_NAME} ${F}--uninstall${N} ${M}NAME${N} ${F}[-y] [-n]${N}
    ${SCRIPT_NAME} ${F}--list${N}

${H}PURGE OPTIONS${N}
    ${F}-d, --dir${N} ${M}DIR${N}         Directory holding the log files
                          (default: ${M}${DEFAULT_LOG_DIR}${N})
    ${F}-p, --prefix${N} ${M}NAME${N}     Log base name, as in mysql-eventslog_filename or
                          mysql-auditlog_filename (default: ${M}${DEFAULT_PREFIX}${N})
    ${F}-k, --keep${N} ${M}N${N}          Rotated files to keep, active file excluded
                          (default: ${M}${DEFAULT_KEEP}${N})
    ${F}-a, --max-age${N} ${M}DAYS${N}    Also delete rotated files older than DAYS days
                          (default: ${M}${DEFAULT_MAX_AGE_DAYS}${N} = disabled)
    ${F}-c, --compress${N}        gzip rotated files that are kept
    ${F}-n, --dry-run${N}         Show what would be done without changing anything
                          (with --install/--uninstall: show the plan and files)
    ${F}-h, --help${N}            Show this help and exit
    ${F}-V, --version${N}         Show version and exit

${H}SERVICE MANAGEMENT${N}
    ${F}--install${N} ${M}NAME${N}        Install or update rotation NAME ([A-Za-z0-9_-], max 64)
    ${F}--uninstall${N} ${M}NAME${N}      Disable and remove rotation NAME (logs are kept)
    ${F}--list${N}                List installed rotations, schedule and next run

${H}SERVICE OPTIONS${N}
    ${F}--schedule${N} ${M}SPEC${N}       systemd OnCalendar expression (default: ${M}${DEFAULT_SCHEDULE}${N})
    ${F}--log-dir${N} ${M}DIR${N}         Execution log directory; log file is ${M}DIR/NAME.log${N}
                          (default: ${M}${DEFAULT_SERVICE_LOG_DIR}${N})
    ${F}--bin-dir${N} ${M}DIR${N}         Where this script is installed for the units
                          (default: ${M}${DEFAULT_BIN_DIR}${N})
    ${F}--user${N} ${M}NAME${N}           Run the service as NAME (default: ${M}${DEFAULT_RUN_USER}${N})
    ${F}--no-hardening${N}        Omit ProtectSystem=strict and related sandboxing
    ${F}--no-logrotate${N}        Do not install a logrotate policy for the execution log
    ${F}--no-enable${N}           Install the timer but do not enable/start it
    ${F}-y, --yes${N}             Apply without asking for confirmation
    ${F}--root${N} ${M}DIR${N}            Write under an alternate root (staging, packaging, tests);
                          no systemctl commands are executed
    ${F}--systemd-version${N} ${M}N${N}   Override detection; append: output needs >= ${MIN_SYSTEMD_APPEND}

${H}SAFETY${N}
    ${R}Deletion is permanent.${N} Run with ${F}--dry-run${N} first.
    The active file (highest numeric suffix) is ${W}never${N} deleted or compressed.
    Files still open by a process are skipped when ${M}lsof${N} is available.
    ${F}--install${N}/${F}--uninstall${N} show the plan and the generated files and ask for
    confirmation (${F}-y${N} skips it). Two rotations cannot manage the same dir + prefix.

${H}EXAMPLES${N}
    ${C}# Preview: keep the last 20 rotated files${N}
    ${X}${SCRIPT_NAME}${N} ${F}--keep${N} ${M}20${N} ${F}--dry-run${N}

    ${C}# Keep max 20 rotated files, none older than 3 days, compress the survivors${N}
    ${X}${SCRIPT_NAME}${N} ${F}-d${N} ${M}/data/proxysql${N} ${F}-k${N} ${M}20${N} ${F}-a${N} ${M}3${N} ${F}-c${N}

    ${C}# Audit log: keep 30 days, compress everything rotated${N}
    ${X}${SCRIPT_NAME}${N} ${F}-d${N} ${M}/data/proxysql${N} ${F}-p${N} ${M}audit.log${N} ${F}-k${N} ${M}1000${N} ${F}-a${N} ${M}30${N} ${F}-c${N}

    ${C}# Daily 00:00 rotations for two ProxySQL instances on the same host${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--install${N} ${M}proxysql1-events${N} ${F}-d${N} ${M}/data/proxysql1${N} ${F}-p${N} ${M}query.log${N} ${F}-k${N} ${M}200${N} ${F}-a${N} ${M}3${N} ${F}-c${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--install${N} ${M}proxysql1-audit${N}  ${F}-d${N} ${M}/data/proxysql1${N} ${F}-p${N} ${M}audit.log${N} ${F}-k${N} ${M}1000${N} ${F}-a${N} ${M}30${N} ${F}-c${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--install${N} ${M}proxysql2-events${N} ${F}-d${N} ${M}/data/proxysql2${N} ${F}-p${N} ${M}query.log${N} ${F}-k${N} ${M}100${N} ${F}-a${N} ${M}2${N} ${F}-c${N} ${F}--schedule${N} ${M}'*-*-* 00/6:00:00'${N}

    ${C}# Preview an installation without changing anything${N}
    ${X}./${SCRIPT_NAME}${N} ${F}--install${N} ${M}proxysql1-events${N} ${F}-d${N} ${M}/data/proxysql1${N} ${F}-k${N} ${M}200${N} ${F}-c${N} ${F}--dry-run${N}

    ${C}# Show installed rotations, remove one${N}
    ${X}${SCRIPT_NAME}${N} ${F}--list${N}
    ${X}sudo ./${SCRIPT_NAME}${N} ${F}--uninstall${N} ${M}proxysql2-events${N}

    ${C}# Cron alternative, once a day at 00:00${N}
    ${X}0 0 * * * root /usr/local/bin/${PURGE_NAME} -d /data/proxysql -p query.log -k 200 -a 3 -c >>/data/log/purge_proxysql_eventslog/cron.log 2>&1${N}

${H}EXIT STATUS${N}
    ${F}0${N}  Success, including when no matching files exist
    ${R}1${N}  Invalid arguments, missing directory or privileges, gzip not found with
       --compress, conflicting rotation, or confirmation declined
EOF
}

# ---------------------------------------------------------------- validation

is_uint()     { [[ "$1" =~ ^[0-9]+$ ]]; }
is_abspath()  { [[ "$1" == /* && "$1" != *[[:space:]%]* ]]; }
is_prefix()   { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_rotation() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
is_username() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_calendar() {
    [[ -n "$1" && "$1" != *%* && "$1" != *$'\n'* ]] || return 1
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze calendar "$1" >/dev/null 2>&1
    fi
}

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"; }

set_action() {
    [[ "$ACTION" == "purge" || "$ACTION" == "$1" ]] ||
        die "--install, --uninstall and --list are mutually exclusive"
    ACTION="$1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)          need_value "$@"; LOG_DIR="$2"; shift 2 ;;
            -p|--prefix)       need_value "$@"; PREFIX="$2"; shift 2 ;;
            -k|--keep)         need_value "$@"; KEEP="$2"; shift 2 ;;
            -a|--max-age)      need_value "$@"; MAX_AGE_DAYS="$2"; shift 2 ;;
            -c|--compress)     COMPRESS=1; shift ;;
            -n|--dry-run)      DRY_RUN=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            -V|--version)      echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            --install)         need_value "$@"; set_action install; ROTATION="$2"; shift 2 ;;
            --uninstall)       need_value "$@"; set_action uninstall; ROTATION="$2"; shift 2 ;;
            --list)            set_action list; shift ;;
            --schedule)        need_value "$@"; SCHEDULE="$2"; shift 2 ;;
            --log-dir)         need_value "$@"; SERVICE_LOG_DIR="$2"; shift 2 ;;
            --bin-dir)         need_value "$@"; BIN_DIR="$2"; shift 2 ;;
            --user)            need_value "$@"; RUN_USER="$2"; shift 2 ;;
            --no-hardening)    HARDENING=0; shift ;;
            --no-logrotate)    LOGROTATE=0; shift ;;
            --no-enable)       ENABLE_TIMER=0; shift ;;
            -y|--yes)          ASSUME_YES=1; shift ;;
            --root)            need_value "$@"; ROOT_DIR="${2%/}"; shift 2 ;;
            --systemd-version) need_value "$@"; SYSTEMD_VERSION="$2"; shift 2 ;;
            *)                 usage >&2; die "Unknown option: $1" ;;
        esac
    done

    # Normalize trailing slashes so units, metadata and conflict checks match
    [[ "$LOG_DIR" == "/" ]] || LOG_DIR="${LOG_DIR%/}"
    [[ "$SERVICE_LOG_DIR" == "/" ]] || SERVICE_LOG_DIR="${SERVICE_LOG_DIR%/}"
    [[ "$BIN_DIR" == "/" ]] || BIN_DIR="${BIN_DIR%/}"

    is_uint "$KEEP"         || die "--keep must be a non-negative integer"
    is_uint "$MAX_AGE_DAYS" || die "--max-age must be a non-negative integer"

    case "$ACTION" in
        purge)
            [[ -d "$LOG_DIR" ]] || die "Directory not found: ${LOG_DIR}"
            if [[ "$COMPRESS" -eq 1 ]] && ! command -v gzip >/dev/null 2>&1; then
                die "gzip not found in PATH"
            fi
            ;;
        install)
            is_rotation "$ROTATION"       || die "Invalid rotation name (use [A-Za-z0-9_-], max 64): ${ROTATION}"
            is_abspath "$LOG_DIR"         || die "--dir must be an absolute path without spaces or '%': ${LOG_DIR}"
            is_prefix "$PREFIX"           || die "Invalid --prefix: ${PREFIX}"
            is_abspath "$SERVICE_LOG_DIR" || die "--log-dir must be an absolute path without spaces or '%': ${SERVICE_LOG_DIR}"
            is_abspath "$BIN_DIR"         || die "--bin-dir must be an absolute path without spaces or '%': ${BIN_DIR}"
            is_calendar "$SCHEDULE"       || die "Invalid OnCalendar expression: ${SCHEDULE}"
            is_username "$RUN_USER"       || die "Invalid --user: ${RUN_USER}"
            ;;
        uninstall)
            is_rotation "$ROTATION" || die "Invalid rotation name: ${ROTATION}"
            ;;
    esac
    [[ -z "$ROOT_DIR" ]] || is_abspath "$ROOT_DIR" || die "Invalid --root: ${ROOT_DIR}"
    [[ -z "$SYSTEMD_VERSION" ]] || is_uint "$SYSTEMD_VERSION" || die "--systemd-version must be an integer"
}

# ---------------------------------------------------------------- purge

# Size of a file in KB (portable: du -k works on GNU and BSD)
size_kb() { du -k "$1" 2>/dev/null | awk '{print $1}'; }

human_kb() {
    awk -v kb="$1" 'BEGIN {
        split("KB MB GB TB", u); i = 1
        while (kb >= 1024 && i < 4) { kb /= 1024; i++ }
        printf "%.2f %s", kb, u[i]
    }'
}

is_open() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -t -- "$1" >/dev/null 2>&1
}

older_than_days() {
    [[ -n "$(find "$1" -maxdepth 0 -mtime +"$2" -print 2>/dev/null)" ]]
}

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s[DRY-RUN]%s %s\n' "$YELLOW" "$NC" "$*"
    else
        "$@"
    fi
}

purge() {
    [[ "$DRY_RUN" -eq 1 ]] && warn "Dry-run mode: no changes will be made"
    info "Directory: ${LOG_DIR} | prefix: ${PREFIX} | keep: ${KEEP} | max-age: ${MAX_AGE_DAYS}d | compress: ${COMPRESS}"

    # Build list "<numeric_suffix> <path>", sorted oldest -> newest
    local files=() f base n line
    while IFS= read -r line; do
        files+=("${line#* }")
    done < <(
        for f in "${LOG_DIR}/${PREFIX}".[0-9]*; do
            [[ -f "$f" ]] || continue
            base="${f##*/}"
            n="${base#"${PREFIX}".}"
            n="${n%.gz}"
            is_uint "$n" || continue
            printf '%s %s\n' "$((10#$n))" "$f"
        done | sort -n -k1,1
    )

    local total=${#files[@]}
    if [[ "$total" -eq 0 ]]; then
        warn "No files matching ${LOG_DIR}/${PREFIX}.NNNNNNNN found"
        exit 0
    fi

    local active="${files[$((total - 1))]}"
    info "Found ${total} file(s). Active (protected): ${active##*/}"

    local rotated=$((total - 1))
    local to_drop_by_count=0
    [[ "$rotated" -gt "$KEEP" ]] && to_drop_by_count=$((rotated - KEEP))

    local freed_kb=0 deleted=0 compressed=0 skipped=0 i kb
    for ((i = 0; i < rotated; i++)); do
        f="${files[$i]}"

        if is_open "$f"; then
            warn "Skipping (open by a process): ${f##*/}"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$i" -lt "$to_drop_by_count" ]] || \
           { [[ "$MAX_AGE_DAYS" -gt 0 ]] && older_than_days "$f" "$MAX_AGE_DAYS"; }; then
            kb="$(size_kb "$f")"
            run rm -f -- "$f"
            freed_kb=$((freed_kb + kb))
            deleted=$((deleted + 1))
            ok "Deleted ${f##*/} ($(human_kb "$kb"))"
            continue
        fi

        if [[ "$COMPRESS" -eq 1 && "$f" != *.gz ]]; then
            kb="$(size_kb "$f")"
            run gzip -f -- "$f"
            if [[ "$DRY_RUN" -eq 0 && -f "${f}.gz" ]]; then
                freed_kb=$((freed_kb + kb - $(size_kb "${f}.gz")))
            fi
            compressed=$((compressed + 1))
            ok "Compressed ${f##*/}"
        fi
    done

    printf '\n%sSummary%s: deleted=%d compressed=%d skipped=%d freed=%s%s\n' \
        "$BOLD" "$NC" "$deleted" "$compressed" "$skipped" "$(human_kb "$freed_kb")" \
        "$([[ "$DRY_RUN" -eq 1 ]] && echo ' (estimated, compression not included)')"
}

# ---------------------------------------------------------------- service helpers

dest()         { printf '%s%s' "$ROOT_DIR" "$1"; }
unit_base()    { printf '%s-%s' "$UNIT_PREFIX" "$1"; }
service_path() { dest "${SYSTEMD_DIR}/$(unit_base "$1").service"; }
timer_path()   { dest "${SYSTEMD_DIR}/$(unit_base "$1").timer"; }
rotate_path()  { dest "${LOGROTATE_DIR}/$(unit_base "$1")"; }
exec_log()     { printf '%s/%s.log' "$SERVICE_LOG_DIR" "$ROTATION"; }
use_append()   { [[ -n "$SYSTEMD_VERSION" && "$SYSTEMD_VERSION" -ge "$MIN_SYSTEMD_APPEND" ]]; }
on_host()      { [[ -z "$ROOT_DIR" ]]; }

detect_systemd() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        SYSTEMD_AVAILABLE=1
    fi
    if [[ -z "$SYSTEMD_VERSION" ]] && command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_VERSION="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
        is_uint "${SYSTEMD_VERSION:-x}" || SYSTEMD_VERSION=""
    fi
}

# Activation (systemctl) only happens on a live systemd host, never with
# --root or --dry-run.
can_activate() { on_host && [[ "$DRY_RUN" -eq 0 && "$SYSTEMD_AVAILABLE" -eq 1 ]]; }

check_service_env() {
    if on_host && [[ "$DRY_RUN" -eq 0 ]]; then
        [[ "$(id -u)" -eq 0 ]] || die "Root privileges required. Run with sudo, or use --dry-run / --root."
        [[ "$SYSTEMD_AVAILABLE" -eq 1 ]] ||
            die "systemd is not running on this host. Use cron, or --root DIR to render the units."
    fi
}

# meta_get FILE KEY -> value of "# plr.KEY=value" in a generated service
meta_get() {
    sed -n "s/^# plr\\.$2=//p" "$1" 2>/dev/null | head -n 1
}

installed_rotations() {
    local f name
    for f in "$(dest "$SYSTEMD_DIR")/${UNIT_PREFIX}-"*.service; do
        [[ -f "$f" ]] || continue
        name="$(meta_get "$f" name)"
        [[ -n "$name" ]] && printf '%s\n' "$name"
    done
}

confirm() {
    local question=$1 answer
    [[ "$ASSUME_YES" -eq 0 && "$DRY_RUN" -eq 0 ]] || return 0
    [[ -t 0 ]] || die "Confirmation required but stdin is not a terminal: re-run with -y"
    printf '\n%s?%s %s %s[y/N]%s: ' "$BLUE" "$NC" "$question" "$GRAY" "$NC"
    IFS= read -r answer || answer=""
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) die "Aborted: nothing was changed" ;;
    esac
}

# write_file DEST MODE < content
write_file() {
    local target=$1 mode=$2 tmp backup
    tmp="$(mktemp "${TMPDIR:-/tmp}/plr.XXXXXX")"
    cat >"$tmp"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        rm -f "$tmp"
        printf '%s[DRY-RUN]%s write %s\n' "$YELLOW" "$NC" "$target"
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
        warn "Backed up previous version to ${backup}"
    fi
    install -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    ok "Wrote ${target}"
}

show_file() {
    local title=$1
    printf '\n%s----- %s -----%s\n' "$GRAY" "$title" "$NC"
    cat
}

# ---------------------------------------------------------------- renderers

purge_cmd() {
    local cmd="${BIN_DIR}/${PURGE_NAME} -d ${LOG_DIR} -p ${PREFIX} -k ${KEEP} -a ${MAX_AGE_DAYS}"
    [[ "$COMPRESS" -eq 0 ]] || cmd="${cmd} -c"
    printf '%s' "$cmd"
}

render_service() {
    local log stamp='=== %%Y-%%m-%%d %%H:%%M:%%S run start ==='
    log="$(exec_log)"
    cat <<EOF
# Generated by ${PURGE_NAME} v${VERSION} --install ${ROTATION}
# Manage with: ${PURGE_NAME} --install/--uninstall/--list (manual edits are backed up on reinstall)
# plr.name=${ROTATION}
# plr.dir=${LOG_DIR}
# plr.prefix=${PREFIX}
# plr.keep=${KEEP}
# plr.max_age=${MAX_AGE_DAYS}
# plr.compress=${COMPRESS}
# plr.schedule=${SCHEDULE}
# plr.log=${log}
# plr.user=${RUN_USER}
[Unit]
Description=ProxySQL log retention ${ROTATION} (${LOG_DIR}/${PREFIX})
Documentation=https://github.com/Fenicce77/fenicceTools/tree/main/proxysql/log_retention
After=proxysql.service
RequiresMountsFor=${LOG_DIR} ${SERVICE_LOG_DIR}

[Service]
Type=oneshot
EOF
    if [[ "$RUN_USER" != "root" ]]; then
        printf 'User=%s\nGroup=%s\n' "$RUN_USER" "$RUN_GROUP"
    fi
    printf 'Nice=10\nIOSchedulingClass=idle\n'
    if use_append; then
        printf '\nStandardOutput=append:%s\nStandardError=inherit\n' "$log"
    fi
    if [[ "$HARDENING" -eq 1 ]]; then
        cat <<EOF

ProtectSystem=strict
ReadWritePaths=${LOG_DIR} ${SERVICE_LOG_DIR}
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF
    fi
    printf '\n'
    if use_append; then
        printf "ExecStartPre=/bin/date '+%s'\n" "$stamp"
        printf 'ExecStart=%s\n' "$(purge_cmd)"
    else
        printf "ExecStartPre=/bin/sh -c 'date \"+%s\" >>%s'\n" "$stamp" "$log"
        printf "ExecStart=/bin/sh -c 'exec %s >>%s 2>&1'\n" "$(purge_cmd)" "$log"
    fi
}

render_timer() {
    cat <<EOF
# Generated by ${PURGE_NAME} v${VERSION} --install ${ROTATION}
[Unit]
Description=Schedule for ProxySQL log retention ${ROTATION}

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

render_logrotate() {
    printf '# Generated by %s v%s --install %s\n%s {\n' \
        "$PURGE_NAME" "$VERSION" "$ROTATION" "$(exec_log)"
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

# ---------------------------------------------------------------- install

check_conflicts() {
    local name f dir prefix
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$ROTATION" ]] || continue
        f="$(service_path "$name")"
        dir="$(meta_get "$f" dir)"
        prefix="$(meta_get "$f" prefix)"
        if [[ "${dir%/}" == "${LOG_DIR%/}" && "$prefix" == "$PREFIX" ]]; then
            die "Rotation '${name}' already manages ${LOG_DIR}/${PREFIX}. Update it with --install ${name}, or remove it first."
        fi
    done < <(installed_rotations)
}

resolve_group() {
    if on_host; then
        id -u "$RUN_USER" >/dev/null 2>&1 || die "User does not exist: ${RUN_USER}"
        RUN_GROUP="$(id -gn "$RUN_USER")"
    else
        RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
    fi
}

script_action() {
    local target
    target="$(dest "${BIN_DIR}/${PURGE_NAME}")"
    if [[ ! -f "$target" ]]; then
        printf 'install'
    elif cmp -s "$SELF_PATH" "$target"; then
        printf 'unchanged'
    else
        printf 'update'
    fi
}

yes_no() { if [[ "$1" -eq 1 ]]; then printf 'yes'; else printf 'no'; fi; }

show_install_plan() {
    local state="new" mode
    [[ ! -f "$(service_path "$ROTATION")" ]] || state="update existing"
    if use_append; then
        mode="StandardOutput=append: (systemd ${SYSTEMD_VERSION})"
    else
        mode="sh -c redirection (systemd ${SYSTEMD_VERSION:-unknown} < ${MIN_SYSTEMD_APPEND})"
    fi

    step "Install rotation '${ROTATION}' (${state})"
    printf '  %-18s %s/%s.NNNNNNNN\n' "Log files:" "$LOG_DIR" "$PREFIX"
    printf '  %-18s keep %s, max-age %sd, compress %s\n' "Retention:" "$KEEP" "$MAX_AGE_DAYS" "$(yes_no "$COMPRESS")"
    printf '  %-18s %s\n' "Schedule:" "$SCHEDULE"
    printf '  %-18s %s:%s\n' "Run as:" "$RUN_USER" "$RUN_GROUP"
    printf '  %-18s %s\n' "Execution log:" "$(exec_log)"
    printf '  %-18s %s (%s)\n' "Script:" "${BIN_DIR}/${PURGE_NAME}" "$(script_action)"
    printf '  %-18s %s\n' "Service:" "$(service_path "$ROTATION")"
    printf '  %-18s %s\n' "Timer:" "$(timer_path "$ROTATION")"
    if [[ "$LOGROTATE" -eq 1 ]]; then
        printf '  %-18s %s\n' "Logrotate:" "$(rotate_path "$ROTATION")"
    fi
    printf '  %-18s %s\n' "Hardening:" "$(yes_no "$HARDENING")"
    printf '  %-18s %s\n' "Output mode:" "$mode"
    printf '  %-18s %s\n' "Enable timer:" "$(yes_no "$ENABLE_TIMER")"

    if on_host && [[ ! -d "$LOG_DIR" ]]; then
        warn "Log directory not found on this host: ${LOG_DIR}"
    fi
    if on_host && [[ "$COMPRESS" -eq 1 ]] && ! command -v gzip >/dev/null 2>&1; then
        warn "gzip not found in PATH: the service will fail with -c"
    fi

    render_service | show_file "$(service_path "$ROTATION")"
    render_timer   | show_file "$(timer_path "$ROTATION")"
    if [[ "$LOGROTATE" -eq 1 ]]; then
        render_logrotate | show_file "$(rotate_path "$ROTATION")"
    fi
}

install_self() {
    local target action
    target="$(dest "${BIN_DIR}/${PURGE_NAME}")"
    action="$(script_action)"
    [[ "$action" != "unchanged" ]] || { ok "Script unchanged ${target}"; return 0; }
    run mkdir -p "$(dirname "$target")"
    run install -m 0755 "$SELF_PATH" "$target"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ "$action" == "install" ]]; then ok "Script installed: ${target}"; else ok "Script updated: ${target}"; fi
    fi
}

prepare_exec_log() {
    local dir file
    dir="$(dest "$SERVICE_LOG_DIR")"
    file="$(dest "$(exec_log)")"
    if [[ ! -d "$dir" ]]; then
        run mkdir -p "$dir"
        run chmod 0750 "$dir"
        if [[ "$(id -u)" -eq 0 ]] && id -u "$RUN_USER" >/dev/null 2>&1; then
            run chown "${RUN_USER}:${RUN_GROUP}" "$dir"
        fi
    fi
    if [[ ! -e "$file" ]]; then
        run touch "$file"
        run chmod 0640 "$file"
        if [[ "$(id -u)" -eq 0 ]] && id -u "$RUN_USER" >/dev/null 2>&1; then
            run chown "${RUN_USER}:${RUN_GROUP}" "$file"
        fi
    fi
}

install_rotation() {
    local timer
    resolve_group
    check_conflicts
    show_install_plan
    confirm "Install rotation '${ROTATION}'"

    step "Applying"
    install_self
    prepare_exec_log
    render_service | write_file "$(service_path "$ROTATION")" 0644
    render_timer   | write_file "$(timer_path "$ROTATION")" 0644
    if [[ "$LOGROTATE" -eq 1 ]]; then
        render_logrotate | write_file "$(rotate_path "$ROTATION")" 0644
    elif [[ -f "$(rotate_path "$ROTATION")" ]]; then
        run rm -f -- "$(rotate_path "$ROTATION")"
    fi

    timer="$(unit_base "$ROTATION").timer"
    if ! can_activate; then
        [[ "$DRY_RUN" -eq 1 ]] && info "Dry-run: nothing was changed"
        on_host || info "Alternate root: systemctl was not executed"
        return 0
    fi

    systemctl daemon-reload
    systemd-analyze verify "$(service_path "$ROTATION")" "$(timer_path "$ROTATION")" >/dev/null 2>&1 ||
        warn "systemd-analyze verify reported issues: systemd-analyze verify $(unit_base "$ROTATION").service"
    if [[ "$ENABLE_TIMER" -eq 1 ]]; then
        systemctl enable "$timer" >/dev/null 2>&1
        systemctl restart "$timer"
        ok "Timer enabled: ${timer}"
    else
        info "Timer not enabled. Enable later with: systemctl enable --now ${timer}"
    fi

    step "Next steps"
    cat <<EOF
  Run now:       systemctl start $(unit_base "$ROTATION").service
  Status:        systemctl status $(unit_base "$ROTATION").service --no-pager
  Next run:      systemctl list-timers ${timer}
  Execution log: tail -n 50 $(exec_log)
  All rotations: ${PURGE_NAME} --list
EOF
}

# ---------------------------------------------------------------- uninstall / list

uninstall_rotation() {
    local f found=0 timer
    timer="$(unit_base "$ROTATION").timer"
    step "Uninstall rotation '${ROTATION}'"
    for f in "$(timer_path "$ROTATION")" "$(service_path "$ROTATION")" "$(rotate_path "$ROTATION")"; do
        if [[ -e "$f" ]]; then
            printf '  remove %s\n' "$f"
            found=1
        fi
    done
    [[ "$found" -eq 1 ]] || die "No rotation named '${ROTATION}' is installed (see --list)"
    printf '  %sKept:%s execution log and %s\n' "$GRAY" "$NC" "${PURGE_NAME}"
    confirm "Remove rotation '${ROTATION}'"

    if can_activate; then
        systemctl disable --now "$timer" >/dev/null 2>&1 || true
    fi
    for f in "$(timer_path "$ROTATION")" "$(service_path "$ROTATION")" "$(rotate_path "$ROTATION")"; do
        if [[ -e "$f" ]]; then
            run rm -f -- "$f"
            [[ "$DRY_RUN" -eq 1 ]] || ok "Removed ${f}"
        fi
    done
    if can_activate; then
        systemctl daemon-reload
        systemctl reset-failed "$(unit_base "$ROTATION").service" >/dev/null 2>&1 || true
    fi
}

list_rotations() {
    local name f state next count=0 fmt='%-20s %-24s %-11s %6s %6s %-4s %-18s %-9s %s\n'
    printf "${BOLD}${fmt}${NC}" NAME DIR PREFIX KEEP AGE GZ SCHEDULE TIMER "NEXT RUN"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        f="$(service_path "$name")"
        state="-"; next="-"
        if on_host && [[ "$SYSTEMD_AVAILABLE" -eq 1 ]]; then
            state="$(systemctl is-active "$(unit_base "$name").timer" 2>/dev/null || true)"
            next="$(systemctl show "$(unit_base "$name").timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
            [[ -n "$next" ]] || next="-"
        fi
        printf "$fmt" "$name" "$(meta_get "$f" dir)" "$(meta_get "$f" prefix)" \
            "$(meta_get "$f" keep)" "$(meta_get "$f" max_age)d" \
            "$(yes_no "$(meta_get "$f" compress)")" "$(meta_get "$f" schedule)" "$state" "$next"
        count=$((count + 1))
    done < <(installed_rotations)
    [[ "$count" -gt 0 ]] || info "No rotations installed. Create one with --install NAME"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        purge)
            purge
            ;;
        install)
            detect_systemd
            check_service_env
            [[ "$DRY_RUN" -eq 0 ]] || warn "Dry-run mode: no changes will be made"
            install_rotation
            ;;
        uninstall)
            detect_systemd
            check_service_env
            [[ "$DRY_RUN" -eq 0 ]] || warn "Dry-run mode: no changes will be made"
            uninstall_rotation
            ;;
        list)
            detect_systemd
            list_rotations
            ;;
    esac
}

main "$@"
