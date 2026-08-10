#!/usr/bin/env bash
# MySQL Foreign Key Topology Analyzer.
# Read-only metadata analyzer compatible with Bash 3.2 on macOS and Linux.
set -euo pipefail

CARDINALITY_MODE=metadata
SHOW_TREE=false
PHYSICAL_ONLY=false
ALLOW_PRODUCTION=false
OUTPUT_FILE=""
OUTPUT_FORMAT=""
TERMINAL_WIDTH_OPTION=""
TERMINAL_WIDTH_OPTION_SET=false
NO_COLOR=false
WORK_DIR=""
EXPORT_TEMP=""
FINAL_STATUS=0

LOGIN_PATH=""
SCHEMA_NAME=""
TABLE_NAME=""
ENVIRONMENT=""
MYSQL_BIN_OPTION=""
MYSQL_BIN_OPTION_SET=false
OUTPUT_FILE_SET=false
OUTPUT_FORMAT_SET=false
TERMINAL_WIDTH=""
TARGET_ENGINE=""

COLOR_BOLD=""
COLOR_CYAN=""
COLOR_RESET=""

cli_error() {
    printf 'ERROR: %s\nTry --help for usage.\n' "$1" >&2
    exit 2
}

runtime_error() {
    local status=$1
    shift
    printf 'ERROR: %s\n' "$*" >&2
    exit "$status"
}

setup_colors() {
    if [[ "$NO_COLOR" == false && -t 1 && "${TERM:-}" != "dumb" ]]; then
        COLOR_BOLD=$'\033[1m'
        COLOR_CYAN=$'\033[0;36m'
        COLOR_RESET=$'\033[0m'
    fi
}

usage() {
    setup_colors
    printf '%bMySQL Foreign Key Topology Analyzer%b\n' "${COLOR_BOLD}${COLOR_CYAN}" "$COLOR_RESET"
    printf '\nUsage:\n'
    printf '  %s -l NAME -s SCHEMA -t TABLE --environment ENVIRONMENT [options]\n' "${0##*/}"
    printf '\nRequired options:\n'
    printf '  -l, --login-path NAME                 MySQL login path\n'
    printf '  -s, --schema NAME                     Target schema\n'
    printf '  -t, --table NAME                      Target table\n'
    printf '      --environment ENVIRONMENT          development, test, staging, or production\n'
    printf '\nAnalysis options:\n'
    printf '  -r, --tree                            Append the dependency tree\n'
    printf '  -c                                    Compatibility mode; select metadata cardinality\n'
    printf '      --cardinality MODE                 metadata or exact\n'
    printf '      --physical-only                    Disable virtual relationship inference\n'
    printf '      --allow-production                 Required only for exact production cardinality\n'
    printf '\nOutput and client options:\n'
    printf '      --output-file FILE                 Write a CSV or TSV report\n'
    printf '      --format FORMAT                    csv or tsv\n'
    printf '      --terminal-width COLUMNS           Width from 120 through 10000\n'
    printf '      --mysql-bin PATH                   MySQL client executable\n'
    printf '      --no-color                         Disable ANSI color sequences\n'
    printf '  -h, --help                            Show this help\n'
    printf '\nVirtual relationship rules:\n'
    printf '  Virtual candidates use exact primary-key names or <table>_<primary-key>.\n'
    printf '  A leading id column alone never starts a virtual relationship.\n'
    printf '\nExit status:\n'
    printf '  0 success; 2 command-line validation; 3 client or preflight failure; 4 degraded analysis.\n'
    printf '\nExamples:\n'
    printf '  %s -l reporting -s sales -t orders --environment test\n' "${0##*/}"
    printf '  %s --login-path=prod --schema=sales --table=orders --environment=production --cardinality=exact --allow-production\n' "${0##*/}"
}

