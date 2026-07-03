#!/usr/bin/env bash

# ==============================================================================
# MySQL Storage & Memory Estimator (Data vs. Index vs. Rows)
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Help Section ---
show_help() {
    echo -e "${CYAN}Usage:${NC} $0 [OPTIONS]"
    echo -e "Estimate MySQL storage, Buffer Pool memory, and row growth."
    echo ""
    echo -e "${YELLOW}Required Arguments:${NC}"
    echo -e "  -l, --login-path PATH   MySQL login path (configured via mysql_config_editor)"
    echo -e "  -d, --database NAME     Target database name"
    echo -e "  -t, --table-prefix PFX  Table prefix (e.g., 'users' matches 'users_*')"
    echo -e "  -r, --rows NUM          Estimated number of rows inserted per time unit"
    echo ""
    echo -e "${YELLOW}Optional Arguments:${NC}"
    echo -e "  -u, --unit UNIT         Time unit for rows: 'hour' or 'day' (Default: day)"
    echo -e "  -k, --retention DAYS    Data retention period in days (Default: 30)"
    echo -e "  -i, --index-factor NUM  Estimated index size multiplier (Default: 0.3 = 30%)"
    echo -e "  -h, --help              Show this help message"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  $0 -l dev_db -d app_data -t logs -r 50000 -k 90"
    echo -e "  $0 -l dev_db -d app_data -t logs -r 2500 -u hour -k 15 -i 0.5"
    exit 0
}

# --- Parse Command Line Arguments ---
RETENTION_DAYS=30 # Default
UNIT="day"        # Default
IDX_FACTOR=0.3    # Default (30% index overhead)

# Show help by default if no arguments are provided
if [[ "$#" -eq 0 ]]; then
    show_help
fi

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -l|--login-path) LOGIN_PATH="$2"; shift ;;
        -d|--database) DB_NAME="$2"; shift ;;
        -t|--table-prefix) TABLE_PREFIX="$2"; shift ;;
        -r|--rows) ROWS="$2"; shift ;;
        -u|--unit) UNIT="$2"; shift ;;
        -k|--retention) RETENTION_DAYS="$2"; shift ;;
        -i|--index-factor) IDX_FACTOR="$2"; shift ;;
        *) 
            echo -e "${RED}Unknown parameter passed: $1${NC}"
            echo -e "Run '${CYAN}$0 --help${NC}' for usage information."
            exit 1 
            ;;
    esac
    shift
done

# --- Validation ---
if [[ -z "$LOGIN_PATH" || -z "$DB_NAME" || -z "$TABLE_PREFIX" || -z "$ROWS" ]]; then
    echo -e "${RED}Error: Missing required arguments.${NC}"
    echo -e "Run '${CYAN}$0 --help${NC}' for usage information."
    exit 1
fi

# Validate numeric inputs (Regex allows decimals for index factor)
if ! [[ "$ROWS" =~ ^[0-9]+$ ]] || ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: --rows and --retention must be positive integers.${NC}"
    exit 1
