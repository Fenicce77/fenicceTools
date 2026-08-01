#!/usr/bin/env bash
# ==============================================================================
# Script: check_opened_sessions.sh
# Description: Real-time MySQL/MariaDB active session monitor with delta tracking,
#              interactive filter controls, and colorized visual output.
# Platforms: Fully compatible with Linux and macOS (Bash 3.2+)
# ==============================================================================

# Ensure cleanup on exit or signals
trap 'cleanup' EXIT INT TERM

# Global variables & default values
LOGIN_PATH=""
DEFAULTS_FILE=""
REFRESH_TIME=5
FILTER_USER=""
FILTER_DB=""
FILTER_HOST=""
EXCLUDE_USERS=""
SHOW_HELP_GUIDE=0
PREV_FILE="/tmp/check_sessions_prev_$$"
OLD_TTY_SETTINGS=""

cleanup() {
    rm -f "$PREV_FILE" 2>/dev/null
    if [[ -t 0 ]]; then
        if [[ -n "$OLD_TTY_SETTINGS" ]]; then
            stty "$OLD_TTY_SETTINGS" 2>/dev/null
        else
            stty echo icanon 2>/dev/null
        fi
    fi
    printf "\033[?25h" 2>/dev/null # Restore cursor
}

# Color definitions with tput and ANSI fallback
setup_colors() {
    if test -t 1 && command -v tput >/dev/null 2>&1; then
        ncolors=$(tput colors 2>/dev/null || echo 0)
        if [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
            BOLD=$(tput bold 2>/dev/null || printf '\033[1m')
            DIM=$(tput dim 2>/dev/null || printf '\033[2m')
            RED=$(tput setaf 1 2>/dev/null || printf '\033[31m')
            GREEN=$(tput setaf 2 2>/dev/null || printf '\033[32m')
            YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[33m')
            BLUE=$(tput setaf 4 2>/dev/null || printf '\033[34m')
            MAGENTA=$(tput setaf 5 2>/dev/null || printf '\033[35m')
            CYAN=$(tput setaf 6 2>/dev/null || printf '\033[36m')
            WHITE=$(tput setaf 7 2>/dev/null || printf '\033[37m')
            RESET=$(tput sgr0 2>/dev/null || printf '\033[0m')
            return
        fi
    fi
    BOLD='\033[1m'
    DIM='\033[2m'
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    MAGENTA='\033[35m'
    CYAN='\033[36m'
    WHITE='\033[37m'
    RESET='\033[0m'
}
setup_colors

# Help banner
show_help() {
    cat << EOF
${BOLD}${CYAN}================================================================================${RESET}
${BOLD}${CYAN}                 MySQL / MariaDB Opened Sessions Monitor                        ${RESET}
${BOLD}${CYAN}================================================================================${RESET}

${BOLD}USAGE:${RESET}
  $0 [OPTIONS]
  $0 <LOGIN_PATH_OR_DEFAULTS_FILE>

${BOLD}DESCRIPTION:${RESET}
  Monitors active user connection counts grouped by User, Database, and Host.
  Displays live screen updates with connection delta tracking (+ / - count changes).

${BOLD}CONNECTION PARAMETERS (At least one required):${RESET}
  ${GREEN}-p, --login-path PATH${RESET}     MySQL login-path section name (e.g., prod, local)
  ${GREEN}-f, --defaults-file FILE${RESET}   Path to MySQL options file (e.g., /path/myconf.cnf)

${BOLD}MONITORING & FILTER OPTIONS:${RESET}
  ${GREEN}-r, --refresh SEC${RESET}          Refresh interval in seconds (default: 5)
  ${GREEN}-u, --user FILTER${RESET}          Filter by User (supports wildcards * or %)
  ${GREEN}-d, --db, --schema FILTER${RESET}  Filter by Database/Schema (supports wildcards * or %)
  ${GREEN}-H, --host FILTER${RESET}          Filter by Host IP/Name (supports wildcards * or %)
  ${GREEN}-x, --exclude-user USERS${RESET}   Comma-separated list of users to exclude
  ${GREEN}-h, --help${RESET}                 Show this colorful help screen and exit

${BOLD}INTERACTIVE RUNTIME KEYBINDINGS:${RESET}
  ${YELLOW}[q]${RESET} Quit monitor                 ${YELLOW}[u]${RESET} Set/Change User filter
  ${YELLOW}[d]${RESET} Set/Change DB filter         ${YELLOW}[h]${RESET} Set/Change Host filter
  ${YELLOW}[r]${RESET} Change Refresh interval      ${YELLOW}[c]${RESET} Clear all active filters
  ${YELLOW}[?]${RESET} Toggle on-screen help guide  ${YELLOW}[Space/Enter]${RESET} Force immediate refresh

${BOLD}EXAMPLES:${RESET}
  $0 --login-path=prod --refresh=3
  $0 --defaults-file=/etc/mysql/my.cnf --user=app_% --db=production
  $0 prod -u root -r 2
  $0 /path/to/myconf.cnf
${BOLD}${CYAN}================================================================================${RESET}
EOF
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo -e "${RED}[ERROR] Missing connection parameters.${RESET}\n"
        show_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--login-path)
                LOGIN_PATH="$2"; shift 2 ;;
            --login-path=*)
                LOGIN_PATH="${1#*=}"; shift ;;
            -f|--defaults-file)
                DEFAULTS_FILE="$2"; shift 2 ;;
            --defaults-file=*)
                DEFAULTS_FILE="${1#*=}"; shift ;;
            -r|--refresh|--refresh-time)
                REFRESH_TIME="$2"; shift 2 ;;
            --refresh=*|--refresh-time=*)
                REFRESH_TIME="${1#*=}"; shift ;;
            -u|--user)
                FILTER_USER="$2"; shift 2 ;;
            --user=*)
                FILTER_USER="${1#*=}"; shift ;;
            -d|--db|--schema)
                FILTER_DB="$2"; shift 2 ;;
            --db=*|--schema=*)
                FILTER_DB="${1#*=}"; shift ;;
            -H|--host)
                FILTER_HOST="$2"; shift 2 ;;
            --host=*)
                FILTER_HOST="${1#*=}"; shift ;;
            -x|--exclude-user)
                EXCLUDE_USERS="$2"; shift 2 ;;
            --exclude-user=*)
                EXCLUDE_USERS="${1#*=}"; shift ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                echo -e "${RED}[ERROR] Unknown option: $1${RESET}\n"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$LOGIN_PATH" && -z "$DEFAULTS_FILE" ]]; then
                    if [[ -f "$1" ]]; then
                        DEFAULTS_FILE="$1"
                    else
                        LOGIN_PATH="$1"
                    fi
                else
                    echo -e "${RED}[ERROR] Unexpected positional argument: $1${RESET}\n"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$LOGIN_PATH" && -z "$DEFAULTS_FILE" ]]; then
        echo -e "${RED}[ERROR] Neither --login-path nor --defaults-file connection parameter was provided.${RESET}\n"
        show_help
        exit 1
    fi
}

