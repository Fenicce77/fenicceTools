#!/bin/bash

# Force standard numeric locale so printf and bc use '.' for decimals
export LC_NUMERIC="C"

# Default values
LOGIN_PATH=""
DATABASE=""
TABLE=""
COLUMNS=""
MAX_PREFIX=50

# Tuning Parameters
MARGINAL_THRESHOLD=0.01  # 1% absolute marginal gain threshold
TARGET_RATIO=0.95        # Must reach 95% of the column's maximum possible selectivity

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --login-path) LOGIN_PATH="$2"; shift ;;
        --database) DATABASE="$2"; shift ;;
        --table) TABLE="$2"; shift ;;
        --columns) COLUMNS="$2"; shift ;;
        --max-prefix) MAX_PREFIX="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Validate required arguments
if [ -z "$LOGIN_PATH" ] || [ -z "$DATABASE" ] || [ -z "$TABLE" ]; then
    echo "Error: Missing required parameters."
    echo "Usage: $0 --login-path <name> --database <db> --table <tbl> [--columns <col1,col2>] [--max-prefix <50>]"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo "Error: 'bc' is not installed."
    exit 1
fi

if [ -z "$COLUMNS" ]; then
    echo "No columns specified. Fetching all string-based columns..."
    QUERY="SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND DATA_TYPE IN ('varchar', 'char', 'text');"
    COLUMNS_OUTPUT=$(mysql --login-path="$LOGIN_PATH" -sN -e "$QUERY" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to retrieve columns. MySQL Error:"
        echo "$COLUMNS_OUTPUT"
        exit 1
    fi
    COLUMNS=$(echo "$COLUMNS_OUTPUT" | tr '\n' ',' | sed 's/,$//')
fi

echo "========================================================"
echo " Analyzing Table: $DATABASE.$TABLE"
echo " Columns        : $COLUMNS"
echo " Method         : Dual-Condition ( >95% Max Sel & <1% Gain )"
echo "========================================================"

IFS=',' read -r -a COL_ARRAY <<< "$COLUMNS"

for COL in "${COL_ARRAY[@]}"; do
    COL=$(echo "$COL" | xargs)
    echo -e "\n-> Analyzing column: **$COL**"

    # 1. Get MIN/MAX lengths safely (Using CAST ensures no strict-mode warnings on numeric columns)
    LENGTHS_QUERY="SELECT CONCAT_WS(',', IFNULL(MIN(CHAR_LENGTH(\`$COL\`)), 0), IFNULL(MAX(CHAR_LENGTH(\`$COL\`)), 0)) FROM \`$DATABASE\`.\`$TABLE\` WHERE \`$COL\` IS NOT NULL AND CAST(\`$COL\` AS CHAR) != '';"
    
    # Capture output and check for execution failure
    LENGTHS=$(mysql --login-path="$LOGIN_PATH" -sN -e "$LENGTHS_QUERY" 2>&1)
    if [ $? -ne 0 ]; then
        echo "   [!] MySQL Execution Error:"
        echo "       $LENGTHS"
        continue
    fi

    if [ -z "$LENGTHS" ]; then
        echo "   [!] Query returned an empty result unexpectedly."
        continue
    fi

    # Safely extract digits only to avoid trailing spaces breaking the integer logic
    MIN_LEN=$(echo "$LENGTHS" | awk -F',' '{print $1}' | tr -dc '0-9')
    ACTUAL_MAX=$(echo "$LENGTHS" | awk -F',' '{print $2}' | tr -dc '0-9')

    MIN_LEN=${MIN_LEN:-0}
    ACTUAL_MAX=${ACTUAL_MAX:-0}

    if [ "$ACTUAL_MAX" -eq 0 ]; then
        echo "   [!] Column is empty or contains only NULLs/empty strings."
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

    echo "   [Info] Data Lengths - Min: $MIN_LEN, Max: $ACTUAL_MAX. Analyzing lengths $START_LEN to $LOOP_LIMIT."

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
        echo "   [!] MySQL Execution Error:"
        echo "       $RESULT"
        continue
    fi

    if [ -z "$RESULT" ] || [ "$RESULT" == "NULL" ]; then
        echo "   [!] Failed to calculate selectivities. (Result was empty)"
        continue
    fi

    # 4. Parse results and execute Dual-Condition logic
    IFS=',' read -r -a SELECTIVITY <<< "$RESULT"
    
    # Identify the maximum selectivity achievable with the evaluated loop limit
    MAX_IDX=$((LOOP_LIMIT - START_LEN))
    MAX_SEL=${SELECTIVITY[$MAX_IDX]}
    TARGET_SEL=$(echo "$MAX_SEL * $TARGET_RATIO" | bc -l)

    echo "   [Info] Max Achievable Selectivity: $(printf "%.4f" "$MAX_SEL") (95% Target: $(printf "%.4f" "$TARGET_SEL"))"
    echo "   --- Prefix Marginal Selectivity Breakdown ---"

    declare -a GAINS
    PREV_SEL=0
    OPTIMAL_LEN=""

    for ((i=START_LEN; i<=LOOP_LIMIT; i++)); do
        IDX=$((i - START_LEN))
        SEL=${SELECTIVITY[$IDX]}
        SEL_FMT=$(printf "%.4f" "$SEL")

        if [ "$i" -eq "$START_LEN" ]; then
            DIFF=$SEL
            GAINS[$i]=$DIFF
            IS_PAST_TARGET=$(echo "$SEL >= $TARGET_SEL" | bc -l)

            if [ "$IS_PAST_TARGET" -eq 1 ] && [ -z "$OPTIMAL_LEN" ]; then
                OPTIMAL_LEN=$i
                echo "   [Length $i] Selectivity: $SEL_FMT | Marginal Gain: Base <-- Optimal (Max selectivity reached instantly)"
            else
                echo "   [Length $i] Selectivity: $SEL_FMT | Marginal Gain: Base"
            fi
        else
            DIFF=$(echo "$SEL - $PREV_SEL" | bc -l)
            GAINS[$i]=$DIFF
            DIFF_FMT=$(printf "%.4f" "$DIFF")

            # Check both conditions
            IS_PAST_TARGET=$(echo "$SEL >= $TARGET_SEL" | bc -l)
            IS_LOW_GAIN=$(echo "$DIFF <= $MARGINAL_THRESHOLD" | bc -l)

            if [ "$IS_PAST_TARGET" -eq 1 ] && [ "$IS_LOW_GAIN" -eq 1 ] && [ -z "$OPTIMAL_LEN" ]; then
                OPTIMAL_LEN=$i
                echo "   [Length $i] Selectivity: $SEL_FMT | Marginal Gain: +$DIFF_FMT <-- Optimal Sweet Spot!"
            else
                echo "   [Length $i] Selectivity: $SEL_FMT | Marginal Gain: +$DIFF_FMT"
            fi
        fi
        PREV_SEL=$SEL
    done

    # 5. Final Recommendation
    echo "   ======================================================"
    if [ -n "$OPTIMAL_LEN" ]; then
        echo "   RECOMMENDATION: Create index with prefix length $OPTIMAL_LEN"
        echo "   SQL: ALTER TABLE \`$TABLE\` ADD INDEX \`idx_${COL}_prefix\` (\`$COL\`($OPTIMAL_LEN));"
    else
        echo "   RECOMMENDATION: Selectivity criteria not met within prefix limit."
        if [ "$LOOP_LIMIT" -lt "$ACTUAL_MAX" ]; then
            echo "   You may need to increase --max-prefix."
        else
            echo "   You should index the full column."
            echo "   SQL: ALTER TABLE \`$TABLE\` ADD INDEX \`idx_${COL}\` (\`$COL\`);"
        fi
    fi
    echo "   ======================================================"
done
echo -e "\nAnalysis Complete."