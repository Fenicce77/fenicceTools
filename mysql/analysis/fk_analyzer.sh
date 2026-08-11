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
REPORT_ELIGIBLE=true
PHYSICAL_AVAILABLE=true
VIRTUAL_METADATA_AVAILABLE=true
STATS_AVAILABLE=true
EXACT_AVAILABLE=false
ACTIVE_CHILD_PID=""

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
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_MAGENTA=""
COLOR_RED=""
COLOR_BLUE=""
COLOR_BOLD_YELLOW=""
COLOR_DIM_CYAN=""
COLOR_DIM=""
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
    COLOR_BOLD=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_MAGENTA=""
    COLOR_RED=""
    COLOR_BLUE=""
    COLOR_BOLD_YELLOW=""
    COLOR_DIM_CYAN=""
    COLOR_DIM=""
    COLOR_RESET=""
    if [[ "$NO_COLOR" == false && -t 1 && "${TERM:-}" != "dumb" ]]; then
        COLOR_BOLD=$'\033[1m'
        COLOR_CYAN=$'\033[0;36m'
        COLOR_GREEN=$'\033[0;32m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_MAGENTA=$'\033[0;35m'
        COLOR_RED=$'\033[0;31m'
        COLOR_BLUE=$'\033[0;34m'
        COLOR_BOLD_YELLOW=$'\033[1;33m'
        COLOR_DIM_CYAN=$'\033[2;36m'
        COLOR_DIM=$'\033[2m'
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
        TERMINAL_WIDTH_OPTION=$TERMINAL_WIDTH
    fi

    if [[ "$ENVIRONMENT" == production && "$CARDINALITY_MODE" == exact ]]; then
        [[ "$ALLOW_PRODUCTION" == true ]] || cli_error 'Exact cardinality in production requires --allow-production.'
    elif [[ "$ALLOW_PRODUCTION" == true ]]; then
        cli_error '--allow-production is valid only with --environment production --cardinality exact.'
    fi
}

