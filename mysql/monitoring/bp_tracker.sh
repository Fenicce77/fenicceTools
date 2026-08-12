#!/usr/bin/env bash
set -euo pipefail

LOGIN_PATH=""; POLL_INTERVAL=10; OUTPUT_FILE=""; NO_COLOR=false
TOP_OBJECTS_COUNT=0; ACTIVE_SESSIONS_COUNT=0; OBJECT_FILTER=""; USER_FILTER=""
MYSQL_BIN=${MYSQL_BIN:-mysql}; COLOR_ENABLED=false; SCREEN_REFRESH_ENABLED=false
C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
PREV_YOUNG=""; PREV_NOT_YOUNG=""; PREV_TIME=""; TOP_OBJECTS_ROW=""; SESSIONS_ROW=""

preparse_no_color() { local x; for x in "$@"; do [[ "$x" == --no-color ]] && NO_COLOR=true; done; return 0; }
terminal_setup() {
  COLOR_ENABLED=false; SCREEN_REFRESH_ENABLED=false
  if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb ]]; then SCREEN_REFRESH_ENABLED=true; [[ "$NO_COLOR" == false ]] && COLOR_ENABLED=true || true; fi
  if [[ "$COLOR_ENABLED" == true ]]; then
    C_RESET=$(tput sgr0 2>/dev/null || true); C_BOLD=$(tput bold 2>/dev/null || true)
    C_RED="${C_BOLD}$(tput setaf 1 2>/dev/null || true)"; C_GREEN="${C_BOLD}$(tput setaf 2 2>/dev/null || true)"
    C_YELLOW="${C_BOLD}$(tput setaf 3 2>/dev/null || true)"; C_CYAN="${C_BOLD}$(tput setaf 6 2>/dev/null || true)"
  fi
}
clear_screen() { [[ "$SCREEN_REFRESH_ENABLED" == true ]] && printf '\033[H\033[2J' || true; }
error() { printf '%b\n' "${C_RED}Error: $1${C_RESET}" >&2; }
help() {
  printf '%b\n\n' "${C_CYAN}${C_BOLD}MySQL InnoDB Buffer Pool Tracker${C_RESET}"
  printf '%b\n' "${C_YELLOW}${C_BOLD}Usage:${C_RESET}"
  printf '%b\n\n' "  ${C_CYAN}$0 -l LOGIN_PATH [OPTIONS]${C_RESET}"
  printf '%b\n' "${C_YELLOW}${C_BOLD}Required:${C_RESET}"
  printf '  %b%-32s%b %b%-19s%b %s\n\n' "$C_GREEN" '-l, --login-path' "$C_RESET" "$C_CYAN" 'NAME' "$C_RESET" 'MySQL login path for the target server'
  printf '%b\n' "${C_YELLOW}${C_BOLD}Monitoring:${C_RESET}"
  printf '  %b%-32s%b %b%-19s%b %s\n' "$C_GREEN" '-i, --interval' "$C_RESET" "$C_CYAN" 'SECONDS' "$C_RESET" 'Refresh interval; positive integer (default: 10)'
  printf '  %b%-32s%b %b%-19s%b %s\n\n' "$C_GREEN" '--no-color' "$C_RESET" "$C_CYAN" '' "$C_RESET" 'Disable ANSI colors; interactive refresh remains enabled'
  printf '%b\n' "${C_YELLOW}${C_BOLD}Runtime and output:${C_RESET}"
  printf '  %b%-32s%b %b%-19s%b %s\n\n' "$C_GREEN" '-o, --output-file' "$C_RESET" "$C_CYAN" 'FILE' "$C_RESET" 'Plain-text snapshot log; query text is never recorded'
  printf '%b\n' "${C_YELLOW}${C_BOLD}Expensive optional views:${C_RESET}"
  printf '  %b%-32s%b %b%-19s%b %s\n' "$C_GREEN" '--top-objects [COUNT]' "$C_RESET" "$C_CYAN" '1-100' "$C_RESET" 'Per-table residency; sampled no more often than every 60 seconds'
  printf '  %b%-32s%b %b%-19s%b %s\n' "$C_GREEN" '--object-filter' "$C_RESET" "$C_CYAN" 'TEXT' "$C_RESET" 'Literal substring filter for top objects'
  printf '  %b%-32s%b %b%-19s%b %s\n' "$C_GREEN" '--active-sessions [COUNT]' "$C_RESET" "$C_CYAN" '1-100' "$C_RESET" 'Session correlation; statement prefix is screen-only'
  printf '  %b%-32s%b %b%-19s%b %s\n\n' "$C_GREEN" '--user-filter' "$C_RESET" "$C_CYAN" 'TEXT' "$C_RESET" 'Literal substring filter for active sessions'
  printf '%b\n' "${C_YELLOW}${C_BOLD}Help:${C_RESET}"
  printf '  %b%-32s%b %b%-19s%b %s\n\n' "$C_GREEN" '-h, --help' "$C_RESET" "$C_CYAN" '' "$C_RESET" 'Show this help and exit'
  printf '%b\n' "${C_YELLOW}${C_BOLD}Examples:${C_RESET}"
  printf '  %b%s -l production%b\n' "$C_CYAN" "$0" "$C_RESET"
  printf '  %b%s -l production --top-objects 10 --active-sessions 5%b\n\n' "$C_CYAN" "$0" "$C_RESET"
  printf '%b\n' "${C_YELLOW}${C_BOLD}Safety:${C_RESET}"
  printf '%b\n' "${C_YELLOW}  Default mode reads only aggregated Buffer Pool statistics. Top objects is opt-in${C_RESET}"
  printf '%b\n' "${C_YELLOW}  because it can inspect resident pages and affect a busy production server.${C_RESET}"
}
need_value() { [[ -n "${2:-}" && "${2:-}" != -* ]] || { error "Option $1 requires a value."; return 1; }; }
valid_count() { [[ "$2" =~ ^[0-9]+$ && "$2" -ge 1 && "$2" -le 100 ]] || { error "$1 count must be between 1 and 100."; return 1; }; }
parse() {
  while [[ $# -gt 0 ]]; do case "$1" in
    -l|--login-path) need_value "$1" "${2:-}"; LOGIN_PATH=$2; shift 2;; --login-path=*) LOGIN_PATH=${1#*=}; shift;;
    -i|--interval) need_value "$1" "${2:-}"; POLL_INTERVAL=$2; shift 2;; --interval=*) POLL_INTERVAL=${1#*=}; shift;;
    -o|--output-file) need_value "$1" "${2:-}"; OUTPUT_FILE=$2; shift 2;; --output-file=*) OUTPUT_FILE=${1#*=}; shift;;
    --top-objects) if [[ -n "${2:-}" && "${2:-}" != -* ]]; then TOP_OBJECTS_COUNT=$2; shift 2; else TOP_OBJECTS_COUNT=10; shift; fi;; --top-objects=*) TOP_OBJECTS_COUNT=${1#*=}; shift;;
    --active-sessions) if [[ -n "${2:-}" && "${2:-}" != -* ]]; then ACTIVE_SESSIONS_COUNT=$2; shift 2; else ACTIVE_SESSIONS_COUNT=5; shift; fi;; --active-sessions=*) ACTIVE_SESSIONS_COUNT=${1#*=}; shift;;
    --object-filter) need_value "$1" "${2:-}"; OBJECT_FILTER=$2; shift 2;; --object-filter=*) OBJECT_FILTER=${1#*=}; shift;;
    --user-filter) need_value "$1" "${2:-}"; USER_FILTER=$2; shift 2;; --user-filter=*) USER_FILTER=${1#*=}; shift;;
    --no-color) NO_COLOR=true; shift;; -h|--help) help; exit 0;; *) error "Unknown option: $1"; return 1;; esac; done
}
validate() { [[ -n "$LOGIN_PATH" ]] || { error 'login-path is required.'; return 1; }; [[ "$POLL_INTERVAL" =~ ^[0-9]+$ && "$POLL_INTERVAL" -ge 1 ]] || { error 'interval must be a positive integer.'; return 1; }; [[ "$TOP_OBJECTS_COUNT" == 0 ]] || valid_count top-objects "$TOP_OBJECTS_COUNT"; [[ "$ACTIVE_SESSIONS_COUNT" == 0 ]] || valid_count active-sessions "$ACTIVE_SESSIONS_COUNT"; }
query() { printf '%s\n' "$1" | "$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
like() { local h; h=$(hex "$1"); printf "REPLACE(REPLACE(REPLACE(CONVERT(X'%s' USING utf8mb4), '\\\\', '\\\\\\\\'), '%%', '\\\\%%'), '_', '\\\\_')" "$h"; }
global() { GLOBAL=$(query $'/* bp-tracker:global */\nSELECT SUM(POOL_SIZE), SUM(FREE_BUFFERS), SUM(DATABASE_PAGES), SUM(MODIFIED_DATABASE_PAGES), ROUND(100 * SUM(MODIFIED_DATABASE_PAGES) / NULLIF(SUM(DATABASE_PAGES), 0), 2), SUM(PAGES_READ_RATE), SUM(PAGES_MADE_YOUNG), SUM(PAGES_NOT_MADE_YOUNG) FROM INFORMATION_SCHEMA.INNODB_BUFFER_POOL_STATS;'); NOW=$(date +%s); }
top() { [[ "$TOP_OBJECTS_COUNT" -gt 0 ]] || return 0; local w='1=1'; if [[ -n "$OBJECT_FILTER" ]]; then w="CONCAT(object_schema, '.', object_name) LIKE CONCAT('%', $(like "$OBJECT_FILTER"), '%') ESCAPE '\\\\'"; fi; TOP_OBJECTS_ROW=$(query "/* bp-tracker:top-objects */ SELECT CONCAT(object_schema, '.', object_name), pages, allocated, data, pages_old, pages_hashed, rows_cached FROM sys.innodb_buffer_stats_by_table WHERE $w ORDER BY allocated DESC LIMIT $TOP_OBJECTS_COUNT;" 2>&1) || TOP_OBJECTS_ROW="TOP OBJECTS UNAVAILABLE: $TOP_OBJECTS_ROW"; return 0; }
sessions() { [[ "$ACTIVE_SESSIONS_COUNT" -gt 0 ]] || return 0; local w='1=1'; if [[ -n "$USER_FILTER" ]]; then w="user LIKE CONCAT('%', $(like "$USER_FILTER"), '%') ESCAPE '\\\\'"; fi; SESSIONS_ROW=$(query "/* bp-tracker:active-sessions */ SELECT user, time, state, LEFT(current_statement, 64) FROM sys.session WHERE user NOT IN ('mysql.session', 'mysql.sys') AND current_statement IS NOT NULL AND $w ORDER BY time DESC LIMIT $ACTIVE_SESSIONS_COUNT;" 2>&1) || SESSIONS_ROW="ACTIVE USER SESSIONS UNAVAILABLE: $SESSIONS_ROW"; return 0; }
rate() { [[ -n "$2" && "$3" -gt 0 && "$1" -ge "$2" ]] || { printf N/A; return; }; awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN {printf "%.2f", (a-b)/s}'; }
log() { if [[ -n "$OUTPUT_FILE" ]]; then printf '%s | %s\n' "$(date '+%F %T')" "$1" >> "$OUTPUT_FILE"; fi; return 0; }
render_interactive_legend() {
  [[ "$SCREEN_REFRESH_ENABLED" == true ]] || return 0
  printf '\n%b\n' "${C_BOLD}Interactive options:${C_RESET} [${C_GREEN}q${C_RESET}] ${C_RED}Quit${C_RESET}"
}
render() {
  local p f d dirty pct io y n elapsed=0 yr nr color=''; IFS=$'\t' read -r p f d dirty pct io y n <<< "$GLOBAL"; [[ -n "$PREV_TIME" ]] && elapsed=$((NOW-PREV_TIME)); yr=$(rate "$y" "$PREV_YOUNG" "$elapsed"); nr=$(rate "$n" "$PREV_NOT_YOUNG" "$elapsed"); [[ "$io" -gt 5000 ]] && color=$C_RED || { [[ "$io" -gt 0 ]] && color=$C_YELLOW || true; }
  clear_screen; printf '%b\n' "${C_CYAN}${C_BOLD}================ BUFFER POOL ACTIVITY ================${C_RESET}"; printf '%s\n' "Pool pages: $p | Free pages: $f | Data pages: $d | Dirty pages: $dirty (${pct}%)"; printf '%b\n' "Read I/O: ${color}$io pages/s${C_RESET} | Young promotions/s: $yr | Old-list stays/s: $nr"; log "BUFFER POOL ACTIVITY | pool=$p free=$f data=$d dirty=$dirty dirty_pct=$pct read_io=$io young_promotions_s=$yr old_list_stays_s=$nr"
  [[ "$TOP_OBJECTS_COUNT" -gt 0 ]] && { printf '%b\n%s\n' "${C_CYAN}TOP OBJECTS${C_RESET}" "$TOP_OBJECTS_ROW"; log "TOP OBJECTS | $TOP_OBJECTS_ROW"; }
  [[ "$ACTIVE_SESSIONS_COUNT" -gt 0 ]] && { printf '%b\n%s\n' "${C_GREEN}ACTIVE USER SESSIONS${C_RESET}" "$SESSIONS_ROW"; log 'ACTIVE USER SESSIONS | metadata sampled'; }
  render_interactive_legend
  PREV_YOUNG=$y; PREV_NOT_YOUNG=$n; PREV_TIME=$NOW
}
run_once() { global; top; sessions; render; }
main() {
  preparse_no_color "$@"
  terminal_setup
  if [[ $# -eq 0 ]]; then
    help
    return 0
  fi
  if ! parse "$@"; then
    help
    return 1
  fi
  terminal_setup
  if ! validate; then
    help
    return 1
  fi
  [[ -n "$OUTPUT_FILE" ]] && : > "$OUTPUT_FILE"
  if [[ "$SCREEN_REFRESH_ENABLED" != true ]]; then run_once; return; fi
  while true; do
    run_once
    if read -r -t "$POLL_INTERVAL" -n 1 -s key; then
      [[ "$key" == q || "$key" == Q ]] && return
    fi
  done
}
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