build_sql_where() {
    local where="WHERE 1=1"
    
    if [[ -n "$FILTER_USER" ]]; then
        local u_pattern="${FILTER_USER//\*/%}"
        [[ "$u_pattern" != *%* ]] && u_pattern="%${u_pattern}%"
        where="$where AND USER LIKE '$u_pattern'"
    fi

    if [[ -n "$FILTER_DB" ]]; then
        local d_pattern="${FILTER_DB//\*/%}"
        [[ "$d_pattern" != *%* ]] && d_pattern="%${d_pattern}%"
        where="$where AND COALESCE(DB,'none') LIKE '$d_pattern'"
    fi

    if [[ -n "$FILTER_HOST" ]]; then
        local h_pattern="${FILTER_HOST//\*/%}"
        [[ "$h_pattern" != *%* ]] && h_pattern="%${h_pattern}%"
        where="$where AND HOST LIKE '$h_pattern'"
    fi

    if [[ -n "$EXCLUDE_USERS" ]]; then
        local old_ifs="$IFS"
        IFS=','
        read -r -a excl_arr <<< "$EXCLUDE_USERS"
        IFS="$old_ifs"
        local excl_sql=""
        for item in "${excl_arr[@]}"; do
            # Trim whitespace
            item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$item" ]]; then
                [[ -n "$excl_sql" ]] && excl_sql="$excl_sql,"
                excl_sql="$excl_sql'$item'"
            fi
        done
        if [[ -n "$excl_sql" ]]; then
            where="$where AND USER NOT IN ($excl_sql)"
        fi
    fi

    echo "$where"
}

