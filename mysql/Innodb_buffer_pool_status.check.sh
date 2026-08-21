#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOGIN_PATH=''
INTERVAL=5
MYSQL_BIN=''
NO_COLOR=0
RESIZE_STATE=''
RESIZE_TEXT=''
RESIZE_CODE=''
RESIZE_PROGRESS=''
TARGET_BYTES=''
COLOR_OPTION_GREEN=''
COLOR_OPTION_RED=''

is_interactive_terminal() {
    [[ -t 0 && -t 1 && -n "${TERM:-}" && "${TERM:-}" != 'dumb' ]]
}

setup_terminal() {
    if [[ "$NO_COLOR" -eq 1 ]] || ! is_interactive_terminal; then
        COLOR_RED=''
        COLOR_GREEN=''
        COLOR_YELLOW=''
        COLOR_CYAN=''
        COLOR_RESET=''
        COLOR_OPTION_GREEN=''
        COLOR_OPTION_RED=''
    else
        COLOR_RED=$'\033[1;31m'
        COLOR_GREEN=$'\033[1;32m'
        COLOR_YELLOW=$'\033[1;33m'
        COLOR_CYAN=$'\033[1;36m'
        COLOR_RESET=$'\033[0m'
        COLOR_OPTION_GREEN=$'\033[32m'
        COLOR_OPTION_RED=$'\033[31m'
    fi
}

show_help() {
    cat <<EOF
${COLOR_CYAN}Usage:${COLOR_RESET} $SCRIPT_NAME -l NAME [OPTIONS]

Monitor the read-only InnoDB buffer pool resize status variables.

${COLOR_CYAN}Required:${COLOR_RESET}
  -l, --login-path NAME   mysql_config_editor login path to use.

${COLOR_CYAN}Options:${COLOR_RESET}
  -i, --interval SECONDS  Sampling interval; positive integer (default: 5).
  --mysql-bin PATH        Path to a regular executable mysql client.
  --no-color              Disable ANSI color output.
  -h, --help              Show this help and exit.

${COLOR_CYAN}Examples:${COLOR_RESET}
  $SCRIPT_NAME -l monitor
  $SCRIPT_NAME -l monitor -i 10 --mysql-bin /usr/local/bin/mysql
EOF
}

cli_error() {
    printf '%sERROR: %s%s\n' "$COLOR_RED" "$1" "$COLOR_RESET" >&2
    show_help >&2
    exit 2
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        if [[ "$argument" == '--no-color' ]]; then
            NO_COLOR=1
            break
        fi
    done
    setup_terminal

    while (($#)); do
        case "$1" in
            -l|--login-path)
                (($# >= 2)) || cli_error '--login-path requires a value.'
                LOGIN_PATH=$2
                shift 2
                ;;
            -i|--interval)
                (($# >= 2)) || cli_error '--interval requires a value.'
                INTERVAL=$2
                shift 2
                ;;
            --mysql-bin)
                (($# >= 2)) || cli_error '--mysql-bin requires a value.'
                MYSQL_BIN=$2
                shift 2
                ;;
            --no-color)
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                cli_error "unknown option: $1"
                ;;
        esac
    done

    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
    [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || cli_error '--interval must be a positive integer.'

    if [[ -z "$MYSQL_BIN" ]]; then
        MYSQL_BIN=$(command -v mysql 2>/dev/null || true)
    fi
    [[ -n "$MYSQL_BIN" && -f "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || cli_error '--mysql-bin must reference a regular executable file.'
}

collect_resize_state() {
    RESIZE_STATE=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names -e "SELECT
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_code' THEN VARIABLE_VALUE END),
    MAX(CASE WHEN VARIABLE_NAME = 'Innodb_buffer_pool_resize_status_progress' THEN VARIABLE_VALUE END),
    @@GLOBAL.innodb_buffer_pool_size
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN (
    'Innodb_buffer_pool_resize_status',
    'Innodb_buffer_pool_resize_status_code',
    'Innodb_buffer_pool_resize_status_progress'
);")
}

parse_resize_state() {
    local remaining=$RESIZE_STATE

    RESIZE_TEXT=${remaining%%$'\t'*}
    remaining=${remaining#*$'\t'}
    RESIZE_CODE=${remaining%%$'\t'*}
    remaining=${remaining#*$'\t'}
    RESIZE_PROGRESS=${remaining%%$'\t'*}
    TARGET_BYTES=${remaining#*$'\t'}
}

stage_name() {
    case "$1" in
        2) printf '%s\n' 'Disabling AHI' ;;
        3) printf '%s\n' 'Withdrawing blocks' ;;
        4) printf '%s\n' 'Acquiring global lock' ;;
        5) printf '%s\n' 'Resizing pool' ;;
        6) printf '%s\n' 'Resizing hash' ;;
        *) return 1 ;;
    esac
}

stage_label() {
    case "$RESIZE_CODE" in
        0) printf '%s\n' 'No resize in progress' ;;
        1) printf '%s\n' 'Starting resize' ;;
        2|3|4|5|6) stage_name "$RESIZE_CODE" ;;
        7) printf '%s\n' 'Resize failed' ;;
        *) printf '%s\n' 'Numeric resize status unavailable' ;;
    esac
}