normalize_detected_terminal_width() {
    local value=$1
    local normalized

    DETECTED_TERMINAL_WIDTH=""
    [[ "$value" =~ ^[0-9]+$ && ${#value} -le 16 ]] || return 1
    normalized=$(printf '%s' "$value" | sed 's/^0*//')
    [[ -n "$normalized" ]] || normalized=0
    if [[ ${#normalized} -gt 5 ]] || \
       [[ ${#normalized} -eq 5 && "$normalized" != "10000" ]] || \
       [[ ${#normalized} -lt 3 ]] || \
       [[ ${#normalized} -eq 3 && "$normalized" < "120" ]]; then
        return 1
    fi
    DETECTED_TERMINAL_WIDTH=$normalized
}

read_stty_columns() {
    local size=""
    local rows=""

    DETECTED_COLUMNS=""
    if [[ -t 0 ]]; then
        size=$(stty size 2>/dev/null || true)
    elif [[ -t 1 ]]; then
        size=$(stty size 2>/dev/null </dev/tty || true)
    fi
    if [[ -n "$size" ]]; then
        read -r rows DETECTED_COLUMNS <<EOF
$size
EOF
    fi
}

detect_terminal_width() {
    local cols=""

    TERMINAL_WIDTH=120
    if [[ "$TERMINAL_WIDTH_OPTION_SET" == true ]]; then
        TERMINAL_WIDTH=$TERMINAL_WIDTH_OPTION
        return 0
    fi

    cols=${COLUMNS:-}
    if normalize_detected_terminal_width "$cols"; then
        TERMINAL_WIDTH=$DETECTED_TERMINAL_WIDTH
        return 0
    fi

    read_stty_columns
    if normalize_detected_terminal_width "$DETECTED_COLUMNS"; then
        TERMINAL_WIDTH=$DETECTED_TERMINAL_WIDTH
        return 0
    fi

    if [[ -t 0 || -t 1 ]]; then
        cols=$(tput cols 2>/dev/null || true)
        if normalize_detected_terminal_width "$cols"; then
            TERMINAL_WIDTH=$DETECTED_TERMINAL_WIDTH
        fi
    fi
}

classification_color() {
    case "$1" in
        PHYSICAL_FK) FIELD_COLOR=$COLOR_CYAN ;;
        COMPLETE_VIRTUAL_FK) FIELD_COLOR=$COLOR_GREEN ;;
        PARTIAL_VIRTUAL_FK) FIELD_COLOR=$COLOR_YELLOW ;;
        AMBIGUOUS_VIRTUAL_FK) FIELD_COLOR=$COLOR_MAGENTA ;;
        *) FIELD_COLOR=$COLOR_RED ;;
    esac
}

relation_status() {
    local classification=$1
    local tags=$2

    if [[ "$tags" == *ERROR* ]]; then
        RELATION_STATUS=ERROR
        STATUS_COLOR=$COLOR_RED
    elif [[ "$classification" == PHYSICAL_FK || "$classification" == COMPLETE_VIRTUAL_FK ]]; then
        if [[ -n "$tags" ]]; then
            RELATION_STATUS=WARNING
            STATUS_COLOR=$COLOR_YELLOW
        else
            RELATION_STATUS=OK
            STATUS_COLOR=$COLOR_GREEN
        fi
    else
        RELATION_STATUS=WARNING
        STATUS_COLOR=$COLOR_YELLOW
    fi
}

wrap_relation_fields() {
    local source_value=$1
    local target_value=$2
    local details_value=$3
    local source_width=$4
    local target_width=$5
    local details_width=$6

    WRAPPED_RELATION_FIELDS=$(printf '%s\t%s\t%s\n' \
        "$source_value" "$target_value" "$details_value" | LC_ALL=C awk -F '\t' \
        -v source_width="$source_width" \
        -v target_width="$target_width" \
        -v details_width="$details_width" '
        function clear(values, key) {
            for (key in values) delete values[key]
        }
        function wrap(value, width, values, starts, count, rest, rest_start, cut, position, character) {
            clear(values)
            clear(starts)
            count = 0
            rest = value
            rest_start = 1
            if (rest == "") {
                values[++count] = ""
                starts[count] = rest_start
                return count
            }
            while (length(rest) > width) {
                cut = width
                for (position = width; position > 1; position--) {
                    character = substr(rest, position, 1)
                    if (character == " " || character == "," || character == ";" ||
                        character == "/" || character == "." || character == "_") {
                        cut = position
                        break
                    }
                }
                values[++count] = substr(rest, 1, cut)
                starts[count] = rest_start
                rest = substr(rest, cut + 1)
                rest_start += cut
            }
            values[++count] = rest
            starts[count] = rest_start
            return count
        }
        {
            source_count = wrap($1, source_width, source_lines, source_starts)
            target_count = wrap($2, target_width, target_lines, target_starts)
            details_count = wrap($3, details_width, details_lines, details_starts)
            line_count = source_count
            if (target_count > line_count) line_count = target_count
            if (details_count > line_count) line_count = details_count
            for (line = 1; line <= line_count; line++) {
                printf "%s%c%s%c%s%c%s\n", source_lines[line], 28,
                    target_lines[line], 28, details_lines[line], 28, details_starts[line]
            }
        }
    ')
}

repeat_table_character() {
    local count=$1
    local character=$2

    REPEATED_TABLE_CHARACTER=$(LC_ALL=C awk -v count="$count" -v character="$character" '
        BEGIN { for (n = 0; n < count; n++) printf "%s", character }
    ')
}

calculate_relation_widths() {
    local dynamic_budget

    DIRECTION_WIDTH=9
    CLASSIFICATION_WIDTH=20
    STATUS_WIDTH=7
    # At the 120-column minimum, each wrap-capable field receives at least
    # 23 columns. Wider terminals distribute additional columns evenly.
    dynamic_budget=$((TERMINAL_WIDTH - DIRECTION_WIDTH - CLASSIFICATION_WIDTH - STATUS_WIDTH - 15))
    SOURCE_WIDTH=$((dynamic_budget / 3))
    TARGET_WIDTH=$((dynamic_budget / 3))
    DETAILS_WIDTH=$((dynamic_budget - SOURCE_WIDTH - TARGET_WIDTH))
}

append_relation_detail() {
    local value=$1

    [[ -n "$value" ]] || return 0
    if [[ -n "$RELATION_DETAILS" ]]; then
        RELATION_DETAILS="$RELATION_DETAILS; $value"
    else
        RELATION_DETAILS=$value
    fi
}

color_relation_detail_names() {
    local line_details=$1
    local line_offset=$2
    local details=$3
    local constraint_name=$4
    local supporting_index=$5
    local details_color=$6

    COLORED_RELATION_DETAILS=$(printf '%s\034%s\034%s\034%s\034%s\034%s\n' \
        "$line_details" "$details" "$line_offset" "$constraint_name" "$supporting_index" "$details_color" | \
        LC_ALL=C awk -F $'\034' \
        -v blue="$COLOR_BLUE" \
        -v reset="$COLOR_RESET" '
        function segment_start(marker, name, position) {
            if (name == "") return 0
            position = index(details, marker name)
            return position == 0 ? 0 : position + length(marker)
        }
        function print_segment(value, start, segment_length, line_start, line_end,
                               overlap_start, overlap_end, cursor) {
            overlap_start = (start > line_start ? start : line_start)
            overlap_end = (start + segment_length - 1 < line_end ? start + segment_length - 1 : line_end)
            if (overlap_start > overlap_end) return line_start
            cursor = overlap_start - line_start + 1
            printf "%s%s%s%s", blue, substr(value, cursor, overlap_end - overlap_start + 1), reset, resume
            return overlap_end + 1
        }
        {
            value = $1
            details = $2
            line_start = $3 + 0
            constraint_name = $4
            supporting_index = $5
            resume = $6
            line_end = line_start + length(value) - 1
            constraint_start = segment_start("constraint=", constraint_name)
            index_start = segment_start("index=", supporting_index)
            cursor = line_start
            for (segment = 1; segment <= 2; segment++) {
                if (constraint_start != 0 &&
                    (index_start == 0 || constraint_start < index_start)) {
                    start = constraint_start
                    name_length = length(constraint_name)
                    constraint_start = 0
                } else if (index_start != 0) {
                    start = index_start
                    name_length = length(supporting_index)
                    index_start = 0
                } else {
                    break
                }
                overlap_start = (start > line_start ? start : line_start)
                overlap_end = (start + name_length - 1 < line_end ? start + name_length - 1 : line_end)
                if (overlap_start <= overlap_end) {
                    printf "%s", substr(value, cursor - line_start + 1, overlap_start - cursor)
                    cursor = print_segment(value, start, name_length, line_start, line_end)
                }
            }
            printf "%s", substr(value, cursor - line_start + 1)
        }
    ')
}

render_relation_line() {
    local direction=$1
    local classification=$2
    local source=$3
    local target=$4
    local status=$5
    local details=$6
    local direction_color=$7
    local classification_field_color=$8
    local target_field_color=$9
    local status_field_color=${10}
    local details_color=${11}
    local colored_details=${12:-$details}
    local detail_padding=$((DETAILS_WIDTH - ${#details}))

    if [[ "$detail_padding" -lt 0 ]]; then
        detail_padding=0
    fi

    printf '%s%-*s%s | %s%-*s%s | %s%-*s%s | %s%-*s%s | %s%-*s%s | ' \
        "$direction_color" "$DIRECTION_WIDTH" "$direction" "$COLOR_RESET" \
        "$classification_field_color" "$CLASSIFICATION_WIDTH" "$classification" "$COLOR_RESET" \
        "" "$SOURCE_WIDTH" "$source" "$COLOR_RESET" \
        "$target_field_color" "$TARGET_WIDTH" "$target" "$COLOR_RESET" \
        "$status_field_color" "$STATUS_WIDTH" "$status" "$COLOR_RESET"
    printf '%s%s%*s%s\n' "$details_color" "$colored_details" "$detail_padding" '' "$COLOR_RESET"
}

filter_relation_section() {
    local relations_file=$1
    local section=$2
    local relation_field_separator=$'\034'

    case "$section" in
        physical_outbound)
            LC_ALL=C awk -F '\t' -v OFS="$relation_field_separator" \
                '$1 == "OUTBOUND" && $2 == "PHYSICAL_FK" { print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' "$relations_file"
            ;;
        physical_inbound)
            LC_ALL=C awk -F '\t' -v OFS="$relation_field_separator" \
                '$1 == "INBOUND" && $2 == "PHYSICAL_FK" { print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' "$relations_file"
            ;;
        complete_virtual)
            LC_ALL=C awk -F '\t' -v OFS="$relation_field_separator" \
                '$2 == "COMPLETE_VIRTUAL_FK" { print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' "$relations_file"
            ;;
        partial_ambiguous_virtual)
            LC_ALL=C awk -F '\t' -v OFS="$relation_field_separator" \
                '$2 == "PARTIAL_VIRTUAL_FK" || $2 == "AMBIGUOUS_VIRTUAL_FK" { print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' "$relations_file"
            ;;
    esac
}

render_relation_section() {
    local relations_file=$1
    local section_title=$2
    local section=$3
    local direction classification source_schema source_table source_columns
    local target_schema target_table target_columns constraint_name supporting_index
    local status_tags details source_value target_value line_source line_target line_details line_details_offset
    local relation_field_separator=$'\034'
    local separator_line
    local continuation
    local details_color
    local found=false

    repeat_table_character "$DIRECTION_WIDTH" '-'
    separator_line=$REPEATED_TABLE_CHARACTER
    repeat_table_character "$CLASSIFICATION_WIDTH" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    repeat_table_character "$SOURCE_WIDTH" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    repeat_table_character "$TARGET_WIDTH" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    repeat_table_character "$STATUS_WIDTH" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    repeat_table_character "$DETAILS_WIDTH" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"

    printf '%s\n' "$section_title"
    render_relation_line DIRECTION CLASSIFICATION SOURCE TARGET STATUS DETAILS \
        "$COLOR_BOLD" "$COLOR_BOLD" "$COLOR_BOLD" "$COLOR_BOLD" "$COLOR_BOLD"
    printf '%s\n' "$separator_line"

    while IFS="$relation_field_separator" read -r direction classification \
        source_schema source_table source_columns target_schema target_table target_columns \
        constraint_name supporting_index status_tags details; do
        [[ -n "$direction" ]] || continue
        found=true
        source_value="${source_schema}.${source_table}${source_columns}"
        if [[ -n "$target_schema" || -n "$target_table" ]]; then
            target_value="${target_schema}.${target_table}${target_columns}"
        else
            target_value=$target_columns
        fi
        RELATION_DETAILS=""
        [[ -z "$constraint_name" ]] || append_relation_detail "constraint=$constraint_name"
        [[ -z "$supporting_index" ]] || append_relation_detail "index=$supporting_index"
        [[ -z "$status_tags" ]] || append_relation_detail "tags=$status_tags"
        append_relation_detail "$details"

        relation_status "$classification" "$status_tags"
        classification_color "$classification"
        details_color=""
        if [[ "$status_tags" == *MISMATCH* || "$status_tags" == *MISSING_COMPONENTS* ||
              "$status_tags" == *ERROR* ]]; then
            details_color=$COLOR_RED
        fi
        wrap_relation_fields "$source_value" "$target_value" "$RELATION_DETAILS" \
            "$SOURCE_WIDTH" "$TARGET_WIDTH" "$DETAILS_WIDTH"
        continuation=false
        while IFS="$relation_field_separator" read -r line_source line_target line_details line_details_offset; do
            color_relation_detail_names "$line_details" "$line_details_offset" "$RELATION_DETAILS" \
                "$constraint_name" "$supporting_index" "$details_color"
            if [[ "$continuation" == false ]]; then
                render_relation_line "$direction" "$classification" "$line_source" "$line_target" \
                    "$RELATION_STATUS" "$line_details" "$COLOR_CYAN" "$FIELD_COLOR" \
                    "$COLOR_BOLD_YELLOW" "$STATUS_COLOR" "$details_color" "$COLORED_RELATION_DETAILS"
                continuation=true
            else
                render_relation_line "" "" "$line_source" "$line_target" "" "$line_details" \
                    "" "" "$COLOR_BOLD_YELLOW" "" "$details_color" "$COLORED_RELATION_DETAILS"
            fi
        done <<EOF
$WRAPPED_RELATION_FIELDS
EOF
    done < <(filter_relation_section "$relations_file" "$section")
    if [[ "$found" == false ]]; then
        printf '%sNone%s\n' "$COLOR_DIM" "$COLOR_RESET"
    fi
    printf '\n'
}

render_index_coverage() {
    local relations_file=$1
    local component_file="$WORK_DIR/relation-component-counts.tsv"
    local indexes_file="$WORK_DIR/indexes.tsv"
    local coverage_field_separator=$'\034'
    local source_value supporting_index cardinality line_source line_index line_cardinality line_cardinality_offset
    local separator_line
    local found=false
    local coverage_budget coverage_source_width coverage_index_width coverage_cardinality_width

    coverage_budget=$((TERMINAL_WIDTH - 6))
    coverage_source_width=$((coverage_budget / 2))
    coverage_index_width=$((coverage_budget / 3))
    coverage_cardinality_width=$((coverage_budget - coverage_source_width - coverage_index_width))

    printf 'SUPPORTING INDEX COVERAGE\n'
    repeat_table_character "$coverage_source_width" '-'
    separator_line=$REPEATED_TABLE_CHARACTER
    repeat_table_character "$coverage_index_width" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    repeat_table_character "$coverage_cardinality_width" '-'
    separator_line="$separator_line-+-$REPEATED_TABLE_CHARACTER"
    printf '%s%-*s%s | %s%-*s%s | %s%-*s%s\n' \
        "$COLOR_BOLD" "$coverage_source_width" SOURCE "$COLOR_RESET" \
        "$COLOR_BOLD" "$coverage_index_width" 'SUPPORTING INDEX' "$COLOR_RESET" \
        "$COLOR_BOLD" "$coverage_cardinality_width" 'INDEX CARDINALITY' "$COLOR_RESET"
    printf '%s\n' "$separator_line"

    while IFS="$coverage_field_separator" read -r source_value supporting_index cardinality; do
        [[ -n "$source_value" ]] || continue
        found=true
        wrap_relation_fields "$source_value" "$supporting_index" "$cardinality" \
            "$coverage_source_width" "$coverage_index_width" "$coverage_cardinality_width"
        while IFS="$coverage_field_separator" read -r line_source line_index line_cardinality line_cardinality_offset; do
            printf '%-*s | %s%-*s%s | %-*s\n' \
                "$coverage_source_width" "$line_source" \
                "$COLOR_BLUE" "$coverage_index_width" "$line_index" "$COLOR_RESET" \
                "$coverage_cardinality_width" "$line_cardinality"
        done <<EOF
$WRAPPED_RELATION_FIELDS
EOF
    done < <(LC_ALL=C awk -F '\t' -v OFS="$coverage_field_separator" '
        FILENAME == ARGV[1] {
            if ($10 == "") next
            relation_key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP \
                $6 SUBSEP $7 SUBSEP $8 SUBSEP $9 SUBSEP $10
            source[relation_key] = $3 "." $4 $5
            source_schema[relation_key] = $3
            source_table[relation_key] = $4
            index_name[relation_key] = $10
            next
        }
        FILENAME == ARGV[2] {
            relation_key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP \
                $6 SUBSEP $7 SUBSEP $8 SUBSEP $9 SUBSEP $10
            component_count[relation_key] = $11
            next
        }
        {
            cardinality[$1 SUBSEP $2 SUBSEP $3 SUBSEP $5] = $7
        }
        END {
            for (key in source) {
                value = "unavailable"
                if (component_count[key] != "") {
                    value = cardinality[source_schema[key] SUBSEP source_table[key] SUBSEP \
                        index_name[key] SUBSEP component_count[key]]
                    if (value == "") value = "unavailable"
                }
                print source[key], index_name[key], value
            }
        }
    ' "$relations_file" "$component_file" "$indexes_file" | LC_ALL=C sort -t "$coverage_field_separator" -k1,1 -k2,2)
    if [[ "$found" == false ]]; then
        printf '%sNone%s\n' "$COLOR_DIM" "$COLOR_RESET"
    fi
    printf '\n'
}

render_relation_tables() {
    local relations_file=$1

    calculate_relation_widths
    render_relation_section "$relations_file" 'PHYSICAL OUTBOUND' physical_outbound
    render_relation_section "$relations_file" 'PHYSICAL INBOUND' physical_inbound
    render_relation_section "$relations_file" 'COMPLETE VIRTUAL RELATIONSHIPS' complete_virtual
    render_relation_section "$relations_file" 'PARTIAL AND AMBIGUOUS VIRTUAL RELATIONSHIPS' partial_ambiguous_virtual
    render_index_coverage "$relations_file"
}

render_tree_tags() {
    local tags=$1
    local tag
    local tag_color
    local old_ifs=$IFS

    [[ -n "$tags" ]] || return 0
    IFS=','
    for tag in $tags; do
        case "$tag" in
            UNINDEXED) tag_color=$COLOR_YELLOW ;;
            *) tag_color=$COLOR_RED ;;
        esac
        printf ' %s[%s]%s' "$tag_color" "$tag" "$COLOR_RESET"
    done
    IFS=$old_ifs
}

render_tree_relation() {
    local connector=$1
    local classification=$2
    local source_schema=$3
    local source_table=$4
    local source_columns=$5
    local target_schema=$6
    local target_table=$7
    local target_columns=$8
    local constraint_name=$9
    local supporting_index=${10}
    local status_tags=${11}
    local details=${12}

    classification_color "$classification"
    printf '%s%s%s ' "$COLOR_DIM_CYAN" "$connector" "$COLOR_RESET"
    printf '%s%s%s ' "$FIELD_COLOR" "$classification" "$COLOR_RESET"
    printf '%s.%s%s' "$source_schema" "$source_table" "$source_columns"
    if [[ -n "$target_schema" || -n "$target_table" ]]; then
        printf ' -> %s.%s%s' "$target_schema" "$target_table" "$target_columns"
    fi
    if [[ -n "$constraint_name" ]]; then
        printf ' constraint=%s%s%s' "$COLOR_BLUE" "$constraint_name" "$COLOR_RESET"
    fi
    if [[ -n "$supporting_index" ]]; then
        printf ' index=%s%s%s' "$COLOR_BLUE" "$supporting_index" "$COLOR_RESET"
    fi
    render_tree_tags "$status_tags"
    if [[ -n "$details" ]]; then
        printf ' %s' "$details"
    fi
    printf '\n'
}

render_tree_branch() {
    local relations_file=$1
    local group_number=$2
    local branch_label=$3
    local group_count=$4
    local branch_is_last=$5
    local relation_field_separator=$'\034'
    local branch_connector child_indent child_connector
    local current=0
    local direction classification source_schema source_table source_columns
    local target_schema target_table target_columns constraint_name supporting_index
    local status_tags details

    if [[ "$branch_is_last" == true ]]; then
        branch_connector='└──'
        child_indent='    '
    else
        branch_connector='├──'
        child_indent='│   '
    fi
    printf '%s%s%s %s\n' "$COLOR_DIM_CYAN" "$branch_connector" "$COLOR_RESET" "$branch_label"

    if [[ "$group_count" -eq 0 ]]; then
        printf '%s%s└──%s %sNone%s\n' "$COLOR_DIM_CYAN" "$child_indent" \
            "$COLOR_RESET" "$COLOR_DIM" "$COLOR_RESET"
        return 0
    fi

    while IFS="$relation_field_separator" read -r direction classification \
        source_schema source_table source_columns target_schema target_table target_columns \
        constraint_name supporting_index status_tags details; do
        current=$((current + 1))
        if [[ "$current" -eq "$group_count" ]]; then
            child_connector="${child_indent}└──"
        else
            child_connector="${child_indent}├──"
        fi
        render_tree_relation "$child_connector" "$classification" \
            "$source_schema" "$source_table" "$source_columns" \
            "$target_schema" "$target_table" "$target_columns" \
            "$constraint_name" "$supporting_index" "$status_tags" "$details"
    done < <(LC_ALL=C awk -F '\t' -v OFS="$relation_field_separator" -v group="$group_number" '
        {
            if ($1 == "OUTBOUND") row_group = ($2 == "PHYSICAL_FK" ? 1 : 2)
            else row_group = ($2 == "PHYSICAL_FK" ? 3 : 4)
            if (row_group == group) {
                print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
            }
        }
    ' "$relations_file")
}

render_tree() {
    local relations_file=$1
    local counts
    local outbound_physical outbound_virtual inbound_physical inbound_virtual

    counts=$(LC_ALL=C awk -F '\t' '
        {
            if ($1 == "OUTBOUND") group = ($2 == "PHYSICAL_FK" ? 1 : 2)
            else group = ($2 == "PHYSICAL_FK" ? 3 : 4)
            count[group]++
        }
        END { printf "%d %d %d %d", count[1], count[2], count[3], count[4] }
    ' "$relations_file")
    read -r outbound_physical outbound_virtual inbound_physical inbound_virtual <<EOF
$counts
EOF

    printf 'DEPENDENCY TREE\n'
    printf '%s%s.%s%s\n' "$COLOR_BOLD_YELLOW" "$SCHEMA_NAME" "$TABLE_NAME" "$COLOR_RESET"
    render_tree_branch "$relations_file" 1 'OUTBOUND PHYSICAL' "$outbound_physical" false
    render_tree_branch "$relations_file" 2 'OUTBOUND VIRTUAL' "$outbound_virtual" false
    render_tree_branch "$relations_file" 3 'INBOUND PHYSICAL' "$inbound_physical" false
    render_tree_branch "$relations_file" 4 'INBOUND VIRTUAL' "$inbound_virtual" true
    printf '\n'
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

    terminate_active_child
    if [[ -n "${EXPORT_TEMP:-}" && -f "$EXPORT_TEMP" ]]; then
        rm -f -- "$EXPORT_TEMP"
    fi
    case "${WORK_DIR:-}" in
        "${workspace_prefix}"*)
            [[ -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
            ;;
    esac
    WORK_DIR=""
    EXPORT_TEMP=""
    return 0
}

terminate_active_child() {
    local child_pid=${ACTIVE_CHILD_PID:-}

    [[ -n "$child_pid" ]] || return 0
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    ACTIVE_CHILD_PID=""
}

handle_signal() {
    local status=$1

    trap - HUP INT TERM
    terminate_active_child
    exit "$status"
}

create_workspace() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fk-analyzer.XXXXXX") || runtime_error 3 'Unable to create temporary workspace.'
    trap cleanup EXIT
    trap 'handle_signal 129' HUP
    trap 'handle_signal 130' INT TERM
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

    "$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --skip-column-names -e "$query"
}

run_mysql_raw_query() {
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

mark_degraded() {
    local message=$1

    printf 'DEGRADED: %s\n' "$message" >&2
    if [[ "$FINAL_STATUS" -eq 0 ]]; then
        FINAL_STATUS=4
    fi
    REPORT_ELIGIBLE=false
}

run_optional_query() {
    local label=$1
    local query=$2
    local output_file=$3
    local stderr_file="$WORK_DIR/${label}.stderr"
    local diagnostic

    if run_mysql_query "$query" > "$output_file" 2> "$stderr_file"; then
        return 0
    fi

    diagnostic=$(sanitize_stderr "$stderr_file")
    [[ -n "$diagnostic" ]] || diagnostic='no diagnostic returned by the MySQL client'
    : > "$output_file"
    mark_degraded "MySQL optional query (${label}) failed: $diagnostic"
    return 1
}

acquire_ddl() {
    local stderr_file="$WORK_DIR/ddl.stderr"
    local diagnostic
    local quoted_schema
    local quoted_table
    local query

    quoted_schema=$(quote_identifier "$SCHEMA_NAME")
    quoted_table=$(quote_identifier "$TABLE_NAME")
    query="SHOW /* fk-analyzer:ddl */ CREATE TABLE ${quoted_schema}.${quoted_table};"

    if ! run_mysql_raw_query "$query" > "$WORK_DIR/ddl.tsv" 2> "$stderr_file"; then
        diagnostic=$(sanitize_stderr "$stderr_file")
        [[ -n "$diagnostic" ]] || diagnostic='no diagnostic returned by the MySQL client'
        runtime_error 3 "MySQL DDL query failed: $diagnostic"
    fi
    LC_ALL=C awk -F '\t' 'NR == 1 && NF >= 2 { found = 1 } END { exit !found }' \
        "$WORK_DIR/ddl.tsv" || runtime_error 3 'MySQL DDL query returned no usable definition.'
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
    if ! run_optional_query columns "$query" "$WORK_DIR/columns.tsv"; then
        VIRTUAL_METADATA_AVAILABLE=false
    fi

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
    if ! run_optional_query pks "$query" "$WORK_DIR/pks.tsv"; then
        VIRTUAL_METADATA_AVAILABLE=false
    fi

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
    if ! run_optional_query physical "$query" "$WORK_DIR/physical-components.tsv"; then
        PHYSICAL_AVAILABLE=false
    fi

    query="SELECT /* fk-analyzer:indexes */ TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
       NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, CARDINALITY
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = ${schema_literal}
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;"
    run_optional_query indexes "$query" "$WORK_DIR/indexes.tsv" || true

    query="SELECT /* fk-analyzer:stats */ COALESCE(TABLE_ROWS, 0)
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ${schema_literal}
  AND TABLE_NAME = ${table_literal};"
    if ! run_optional_query stats "$query" "$WORK_DIR/stats.tsv"; then
        STATS_AVAILABLE=false
    fi
}

acquire_exact_cardinality() {
    local quoted_schema
    local quoted_table
    local query

    [[ "$CARDINALITY_MODE" == exact ]] || return 0
    quoted_schema=$(quote_identifier "$SCHEMA_NAME")
    quoted_table=$(quote_identifier "$TABLE_NAME")
    query="SELECT /* fk-analyzer:exact */ COUNT(*) FROM ${quoted_schema}.${quoted_table};"
    if run_optional_query exact "$query" "$WORK_DIR/exact.tsv"; then
        EXACT_AVAILABLE=true
    fi
}

build_physical_relations() {
    local physical_file="$WORK_DIR/physical-components.tsv"
    local indexes_file="$WORK_DIR/indexes.tsv"
    local component_file="$WORK_DIR/relation-component-counts.tsv"

    : > "$component_file"

    if [[ "$PHYSICAL_AVAILABLE" == false ]]; then
        : > "$WORK_DIR/relations.tsv"
        return 0
    fi

    awk -F '\t' -v OFS='\t' -v physical_file="$physical_file" -v component_file="$component_file" \
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
                print direction, "PHYSICAL_FK", source_schema[key], source_table[key], source_tuple,
                    target_schema[key], target_table[key], target_tuple, constraint_name[key],
                    supporting_index, ordinal_max[key] > component_file
            }
        }
    ' "$physical_file" "$indexes_file" > "$WORK_DIR/relations.tsv"
}

sort_relations() {
    local relations_file="$WORK_DIR/relations.tsv"
    local sorted_file="$WORK_DIR/sorted-relations.tsv"

    [[ -f "$relations_file" ]] || return 0
    LC_ALL=C awk -F '\t' -v OFS='\t' '
        {
            direction_rank = ($1 == "OUTBOUND" ? 1 : 2)
            if ($2 == "PHYSICAL_FK") classification_rank = 1
            else if ($2 == "COMPLETE_VIRTUAL_FK") classification_rank = 2
            else if ($2 == "PARTIAL_VIRTUAL_FK") classification_rank = 3
            else classification_rank = 4
            print direction_rank, classification_rank, $3, $4, $9, $0
        }
    ' "$relations_file" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 -k4,4 -k5,5 | \
        LC_ALL=C cut -f6- > "$sorted_file"
    mv "$sorted_file" "$relations_file"
}

build_virtual_relations() {
    local columns_file="$WORK_DIR/columns.tsv"
    local pks_file="$WORK_DIR/pks.tsv"
    local indexes_file="$WORK_DIR/indexes.tsv"
    local relations_file="$WORK_DIR/relations.tsv"
    local component_file="$WORK_DIR/relation-component-counts.tsv"
    local virtual_file="$WORK_DIR/virtual-relations.tsv"
    local virtual_component_file="$WORK_DIR/virtual-relation-component-counts.tsv"
    local combined_file="$WORK_DIR/combined-relations.tsv"
    local combined_component_file="$WORK_DIR/combined-relation-component-counts.tsv"

    if [[ "$PHYSICAL_ONLY" == true || "$VIRTUAL_METADATA_AVAILABLE" == false ]]; then
        sort_relations
        return 0
    fi

    : > "$virtual_component_file"

    LC_ALL=C awk -F '\t' -v OFS='\t' \
        -v columns_file="$columns_file" \
        -v pks_file="$pks_file" \
        -v indexes_file="$indexes_file" \
        -v relations_file="$relations_file" \
        -v component_file="$virtual_component_file" \
        -v selected_schema="$SCHEMA_NAME" \
        -v selected_table="$TABLE_NAME" '
        function sort_list(values, count, left, right, temporary) {
            for (left = 1; left <= count; left++) {
                for (right = left + 1; right <= count; right++) {
                    if (values[right] < values[left]) {
                        temporary = values[left]
                        values[left] = values[right]
                        values[right] = temporary
                    }
                }
            }
        }
        function clear_array(values, key) {
            for (key in values) {
                delete values[key]
            }
        }
        function type_matches(source_schema, source_table, source_column,
                              target_schema, target_table, target_column,
                              source_key, target_key) {
            source_key = source_schema SUBSEP source_table SUBSEP source_column
            target_key = target_schema SUBSEP target_table SUBSEP target_column
            if (column_type[source_key] != column_type[target_key]) {
                return 0
            }
            if (column_charset[source_key] != "" || column_charset[target_key] != "") {
                return column_charset[source_key] == column_charset[target_key] &&
                    column_collation[source_key] == column_collation[target_key]
            }
            return 1
        }
        function tuple_add(tuple, column) {
            return tuple == "" ? column : tuple ", " column
        }
        function target_description(target_key, parts, ordinal, tuple) {
            split(target_key, parts, SUBSEP)
            tuple = ""
            for (ordinal = 1; ordinal <= pk_max[target_key]; ordinal++) {
                tuple = tuple_add(tuple, pk_column[target_key, ordinal])
            }
            return parts[1] "." parts[2] "(" tuple ")"
        }
        function relation_is_scoped(source_schema, source_table, target_schema, target_table) {
            return (source_schema == selected_schema && source_table == selected_table) ||
                (target_schema == selected_schema && target_table == selected_table)
        }
        function direct_candidate_is_physical(source_key, target_key,
                                               source_parts, target_parts, ordinal,
                                               target_column, prefixed_column,
                                               source_column, source_tuple, target_tuple,
                                               signature) {
            split(source_key, source_parts, SUBSEP)
            split(target_key, target_parts, SUBSEP)
            source_tuple = ""
            target_tuple = ""
            for (ordinal = 1; ordinal <= pk_max[target_key]; ordinal++) {
                target_column = pk_column[target_key, ordinal]
                prefixed_column = target_parts[2] "_" target_column
                source_column = ""
                if ((source_key SUBSEP target_column) in column_exists) {
                    source_column = target_column
                } else if ((source_key SUBSEP prefixed_column) in column_exists) {
                    source_column = prefixed_column
                }
                if (source_column == "") {
                    continue
                }
                source_tuple = tuple_add(source_tuple, source_column)
                target_tuple = tuple_add(target_tuple, target_column)
            }
            signature = source_parts[1] SUBSEP source_parts[2] SUBSEP \
                "(" source_tuple ")" SUBSEP target_parts[1] SUBSEP target_parts[2] SUBSEP \
                "(" target_tuple ")"
            return signature in physical_relation
        }
        function direct_candidate_is_fully_compatible(source_key, target_key,
                                                       source_parts, target_parts,
                                                       ordinal, target_column,
                                                       prefixed_column, source_column) {
            split(source_key, source_parts, SUBSEP)
            split(target_key, target_parts, SUBSEP)
            for (ordinal = 1; ordinal <= pk_max[target_key]; ordinal++) {
                target_column = pk_column[target_key, ordinal]
                prefixed_column = target_parts[2] "_" target_column
                source_column = ""
                if ((source_key SUBSEP target_column) in column_exists) {
                    source_column = target_column
                } else if ((source_key SUBSEP prefixed_column) in column_exists) {
                    source_column = prefixed_column
                }
                if (source_column == "" ||
                    !type_matches(source_parts[1], source_parts[2], source_column,
                                  target_parts[1], target_parts[2], target_column)) {
                    return 0
                }
            }
            return 1
        }
        function find_supporting_index(source_schema, source_table, mapped_count,
                                       index_number, index_key, parts, ordinal, matches) {
            selected_supporting_index = ""
            index_order_mismatch = 0
            for (index_number = 1; index_number <= index_count; index_number++) {
                index_key = sorted_indexes[index_number]
                split(index_key, parts, SUBSEP)
                if (parts[1] != source_schema || parts[2] != source_table) {
                    continue
                }
                matches = 1
                for (ordinal = 1; ordinal <= mapped_count; ordinal++) {
                    if (index_column[index_key, ordinal] != mapped_source[ordinal]) {
                        matches = 0
                        break
                    }
                }
                if (matches) {
                    selected_supporting_index = parts[3]
                    return
                }
            }
            for (index_number = 1; index_number <= index_count; index_number++) {
                index_key = sorted_indexes[index_number]
                split(index_key, parts, SUBSEP)
                if (parts[1] != source_schema || parts[2] != source_table) {
                    continue
                }
                clear_array(index_member)
                for (ordinal = 1; ordinal <= mapped_count; ordinal++) {
                    index_member[index_column[index_key, ordinal]]++
                }
                matches = 1
                for (ordinal = 1; ordinal <= mapped_count; ordinal++) {
                    if (index_member[mapped_source[ordinal]] != 1) {
                        matches = 0
                        break
                    }
                }
                if (matches) {
                    index_order_mismatch = 1
                    return
                }
            }
        }
        function emit_candidate(source_key, target_key, match_mode,
                                source_parts, target_parts, ordinal, target_column,
                                source_column, prefixed_column, source_tuple,
                                target_tuple, mapped_count, missing_components,
                                type_mismatch, status_tags, classification,
                                direction, signature) {
            split(source_key, source_parts, SUBSEP)
            split(target_key, target_parts, SUBSEP)
            if (!relation_is_scoped(source_parts[1], source_parts[2], target_parts[1], target_parts[2])) {
                return
            }

            clear_array(mapped_source)
            clear_array(mapped_target)
            mapped_count = 0
            missing_components = 0
            type_mismatch = 0
            current_pk_count = pk_max[target_key]
            for (ordinal = 1; ordinal <= current_pk_count; ordinal++) {
                target_column = pk_column[target_key, ordinal]
                prefixed_column = target_parts[2] "_" target_column
                source_column = ""
                if (ordinal == 1 && match_mode == "prefixed") {
                    if ((source_key SUBSEP prefixed_column) in column_exists) {
                        source_column = prefixed_column
                    }
                } else if ((source_key SUBSEP target_column) in column_exists) {
                    source_column = target_column
                } else if ((source_key SUBSEP prefixed_column) in column_exists) {
                    source_column = prefixed_column
                }
                if (source_column == "") {
                    missing_components = 1
                    continue
                }
                mapped_count++
                mapped_source[mapped_count] = source_column
                mapped_target[mapped_count] = target_column
                if (!type_matches(source_parts[1], source_parts[2], source_column,
                                  target_parts[1], target_parts[2], target_column)) {
                    type_mismatch = 1
                }
            }
            if (mapped_count == 0) {
                return
            }

            source_tuple = ""
            target_tuple = ""
            for (ordinal = 1; ordinal <= mapped_count; ordinal++) {
                source_tuple = tuple_add(source_tuple, mapped_source[ordinal])
                target_tuple = tuple_add(target_tuple, mapped_target[ordinal])
            }
            source_tuple = "(" source_tuple ")"
            target_tuple = "(" target_tuple ")"
            signature = source_parts[1] SUBSEP source_parts[2] SUBSEP source_tuple SUBSEP \
                target_parts[1] SUBSEP target_parts[2] SUBSEP target_tuple
            if (signature in physical_relation || signature in virtual_relation) {
                return
            }

            find_supporting_index(source_parts[1], source_parts[2], mapped_count)
            status_tags = ""
            if (missing_components) {
                status_tags = "MISSING_COMPONENTS"
            }
            if (type_mismatch) {
                status_tags = status_tags (status_tags == "" ? "" : ",") "TYPE_MISMATCH"
            }
            if (selected_supporting_index == "" && !index_order_mismatch) {
                status_tags = status_tags (status_tags == "" ? "" : ",") "UNINDEXED"
            }
            if (index_order_mismatch) {
                status_tags = status_tags (status_tags == "" ? "" : ",") "INDEX_ORDER_MISMATCH"
            }
            classification = status_tags == "" ? "COMPLETE_VIRTUAL_FK" : "PARTIAL_VIRTUAL_FK"
            direction = source_parts[1] == selected_schema && source_parts[2] == selected_table ? \
                "OUTBOUND" : "INBOUND"
            virtual_relation[signature] = 1
            print direction, classification, source_parts[1], source_parts[2], source_tuple,
                target_parts[1], target_parts[2], target_tuple, "", selected_supporting_index,
                status_tags, ""
            print direction, classification, source_parts[1], source_parts[2], source_tuple,
                target_parts[1], target_parts[2], target_tuple, "", selected_supporting_index,
                mapped_count > component_file
        }
        function emit_ambiguous(source_key, first_column, candidate_count,
                                source_parts, candidate_number, descriptions,
                                details, direction, source_tuple, target_key,
                                target_parts, scoped, supporting_index) {
            split(source_key, source_parts, SUBSEP)
            scoped = source_parts[1] == selected_schema && source_parts[2] == selected_table
            for (candidate_number = 1; candidate_number <= candidate_count; candidate_number++) {
                target_key = direct_targets[candidate_number]
                split(target_key, target_parts, SUBSEP)
                if (target_parts[1] == selected_schema && target_parts[2] == selected_table) {
                    scoped = 1
                }
                descriptions[candidate_number] = target_description(target_key)
            }
            if (!scoped) {
                return
            }
            sort_list(descriptions, candidate_count)
            details = "Candidate targets: " descriptions[1]
            for (candidate_number = 2; candidate_number <= candidate_count; candidate_number++) {
                details = details ", " descriptions[candidate_number]
            }
            mapped_source[1] = first_column
            current_pk_count = 1
            find_supporting_index(source_parts[1], source_parts[2], 1)
            supporting_index = selected_supporting_index
            source_tuple = "(" first_column ")"
            direction = source_parts[1] == selected_schema && source_parts[2] == selected_table ? \
                "OUTBOUND" : "INBOUND"
            print direction, "AMBIGUOUS_VIRTUAL_FK", source_parts[1], source_parts[2],
                source_tuple, "", "", source_tuple, "", supporting_index, "", details
            print direction, "AMBIGUOUS_VIRTUAL_FK", source_parts[1], source_parts[2],
                source_tuple, "", "", source_tuple, "", supporting_index, 1 > component_file
        }
        FILENAME == columns_file {
            table_key = $1 SUBSEP $2
            column_key = table_key SUBSEP $3
            if (!(table_key in source_table_seen)) {
                source_table_seen[table_key] = 1
                source_tables[++source_table_count] = table_key
            }
            column_exists[column_key] = 1
            column_type[column_key] = $5
            column_charset[column_key] = $6
            column_collation[column_key] = $7
            next
        }
        FILENAME == pks_file {
            target_key = $1 SUBSEP $2
            if (!(target_key in target_table_seen)) {
                target_table_seen[target_key] = 1
                target_tables[++target_table_count] = target_key
            }
            pk_column[target_key, $4] = $3
            if (($4 + 0) > pk_max[target_key]) {
                pk_max[target_key] = $4 + 0
            }
            if ($4 == 1 && !($3 in first_pk_seen)) {
                first_pk_seen[$3] = 1
                first_pk_names[++first_pk_count] = $3
            }
            next
        }
        FILENAME == indexes_file {
            index_key = $1 SUBSEP $2 SUBSEP $3
            if (!(index_key in index_seen)) {
                index_seen[index_key] = 1
                sorted_indexes[++index_count] = index_key
            }
            index_column[index_key, $5] = $6
            next
        }
        FILENAME == relations_file {
            if ($2 != "PHYSICAL_FK") {
                next
            }
            physical_relation[$3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP $8] = 1
            next
        }
        END {
            sort_list(source_tables, source_table_count)
            sort_list(target_tables, target_table_count)
            sort_list(first_pk_names, first_pk_count)
            sort_list(sorted_indexes, index_count)

            for (source_number = 1; source_number <= source_table_count; source_number++) {
                source_key = source_tables[source_number]
                split(source_key, source_parts, SUBSEP)

                for (target_number = 1; target_number <= target_table_count; target_number++) {
                    target_key = target_tables[target_number]
                    split(target_key, target_parts, SUBSEP)
                    if (source_key == target_key) {
                        continue
                    }
                    first_column = target_parts[2] "_" pk_column[target_key, 1]
                    if ((source_key SUBSEP first_column) in column_exists) {
                        emit_candidate(source_key, target_key, "prefixed")
                    }
                }

                for (name_number = 1; name_number <= first_pk_count; name_number++) {
                    first_column = first_pk_names[name_number]
                    if (first_column == "id" || !((source_key SUBSEP first_column) in column_exists)) {
                        continue
                    }
                    clear_array(direct_targets)
                    clear_array(compatible_targets)
                    direct_count = 0
                    compatible_count = 0
                    for (target_number = 1; target_number <= target_table_count; target_number++) {
                        target_key = target_tables[target_number]
                        split(target_key, target_parts, SUBSEP)
                        if (source_key == target_key || pk_column[target_key, 1] != first_column) {
                            continue
                        }
                        if (type_matches(source_parts[1], source_parts[2], first_column,
                                         target_parts[1], target_parts[2], first_column) &&
                            !direct_candidate_is_physical(source_key, target_key)) {
                            direct_targets[++direct_count] = target_key
                            if (direct_candidate_is_fully_compatible(source_key, target_key)) {
                                compatible_targets[++compatible_count] = target_key
                            }
                        }
                    }
                    if (compatible_count > 0) {
                        clear_array(direct_targets)
                        direct_count = compatible_count
                        for (candidate_number = 1; candidate_number <= compatible_count; candidate_number++) {
                            direct_targets[candidate_number] = compatible_targets[candidate_number]
                        }
                    }
                    if (direct_count == 1) {
                        emit_candidate(source_key, direct_targets[1], "direct")
                    } else if (direct_count > 1) {
                        emit_ambiguous(source_key, first_column, direct_count)
                    }
                }
            }
        }
    ' "$columns_file" "$pks_file" "$indexes_file" "$relations_file" > "$virtual_file"

    cat "$relations_file" "$virtual_file" > "$combined_file"
    mv "$combined_file" "$relations_file"
    cat "$component_file" "$virtual_component_file" > "$combined_component_file"
    mv "$combined_component_file" "$component_file"
    sort_relations
}

render_ddl() {
    printf 'TABLE DDL\n'
    LC_ALL=C cut -f2- "$WORK_DIR/ddl.tsv"
    printf '\n'
}

read_cardinality_value() {
    local file=$1
    local label=$2
    local value=""

    [[ -f "$file" ]] && value=$(<"$file")
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        mark_degraded "$label returned an invalid non-negative integer."
        CARDINALITY_VALUE=""
        return 1
    fi
    CARDINALITY_VALUE=$value
}

render_cardinality() {
    local estimated=""
    local exact=""
    local comparison
    local absolute_difference
    local percentage_drift

    printf 'CARDINALITY\n'
    if [[ "$STATS_AVAILABLE" == true ]] && \
       read_cardinality_value "$WORK_DIR/stats.tsv" 'Metadata cardinality'; then
        estimated=$CARDINALITY_VALUE
        printf 'Estimated rows: %s\n' "$estimated"
    else
        STATS_AVAILABLE=false
        printf 'Estimated rows: unavailable\n'
    fi

    if [[ "$CARDINALITY_MODE" == exact ]]; then
        if [[ "$EXACT_AVAILABLE" == true ]] && \
           read_cardinality_value "$WORK_DIR/exact.tsv" 'Exact cardinality'; then
            exact=$CARDINALITY_VALUE
            printf 'Exact rows: %s\n' "$exact"
        else
            EXACT_AVAILABLE=false
            printf 'Exact rows: unavailable\n'
        fi

        if [[ -n "$estimated" && -n "$exact" ]]; then
            comparison=$(LC_ALL=C awk -v estimated="$estimated" -v exact="$exact" '
                BEGIN {
                    difference = exact - estimated
                    if (difference < 0) difference = -difference
                    if (exact == 0) {
                        percentage = (estimated == 0 ? 0 : 100)
                    } else {
                        percentage = 100 * difference / exact
                    }
                    printf "%.0f\t%.2f", difference, percentage
                }
            ')
            IFS=$'\t' read -r absolute_difference percentage_drift <<EOF
$comparison
EOF
            printf 'Absolute difference: %s\n' "$absolute_difference"
            printf 'Percentage drift: %s%%\n' "$percentage_drift"
        fi
    fi
    printf '\n'
}

resolve_output_format() {
    if [[ -n "$OUTPUT_FORMAT" ]]; then
        return 0
    fi
    case "$OUTPUT_FILE" in
        *.tsv|*.TSV) OUTPUT_FORMAT=tsv ;;
        *) OUTPUT_FORMAT=csv ;;
    esac
}

wait_for_active_child() {
    local child_status

    if wait "$ACTIVE_CHILD_PID"; then
        ACTIVE_CHILD_PID=""
        return 0
    else
        child_status=$?
    fi
    ACTIVE_CHILD_PID=""
    return "$child_status"
}

publish_report() {
    local output_directory

    [[ -n "$OUTPUT_FILE" && "$REPORT_ELIGIBLE" == true ]] || return 0
    resolve_output_format
    output_directory=$(dirname "$OUTPUT_FILE")
    EXPORT_TEMP=$(mktemp "$output_directory/.fk-analyzer.XXXXXX") \
        || runtime_error 3 'Unable to create a temporary report.'

    case "$OUTPUT_FORMAT" in
        csv)
            printf '%s\n' 'Direction,Classification,Source_Schema,Source_Table,Source_Columns,Target_Schema,Target_Table,Target_Columns,Constraint_Name,Supporting_Index,Status_Tags,Details' \
                > "$EXPORT_TEMP" || runtime_error 3 'Unable to write the CSV report header.'
            LC_ALL=C awk -F '\t' -v report_conversion=csv '
                function quote_csv(value) {
                    gsub(/"/, "\"\"", value)
                    return "\"" value "\""
                }
                NF != 12 { exit 1 }
                {
                    for (field = 1; field <= 12; field++) {
                        printf "%s%s", (field == 1 ? "" : ","), quote_csv($field)
                    }
                    printf "\n"
                }
            ' "$WORK_DIR/relations.tsv" >> "$EXPORT_TEMP" &
            ACTIVE_CHILD_PID=$!
            if ! wait_for_active_child; then
                runtime_error 3 'Unable to convert the report to CSV.'
            fi
            ;;
        tsv)
            printf '%s\n' $'Direction\tClassification\tSource_Schema\tSource_Table\tSource_Columns\tTarget_Schema\tTarget_Table\tTarget_Columns\tConstraint_Name\tSupporting_Index\tStatus_Tags\tDetails' \
                > "$EXPORT_TEMP" || runtime_error 3 'Unable to write the TSV report header.'
            LC_ALL=C awk -F '\t' -v report_conversion=tsv '
                NF != 12 { exit 1 }
                { print $0 }
            ' "$WORK_DIR/relations.tsv" >> "$EXPORT_TEMP" &
            ACTIVE_CHILD_PID=$!
            if ! wait_for_active_child; then
                runtime_error 3 'Unable to convert the report to TSV.'
            fi
            ;;
    esac

    if ! mv -f -- "$EXPORT_TEMP" "$OUTPUT_FILE"; then
        runtime_error 3 'Unable to publish the report.'
    fi
    EXPORT_TEMP=""
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
    FINAL_STATUS=0
    REPORT_ELIGIBLE=true
    PHYSICAL_AVAILABLE=true
    VIRTUAL_METADATA_AVAILABLE=true
    STATS_AVAILABLE=true
    EXACT_AVAILABLE=false
    EXPORT_TEMP=""
    ACTIVE_CHILD_PID=""
    create_workspace
    resolve_mysql_bin
    connection_preflight
    target_preflight
    acquire_ddl
    acquire_metadata
    acquire_exact_cardinality
    build_physical_relations
    build_virtual_relations

    detect_terminal_width
    setup_colors
    printf 'Target preflight succeeded: %s%s.%s%s (%s)\n' \
        "$COLOR_BOLD_YELLOW" "$SCHEMA_NAME" "$TABLE_NAME" "$COLOR_RESET" "$TARGET_ENGINE"
    render_ddl
    render_relation_tables "$WORK_DIR/relations.tsv"
    render_cardinality
    if [[ "$SHOW_TREE" == true ]]; then
        render_tree "$WORK_DIR/relations.tsv"
    fi
    publish_report
    return "$FINAL_STATUS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
