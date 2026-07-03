#!/bin/bash

LOGIN_PATH=$1
DATABASE=$2
TABLE=$3
THRESHOLD=500000 

if [ -z "$TABLE" ] || [ -z "$DATABASE" ]; then
    echo "Usage: $0 <login_path> <database> <table_name>"
    exit 1
fi

# 1. Verification Layer: Compare Metadata vs. Reality
META_ROWS=$(mysql --login-path="$LOGIN_PATH" -N -s -e "SELECT TABLE_ROWS FROM information_schema.tables WHERE table_schema='$DATABASE' AND table_name='$TABLE';")
LIVE_ROWS=$(mysql --login-path="$LOGIN_PATH" -N -s -e "SELECT COUNT(*) FROM $DATABASE.$TABLE;")

# Handle potential empty strings from failed queries
[ -z "$META_ROWS" ] && META_ROWS=0
[ -z "$LIVE_ROWS" ] && LIVE_ROWS=0

echo "--- Consistency Check: $DATABASE.$TABLE ---"
echo "Metadata Rows: $META_ROWS | Live Rows: $LIVE_ROWS"

# Decision Logic: If Live count is higher than Metadata, or Meta is 0 while Live isn't, use Live.
if [ "$LIVE_ROWS" -gt "$META_ROWS" ] || [ "$META_ROWS" -eq 0 ]; then
    TOTAL_ROWS=$LIVE_ROWS
    FORCE_LIVE=true
    echo "Status: Statistics are STALE or Table is growing. Forcing Live Calculations."
else
    TOTAL_ROWS=$META_ROWS
    FORCE_LIVE=false
    echo "Status: Metadata appears consistent."
fi

echo "------------------------------------------------------------"

TEMP_REPORT=$(mktemp)

# 2. Get Column List
COLUMNS=$(mysql --login-path="$LOGIN_PATH" -N -s -e "SELECT COLUMN_NAME FROM information_schema.columns WHERE table_schema='$DATABASE' AND table_name='$TABLE';")

for COL in $COLUMNS; do
    # Get Index Info
    INDEX_INFO=$(mysql --login-path="$LOGIN_PATH" -N -s -e "
        SELECT GROUP_CONCAT(CONCAT(INDEX_NAME, '(#', SEQ_IN_INDEX, ')') SEPARATOR ', ') 
        FROM information_schema.STATISTICS 
        WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND COLUMN_NAME='$COL';")
    
    [ -z "$INDEX_INFO" ] && INDEX_INFO="---"

    # 3. Cardinality Strategy
    # We use live count if we forced it earlier OR if table is below performance threshold
    if [ "$FORCE_LIVE" = true ] || [ "$TOTAL_ROWS" -lt "$THRESHOLD" ]; then
        CARD=$(mysql --login-path="$LOGIN_PATH" -N -s -e "SELECT COUNT(DISTINCT \`$COL\`) FROM $DATABASE.$TABLE;")
    else
        CARD=$(mysql --login-path="$LOGIN_PATH" -N -s -e "SELECT CARDINALITY FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND COLUMN_NAME='$COL' LIMIT 1;")
        [ -z "$CARD" ] && CARD=0
    fi

    # 4. Calculate Ratios
    if [ "$TOTAL_ROWS" -gt 0 ]; then
        RATIO=$(echo "scale=4; $CARD / $TOTAL_ROWS" | bc)
        PCT=$(echo "scale=2; ($CARD / $TOTAL_ROWS) * 100" | bc)
    else
        RATIO="0.0000"
        PCT="0.00"
    fi

    echo "$COL|$CARD|$RATIO|$PCT|$INDEX_INFO" >> "$TEMP_REPORT"
done

# 5. Final Formatted & Sorted Output
echo "----------------------------------------------------------------------------------------------------------------"
printf "%-20s | %-12s | %-10s | %-12s | %-30s\n" "Column Name" "Cardinality" "Ratio" "Selectivity" "Existing Indexes (Pos)"
echo "----------------------------------------------------------------------------------------------------------------"

# Sort by Cardinality (Column 2) numerically reversed
sort -t'|' -k2 -rn "$TEMP_REPORT" | while IFS='|' read -r NAME CARD RAT PCT IDX; do
    printf "%-20s | %-12s | %-10s | %-11s%% | %-30s\n" "$NAME" "$CARD" "$RAT" "$PCT" "$IDX"
done

rm "$TEMP_REPORT"