fetch_and_render() {
    local where_clause
    where_clause=$(build_sql_where)

    local sql_query="SELECT COALESCE(USER, 'system user') AS usr, COALESCE(DB, 'none') AS dbname, SUBSTRING_INDEX(SUBSTRING_INDEX(HOST,':',1),'.',4) AS host_src, COUNT(*) AS total FROM information_schema.PROCESSLIST $where_clause GROUP BY USER, DB, SUBSTRING_INDEX(SUBSTRING_INDEX(HOST,':',1),'.',4) ORDER BY total DESC, usr, dbname, host_src;"

    local curr_data
    curr_data=$("$MYSQLBIN" "${MYSQL_ARGS[@]}" -e "$sql_query" 2>&1)
    local query_status=$?

    if [[ $query_status -ne 0 ]]; then
        clear
        echo -e "${RED}[ERROR] MySQL query execution failed:${RESET}"
        echo -e "${YELLOW}$curr_data${RESET}\n"
        echo -e "${CYAN}Retrying in ${REFRESH_TIME}s... Press [q] to exit.${RESET}"
        return 1
    fi

    # Ensure prev file exists before awk
    [[ ! -f "$PREV_FILE" ]] && touch "$PREV_FILE"

    clear
    awk -v prev_file="$PREV_FILE" \
        -v hostname="$(hostname)" \
        -v conn_info="${DEFAULTS_FILE:---login-path=$LOGIN_PATH}" \
        -v refresh_sec="$REFRESH_TIME" \
        -v f_user="${FILTER_USER:-all}" \
        -v f_db="${FILTER_DB:-all}" \
        -v f_host="${FILTER_HOST:-all}" \
        -v show_help_banner="$SHOW_HELP_GUIDE" \
        -v c_bold="$BOLD" -v c_dim="$DIM" -v c_red="$RED" -v c_grn="$GREEN" \
        -v c_yel="$YELLOW" -v c_blu="$BLUE" -v c_mag="$MAGENTA" -v c_cyn="$CYAN" -v c_rst="$RESET" '
    BEGIN {
        FS = "\t"
        has_prev = 0

        # Read previous iteration counts into array
        while ((getline line < prev_file) > 0) {
            n = split(line, fields, "\t")
            if (n >= 4) {
                key = fields[1] "\t" fields[2] "\t" fields[3]
                prev_counts[key] = fields[4] + 0
                has_prev = 1
            }
        }
        close(prev_file)

        # Truncate prev_file for writing current iteration
        printf "" > prev_file

        "date +\"%Y-%m-%d %H:%M:%S\"" | getline now_str
        close("date +\"%Y-%m-%d %H:%M:%S\"")

        print c_cyn "====================================================================================================" c_rst
        printf "%s MySQL Session Monitor %s| Host: %s%s%s | Time: %s%s%s | Refresh: %s%ss%s\n", \
            c_bold, c_rst, c_mag, hostname, c_rst, c_grn, now_str, c_rst, c_yel, refresh_sec, c_rst
        print c_cyn "====================================================================================================" c_rst
        printf " Connection: %s%s%s\n", c_bold, conn_info, c_rst
        printf " Filters   : User [%s%s%s]  DB [%s%s%s]  Host [%s%s%s]\n", \
            c_yel, f_user, c_rst, c_yel, f_db, c_rst, c_yel, f_host, c_rst
        print c_cyn "----------------------------------------------------------------------------------------------------" c_rst
        printf " %s%-22s %-25s %-25s %-10s %-10s%s\n", c_bold, "USER", "DATABASE", "HOST/SOURCE", "COUNT", "DELTA", c_rst
        print c_cyn "----------------------------------------------------------------------------------------------------" c_rst

        total_count = 0
        total_prev = 0
        rows = 0
    }

    {
        user = $1
        db = $2
        host = $3
        cnt = $4 + 0
        key = user "\t" db "\t" host

        # Append to prev_file for next tick
        print key "\t" cnt >> prev_file

        total_count += cnt
        rows++

        if (has_prev && (key in prev_counts)) {
            p_cnt = prev_counts[key]
            total_prev += p_cnt
            diff = cnt - p_cnt
            if (diff > 0) {
                delta_str = sprintf("%s+%d%s", c_grn c_bold, diff, c_rst)
            } else if (diff < 0) {
                delta_str = sprintf("%s%d%s", c_red c_bold, diff, c_rst)
            } else {
                delta_str = sprintf("%s0%s", c_dim, c_rst)
            }
        } else if (has_prev) {
            delta_str = sprintf("%sNEW%s", c_yel c_bold, c_rst)
        } else {
            delta_str = sprintf("%s-%s", c_dim, c_rst)
        }

        u_disp = (length(user) > 22) ? substr(user,1,19) "..." : user
        d_disp = (length(db) > 25) ? substr(db,1,22) "..." : db
        h_disp = (length(host) > 25) ? substr(host,1,22) "..." : host

        printf " %-22s %-25s %-25s %-10d %-18s\n", u_disp, d_disp, h_disp, cnt, delta_str
    }

    END {
        close(prev_file)

        if (rows == 0) {
            print c_dim " (No active connections matching filters)" c_rst
        }

        print c_cyn "----------------------------------------------------------------------------------------------------" c_rst

        if (has_prev) {
            tot_diff = total_count - total_prev
            if (tot_diff > 0) {
                tot_delta_str = sprintf("%s+%d%s", c_grn c_bold, tot_diff, c_rst)
            } else if (tot_diff < 0) {
                tot_delta_str = sprintf("%s%d%s", c_red c_bold, tot_diff, c_rst)
            } else {
                tot_delta_str = sprintf("%s0%s", c_dim, c_rst)
            }
        } else {
            tot_delta_str = sprintf("%s-%s", c_dim, c_rst)
        }

        printf " %sTOTAL CONNECTIONS: %-5d%s %27s %sTOTAL DELTA: %-18s%s\n", \
            c_bold, total_count, c_rst, "", c_bold, tot_delta_str, c_rst
        print c_cyn "====================================================================================================" c_rst
        printf " Keybindings: %s[q]%s Quit  %s[u]%s User  %s[d]%s DB  %s[h]%s Host  %s[r]%s Refresh  %s[c]%s Clear  %s[?]%s Help\n", \
            c_yel, c_rst, c_yel, c_rst, c_yel, c_rst, c_yel, c_rst, c_yel, c_rst, c_yel, c_rst, c_yel, c_rst
        print c_cyn "====================================================================================================" c_rst

        if (show_help_banner + 0 == 1) {
            print c_yel " [HELP BANNER]" c_rst
            print "  • Press key 'u', 'd', or 'h' to set filtering for User, DB, or Host."
            print "  • Press key 'c' to clear filters."
            print "  • Press key 'r' to change the refresh rate."
            print "  • Delta shows changes since last screen update (+Green increase, -Red decrease)."
            print c_cyn "====================================================================================================" c_rst
        }
    }' <<< "$curr_data"
}