fi
if ! [[ "$IDX_FACTOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo -e "${RED}Error: --index-factor must be a number (e.g., 0.3).${NC}"
    exit 1
fi

# Convert unit to lowercase and set dynamic SQL variables
UNIT=$(echo "$UNIT" | tr '[:upper:]' '[:lower:]')
if [[ "$UNIT" == "hour" ]]; then
    CALC_DAILY_ROWS=$(( ROWS * 24 ))
    DISPLAY_INPUT="$ROWS/hr"
    UNIT_DIVISOR=24
    UNIT_LABEL="Hour"
    DAILY_TOTAL_COL="ROUND(SUM(daily_data_mb + daily_idx_mb), 2) AS Total_MB_Day,"
elif [[ "$UNIT" == "day" ]]; then
    CALC_DAILY_ROWS=$ROWS
    DISPLAY_INPUT="$ROWS/day"
    UNIT_DIVISOR=1
    UNIT_LABEL="Day"
    DAILY_TOTAL_COL="" # Omit to prevent column duplication when unit is already 'Day'
else
    echo -e "${RED}Error: --unit must be either 'hour' or 'day'.${NC}"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M")
CSV_OUT="storage_estimate_${TABLE_PREFIX}_${TIMESTAMP}.csv"

# --- 1. Check Connection, Version, and Buffer Pool Size ---
MYSQL_VER=$(mysql --login-path="$LOGIN_PATH" -sN -e "SELECT VERSION();" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Connection failed.${NC} Check your login-path: 'mysql_config_editor list'"
    exit 1
fi

# Fetch Buffer Pool Size in Bytes and convert to GB for display
BP_BYTES=$(mysql --login-path="$LOGIN_PATH" -sN -e "SELECT @@innodb_buffer_pool_size;" 2>/dev/null)
if [[ -n "$BP_BYTES" && "$BP_BYTES" =~ ^[0-9]+$ ]]; then
    BP_GB=$(awk "BEGIN {printf \"%.2f\", $BP_BYTES / 1024 / 1024 / 1024}")
else
    BP_GB="Unknown"
    BP_BYTES=1 # Prevent division by zero if fetching fails
fi

echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
echo -e "${YELLOW}MySQL Version:${NC} $MYSQL_VER | ${YELLOW}Buffer Pool Size:${NC} ${BP_GB} GB"
echo -e "${YELLOW}Target DB:    ${NC} $DB_NAME.${TABLE_PREFIX}*"
echo -e "${YELLOW}Growth Rate:  ${NC} $DISPLAY_INPUT | ${YELLOW}Retention:${NC} $RETENTION_DAYS days"
echo -e "${YELLOW}Index Factor: ${NC} $IDX_FACTOR | ${YELLOW}Output File:${NC} $CSV_OUT"
echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"

# --- 2. The SQL Query ---
QUERY="
SELECT 
    IFNULL(TABLE_NAME, 'TOTAL') AS Table_Name,
    CAST(SUM(daily_rows) / $UNIT_DIVISOR AS UNSIGNED) AS Rows_$UNIT_LABEL,
    CAST(SUM(daily_rows) * $RETENTION_DAYS AS UNSIGNED) AS Total_Rows,
    ROUND(SUM(daily_data_mb) / $UNIT_DIVISOR, 4) AS Data_MB_$UNIT_LABEL,
    ROUND(SUM(daily_idx_mb) / $UNIT_DIVISOR, 4) AS Idx_MB_$UNIT_LABEL,
    ROUND(SUM(daily_data_mb + daily_idx_mb) / $UNIT_DIVISOR, 4) AS Total_MB_$UNIT_LABEL,
    $DAILY_TOTAL_COL
    ROUND((SUM(daily_data_mb + daily_idx_mb) * 30) / 1024, 2) AS Total_GB_Month,
    ROUND((SUM(daily_data_mb + daily_idx_mb) * $RETENTION_DAYS) / 1024, 2) AS Retention_GB,
    CONCAT(ROUND(((SUM(daily_data_mb + daily_idx_mb) * $RETENTION_DAYS) * 1024 * 1024 / @@innodb_buffer_pool_size) * 100, 2), '%') AS BP_Pct_Total
FROM (
    SELECT 
        TABLE_NAME,
        $CALC_DAILY_ROWS AS daily_rows,
        -- Data Size: Row size * est. daily rows * 1.2 (InnoDB Fragmentation factor)
        (SUM(col_size) * $CALC_DAILY_ROWS * 1.2) / 1024 / 1024 AS daily_data_mb,
        -- Index Size: Calculated based on the provided index factor multiplier
        (SUM(col_size) * $CALC_DAILY_ROWS * 1.2 * $IDX_FACTOR) / 1024 / 1024 AS daily_idx_mb
    FROM (
        SELECT 
            TABLE_NAME,
            CASE 
                -- Numerics
                WHEN DATA_TYPE IN ('tinyint', 'bool', 'boolean') THEN 1
                WHEN DATA_TYPE = 'smallint' THEN 2
                WHEN DATA_TYPE = 'mediumint' THEN 3
                WHEN DATA_TYPE = 'int' THEN 4
                WHEN DATA_TYPE = 'bigint' THEN 8
                WHEN DATA_TYPE = 'float' THEN 4
                WHEN DATA_TYPE = 'double' THEN 8
                WHEN DATA_TYPE = 'decimal' THEN (NUMERIC_PRECISION / 2) + 1
                -- Dates
                WHEN DATA_TYPE = 'date' THEN 3
                WHEN DATA_TYPE IN ('datetime', 'timestamp') THEN 8
                WHEN DATA_TYPE = 'time' THEN 3
                WHEN DATA_TYPE = 'year' THEN 1
                -- Strings
                WHEN DATA_TYPE IN ('char', 'varchar', 'binary', 'varbinary') THEN CHARACTER_OCTET_LENGTH
                -- LOBs / JSON / Geospatial (Baseline 1KB per row)
                WHEN DATA_TYPE LIKE '%text%' OR DATA_TYPE LIKE '%blob%' OR DATA_TYPE IN ('json', 'geometry', 'point') THEN 1024
                ELSE 8 
            END AS col_size
        FROM information_schema.COLUMNS 
        WHERE TABLE_SCHEMA = '$DB_NAME' 
          AND TABLE_NAME LIKE '$TABLE_PREFIX%'
    ) AS col_data
    GROUP BY TABLE_NAME
) AS table_totals
GROUP BY TABLE_NAME WITH ROLLUP;"

# --- 3. Execute and Output to Table (Terminal) and CSV (File) ---
# Generate Terminal Table
mysql --login-path="$LOGIN_PATH" -t -e "$QUERY" "$DB_NAME"

# Generate CSV
mysql --login-path="$LOGIN_PATH" -s -e "$QUERY" "$DB_NAME" | tr '\t' ',' > "$CSV_OUT"

echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Done.${NC} CSV report generated: ${YELLOW}$CSV_OUT${NC}"