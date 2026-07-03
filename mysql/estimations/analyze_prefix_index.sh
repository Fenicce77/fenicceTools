#!/usr/bin/env bash

# Force standard numeric locale so printf and bc use '.' for decimals
export LC_NUMERIC="C"

# 100% Cross-Platform ANSI Color Codes (Evaluates the raw escape sequence safely)
C_RESET=$(printf '\033[0m')
C_BOLD_RED=$(printf '\033[1;31m')
C_BOLD_GREEN=$(printf '\033[1;32m')
C_BOLD_YELLOW=$(printf '\033[1;33m')
C_BOLD_BLUE=$(printf '\033[1;34m')
C_CYAN=$(printf '\033[36m')

# Default values
LOGIN_PATH=""
DATABASE=""
TABLE=""
COLUMNS=""
MAX_PREFIX=50

# Tuning Parameters
MARGINAL_THRESHOLD=0.01  # 1% absolute marginal gain threshold
TARGET_RATIO=0.95        # Must reach 95% of the column's maximum possible selectivity

# Help Function
show_help() {
    echo "${C_BOLD_BLUE}==============================================================================${C_RESET}"
    echo "${C_BOLD_GREEN} MySQL Optimal Index Prefix Analyzer${C_RESET}"
    echo "${C_BOLD_BLUE}==============================================================================${C_RESET}"
    echo "${C_BOLD_YELLOW}Usage:${C_RESET} $0 -l <name> -d <db> -t <tbl> [OPTIONS]"
    echo ""
    echo "Analyzes the best leftmost head (prefix length) for string-based columns to"
    echo "optimize index creation, using a dual-condition algorithm (Max Selectivity &"
    echo "Marginal Gain)."
    echo ""
    echo "${C_BOLD_YELLOW}Required Arguments:${C_RESET}"
    echo "  ${C_BOLD_GREEN}-l, --login-path${C_RESET} ${C_CYAN}<name>${C_RESET}   MySQL login path (configured via mysql_config_editor)"
    echo "  ${C_BOLD_GREEN}-d, --database${C_RESET}   ${C_CYAN}<db>${C_RESET}     Target database name"
    echo "  ${C_BOLD_GREEN}-t, --table${C_RESET}      ${C_CYAN}<tbl>${C_RESET}    Target table name"
    echo ""
    echo "${C_BOLD_YELLOW}Optional Arguments:${C_RESET}"
    echo "  ${C_BOLD_GREEN}-c, --columns${C_RESET}    ${C_CYAN}<cols>${C_RESET}   Comma-separated list of columns to analyze."
    echo "                            (If omitted, fetches all varchar/char/text columns)"
    echo "  ${C_BOLD_GREEN}-m, --max-prefix${C_RESET} ${C_CYAN}<num>${C_RESET}    Maximum prefix length to evaluate (Default: 50)"
    echo "  ${C_BOLD_GREEN}-h, --help${C_RESET}                Show this help message and exit"
    echo ""
    echo "${C_BOLD_YELLOW}Example Usage:${C_RESET}"
    echo "  $0 ${C_BOLD_GREEN}-l${C_RESET} root-gh-replica ${C_BOLD_GREEN}-d${C_RESET} dev_betika ${C_BOLD_GREEN}-t${C_RESET} profile"
    echo "  $0 ${C_BOLD_GREEN}-l${C_RESET} root-gh-replica ${C_BOLD_GREEN}-d${C_RESET} dev_betika ${C_BOLD_GREEN}-t${C_RESET} profile ${C_BOLD_GREEN}-c${C_RESET} first_name,last_name"
    echo "${C_BOLD_BLUE}==============================================================================${C_RESET}"
}

# Check if no arguments were passed
if [[ "$#" -eq 0 ]]; then
    show_help
    exit 0
fi

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -l|--login-path) LOGIN_PATH="$2"; shift ;;
        -d|--database) DATABASE="$2"; shift ;;
        -t|--table) TABLE="$2"; shift ;;
        -c|--columns) COLUMNS="$2"; shift ;;
        -m|--max-prefix) MAX_PREFIX="$2"; shift ;;
        *) echo "${C_BOLD_RED}Unknown parameter: $1${C_RESET}"; echo ""; show_help; exit 1 ;;
    esac
    shift
done

# Validate required arguments
if [ -z "$LOGIN_PATH" ] || [ -z "$DATABASE" ] || [ -z "$TABLE" ]; then
    echo "${C_BOLD_RED}Error: Missing required parameters (-l/--login-path, -d/--database, -t/--table).${C_RESET}"
    echo ""
    show_help
    exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
    echo "${C_BOLD_RED}Error: 'bc' is not installed.${C_RESET}"
    exit 1
fi

