#!/usr/bin/env bash

# ==============================================================================
# Color and Environment Variables
# ==============================================================================
red='\033[0;31m'
yel='\033[1;33m'
cyn='\033[0;36m'
grn='\033[0;32m'
off='\033[0m'

# Default values
PERF_THRESHOLD=500000 
DRIFT_THRESHOLD=10    
TABLE_ARRAY=()

# ==============================================================================
# Help Function (Usage)
# ==============================================================================
usage() {
    echo -e "${yel}Usage: $0 -l <login-path> -d <database> [-t <tables>] [-f <file>] [-p <perf_threshold>] [-r <drift_threshold>]${off}"
    echo -e "  -l  MySQL login-path (Required)"
    echo -e "  -d  Database (Required)"
    echo -e "  -t  Table Name(s), comma-separated (e.g., 'users,orders')"
    echo -e "  -f  File containing table names (one per line)"
    echo -e "  -p  Row limit to force live scan (Default: 500000)"
    echo -e "  -r  Allowed % of desync (Drift) limit (Default: 10)"
    echo -e "\n${cyn}Note: You must provide either -t or -f (or both).${off}"
    exit 1
}

# ==============================================================================
# Parameter Parsing
# ==============================================================================
while getopts "l:d:t:f:p:r:h" opt; do
    case ${opt} in
        l ) LOGIN_PATH="$OPTARG" ;;
        d ) DATABASE="$OPTARG" ;;
        t ) TABLE_STRING="$OPTARG" ;;
        f ) TABLE_FILE="$OPTARG" ;;
        p ) PERF_THRESHOLD="$OPTARG" ;;
        r ) DRIFT_THRESHOLD="$OPTARG" ;;
        h ) usage ;;
        \? ) usage ;;
    esac
done

if [[ -z "$LOGIN_PATH" ]] || [[ -z "$DATABASE" ]]; then
    echo -e "${red}[ERROR] Missing mandatory parameters (-l, -d).${off}\n"
    usage
fi

if [[ -z "$TABLE_STRING" ]] && [[ -z "$TABLE_FILE" ]]; then
    echo -e "${red}[ERROR] You must specify tables using -t or -f.${off}\n"
    usage
fi

# ==============================================================================
# Initialization and Detection
# ==============================================================================
MYSQLBIN=$(command -v mysql)
if [[ -z "$MYSQLBIN" ]]; then
    echo -e "${red}[ERROR] MySQL binary not found in the system.${off}"
    exit 1
fi

BCBIN=$(command -v bc)
if [[ -z "$BCBIN" ]]; then
    echo -e "${red}[ERROR] 'bc' utility not found. Please install it for mathematical calculations.${off}"
    exit 1
fi

echo -e "${cyn}Connecting to MySQL and verifying connection...${off}"
CONNECTION_CHECK=$($MYSQLBIN --login-path="${LOGIN_PATH}" -B -N -e "SELECT 1;" 2>/dev/null)

if [[ -z "$CONNECTION_CHECK" ]]; then
    echo -e "${red}[ERROR] Could not connect to MySQL. Check your login-path or credentials.${off}"
    exit 1
fi

# ==============================================================================
# Build Table List
# ==============================================================================
# 1. Add tables from command line string (-t)
if [[ -n "$TABLE_STRING" ]]; then
    # Replace commas with spaces and convert to array
    IFS=',' read -r -a TEMP_ARR <<< "$TABLE_STRING"
    for t in "${TEMP_ARR[@]}"; do
        TABLE_ARRAY+=("$(echo "$t" | xargs)") # xargs safely trims whitespace
    done
fi

# 2. Add tables from file (-f)
if [[ -n "$TABLE_FILE" ]]; then
    if [[ ! -f "$TABLE_FILE" ]]; then
        echo -e "${red}[ERROR] File '$TABLE_FILE' not found.${off}"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        TABLE_ARRAY+=("$(echo "$line" | xargs)")
    done < "$TABLE_FILE"
fi