parse_arguments() {
    local argument

    NO_COLOR=false
    for argument in "$@"; do
        if [[ "$argument" == "--no-color" ]]; then
            NO_COLOR=true
            break
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--login-path)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                LOGIN_PATH=$2
                shift 2
                ;;
            --login-path=*)
                LOGIN_PATH=${1#--login-path=}
                shift
                ;;
            -s|--schema)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                SCHEMA_NAME=$2
                shift 2
                ;;
            --schema=*)
                SCHEMA_NAME=${1#--schema=}
                shift
                ;;
            -t|--table)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                TABLE_NAME=$2
                shift 2
                ;;
            --table=*)
                TABLE_NAME=${1#--table=}
                shift
                ;;
            --environment)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                ENVIRONMENT=$2
                shift 2
                ;;
            --environment=*)
                ENVIRONMENT=${1#--environment=}
                shift
                ;;
            -r|--tree)
                SHOW_TREE=true
                shift
                ;;
            -c)
                CARDINALITY_MODE=metadata
                shift
                ;;
            --cardinality)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                CARDINALITY_MODE=$2
                shift 2
                ;;
            --cardinality=*)
                CARDINALITY_MODE=${1#--cardinality=}
                shift
                ;;
            --physical-only)
                PHYSICAL_ONLY=true
                shift
                ;;
            --allow-production)
                ALLOW_PRODUCTION=true
                shift
                ;;
            --output-file)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                OUTPUT_FILE=$2
                OUTPUT_FILE_SET=true
                shift 2
                ;;
            --output-file=*)
                OUTPUT_FILE=${1#--output-file=}
                OUTPUT_FILE_SET=true
                shift
                ;;
            --format)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                OUTPUT_FORMAT=$2
                OUTPUT_FORMAT_SET=true
                shift 2
                ;;
            --format=*)
                OUTPUT_FORMAT=${1#--format=}
                OUTPUT_FORMAT_SET=true
                shift
                ;;
            --terminal-width)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                TERMINAL_WIDTH_OPTION=$2
                TERMINAL_WIDTH_OPTION_SET=true
                shift 2
                ;;
            --terminal-width=*)
                TERMINAL_WIDTH_OPTION=${1#--terminal-width=}
                TERMINAL_WIDTH_OPTION_SET=true
                shift
                ;;
            --mysql-bin)
                [[ $# -ge 2 ]] || cli_error "$1 requires a value."
                MYSQL_BIN_OPTION=$2
                MYSQL_BIN_OPTION_SET=true
                shift 2
                ;;
            --mysql-bin=*)
                MYSQL_BIN_OPTION=${1#--mysql-bin=}
                MYSQL_BIN_OPTION_SET=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                usage
                return 1
                ;;
            *)
                cli_error "Unknown option: $1"
                ;;
        esac
    done
}

