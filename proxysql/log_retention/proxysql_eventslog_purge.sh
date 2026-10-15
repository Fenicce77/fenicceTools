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
# Compatible with Linux and macOS (bash >= 3.2).

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.2.0"

# Defaults (help always shows these, not values parsed so far)
readonly DEFAULT_LOG_DIR="/data/proxysql"
readonly DEFAULT_PREFIX="query.log"
readonly DEFAULT_KEEP=10
readonly DEFAULT_MAX_AGE_DAYS=0

LOG_DIR="$DEFAULT_LOG_DIR"
PREFIX="$DEFAULT_PREFIX"
KEEP="$DEFAULT_KEEP"
MAX_AGE_DAYS="$DEFAULT_MAX_AGE_DAYS"
COMPRESS=0
DRY_RUN=0

# Colors (only when stdout is a TTY)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

info()  { printf '%s[INFO]%s  %s\n' "$BLUE" "$NC" "$*"; }
ok()    { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

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
    audit log (${M}audit.log.NNNNNNNN${N}) files. One prefix is processed per run.

${H}USAGE${N}
    ${SCRIPT_NAME} ${F}[OPTIONS]${N}

${H}OPTIONS${N}
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
    ${F}-h, --help${N}            Show this help and exit
    ${F}-V, --version${N}         Show version and exit

${H}SAFETY${N}
    ${R}Deletion is permanent.${N} Run with ${F}--dry-run${N} first.
    The active file (highest numeric suffix) is ${W}never${N} deleted or compressed.
    Files still open by a process are skipped when ${M}lsof${N} is available.

${H}EXAMPLES${N}
    ${C}# Preview: keep the last 20 rotated files${N}
    ${X}${SCRIPT_NAME}${N} ${F}--keep${N} ${M}20${N} ${F}--dry-run${N}

    ${C}# Keep max 20 rotated files, none older than 3 days, compress the survivors${N}
    ${X}${SCRIPT_NAME}${N} ${F}-d${N} ${M}/data/proxysql${N} ${F}-k${N} ${M}20${N} ${F}-a${N} ${M}3${N} ${F}-c${N}

    ${C}# Audit log: keep 30 days, compress everything rotated${N}
    ${X}${SCRIPT_NAME}${N} ${F}-d${N} ${M}/data/proxysql${N} ${F}-p${N} ${M}audit.log${N} ${F}-k${N} ${M}1000${N} ${F}-a${N} ${M}30${N} ${F}-c${N}

    ${C}# Cron (/etc/cron.d/proxysql-logs), every 30 minutes${N}
    ${X}*/30 * * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p query.log -k 20 -a 3 -c >/dev/null 2>&1${N}
    ${X}*/30 * * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p audit.log -k 1000 -a 30 -c >/dev/null 2>&1${N}

    ${C}# Cron, once a day at 00:00${N}
    ${X}0 0 * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p query.log -k 200 -a 3 -c >>/var/log/proxysql/log_retention.log 2>&1${N}

    ${C}# systemd timer, once a day at 00:00 (see README for the full unit files)${N}
    ${X}OnCalendar=*-*-* 00:00:00${N}

${H}EXIT STATUS${N}
    ${F}0${N}  Success, including when no matching files exist
    ${R}1${N}  Invalid arguments, missing directory, or gzip not found with --compress
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)      [[ $# -ge 2 ]] || die "$1 requires a value"; LOG_DIR="$2"; shift 2 ;;
            -p|--prefix)   [[ $# -ge 2 ]] || die "$1 requires a value"; PREFIX="$2"; shift 2 ;;
            -k|--keep)     [[ $# -ge 2 ]] || die "$1 requires a value"; KEEP="$2"; shift 2 ;;
            -a|--max-age)  [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_AGE_DAYS="$2"; shift 2 ;;
            -c|--compress) COMPRESS=1; shift ;;
            -n|--dry-run)  DRY_RUN=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            -V|--version)  echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            *)             usage >&2; die "Unknown option: $1" ;;
        esac
    done

    is_uint "$KEEP"         || die "--keep must be a non-negative integer"
    is_uint "$MAX_AGE_DAYS" || die "--max-age must be a non-negative integer"
    [[ -d "$LOG_DIR" ]]     || die "Directory not found: ${LOG_DIR}"
    if [[ "$COMPRESS" -eq 1 ]] && ! command -v gzip >/dev/null 2>&1; then
        die "gzip not found in PATH"
    fi
}

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

main() {
    parse_args "$@"

    [[ "$DRY_RUN" -eq 1 ]] && warn "Dry-run mode: no changes will be made"
    info "Directory: ${LOG_DIR} | prefix: ${PREFIX} | keep: ${KEEP} | max-age: ${MAX_AGE_DAYS}d | compress: ${COMPRESS}"

    # Build list "<numeric_suffix> <path>", sorted oldest -> newest
    local files=() f base n
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

main "$@"
