#!/bin/bash

# ==============================================================================
# Advanced SQL Single Query Generator (macOS & Linux Compatible)
# ==============================================================================

# --- Cross-Platform Color Definitions ---
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"

# --- Help Menu ---
show_help() {
    echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
    echo -e "${BOLD}${CYAN}               Advanced SQL Single Query Generator Tool               ${RESET}"
    echo -e "${BOLD}${CYAN}==============================================================================${RESET}"
    echo -e "${DIM}This tool automatically parses complex bulk INSERT, UPDATE, or DELETE queries,"
    echo -e "finds the safest index (Primary Key), and generates single, safe SQL statements.${RESET}\n"
    
    echo -e "${BOLD}USAGE:${RESET}"
    echo -e "  $0 [OPTIONS]\n"
    
    echo -e "${BOLD}OPTIONS:${RESET}"
    echo -e "  ${GREEN}--login-path=...${RESET}   MySQL login path (e.g., --login-path=local_db)"
    echo -e "  ${GREEN}--database=...${RESET}     Target database name"
    echo -e "  ${GREEN}--query-file=...${RESET}   File containing the complex bulk query"
    echo -e "  ${GREEN}-h, --help${RESET}         Display this help menu and exit\n"
    exit 0
}

if [[ "$#" -eq 0 ]]; then
    show_help
fi

LOGIN_PATH=""
DATABASE=""
QUERY_FILE=""

# --- Parameter Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --login-path=*) LOGIN_PATH="${1#*=}"; shift ;;
        --database=*) DATABASE="${1#*=}"; shift ;;
        --query-file=*) QUERY_FILE="${1#*=}"; shift ;;
        *) echo -e "${RED}${BOLD}Error:${RESET} ${RED}Unknown parameter: $1${RESET}" >&2; exit 1 ;;
    esac
done

