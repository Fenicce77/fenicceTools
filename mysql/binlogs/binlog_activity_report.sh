#!/usr/bin/env bash
# Report DML and DDL activity from local or remote MySQL/MariaDB binary logs.
set -euo pipefail

PROGRAM_NAME=${0##*/}
NO_COLOR=false
SOURCE=""
LOCAL_FILES=()
LOCAL_DIR=""
REMOTE_LOGIN_PATH=""
REMOTE_BINLOG_FILES=()
SERVER_VERSION=""
SERVER_FAMILY=""
BINLOG_FORMAT=""
SCOPE="all"
START_DATETIME=""
STOP_DATETIME=""
TOP_TABLES=10
CSV_PATH=""
MYSQLBINLOG_BIN=""
INPUT_FILES=()
PROFILE=""
READER=""

COLOR_BOLD=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_RESET=""

setup_colors() {
    local output_fd=${1:-1}

    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_CYAN=""
    COLOR_RESET=""

    [[ "$NO_COLOR" == false && "${TERM:-dumb}" != dumb ]] || return 0
    case "$output_fd" in
        1) [[ -t 1 ]] || return 0 ;;
        2) [[ -t 2 ]] || return 0 ;;
        *) return 0 ;;
    esac

    COLOR_BOLD=$'\033[1m'
    COLOR_RED=$'\033[0;31m'
    COLOR_CYAN=$'\033[0;36m'
    COLOR_RESET=$'\033[0m'
}

print_help() {
    local output_fd=${1:-1}

    setup_colors "$output_fd"
    {
        printf '%bBinlog Activity Report%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$COLOR_RESET"
        printf '\n%bUsage:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '  %s --source local (--file FILE [FILE ...] | --dir DIRECTORY) \\\n' "$PROGRAM_NAME"
        printf '      --server-version VERSION --binlog-format statement|row|mixed [OPTIONS]\n'
        printf '  %s --source remote --login-path NAME --binlog-file FILE [FILE ...] [OPTIONS]\n' "$PROGRAM_NAME"
        printf '  %s --help\n' "$PROGRAM_NAME"

        printf '\n%bRequired:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '      --source local|remote        Select the binlog source explicitly\n'

        printf '\n%bLocal source:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '      --file FILE [FILE ...]       Read one or more local binlog files; repeatable\n'
        printf '      --dir DIRECTORY              Read regular files in deterministic name order\n'
        printf '      --server-version VERSION     Declare the source server version\n'
        printf '      --server-family FAMILY       mysql or mariadb; derived from VERSION by default\n'
        printf '      --binlog-format FORMAT       statement, row, or mixed\n'

        printf '\n%bRemote source:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '      --login-path NAME            MySQL option-file login path\n'
        printf '      --binlog-file FILE [FILE ...] Read one or more remote binlog files; repeatable\n'
        printf '      --server-version VERSION     Override discovered server version\n'
        printf '      --server-family FAMILY       Override discovered server family\n'
        printf '      --binlog-format FORMAT       Override discovered binlog format\n'

        printf '\n%bAnalysis and output:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '      --scope dml|ddl|all          Activity classes to report (default: all)\n'
        printf '      --start DATETIME             Inclusive mysqlbinlog start bound\n'
        printf '      --stop DATETIME              Inclusive mysqlbinlog stop bound\n'
        printf '      --top-tables NUMBER          Number of tables in the summary (default: 10)\n'
        printf '      --csv PATH                   Write an additional plain CSV report\n'
        printf '      --mysqlbinlog-bin PATH       Reader path or command name\n'
        printf '      --no-color                   Disable ANSI colors\n'
        printf '  -h, --help                       Show this help\n'

        printf '\n%bReader discovery:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '  mysqlbinlog is preferred; mariadb-binlog is used as a fallback.\n'

        printf '\n%bExamples:%b\n' "$COLOR_BOLD" "$COLOR_RESET"
        printf '  %s --source local --file mysql-bin.000001 \\\n' "$PROGRAM_NAME"
        printf '      --server-version 8.4.6 --binlog-format row\n'
        printf '  %s --source local --dir "/var/lib/mysql/binlogs archive" \\\n' "$PROGRAM_NAME"
        printf '      --server-version 10.11.8-MariaDB --binlog-format mixed\n'
        printf '  %s --source remote --login-path reporting \\\n' "$PROGRAM_NAME"
        printf '      --binlog-file mysql-bin.000001 mysql-bin.000002\n'
    } >&"$output_fd"
}