if [ -z "$COLUMNS" ]; then
    echo "${C_CYAN}No columns specified. Fetching all string-based columns...${C_RESET}"
    QUERY="SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND DATA_TYPE IN ('varchar', 'char', 'text');"
    COLUMNS_OUTPUT=$(mysql --login-path="$LOGIN_PATH" -sN -e "$QUERY" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "${C_BOLD_RED}Error: Failed to retrieve columns. MySQL Error:${C_RESET}"
        echo "$COLUMNS_OUTPUT"
        exit 1
    fi
    COLUMNS=$(echo "$COLUMNS_OUTPUT" | tr '\n' ',' | sed 's/,$//')
fi

echo "${C_BOLD_BLUE}========================================================${C_RESET}"
echo " ${C_BOLD_YELLOW}Analyzing Table:${C_RESET} $DATABASE.$TABLE"
echo " ${C_BOLD_YELLOW}Columns        :${C_RESET} $COLUMNS"
echo " ${C_BOLD_YELLOW}Method         :${C_RESET} Dual-Condition ( >95% Max Sel & <1% Gain )"
echo "${C_BOLD_BLUE}========================================================${C_RESET}"

IFS=',' read -r -a COL_ARRAY <<< "$COLUMNS"

for COL in "${COL_ARRAY[@]}"; do
    COL=$(echo "$COL" | xargs)
    echo ""
    echo "${C_BOLD_YELLOW}-> Analyzing column: ${C_BOLD_GREEN}**$COL**${C_RESET}"

    # 1. Get MIN/MAX lengths safely
    LENGTHS_QUERY="SELECT CONCAT_WS(',', IFNULL(MIN(CHAR_LENGTH(\`$COL\`)), 0), IFNULL(MAX(CHAR_LENGTH(\`$COL\`)), 0)) FROM \`$DATABASE\`.\`$TABLE\` WHERE \`$COL\` IS NOT NULL AND CAST(\`$COL\` AS CHAR) != '';"
    
    LENGTHS=$(mysql --login-path="$LOGIN_PATH" -sN -e "$LENGTHS_QUERY" 2>&1)
    if [ $? -ne 0 ]; then
        echo "   ${C_BOLD_RED}[!] MySQL Execution Error:${C_RESET}"
        echo "       $LENGTHS"
        continue
    fi

    if [ -z "$LENGTHS" ]; then
        echo "   ${C_BOLD_RED}[!] Query returned an empty result unexpectedly.${C_RESET}"
        continue
    fi

    # Safely extract digits only to avoid trailing spaces breaking the integer logic
    MIN_LEN=$(echo "$LENGTHS" | awk -F',' '{print $1}' | tr -dc '0-9')
    ACTUAL_MAX=$(echo "$LENGTHS" | awk -F',' '{print $2}' | tr -dc '0-9')

    MIN_LEN=${MIN_LEN:-0}
    ACTUAL_MAX=${ACTUAL_MAX:-0}

    if [ "$ACTUAL_MAX" -eq 0 ]; then
        echo "   ${C_BOLD_RED}[!] Column is empty or contains only NULLs/empty strings.${C_RESET}"
        continue
    fi

    # Ensure START_LEN is at least 1
    START_LEN=$MIN_LEN
    if [ "$START_LEN" -lt 1 ]; then
        START_LEN=1
    fi

    LOOP_LIMIT=$ACTUAL_MAX
    if [ "$MAX_PREFIX" -lt "$ACTUAL_MAX" ]; then
        LOOP_LIMIT=$MAX_PREFIX
    fi
    
    # Safety check in case MAX_PREFIX was set lower than MIN_LEN
    if [ "$LOOP_LIMIT" -lt "$START_LEN" ]; then
        LOOP_LIMIT=$START_LEN
    fi

    echo "   ${C_CYAN}[Info] Data Lengths - Min: $MIN_LEN, Max: $ACTUAL_MAX. Analyzing lengths $START_LEN to $LOOP_LIMIT.${C_RESET}"

    # 2. Build dynamic SQL query starting from START_LEN
    SQL_SELECT=""
    for ((i=START_LEN; i<=LOOP_LIMIT; i++)); do
        SQL_SELECT="$SQL_SELECT ROUND(COUNT(DISTINCT LEFT(\`$COL\`, $i))/COUNT(*), 4),"
    done
    SQL_SELECT=${SQL_SELECT%,} 
    
    SQL="SELECT CONCAT_WS(',', $SQL_SELECT) FROM \`$DATABASE\`.\`$TABLE\` WHERE \`$COL\` IS NOT NULL AND CAST(\`$COL\` AS CHAR) != '';"

    # 3. Execute query
    RESULT=$(mysql --login-path="$LOGIN_PATH" -sN -e "$SQL" 2>&1)
    if [ $? -ne 0 ]; then
        echo "   ${C_BOLD_RED}[!] MySQL Execution Error:${C_RESET}"
        echo "       $RESULT"
        continue
    fi

    if [ -z "$RESULT" ] || [ "$RESULT" == "NULL" ]; then
        echo "   ${C_BOLD_RED}[!] Failed to calculate selectivities. (Result was empty)${C_RESET}"
        continue
    fi

    # 4. Parse results and execute Dual-Condition logic
    IFS=',' read -r -a SELECTIVITY <<< "$RESULT"
    
    MAX_IDX=$((LOOP_LIMIT - START_LEN))
    MAX_SEL=${SELECTIVITY[$MAX_IDX]}
    TARGET_SEL=$(echo "$MAX_SEL * $TARGET_RATIO" | bc -l)

    echo "   ${C_CYAN}[Info] Max Achievable Selectivity: $(printf "%.4f" "$MAX_SEL") (95% Target: $(printf "%.4f" "$TARGET_SEL"))${C_RESET}"
    echo "   ${C_CYAN}--- Prefix Marginal Selectivity Breakdown ---${C_RESET}"

    declare -a GAINS
    PREV_SEL=0
    OPTIMAL_LEN=""

    for ((i=START_LEN; i<=LOOP_LIMIT; i++)); do
        IDX=$((i - START_LEN))
        SEL=${SELECTIVITY[$IDX]}
        SEL_FMT=$(printf "%.4f" "$SEL")
        
        # Format the length number to align the columns (left-aligned, 2 characters wide)
        PADDED_LEN=$(printf "%-2d" "$i")

        if [ "$i" -eq "$START_LEN" ]; then
            DIFF=$SEL
            GAINS[$i]=$DIFF
            IS_PAST_TARGET=$(echo "$SEL >= $TARGET_SEL" | bc -l)

            # Pad "Base" to 7 characters to align with "+0.xxxx"
            if [ "$IS_PAST_TARGET" -eq 1 ] && [ -z "$OPTIMAL_LEN" ]; then
                OPTIMAL_LEN=$i
                echo "   [Length ${PADDED_LEN}] Selectivity: $SEL_FMT | Marginal Gain: Base    ${C_BOLD_GREEN}<-- Optimal (Max selectivity reached instantly)${C_RESET}"
            else
                echo "   [Length ${PADDED_LEN}] Selectivity: $SEL_FMT | Marginal Gain: Base   "
            fi
        else
            DIFF=$(echo "$SEL - $PREV_SEL" | bc -l)
            GAINS[$i]=$DIFF
            DIFF_FMT=$(printf "%.4f" "$DIFF")

            IS_PAST_TARGET=$(echo "$SEL >= $TARGET_SEL" | bc -l)
            IS_LOW_GAIN=$(echo "$DIFF <= $MARGINAL_THRESHOLD" | bc -l)

            if [ "$IS_PAST_TARGET" -eq 1 ] && [ "$IS_LOW_GAIN" -eq 1 ] && [ -z "$OPTIMAL_LEN" ]; then
                OPTIMAL_LEN=$i
                echo "   [Length ${PADDED_LEN}] Selectivity: $SEL_FMT | Marginal Gain: +$DIFF_FMT ${C_BOLD_GREEN}<-- Optimal Sweet Spot!${C_RESET}"
            else
                echo "   [Length ${PADDED_LEN}] Selectivity: $SEL_FMT | Marginal Gain: +$DIFF_FMT"
            fi
        fi
        PREV_SEL=$SEL
    done

    # 5. Final Recommendation
    echo "   ${C_BOLD_BLUE}======================================================${C_RESET}"
    if [ -n "$OPTIMAL_LEN" ]; then
        echo "   ${C_BOLD_YELLOW}RECOMMENDATION:${C_RESET} Create index with prefix length ${C_BOLD_GREEN}$OPTIMAL_LEN${C_RESET}"
        echo "   ${C_CYAN}SQL:${C_RESET} ALTER TABLE \`$TABLE\` ADD INDEX \`idx_${COL}_prefix\` (\`$COL\`($OPTIMAL_LEN));"
    else
        echo "   ${C_BOLD_YELLOW}RECOMMENDATION:${C_RESET} Selectivity criteria not met within prefix limit."
        if [ "$LOOP_LIMIT" -lt "$ACTUAL_MAX" ]; then
            echo "   You may need to increase -m/--max-prefix."
        else
            echo "   You should index the full column."
            echo "   ${C_CYAN}SQL:${C_RESET} ALTER TABLE \`$TABLE\` ADD INDEX \`idx_${COL}\` (\`$COL\`);"
        fi
    fi
    echo "   ${C_BOLD_BLUE}======================================================${C_RESET}"
done
echo ""
echo "${C_BOLD_GREEN}Analysis Complete.${C_RESET}"