validate_identifier() {
    local value=$1
    local option_name=$2

    [[ ${#value} -le 64 ]] || cli_error "$option_name must be 1 to 64 characters."
    [[ "$value" != *' ' ]] || cli_error "$option_name must not end with an ASCII space."
    if LC_ALL=C printf '%s' "$value" | LC_ALL=C od -v -An -tu1 | awk '{ for (i = 1; i <= NF; i++) if ($i < 32 || $i == 127) { found = 1; exit } } END { exit(found ? 0 : 1) }'; then
        cli_error "$option_name must not contain control characters."
    fi
}

validate_terminal_width() {
    local value=$1
    local normalized

    [[ "$value" =~ ^[0-9]+$ ]] || cli_error '--terminal-width must be an integer from 120 through 10000.'
    normalized=$(printf '%s' "$value" | sed 's/^0*//')
    [[ -n "$normalized" ]] || normalized=0

    if [[ ${#normalized} -gt 5 ]] || \
       [[ ${#normalized} -eq 5 && "$normalized" > "10000" ]] || \
       [[ ${#normalized} -lt 3 ]]; then
        cli_error '--terminal-width must be an integer from 120 through 10000.'
    fi
    if [[ ${#normalized} -eq 3 && "$normalized" < "120" ]]; then
        cli_error '--terminal-width must be an integer from 120 through 10000.'
    fi

    TERMINAL_WIDTH=$normalized
}

validate_arguments() {
    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
    [[ -n "$SCHEMA_NAME" ]] || cli_error '--schema is required.'
    [[ -n "$TABLE_NAME" ]] || cli_error '--table is required.'
    [[ -n "$ENVIRONMENT" ]] || cli_error '--environment is required.'

    case "$ENVIRONMENT" in
        development|test|staging|production) ;;
        *) cli_error '--environment must be development, test, staging, or production.' ;;
    esac
    case "$CARDINALITY_MODE" in
        metadata|exact) ;;
        *) cli_error '--cardinality must be metadata or exact.' ;;
    esac
    case "$OUTPUT_FORMAT" in
        ""|csv|tsv) ;;
        *) cli_error '--format must be csv or tsv.' ;;
    esac

    [[ "$OUTPUT_FILE_SET" == false || -n "$OUTPUT_FILE" ]] || cli_error '--output-file must not be empty.'
    [[ "$OUTPUT_FORMAT_SET" == false || -n "$OUTPUT_FORMAT" ]] || cli_error '--format must not be empty.'
    [[ "$TERMINAL_WIDTH_OPTION_SET" == false || -n "$TERMINAL_WIDTH_OPTION" ]] || cli_error '--terminal-width must not be empty.'
    [[ "$MYSQL_BIN_OPTION_SET" == false || -n "$MYSQL_BIN_OPTION" ]] || cli_error '--mysql-bin must not be empty.'

    validate_identifier "$SCHEMA_NAME" '--schema'
    validate_identifier "$TABLE_NAME" '--table'

    if [[ "$TERMINAL_WIDTH_OPTION_SET" == true ]]; then
        validate_terminal_width "$TERMINAL_WIDTH_OPTION"
    fi

    if [[ "$ENVIRONMENT" == production && "$CARDINALITY_MODE" == exact ]]; then
        [[ "$ALLOW_PRODUCTION" == true ]] || cli_error 'Exact cardinality in production requires --allow-production.'
    elif [[ "$ALLOW_PRODUCTION" == true ]]; then
        cli_error '--allow-production is valid only with --environment production --cardinality exact.'
    fi
}

sql_literal() {
    printf 'CONVERT(0x'
    LC_ALL=C printf '%s' "$1" | LC_ALL=C od -v -An -tx1 | tr -d ' \n'
    printf ' USING utf8mb4)'
}

quote_identifier() {
    local identifier=$1
    identifier=${identifier//\`/\`\`}
    printf '`%s`' "$identifier"
}

cleanup() {
    local workspace_prefix="${TMPDIR:-/tmp}/fk-analyzer."

    case "${WORK_DIR:-}" in
        "${workspace_prefix}"*)
            [[ -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
            ;;
    esac
    WORK_DIR=""
    EXPORT_TEMP=""
    return 0
}

create_workspace() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fk-analyzer.XXXXXX") || runtime_error 3 'Unable to create temporary workspace.'
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT TERM
}

resolve_mysql_bin() {
    local candidate=""

    if [[ -n "$MYSQL_BIN_OPTION" ]]; then
        candidate=$MYSQL_BIN_OPTION
    elif [[ -n "${MYSQL_BIN:-}" ]]; then
        candidate=$MYSQL_BIN
    else
        candidate=$(command -v mysql 2>/dev/null || true)
    fi

    [[ -n "$candidate" && -x "$candidate" ]] || runtime_error 3 'Unable to resolve an executable MySQL client.'
    MYSQL_BIN=$candidate
}

run_mysql_query() {
    local query=$1

    "$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --skip-column-names --raw -e "$query"
}

sanitize_stderr() {
    local stderr_file=$1
    local message

    message=$(LC_ALL=C tr '\r\n' '  ' < "$stderr_file" | LC_ALL=C tr -d '[:cntrl:]')
    message=${message:0:240}
    printf '%s' "$message"
}

connection_preflight() {
    local stderr_file="$WORK_DIR/connection.stderr"
    local result
    local diagnostic
    local query='SELECT /* fk-analyzer:connection */ VERSION(), @@innodb_buffer_pool_size;'

    if ! result=$(run_mysql_query "$query" 2> "$stderr_file"); then
        diagnostic=$(sanitize_stderr "$stderr_file")
        [[ -n "$diagnostic" ]] || diagnostic='no diagnostic returned by the MySQL client'
        runtime_error 3 "MySQL connection preflight failed: $diagnostic"
    fi
    [[ -n "$result" ]] || runtime_error 3 'MySQL connection preflight returned no data.'
}

target_preflight() {
    local stderr_file="$WORK_DIR/target.stderr"
    local result
    local diagnostic
    local schema_literal
    local table_literal
    local target_table
    local target_engine
    local extra
    local query

    schema_literal=$(sql_literal "$SCHEMA_NAME")
    table_literal=$(sql_literal "$TABLE_NAME")
    query="SELECT /* fk-analyzer:target */ TABLE_NAME, ENGINE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ${schema_literal}
  AND TABLE_NAME = ${table_literal}
  AND TABLE_TYPE = 0x42415345205441424C45;"

    if ! result=$(run_mysql_query "$query" 2> "$stderr_file"); then
        diagnostic=$(sanitize_stderr "$stderr_file")
        [[ -n "$diagnostic" ]] || diagnostic='no diagnostic returned by the MySQL client'
        runtime_error 3 "MySQL target preflight failed: $diagnostic"
    fi
    [[ -n "$result" && "$result" != *$'\n'* ]] || runtime_error 3 'Target table preflight did not find exactly one base table.'
    IFS=$'\t' read -r target_table target_engine extra <<< "$result"
    [[ -n "$target_table" && -n "$target_engine" && -z "$extra" ]] || runtime_error 3 'Target table preflight did not find exactly one base table.'
    TARGET_ENGINE=$target_engine
}

run_metadata_query() {
    local label=$1
    local query=$2
    local output_file=$3
    local stderr_file="$WORK_DIR/${label}.stderr"
    local diagnostic

    if ! run_mysql_query "$query" > "$output_file" 2> "$stderr_file"; then
        diagnostic=$(sanitize_stderr "$stderr_file")
        [[ -n "$diagnostic" ]] || diagnostic='no diagnostic returned by the MySQL client'
        runtime_error 3 "MySQL metadata query (${label}) failed: $diagnostic"
    fi
}

acquire_metadata() {
    local schema_literal
    local table_literal
    local query

    schema_literal=$(sql_literal "$SCHEMA_NAME")
    table_literal=$(sql_literal "$TABLE_NAME")

    query="SELECT /* fk-analyzer:columns */ TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
       ORDINAL_POSITION, COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = ${schema_literal}
ORDER BY TABLE_NAME, ORDINAL_POSITION;"
    run_metadata_query columns "$query" "$WORK_DIR/columns.tsv"

    query="SELECT /* fk-analyzer:pks */ kcu.CONSTRAINT_SCHEMA, kcu.TABLE_NAME,
       kcu.COLUMN_NAME, kcu.ORDINAL_POSITION
FROM information_schema.KEY_COLUMN_USAGE AS kcu
JOIN information_schema.TABLE_CONSTRAINTS AS tc
  ON tc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
 AND tc.TABLE_NAME = kcu.TABLE_NAME
 AND tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
WHERE kcu.CONSTRAINT_SCHEMA = ${schema_literal}
  AND tc.CONSTRAINT_TYPE = 0x5052494D415259204B4559
ORDER BY kcu.TABLE_NAME, kcu.ORDINAL_POSITION;"
    run_metadata_query pks "$query" "$WORK_DIR/pks.tsv"

    query="SELECT /* fk-analyzer:physical */ kcu.CONSTRAINT_NAME, kcu.CONSTRAINT_SCHEMA,
       kcu.TABLE_NAME, kcu.COLUMN_NAME, kcu.REFERENCED_TABLE_SCHEMA,
       kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME,
       kcu.ORDINAL_POSITION, rc.UPDATE_RULE, rc.DELETE_RULE
FROM information_schema.KEY_COLUMN_USAGE AS kcu
JOIN information_schema.REFERENTIAL_CONSTRAINTS AS rc
  ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
 AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
 AND rc.TABLE_NAME = kcu.TABLE_NAME
WHERE kcu.CONSTRAINT_SCHEMA = ${schema_literal}
  AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
  AND (kcu.TABLE_NAME = ${table_literal}
       OR (kcu.REFERENCED_TABLE_SCHEMA = ${schema_literal}
           AND kcu.REFERENCED_TABLE_NAME = ${table_literal}))
ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION;"
    run_metadata_query physical "$query" "$WORK_DIR/physical-components.tsv"

    query="SELECT /* fk-analyzer:indexes */ TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
       NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, CARDINALITY
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = ${schema_literal}
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;"
    run_metadata_query indexes "$query" "$WORK_DIR/indexes.tsv"

    query="SELECT /* fk-analyzer:stats */ TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ${schema_literal}
  AND TABLE_NAME = ${table_literal};"
    run_metadata_query stats "$query" "$WORK_DIR/stats.tsv"
}

build_physical_relations() {
    local physical_file="$WORK_DIR/physical-components.tsv"
    local indexes_file="$WORK_DIR/indexes.tsv"

    awk -F '\t' -v OFS='\t' -v physical_file="$physical_file" \
        -v selected_schema="$SCHEMA_NAME" -v selected_table="$TABLE_NAME" '
        FILENAME == physical_file {
            if (!(($2 == selected_schema && $3 == selected_table) ||
                  ($5 == selected_schema && $6 == selected_table))) {
                next
            }
            key = $2 SUBSEP $1 SUBSEP $3 SUBSEP $5 SUBSEP $6
            if (!(key in relation_seen)) {
                relation_seen[key] = 1
                relation_order[++relation_count] = key
                constraint_name[key] = $1
                source_schema[key] = $2
                source_table[key] = $3
                target_schema[key] = $5
                target_table[key] = $6
                update_rule[key] = $9
                delete_rule[key] = $10
            }
            source_column[key, $8] = $4
            target_column[key, $8] = $7
            if (($8 + 0) > ordinal_max[key]) {
                ordinal_max[key] = $8 + 0
            }
            next
        }
        {
            index_key = $1 SUBSEP $2 SUBSEP $3
            if (!(index_key in index_seen)) {
                index_seen[index_key] = 1
                index_order[++index_count] = index_key
            }
            index_column[index_key, $5] = $6
        }
        END {
            for (relation_number = 1; relation_number <= relation_count; relation_number++) {
                key = relation_order[relation_number]
                source_tuple = "("
                target_tuple = "("
                for (ordinal = 1; ordinal <= ordinal_max[key]; ordinal++) {
                    if (ordinal > 1) {
                        source_tuple = source_tuple ", "
                        target_tuple = target_tuple ", "
                    }
                    source_tuple = source_tuple source_column[key, ordinal]
                    target_tuple = target_tuple target_column[key, ordinal]
                }
                source_tuple = source_tuple ")"
                target_tuple = target_tuple ")"

                supporting_index = ""
                for (index_number = 1; index_number <= index_count; index_number++) {
                    index_key = index_order[index_number]
                    split(index_key, index_parts, SUBSEP)
                    if (index_parts[1] != source_schema[key] || index_parts[2] != source_table[key]) {
                        continue
                    }
                    matches = 1
                    for (ordinal = 1; ordinal <= ordinal_max[key]; ordinal++) {
                        if (index_column[index_key, ordinal] != source_column[key, ordinal]) {
                            matches = 0
                            break
                        }
                    }
                    if (matches) {
                        supporting_index = index_parts[3]
                        break
                    }
                }

                status_tags = (supporting_index == "" ? "UNINDEXED" : "")
                direction = (source_schema[key] == selected_schema && source_table[key] == selected_table ? "OUTBOUND" : "INBOUND")
                details = "ON UPDATE " update_rule[key] "; ON DELETE " delete_rule[key]
                print direction, "PHYSICAL_FK", source_schema[key], source_table[key], source_tuple,
                    target_schema[key], target_table[key], target_tuple, constraint_name[key],
                    supporting_index, status_tags, details
            }
        }
    ' "$physical_file" "$indexes_file" > "$WORK_DIR/relations.tsv"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        return 0
    fi

    if ! parse_arguments "$@"; then
        return 0
    fi
    validate_arguments
    create_workspace
    resolve_mysql_bin
    connection_preflight
    target_preflight
    acquire_metadata
    build_physical_relations

    printf 'Target preflight succeeded: %s.%s (%s)\n' "$SCHEMA_NAME" "$TABLE_NAME" "$TARGET_ENGINE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