usage_error() {
    local message=$1

    setup_colors 2
    printf '%bERROR:%b %s\n\n' "${COLOR_BOLD}${COLOR_RED}" "$COLOR_RESET" "$message" >&2
    print_help 2
    exit 2
}

runtime_error() {
    setup_colors 2
    printf '%bERROR:%b %s\n' "${COLOR_BOLD}${COLOR_RED}" "$COLOR_RESET" "$1" >&2
    exit 1
}

require_value() {
    local option=$1
    local remaining=$2

    [[ "$remaining" -ge 2 ]] || usage_error "Option $option requires a value."
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --source)
                require_value "$1" "$#"
                SOURCE=$2
                shift 2
                ;;
            --file)
                shift
                [[ "$#" -gt 0 && "$1" != --* ]] \
                    || usage_error 'Option --file requires at least one path.'
                while [[ "$#" -gt 0 && "$1" != --* ]]; do
                    LOCAL_FILES[${#LOCAL_FILES[@]}]=$1
                    shift
                done
                ;;
            --dir)
                require_value "$1" "$#"
                LOCAL_DIR=$2
                shift 2
                ;;
            --login-path)
                require_value "$1" "$#"
                REMOTE_LOGIN_PATH=$2
                shift 2
                ;;
            --binlog-file)
                shift
                [[ "$#" -gt 0 && "$1" != --* ]] \
                    || usage_error 'Option --binlog-file requires at least one name.'
                while [[ "$#" -gt 0 && "$1" != --* ]]; do
                    REMOTE_BINLOG_FILES[${#REMOTE_BINLOG_FILES[@]}]=$1
                    shift
                done
                ;;
            --server-version)
                require_value "$1" "$#"
                SERVER_VERSION=$2
                shift 2
                ;;
            --server-family)
                require_value "$1" "$#"
                SERVER_FAMILY=$2
                shift 2
                ;;
            --binlog-format)
                require_value "$1" "$#"
                BINLOG_FORMAT=$2
                shift 2
                ;;
            --scope)
                require_value "$1" "$#"
                SCOPE=$2
                shift 2
                ;;
            --start)
                require_value "$1" "$#"
                START_DATETIME=$2
                shift 2
                ;;
            --stop)
                require_value "$1" "$#"
                STOP_DATETIME=$2
                shift 2
                ;;
            --top-tables)
                require_value "$1" "$#"
                TOP_TABLES=$2
                shift 2
                ;;
            --csv)
                require_value "$1" "$#"
                CSV_PATH=$2
                shift 2
                ;;
            --mysqlbinlog-bin)
                require_value "$1" "$#"
                MYSQLBINLOG_BIN=$2
                shift 2
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                print_help 1
                exit 0
                ;;
            --*)
                usage_error "Unknown option: $1"
                ;;
            *)
                usage_error "Unexpected argument: $1"
                ;;
        esac
    done
}

derive_server_family() {
    local version=$1
    local normalized

    normalized=$(printf '%s' "$version" | tr '[:upper:]' '[:lower:]')
    case "$normalized" in
        *mariadb*) printf 'mariadb\n' ;;
        *) printf 'mysql\n' ;;
    esac
}

resolve_profile() {
    local family=$1
    local version=$2
    local numeric_version major minor remainder

    PROFILE=""
    numeric_version=${version%%[-[:space:]]*}
    major=${numeric_version%%.*}
    remainder=${numeric_version#*.}
    minor=${remainder%%.*}

    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1

    case "$family" in
        mysql)
            if [[ "$major" -eq 5 && "$minor" -eq 7 ]]; then
                PROFILE='mysql-5.7'
            elif [[ "$major" -ge 8 ]]; then
                PROFILE='mysql-8.0+'
            else
                return 1
            fi
            ;;
        mariadb)
            [[ "$major" -ge 10 ]] || return 1
            PROFILE='mariadb-10+'
            ;;
        *)
            return 1
            ;;
    esac
}

