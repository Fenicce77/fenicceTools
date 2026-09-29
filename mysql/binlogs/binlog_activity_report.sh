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
EVENTS_TEMP_FILE=""

COLOR_BOLD=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RESET=""

setup_colors() {
    local output_fd=${1:-1}

    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
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
    COLOR_GREEN=$'\033[0;32m'
    COLOR_YELLOW=$'\033[0;33m'
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

cleanup_events_temp_file() {
    if [[ -n "$EVENTS_TEMP_FILE" ]]; then
        rm -f "$EVENTS_TEMP_FILE"
        EVENTS_TEMP_FILE=""
    fi
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

normalize_events() {
    local input_file=$1
    local family=$2
    local profile=$3
    local format=$4

    awk -v family="$family" -v profile="$profile" -v format="$format" '
        BEGIN {
            OFS = "\t"
            timestamp = "-"
            position = "-"
            current_schema = "-"
            transaction_id = ""
            in_transaction = 0
            sql_block = ""
            buffered = 0
        }

        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        function normalize_timestamp(date_token, time_token, year) {
            year = substr(date_token, 1, 2) + 0
            year = (year >= 70 ? 1900 : 2000) + year
            return sprintf("%04d-%s-%s %s", year,
                substr(date_token, 3, 2), substr(date_token, 5, 2), time_token)
        }

        function parse_reference(value, first, remainder, separator, count, parts) {
            parsed_schema = ""
            parsed_table = ""
            value = trim(value)

            if (substr(value, 1, 1) == "`") {
                value = substr(value, 2)
                separator = index(value, "`")
                if (separator == 0) {
                    return
                }
                first = substr(value, 1, separator - 1)
                remainder = trim(substr(value, separator + 1))
                if (substr(remainder, 1, 1) == ".") {
                    remainder = trim(substr(remainder, 2))
                    if (substr(remainder, 1, 1) == "`") {
                        remainder = substr(remainder, 2)
                        separator = index(remainder, "`")
                        parsed_schema = first
                        parsed_table = separator > 0 \
                            ? substr(remainder, 1, separator - 1) : remainder
                    } else {
                        split(remainder, parts, /[[:space:](;,]+/)
                        parsed_schema = first
                        parsed_table = parts[1]
                    }
                } else {
                    parsed_table = first
                }
                return
            }

            split(value, parts, /[[:space:](;,]+/)
            count = split(parts[1], reference_parts, /\./)
            if (count > 1) {
                parsed_schema = reference_parts[count - 1]
                parsed_table = reference_parts[count]
            } else {
                parsed_table = parts[1]
            }
            gsub(/`/, "", parsed_schema)
            gsub(/`/, "", parsed_table)
        }

        function print_event(event_timestamp, event_position, event_class,
            operation, event_schema, event_table, event_transaction) {
            if (event_schema == "") {
                event_schema = "-"
            }
            if (event_table == "") {
                event_table = "-"
            }
            if (event_transaction == "") {
                event_transaction = "-"
            }
            print event_timestamp, event_position, event_class, operation,
                event_schema, event_table, event_transaction
        }

        function buffer_event(event_class, operation, event_schema, event_table) {
            buffered++
            event_timestamps[buffered] = timestamp
            event_positions[buffered] = position
            event_classes[buffered] = event_class
            event_operations[buffered] = operation
            event_schemas[buffered] = event_schema
            event_tables[buffered] = event_table
            event_transactions[buffered] = transaction_id
        }

        function flush_events(fallback_transaction, event_index, event_transaction) {
            for (event_index = 1; event_index <= buffered; event_index++) {
                event_transaction = event_transactions[event_index]
                if (event_transaction == "") {
                    event_transaction = fallback_transaction
                }
                print_event(event_timestamps[event_index], event_positions[event_index],
                    event_classes[event_index], event_operations[event_index],
                    event_schemas[event_index], event_tables[event_index], event_transaction)
                delete event_timestamps[event_index]
                delete event_positions[event_index]
                delete event_classes[event_index]
                delete event_operations[event_index]
                delete event_schemas[event_index]
                delete event_tables[event_index]
                delete event_transactions[event_index]
            }
            buffered = 0
        }

        function record_statement(sql, upper_sql, operation, event_class,
            remainder, prefix_length, event_schema, event_table) {
            sql = trim(sql)
            gsub(/[[:space:]]+/, " ", sql)
            gsub(/\/\*!\*\//, "", sql)
            sub(/;[[:space:]]*$/, "", sql)
            upper_sql = toupper(sql)
            operation = ""
            event_class = ""

            if (match(upper_sql, /^INSERT[[:space:]]+(IGNORE[[:space:]]+)?INTO[[:space:]]+/)) {
                operation = "INSERT"
                event_class = "DML"
            } else if (match(upper_sql, /^REPLACE[[:space:]]+(INTO[[:space:]]+)?/)) {
                operation = "REPLACE"
                event_class = "DML"
            } else if (match(upper_sql, /^UPDATE[[:space:]]+/)) {
                operation = "UPDATE"
                event_class = "DML"
            } else if (match(upper_sql, /^DELETE[[:space:]]+FROM[[:space:]]+/)) {
                operation = "DELETE"
                event_class = "DML"
            } else if (match(upper_sql, /^ALTER[[:space:]]+TABLE[[:space:]]+/)) {
                operation = "ALTER"
                event_class = "DDL"
            } else if (match(upper_sql, /^CREATE[[:space:]]+(TEMPORARY[[:space:]]+)?TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?/)) {
                operation = "CREATE"
                event_class = "DDL"
            } else if (match(upper_sql, /^DROP[[:space:]]+(TEMPORARY[[:space:]]+)?TABLE[[:space:]]+(IF[[:space:]]+EXISTS[[:space:]]+)?/)) {
                operation = "DROP"
                event_class = "DDL"
            } else if (match(upper_sql, /^TRUNCATE[[:space:]]+(TABLE[[:space:]]+)?/)) {
                operation = "TRUNCATE"
                event_class = "DDL"
            } else if (match(upper_sql, /^RENAME[[:space:]]+TABLE[[:space:]]+/)) {
                operation = "RENAME"
                event_class = "DDL"
            } else {
                return
            }

            prefix_length = RLENGTH
            remainder = substr(sql, prefix_length + 1)
            parse_reference(remainder)
            event_schema = parsed_schema == "" ? current_schema : parsed_schema
            event_table = parsed_table

            if (in_transaction) {
                buffer_event(event_class, operation, event_schema, event_table)
            } else {
                print_event(timestamp, position, event_class, operation,
                    event_schema, event_table, transaction_id)
            }
        }

        {
            line = $0
            if (line ~ /^[[:space:]]*(###|#Q>)/) {
                next
            }

            header = line
            is_event_header = header ~ /^#[0-9][0-9][0-9][0-9][0-9][0-9][[:space:]]+[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/
            if (is_event_header) {
                sub(/^#/, "", header)
                split(header, header_parts, /[[:space:]]+/)
                timestamp = normalize_timestamp(header_parts[1], header_parts[2])
            }

            if (line ~ /^#[[:space:]]+at[[:space:]]+[0-9]+/) {
                position_value = line
                sub(/^#[[:space:]]+at[[:space:]]+/, "", position_value)
                sub(/[^0-9].*$/, "", position_value)
                position = position_value
                next
            }

            if (line ~ /GTID_NEXT[[:space:]]*=/) {
                gtid_value = line
                sub(/^.*GTID_NEXT[[:space:]]*=[[:space:]]*/, "", gtid_value)
                gsub(/[\047\042]/, "", gtid_value)
                sub(/[[:space:]]*\/\*.*$/, "", gtid_value)
                sub(/;.*$/, "", gtid_value)
                transaction_id = trim(gtid_value)
                next
            }

            if (is_event_header && family == "mariadb" \
                && line ~ /GTID[[:space:]]+[0-9]+-[0-9]+-[0-9]+/) {
                gtid_value = line
                sub(/^.*GTID[[:space:]]+/, "", gtid_value)
                split(gtid_value, gtid_parts, /[[:space:]]+/)
                transaction_id = gtid_parts[1]
            }

            if (is_event_header && line ~ /Table_map:[[:space:]]*/) {
                table_reference = line
                sub(/^.*Table_map:[[:space:]]*/, "", table_reference)
                parse_reference(table_reference)
                table_id = line
                sub(/^.*mapped to number[[:space:]]+/, "", table_id)
                sub(/[^0-9].*$/, "", table_id)
                if (table_id != "") {
                    mapped_schemas[table_id] = parsed_schema
                    mapped_tables[table_id] = parsed_table
                }
                next
            }

            row_operation = ""
            if (is_event_header \
                && line ~ /Write_rows[^:]*:[[:space:]]+table id[[:space:]]+[0-9]+/) {
                row_operation = "INSERT"
            } else if (is_event_header \
                && line ~ /Update_rows[^:]*:[[:space:]]+table id[[:space:]]+[0-9]+/) {
                row_operation = "UPDATE"
            } else if (is_event_header \
                && line ~ /Delete_rows[^:]*:[[:space:]]+table id[[:space:]]+[0-9]+/) {
                row_operation = "DELETE"
            }
            if (row_operation != "") {
                table_id = line
                sub(/^.*table id[[:space:]]+/, "", table_id)
                sub(/[^0-9].*$/, "", table_id)
                buffer_event("DML", row_operation,
                    mapped_schemas[table_id], mapped_tables[table_id])
                next
            }

            if (is_event_header && line ~ /Xid[[:space:]]*=[[:space:]]*[0-9]+/) {
                xid_value = line
                sub(/^.*Xid[[:space:]]*=[[:space:]]*/, "", xid_value)
                sub(/[^0-9].*$/, "", xid_value)
                flush_events("XID:" xid_value)
                transaction_id = ""
                in_transaction = 0
                next
            }

            trimmed_line = trim(line)
            upper_line = toupper(trimmed_line)

            if (upper_line ~ /^BEGIN([[:space:];]|\/)/) {
                in_transaction = 1
                next
            }
            if (upper_line ~ /^COMMIT([[:space:];]|\/)/) {
                flush_events(transaction_id)
                transaction_id = ""
                in_transaction = 0
                next
            }
            if (upper_line ~ /^USE[[:space:]]+/) {
                schema_value = trimmed_line
                sub(/^[Uu][Ss][Ee][[:space:]]+/, "", schema_value)
                sub(/\/\*!\*\/;.*$/, "", schema_value)
                sub(/;.*$/, "", schema_value)
                gsub(/`/, "", schema_value)
                current_schema = trim(schema_value)
                next
            }

            if (sql_block != "") {
                sql_block = sql_block " " trimmed_line
                if (line ~ /\/\*!\*\/;/ || line ~ /;[[:space:]]*$/) {
                    record_statement(sql_block)
                    sql_block = ""
                }
                next
            }

            if (upper_line ~ /^(INSERT|REPLACE|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|RENAME)[[:space:]]/) {
                sql_block = trimmed_line
                if (line ~ /\/\*!\*\/;/ || line ~ /;[[:space:]]*$/) {
                    record_statement(sql_block)
                    sql_block = ""
                }
            }
        }

        END {
            if (sql_block != "") {
                record_statement(sql_block)
            }
            flush_events(transaction_id)
        }
    ' "$input_file"
}

read_local_files() {
    local output_file=$1
    local input_file

    : > "$output_file"

    for input_file in "${INPUT_FILES[@]}"; do
        if ! "$READER" --base64-output=DECODE-ROWS --verbose "$input_file" \
            | normalize_events /dev/stdin "$SERVER_FAMILY" "$PROFILE" "$BINLOG_FORMAT" \
                >> "$output_file"; then
            runtime_error "Binlog reader failed for: $input_file"
        fi
    done
}

operation_color() {
    case "$1" in
        INSERT|REPLACE) printf '%s' "$COLOR_GREEN" ;;
        UPDATE) printf '%s' "$COLOR_YELLOW" ;;
        DELETE) printf '%s' "$COLOR_RED" ;;
        CREATE|ALTER|DROP|TRUNCATE|RENAME) printf '%s' "$COLOR_CYAN" ;;
        *) printf '%s' "$COLOR_RESET" ;;
    esac
}

render_activity_report() {
    local events_file=$1
    local timestamp position event_class operation schema table transaction color class_scope

    setup_colors 1
    printf '\nActivity events:\n'
    while IFS=$'\t' read -r timestamp position event_class operation schema table transaction; do
        [[ -n "$timestamp" ]] || continue
        case "$event_class" in
            DML) class_scope=dml ;;
            DDL) class_scope=ddl ;;
            *) class_scope=unknown ;;
        esac
        if [[ "$SCOPE" != all && "$SCOPE" != "$class_scope" ]]; then
            continue
        fi
        color=$(operation_color "$operation")
        printf '%s  %s  %s  %b%s%b  %s.%s  %s\n' \
            "$timestamp" "$position" "$event_class" "$color" "$operation" \
            "$COLOR_RESET" "$schema" "$table" "$transaction"
    done < "$events_file"

    printf '\nTop tables by event count:\n'
    awk -v scope="$SCOPE" '
        BEGIN { FS = "\t" }
        scope == "all" || tolower($3) == scope {
            counts[$5 "." $6]++
        }
        END {
            for (table_name in counts) {
                print counts[table_name] "\t" table_name
            }
        }
    ' "$events_file" \
        | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 \
        | awk -F $'\t' -v limit="$TOP_TABLES" \
            'NR <= limit { printf "%d  %s\n", $1, $2 }'
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
            EVENTS_TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/binlog-activity-report.XXXXXX") \
                || runtime_error 'Unable to create temporary event file.'
            trap cleanup_events_temp_file EXIT
            read_local_files "$EVENTS_TEMP_FILE"
            print_local_summary
            render_activity_report "$EVENTS_TEMP_FILE"
            cleanup_events_temp_file
            trap - EXIT
            ;;
        remote)
            usage_error 'Remote source support is not available in this implementation stage.'
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