handle_input() {
    local key
    if [[ -t 0 ]]; then
        read -t "$REFRESH_TIME" -n 1 -r key 2>/dev/null
    else
        sleep "$REFRESH_TIME"
        return
    fi

    if [[ $? -eq 0 && -n "$key" ]]; then
        case "$key" in
            q|Q)
                echo -e "\n${CYAN}Exiting MySQL Session Monitor. Goodbye!${RESET}"
                exit 0
                ;;
            u|U)
                stty echo icanon 2>/dev/null
                printf "\n${YELLOW}Enter User filter (leave empty to clear, * for wildcard): ${RESET}"
                read -r FILTER_USER
                stty -icanon -echo min 0 time 0 2>/dev/null
                ;;
            d|D)
                stty echo icanon 2>/dev/null
                printf "\n${YELLOW}Enter Database filter (leave empty to clear, * for wildcard): ${RESET}"
                read -r FILTER_DB
                stty -icanon -echo min 0 time 0 2>/dev/null
                ;;
            h|H)
                stty echo icanon 2>/dev/null
                printf "\n${YELLOW}Enter Host filter (leave empty to clear, * for wildcard): ${RESET}"
                read -r FILTER_HOST
                stty -icanon -echo min 0 time 0 2>/dev/null
                ;;
            r|R)
                stty echo icanon 2>/dev/null
                printf "\n${YELLOW}Enter Refresh interval in seconds: ${RESET}"
                read -r new_ref
                if [[ "$new_ref" =~ ^[0-9]+$ ]] && [[ "$new_ref" -gt 0 ]]; then
                    REFRESH_TIME="$new_ref"
                fi
                stty -icanon -echo min 0 time 0 2>/dev/null
                ;;
            c|C)
                FILTER_USER=""
                FILTER_DB=""
                FILTER_HOST=""
                ;;
            \?)
                if [[ $SHOW_HELP_GUIDE -eq 1 ]]; then
                    SHOW_HELP_GUIDE=0
                else
                    SHOW_HELP_GUIDE=1
                fi
                ;;
            *)
                # Space/Enter or other key forces immediate refresh
                ;;
        esac
    fi
}

# Main Execution Flow
parse_args "$@"

# Check for mysql executable
MYSQLBIN=$(which mysql 2>/dev/null)
if [[ -z "$MYSQLBIN" ]]; then
    echo -e "${RED}[ERROR] 'mysql' client command not found in PATH.${RESET}"
    exit 1
fi

# Prepare MySQL base arguments
MYSQL_ARGS=("-N" "-B" "-A" "information_schema")
if [[ -n "$DEFAULTS_FILE" ]]; then
    MYSQL_ARGS=("--defaults-file=$DEFAULTS_FILE" "${MYSQL_ARGS[@]}")
elif [[ -n "$LOGIN_PATH" ]]; then
    MYSQL_ARGS=("--login-path=$LOGIN_PATH" "${MYSQL_ARGS[@]}")
fi

# Save terminal state if in TTY
if [[ -t 0 ]]; then
    OLD_TTY_SETTINGS=$(stty -g 2>/dev/null)
    stty -icanon -echo min 0 time 0 2>/dev/null
    printf "\033[?25l" 2>/dev/null # Hide cursor for smoother rendering
fi

# Main monitoring loop
while true; do
    fetch_and_render
    handle_input
done