stage_color() {
    case "$RESIZE_CODE" in
        0) printf '%s' "$COLOR_GREEN" ;;
        1) printf '%s' "$COLOR_CYAN" ;;
        2|3|4|5|6) printf '%s' "$COLOR_YELLOW" ;;
        7|*) printf '%s' "$COLOR_RED" ;;
    esac
}

format_target_size() {
    [[ "$1" =~ ^[0-9]+$ ]] || {
        printf '%s\n' 'N/A'
        return
    }

    awk -v bytes="$1" '
        BEGIN {
            split("B KiB MiB GiB TiB", units, " ")
            value = bytes
            unit = 1
            while (value >= 1024 && unit < 5) {
                value /= 1024
                unit++
            }
            if (unit == 1) {
                printf "%.0f %s\n", value, units[unit]
            } else {
                printf "%.2f %s\n", value, units[unit]
            }
        }
    '
}

stage_progress() {
    if [[ ! "$RESIZE_CODE" =~ ^[0-7]$ || ! "$RESIZE_PROGRESS" =~ ^[0-9]+$ ]]; then
        printf '%s\n' 'N/A'
        return
    fi

    if ((RESIZE_PROGRESS > 100)); then
        printf '%s\n' '100'
    else
        printf '%s\n' "$RESIZE_PROGRESS"
    fi
}

progress_bar() {
    local percent=$1
    local filled_cells empty_cells filled empty

    filled_cells=$((percent * 16 / 100))
    empty_cells=$((16 - filled_cells))
    printf -v filled '%*s' "$filled_cells" ''
    printf -v empty '%*s' "$empty_cells" ''
    filled=${filled// /#}
    empty=${empty// /-}
    printf '[%s%s] %s%%\n' "$filled" "$empty" "$percent"
}

render_frame() {
    local label color progress target

    label=$(stage_label)
    color=$(stage_color)
    progress=$(stage_progress)
    target=$(format_target_size "$TARGET_BYTES")

    printf '%s\n' 'InnoDB Buffer Pool Resize Monitor'
    printf 'Login path: %s\n' "$LOGIN_PATH"
    printf 'Target buffer pool size: %s\n' "$target"
    printf 'Refresh interval: %s seconds\n' "$INTERVAL"
    printf '%sStage: %s (%s)%s\n' "$color" "$label" "${RESIZE_CODE:-N/A}" "$COLOR_RESET"
    if [[ "$progress" == 'N/A' ]]; then
        printf 'Stage progress: %s\n' "$progress"
        printf '%s\n' 'Numeric resize status is unavailable'
    else
        printf 'Stage progress: %s%%\n' "$progress"
        progress_bar "$progress"
    fi
    printf 'Server status: %s\n' "$RESIZE_TEXT"
}

run_sample() {
    collect_resize_state || return $?
    parse_resize_state
    render_frame

    case "$RESIZE_CODE" in
        0) return 0 ;;
        7) return 7 ;;
        *) return 1 ;;
    esac
}

refresh_screen() {
    is_interactive_terminal && printf '\033[H\033[2J'
}

render_interactive_options() {
    printf '\nInteractive options: [%sq%s] %sQuit%s\n' \
        "$COLOR_OPTION_GREEN" "$COLOR_RESET" "$COLOR_OPTION_RED" "$COLOR_RESET"
}

monitor_loop() {
    local result key

    if ! is_interactive_terminal; then
        if run_sample; then
            return 0
        else
            return $?
        fi
    fi

    while true; do
        refresh_screen
        if run_sample; then
            result=0
        else
            result=$?
        fi

        case "$result" in
            0) return 0 ;;
            7) return 7 ;;
        esac

        render_interactive_options
        key=''
        read -r -s -n 1 -t "$INTERVAL" key || true
        [[ "$key" =~ ^[qQ]$ ]] && return 0
    done
}

main() {
    parse_arguments "$@"
    monitor_loop
}

main "$@"