if [[ ${#TABLE_ARRAY[@]} -eq 0 ]]; then
    echo -e "${red}[ERROR] No valid tables provided to process.${off}"
    exit 1
fi

# Remove duplicates (Cross-Platform compatible via sort -u)
UNIQUE_TABLES=()
for tbl in $(printf '%s\n' "${TABLE_ARRAY[@]}" | sort -u); do
    UNIQUE_TABLES+=("$tbl")
done

# ==============================================================================
# Main Processing Loop
# ==============================================================================
for TABLE in "${UNIQUE_TABLES[@]}"; do
    
    echo -e "\n${yel}================================================================================================================${off}"
    echo -e "${cyn}  ANALYZING TABLE: $DATABASE.$TABLE ${off}"
    echo -e "${yel}================================================================================================================${off}"

    # Verify if table exists
    TABLE_EXISTS=$($MYSQLBIN --login-path="${LOGIN_PATH}" -N -s -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DATABASE' AND table_name='$TABLE';")
    if [[ "$TABLE_EXISTS" -eq 0 ]]; then
        echo -e "${red}[WARNING] Table '$DATABASE.$TABLE' does not exist or you do not have permissions. Skipping...${off}"
        continue
    fi

    # ==============================================================================
    # Statistics and Drift Verification
    # ==============================================================================
    META_ROWS=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema='$DATABASE' AND table_name='$TABLE';")
    LIVE_ROWS=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "SELECT COUNT(*) FROM $DATABASE.$TABLE;")

    [[ -z "$META_ROWS" || "$META_ROWS" -eq 0 ]] && META_ROWS=1 
    [[ -z "$LIVE_ROWS" ]] && LIVE_ROWS=0

    DIFF=$(echo "$LIVE_ROWS - $META_ROWS" | bc | tr -d '-')
    DRIFT_PCT=$(echo "scale=2; ($DIFF / $LIVE_ROWS) * 100" | bc 2>/dev/null || echo 0)

    echo -e "${grn}--- Stats Sync Check ---${off}"
    echo "Metadata Rows : $META_ROWS"
    echo "Live Rows     : $LIVE_ROWS"
    echo "Drift Variance: $DRIFT_PCT%"

    FORCE_LIVE=false
    if (( $(echo "$DRIFT_PCT > $DRIFT_THRESHOLD" | bc -l) )) || [[ "$LIVE_ROWS" -lt "$PERF_THRESHOLD" ]]; then
        echo -e "${yel}Status: Forcing live calculations (Excluding NULL/Empty/Zero-Dates).${off}"
        FORCE_LIVE=true
        TOTAL_ROWS=$LIVE_ROWS
    else
        echo -e "${cyn}Status: Using Metadata estimates.${off}"
        FORCE_LIVE=false
        TOTAL_ROWS=$META_ROWS
    fi

    echo "----------------------------------------------------------------------------------------------------------------"
    
    # Safe temp file creation for both GNU and BSD
    TEMP_REPORT=$(mktemp "${TMPDIR:-/tmp}/cardinality_XXXXXX")

    # ==============================================================================
    # Column Analysis and Cardinality
    # ==============================================================================
    COLUMNS=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "SELECT COLUMN_NAME FROM information_schema.columns WHERE table_schema='$DATABASE' AND table_name='$TABLE';")

    for COL in $COLUMNS; do
        INDEX_INFO=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "
            SELECT GROUP_CONCAT(CONCAT(INDEX_NAME, '(#', SEQ_IN_INDEX, ')') SEPARATOR ', ') 
            FROM information_schema.STATISTICS 
            WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND COLUMN_NAME='$COL';")
        
        [[ -z "$INDEX_INFO" ]] && INDEX_INFO="---"

        if [[ "$FORCE_LIVE" == true ]]; then
            STATS=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "
                SELECT 
                    COUNT(DISTINCT CASE WHEN \`$COL\` IS NOT NULL AND CHAR_LENGTH(\`$COL\`) > 0 THEN \`$COL\` END), 
                    COUNT(CASE WHEN \`$COL\` IS NOT NULL AND CHAR_LENGTH(\`$COL\`) > 0 THEN 1 END) 
                FROM $DATABASE.$TABLE;")
            
            CARD=$(echo "$STATS" | awk '{print $1}')
            CLEAN_ROWS=$(echo "$STATS" | awk '{print $2}')
            
            [[ -z "$CARD" ]] && CARD=0
            [[ -z "$CLEAN_ROWS" ]] && CLEAN_ROWS=0
            CURRENT_DENOMINATOR=$CLEAN_ROWS
        else
            CARD=$($MYSQLBIN --login-path="$LOGIN_PATH" -N -s -e "SELECT CARDINALITY FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND COLUMN_NAME='$COL' LIMIT 1;")
            [[ -z "$CARD" ]] && CARD=0
            CURRENT_DENOMINATOR=$TOTAL_ROWS
        fi

        if [[ "$CURRENT_DENOMINATOR" -gt 0 ]]; then
            RATIO=$(echo "scale=4; $CARD / $CURRENT_DENOMINATOR" | bc)
            PCT=$(echo "scale=2; ($CARD / $CURRENT_DENOMINATOR) * 100" | bc)
        else
            RATIO="0.0000"; PCT="0.00"
        fi

        echo "$COL|$CARD|$RATIO|$PCT|$INDEX_INFO" >> "$TEMP_REPORT"
    done

    # ==============================================================================
    # Final Table Report
    # ==============================================================================
    printf "${grn}%-20s | %-12s | %-10s | %-12s | %-30s${off}\n" "Column Name" "Cardinality" "Ratio" "Selectivity" "Existing Indexes (Pos)"
    echo "----------------------------------------------------------------------------------------------------------------"

    # Standard POSIX sort implementation
    sort -t'|' -k2 -rn "$TEMP_REPORT" | while IFS='|' read -r NAME CARD RAT PCT IDX; do
        printf "%-20s | %-12s | %-10s | %-11s%% | %-30s\n" "$NAME" "$CARD" "$RAT" "$PCT" "$IDX"
    done

    # Clean up temp file safely
    rm -f "$TEMP_REPORT"

done # End of Main Loop

echo -e "\n${grn}[SUCCESS] All requested tables have been processed.${off}"
