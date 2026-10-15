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
readonly VERSION="1.1.1"

# Defaults
LOG_DIR="/data/proxysql"
PREFIX="query.log"
KEEP=10
MAX_AGE_DAYS=0
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
    cat <<EOF
${BOLD}${SCRIPT_NAME}${NC} v${VERSION}

Purge and/or compress rotated ProxySQL events log (query.log.NNNNNNNN) or
audit log (audit.log.NNNNNNNN) files. One prefix is processed per run.
The most recent file (the one ProxySQL is writing to) is always preserved.
Files currently opened by any process (checked via lsof, if available) are skipped.

${BOLD}USAGE${NC}
    ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${NC}
    -d, --dir DIR         Directory holding the events log files (default: ${LOG_DIR})
    -p, --prefix NAME     Log base name, as in mysql-eventslog_filename or
                          mysql-auditlog_filename (default: ${PREFIX})
    -k, --keep N          Number of rotated files to keep, active file excluded (default: ${KEEP})
    -a, --max-age DAYS    Also delete rotated files older than DAYS days (default: 0 = disabled)
    -c, --compress        gzip rotated files that are kept
    -n, --dry-run         Show what would be done without changing anything
    -h, --help            Show this help and exit
    -V, --version         Show version and exit

${BOLD}EXAMPLES${NC}
    # Preview: keep the last 20 rotated files
    ${SCRIPT_NAME} --keep 20 --dry-run

    # Keep max 20 rotated files, none older than 3 days, compress the survivors
    ${SCRIPT_NAME} -d /data/proxysql -k 20 -a 3 -c

    # Audit log: keep 30 days, compress everything rotated
    ${SCRIPT_NAME} -d /data/proxysql -p audit.log -k 1000 -a 30 -c

    # Cron (/etc/cron.d/proxysql-logs), every 30 minutes
    */30 * * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p query.log -k 20 -a 3 -c >/dev/null 2>&1
    */30 * * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p audit.log -k 1000 -a 30 -c >/dev/null 2>&1

    # Cron, once a day at 00:00
    0 0 * * * proxysql /usr/local/bin/${SCRIPT_NAME} -p query.log -k 200 -a 3 -c >>/var/log/proxysql/log_retention.log 2>&1

    # systemd timer, once a day at 00:00 (see README for the full unit files)
    OnCalendar=*-*-* 00:00:00
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