if [[ -z "$LOGIN_PATH" || -z "$DATABASE" || -z "$QUERY_FILE" ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} ${RED}Missing required parameters.${RESET}" >&2
    echo -e "Run ${CYAN}$0 --help${RESET} for usage instructions." >&2
    exit 1
fi

if [[ ! -f "$QUERY_FILE" ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} ${RED}Query file '$QUERY_FILE' not found.${RESET}" >&2
    exit 1
fi

# Read query, replace non-breaking spaces, strip newlines for easier regex parsing
FULL_QUERY=$(perl -pe 's/\xC2\xA0/ /g' "$QUERY_FILE" | tr -s ' \n\t\r' ' ' | sed 's/^ //;s/ $//')

# ------------------------------------------------------------------------------
# 1. Identify Operation and Target Table (Using cross-platform Perl)
# ------------------------------------------------------------------------------
OPERATION=$(echo "$FULL_QUERY" | awk '{print toupper($1)}')

if [[ "$OPERATION" == "INSERT" ]]; then
    TARGET_TABLE=$(echo "$FULL_QUERY" | perl -nle 'print $1 if /INTO\s+([a-zA-Z0-9_]+)/i')
elif [[ "$OPERATION" == "UPDATE" ]]; then
    TARGET_TABLE=$(echo "$FULL_QUERY" | perl -nle 'print $2 if /UPDATE\s+(IGNORE\s+)?([a-zA-Z0-9_]+)/i')
elif [[ "$OPERATION" == "DELETE" ]]; then
    TARGET_TABLE=$(echo "$FULL_QUERY" | perl -nle 'print $1 if /FROM\s+([a-zA-Z0-9_]+)/i')
else
    echo -e "${RED}${BOLD}Error:${RESET} ${RED}Unrecognized operation '$OPERATION'. Script supports INSERT, UPDATE, DELETE.${RESET}" >&2
    exit 1
fi

echo -e "${BLUE}[*] Detected Operation:${RESET} ${BOLD}${YELLOW}$OPERATION${RESET} on table ${BOLD}${CYAN}$TARGET_TABLE${RESET}" >&2

# ------------------------------------------------------------------------------
# 2. Detect Best Index (Primary Key > Unique Index)
# ------------------------------------------------------------------------------
echo -e "${BLUE}[*] Analyzing table indices...${RESET}" >&2

INDEX_COL=$(mysql --login-path="$LOGIN_PATH" -D "$DATABASE" -sN -e "
    SELECT COLUMN_NAME 
    FROM information_schema.KEY_COLUMN_USAGE 
    WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME = '$TARGET_TABLE' AND CONSTRAINT_NAME = 'PRIMARY' LIMIT 1;
")

if [[ -z "$INDEX_COL" ]]; then
    INDEX_COL=$(mysql --login-path="$LOGIN_PATH" -D "$DATABASE" -sN -e "
        SELECT COLUMN_NAME 
        FROM information_schema.STATISTICS 
        WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME = '$TARGET_TABLE' AND NON_UNIQUE = 0 ORDER BY SEQ_IN_INDEX LIMIT 1;
    ")
fi

if [[ -z "$INDEX_COL" && "$OPERATION" != "INSERT" ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} ${RED}No Primary Key or Unique Index found for $TARGET_TABLE. Required for safe UPDATE/DELETE.${RESET}" >&2
    exit 1
fi

if [[ -n "$INDEX_COL" ]]; then
    echo -e "${GREEN}[+] Found optimal index column:${RESET} ${BOLD}$INDEX_COL${RESET}" >&2
fi

# ------------------------------------------------------------------------------
# 3. Rewrite Bulk Query to a SELECT Query
# ------------------------------------------------------------------------------
echo -e "${BLUE}[*] Rewriting query to map data...${RESET}" >&2

if [[ "$OPERATION" == "INSERT" ]]; then
    # Grab the first set of parentheses for columns and remove all whitespace
    COLUMNS=$(echo "$FULL_QUERY" | perl -nle 'print $1 if /\(\s*(.*?)\s*\)/' | head -n 1 | sed 's/[[:space:]]//g')
    
    # Grab SELECT query and explicitly strip trailing parenthesis/semicolons
    FETCH_QUERY=$(echo "$FULL_QUERY" | perl -nle 'print $1 if /(\bSELECT\b.*)/i' | perl -pe 's/\)[ \t;]*$//')
    
elif [[ "$OPERATION" == "DELETE" ]]; then
    COLUMNS="$INDEX_COL"
    FETCH_QUERY=$(echo "$FULL_QUERY" | perl -pe "s/^DELETE.*?FROM/SELECT $TARGET_TABLE.$INDEX_COL FROM/i")

elif [[ "$OPERATION" == "UPDATE" ]]; then
    SET_BLOCK=$(echo "$FULL_QUERY" | perl -nle 'print $1 if /SET\s+(.*?)\s+(WHERE|ORDER BY|LIMIT|$)/i')
    TARGET_COLS=""
    FETCH_VALS=""
    
    IFS=',' read -ra PAIRS <<< "$SET_BLOCK"
    for pair in "${PAIRS[@]}"; do
        col=$(echo "$pair" | awk -F'=' '{print $1}' | tr -d ' ' | sed 's/.*\.//')
        val=$(echo "$pair" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')
        TARGET_COLS="${TARGET_COLS}${col},"
        FETCH_VALS="${FETCH_VALS}${val},"
    done
    
    TARGET_COLS=${TARGET_COLS%,}
    FETCH_VALS=${FETCH_VALS%,}
    COLUMNS="$INDEX_COL,$TARGET_COLS"
    FETCH_QUERY=$(echo "$FULL_QUERY" | perl -pe "s/^UPDATE(.*?)\s+SET.*?(WHERE|ORDER BY|LIMIT|$)/SELECT $TARGET_TABLE.$INDEX_COL, $FETCH_VALS FROM\1 \2/i")
fi

echo -e "${DIM}    -> ${FETCH_QUERY}${RESET}" >&2

# ------------------------------------------------------------------------------
# 4. Fetch Schema Types and Raw Data
# ------------------------------------------------------------------------------
echo -e "${BLUE}[*] Fetching schema data types...${RESET}" >&2

# Exporting this as an Environment Variable prevents macOS awk from crashing on multi-line variables
export SCHEMA_DATA=$(mysql --login-path="$LOGIN_PATH" -D "$DATABASE" -sN -e "
    SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS 
    WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME = '$TARGET_TABLE';
" | awk '{print $1":"$2}')

echo -e "${BLUE}[*] Executing fetch query against database...${RESET}" >&2
mysql --login-path="$LOGIN_PATH" -D "$DATABASE" -sN -e "$FETCH_QUERY" > /tmp/raw_data.tsv

# Handle MySQL errors gracefully
if [[ $? -ne 0 ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} ${RED}The fetch query failed to execute properly. See the MySQL error above.${RESET}" >&2
    rm -f /tmp/raw_data.tsv
    exit 1
fi

ROW_COUNT=$(wc -l < /tmp/raw_data.tsv | tr -d ' ')
echo -e "${GREEN}[+] Successfully fetched ${BOLD}$ROW_COUNT${RESET}${GREEN} rows to process.${RESET}" >&2

# ------------------------------------------------------------------------------
# 5. Generate Final Queries
# ------------------------------------------------------------------------------
if [[ "$ROW_COUNT" -gt 0 ]]; then
    echo -e "${BLUE}[*] Generating single statements...${RESET}" >&2

    awk -F'\t' -v op="$OPERATION" \
        -v table="$TARGET_TABLE" \
        -v cols="$COLUMNS" \
        -v pk_col="$INDEX_COL" '
    BEGIN {
        # Read the multiline schema string safely from environment variables
        schema_env = ENVIRON["SCHEMA_DATA"];
        split(schema_env, schema_lines, "\n");
        
        for (i in schema_lines) {
            if (schema_lines[i] != "") {
                split(schema_lines[i], pair, ":");
                col_types[pair[1]] = pair[2];
            }
        }
        num_cols = split(cols, col_order, ",");
        numeric_types = "int|tinyint|smallint|mediumint|bigint|float|double|decimal|numeric";
    }
    {
        for (i = 1; i <= NF; i++) {
            val = $i;
            col_name = col_order[i];
            type = tolower(col_types[col_name]);
            
            if (val == "\\N" || val == "") {
                formatted[i] = "NULL";
            } else if (type ~ numeric_types) {
                formatted[i] = val;
            } else {
                gsub(/\x27/, "\x27\x27", val);
                formatted[i] = "\x27" val "\x27";
            }
        }

        if (op == "INSERT") {
            val_str = "";
            for (i = 1; i <= num_cols; i++) {
                val_str = val_str formatted[i] (i < num_cols ? ", " : "");
            }
            printf "INSERT IGNORE INTO %s (%s) VALUES (%s);\n", table, cols, val_str;
        } 
        else if (op == "UPDATE") {
            set_str = "";
            for (i = 2; i <= num_cols; i++) {
                set_str = set_str col_order[i] " = " formatted[i] (i < num_cols ? ", " : "");
            }
            printf "UPDATE %s SET %s WHERE %s = %s;\n", table, set_str, pk_col, formatted[1];
        }
        else if (op == "DELETE") {
            printf "DELETE FROM %s WHERE %s = %s;\n", table, pk_col, formatted[1];
        }
    }
    ' /tmp/raw_data.tsv
else
    echo -e "${YELLOW}[!] 0 rows were found. No queries generated.${RESET}" >&2
fi

rm -f /tmp/raw_data.tsv

echo -e "${GREEN}${BOLD}[✔] Process completed successfully!${RESET}" >&2