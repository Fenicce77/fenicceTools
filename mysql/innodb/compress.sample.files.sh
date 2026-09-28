#!/usr/bin/env bash
set -euo pipefail

PROGRAM=$(basename "$0")
CONFIG_FILE=''
APPLY=false
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''

init_colors() {
    if [ -t 1 ] && [ "${TERM:-}" != dumb ]; then
        RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
        CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    fi
}

help() {
    printf '%s%s%s\n\n' "$CYAN$BOLD" 'Compress InnoDB status sample directories safely.' "$NC"
    printf 'Usage: %s --config FILE [--dry-run|--apply] [--no-color]\n\n' "$PROGRAM"
    cat <<'EOF'
Options:
  -c, --config FILE  Configuration with logdir, dailytocompressret, and toremovalretention.
      --dry-run      Print planned compression and removal actions (default).
      --apply        Perform the planned actions.
      --no-color     Disable ANSI colors.
  -h, --help         Show this help.

Examples:
  compress.sample.files.sh --config /etc/innodb/compress.cnf
  compress.sample.files.sh --config /etc/innodb/compress.cnf --apply
EOF
}

fail() { printf '%sERROR:%s %s\n\n' "$RED$BOLD" "$NC" "$1" >&2; help >&2; exit 2; }
info() { printf '%sINFO:%s %s\n' "$CYAN$BOLD" "$NC" "$1"; }
plan() { printf '%s%s:%s %s\n' "$YELLOW$BOLD" "$( $APPLY && printf APPLY || printf DRY-RUN )" "$NC" "$1"; }

read_option() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" {v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit}' "$CONFIG_FILE"; }
is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

main() {
    init_colors
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -c|--config) [ "$#" -ge 2 ] || fail '--config requires a file.'; CONFIG_FILE=$2; shift 2 ;;
            --dry-run) APPLY=false; shift ;;
            --apply) APPLY=true; shift ;;
            --no-color) RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''; shift ;;
            -h|--help) help; exit 0 ;;
            *) fail "unknown option: $1" ;;
        esac
    done
    [ -r "$CONFIG_FILE" ] || fail 'a readable --config file is required.'
    local logdir compress_after remove_after day archive temp
    logdir=$(read_option logdir); compress_after=$(read_option dailytocompressret); remove_after=$(read_option toremovalretention)
    [ -n "$logdir" ] && [ -d "$logdir" ] && [ "$logdir" != / ] || fail 'logdir must be an existing directory other than /.'
    is_integer "$compress_after" || fail 'dailytocompressret must be a non-negative integer.'
    is_integer "$remove_after" || fail 'toremovalretention must be a non-negative integer.'
    info "mode: $( $APPLY && printf apply || printf dry-run ); root: $logdir"
    while IFS= read -r -d '' archive; do
        plan "remove expired archive: $archive"
        $APPLY && rm -f -- "$archive"
    done < <(find "$logdir" -maxdepth 1 -type f -name '*.tar.gz' -mtime "+$remove_after" -print0)
    while IFS= read -r -d '' day; do
        [[ "$(basename "$day")" =~ ^[0-9]{8}$ ]] || continue
        archive="$day.tar.gz"
        if [ -e "$archive" ]; then
            printf '%sWARNING:%s archive already exists; skipping source directory: %s\n' "$YELLOW$BOLD" "$NC" "$day" >&2
            continue
        fi
        plan "archive sample directory: $day -> $archive"
        if $APPLY; then
            temp=$(mktemp "$logdir/.${PROGRAM}.XXXXXX")
            tar -czf "$temp" -C "$logdir" "$(basename "$day")"
            tar -tzf "$temp" >/dev/null
            mv -- "$temp" "$archive"
            rm -rf -- "$day"
        fi
    done < <(find "$logdir" -mindepth 1 -maxdepth 1 -type d -mtime "+$compress_after" -print0)
    printf '%sDONE:%s %s\n' "$GREEN$BOLD" "$NC" "$( $APPLY && printf 'changes applied' || printf 'no changes made' )"
}
main "$@"