add_unique_input() {
    local candidate=$1
    local existing

    for existing in "${INPUT_FILES[@]}"; do
        [[ "$existing" != "$candidate" ]] || return 0
    done
    INPUT_FILES[${#INPUT_FILES[@]}]=$candidate
}

collect_local_files() {
    local candidate
    local LC_ALL=C

    INPUT_FILES=()
    if [[ -n "$LOCAL_DIR" ]]; then
        [[ -d "$LOCAL_DIR" && -r "$LOCAL_DIR" ]] \
            || usage_error "Binlog directory is not readable: $LOCAL_DIR"

        for candidate in "$LOCAL_DIR"/* "$LOCAL_DIR"/.[!.]* "$LOCAL_DIR"/..?*; do
            [[ -f "$candidate" && -r "$candidate" ]] || continue
            add_unique_input "$candidate"
        done
    else
        for candidate in "${LOCAL_FILES[@]}"; do
            [[ -f "$candidate" && -r "$candidate" ]] \
                || usage_error "Binlog file is not readable: $candidate"
            add_unique_input "$candidate"
        done
    fi

    [[ "${#INPUT_FILES[@]}" -gt 0 ]] \
        || usage_error 'Local source selection did not contain any readable files.'
}

resolve_reader() {
    local resolved=""

    READER=""
    if [[ -n "$MYSQLBINLOG_BIN" ]]; then
        resolved=$(command -v "$MYSQLBINLOG_BIN" 2>/dev/null || true)
        [[ -n "$resolved" && -x "$resolved" && ! -d "$resolved" ]] || return 1
        READER=$resolved
        return 0
    fi

    resolved=$(command -v mysqlbinlog 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
        READER=$resolved
        return 0
    fi

    resolved=$(command -v mariadb-binlog 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
        READER=$resolved
        return 0
    fi

    return 1
}

validate_common_arguments() {
    [[ -n "$SOURCE" ]] || usage_error 'Option --source is required.'
    case "$SOURCE" in
        local|remote) ;;
        *) usage_error 'Source must be local or remote.' ;;
    esac

    case "$SCOPE" in
        dml|ddl|all) ;;
        *) usage_error 'Scope must be dml, ddl, or all.' ;;
    esac

    [[ "$TOP_TABLES" =~ ^[1-9][0-9]*$ ]] \
        || usage_error 'Top tables must be a positive integer.'
}

validate_local_arguments() {
    if [[ "${#LOCAL_FILES[@]}" -gt 0 && -n "$LOCAL_DIR" ]]; then
        usage_error 'Local source accepts either --file or --dir, not both.'
    fi
    if [[ "${#LOCAL_FILES[@]}" -eq 0 && -z "$LOCAL_DIR" ]]; then
        usage_error 'Local source requires --file or --dir.'
    fi
    [[ -n "$SERVER_VERSION" ]] \
        || usage_error 'Local source requires --server-version.'
    [[ -n "$BINLOG_FORMAT" ]] \
        || usage_error 'Local source requires --binlog-format.'

    case "$BINLOG_FORMAT" in
        statement|row|mixed) ;;
        *) usage_error 'Binlog format must be statement, row, or mixed.' ;;
    esac

    if [[ -n "$SERVER_FAMILY" ]]; then
        case "$SERVER_FAMILY" in
            mysql|mariadb) ;;
            *) usage_error 'Server family must be mysql or mariadb.' ;;
        esac
    else
        SERVER_FAMILY=$(derive_server_family "$SERVER_VERSION")
    fi

    resolve_profile "$SERVER_FAMILY" "$SERVER_VERSION" \
        || usage_error "Unsupported server family/version: $SERVER_FAMILY $SERVER_VERSION"
    collect_local_files
    resolve_reader || usage_error 'Neither mysqlbinlog nor mariadb-binlog is available.'
}

read_local_files() {
    local input_file

    for input_file in "${INPUT_FILES[@]}"; do
        "$READER" --base64-output=DECODE-ROWS --verbose "$input_file" >/dev/null \
            || runtime_error "Binlog reader failed for: $input_file"
    done
}

print_local_summary() {
    local input_file

    setup_colors 1
    printf '%bBinlog Activity Report%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$COLOR_RESET"
    printf 'Source: local\n'
    printf 'Server family: %s\n' "$SERVER_FAMILY"
    printf 'Server version: %s\n' "$SERVER_VERSION"
    printf 'Server profile: %s\n' "$PROFILE"
    printf 'Binlog format: %s\n' "$BINLOG_FORMAT"
    printf 'Scope: %s\n' "$SCOPE"
    printf 'Top tables: %s\n' "$TOP_TABLES"
    printf 'Reader: %s\n' "$READER"
    printf 'Input files:\n'
    for input_file in "${INPUT_FILES[@]}"; do
        printf '  %s\n' "$input_file"
    done
}

main() {
    parse_arguments "$@"
    validate_common_arguments

    case "$SOURCE" in
        local)
            validate_local_arguments
            read_local_files
            print_local_summary
            ;;
        remote)
            usage_error 'Remote source support is not available in this implementation stage.'
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
