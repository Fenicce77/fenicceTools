#!/usr/bin/env bash
# ==============================================================================
# Script: fk_analyzer.sh
# Role: Senior DBA Diagnostic Tool for MySQL 8.0.x / 8.4.x (GCP Cloud SQL)
# Description: Shows DDL, analyzes physical and virtual foreign key relationships,
#              evaluates indexes, cardinality, and lists full compound index maps.
# Environment: Linux/MacOS, bash. Requires mysql client and login-path.
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
L_GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
L_MAGENTA='\033[1;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Variables ---
LOGIN_PATH=""
SCHEMA_NAME=""
TABLE_NAME=""
SHOW_TREE=0
SHOW_CARDINALITY=0

# --- Functions ---

usage() {
    echo -e "${BOLD}${CYAN}MySQL Referential Topology Analyzer (Physical & Virtual)${RESET}"
    echo -e "Usage: $0 -l <login-path> -s <schema> -t <table> [OPTIONS]\n"
    echo -e "${BOLD}Required Parameters:${RESET}"
    echo -e "  -l    MySQL login-path (configured via mysql_config_editor)"
    echo -e "  -s    Target database schema"
    echo -e "  -t    Target table name\n"
    echo -e "${BOLD}Optional Parameters:${RESET}"
    echo -e "  -c    Enable Cardinality & Table Statistics Analysis"
    echo -e "  -r    Enable Tree Representation of references"
    echo -e "  -h    Show this help menu\n"
    echo -e "${BOLD}Example:${RESET}"
    echo -e "  $0 -l my_cloudsql_prod -s ecom_db -t orders -c -r"
    exit 1
}

# Parse Arguments
while getopts "l:s:t:crh" opt; do
    case ${opt} in
        l ) LOGIN_PATH=$OPTARG ;;
        s ) SCHEMA_NAME=$OPTARG ;;
        t ) TABLE_NAME=$OPTARG ;;
        c ) SHOW_CARDINALITY=1 ;;
        r ) SHOW_TREE=1 ;;
        h | * ) usage ;;
    esac
done

# Enforce mandatory parameters
if [[ -z "$LOGIN_PATH" || -z "$SCHEMA_NAME" || -z "$TABLE_NAME" ]]; then
    echo -e "${RED}Error: Missing required parameters.${RESET}"
    usage
fi

# MySQL execution wrapper
run_mysql() {
    local query="$1"
    mysql --login-path="${LOGIN_PATH}" -sNe "${query}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error executing MySQL query. Check your login-path and connection to Cloud SQL.${RESET}"
        exit 1
    fi
}

echo -e "\n${BOLD}${CYAN}====================================================================${RESET}"
echo -e "${BOLD}${CYAN}  REFERENTIAL TOPOLOGY REPORT FOR: ${YELLOW}${SCHEMA_NAME}.${TABLE_NAME}${RESET}"
echo -e "${BOLD}${CYAN}====================================================================${RESET}\n"

# ---------------------------------------------------------
# 0. Table DDL & Primary Key Identification
# ---------------------------------------------------------
echo -e "${BOLD}${CYAN}[0] TABLE DDL & IDENTITY${RESET}"
DDL_QUERY="SHOW CREATE TABLE \`${SCHEMA_NAME}\`.\`${TABLE_NAME}\`;"
DDL_RES=$(run_mysql "${DDL_QUERY}" | cut -f2)

if [[ -n "$DDL_RES" ]]; then
    echo -e "${DIM}${CYAN}┌──────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BLUE}${DDL_RES}${RESET}"
    echo -e "${DIM}${CYAN}└──────────────────────────────────────────────────────────────────┘${RESET}\n"
else
    echo -e "  ${RED}Failed to retrieve DDL. Check table existence or permissions.${RESET}\n"
fi

PK_COL=$(run_mysql "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND CONSTRAINT_NAME='PRIMARY' LIMIT 1;")
if [[ -n "$PK_COL" ]]; then
    PK_TYPE=$(run_mysql "SELECT COLUMN_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${PK_COL}';")
    echo -e "  ${BOLD}Primary Key Detected:${RESET} ${YELLOW}${PK_COL}${RESET} (${CYAN}${PK_TYPE}${RESET})\n"
else
    echo -e "  ${YELLOW}Warning: No Primary Key detected for this table.${RESET}\n"
fi

# ---------------------------------------------------------
# 1. References FROM the table (Outbound Physical FKs)
# ---------------------------------------------------------
QUERY_OUTBOUND="
SELECT rc.CONSTRAINT_NAME, 
       kcu.COLUMN_NAME, 
       kcu.REFERENCED_TABLE_NAME, 
       kcu.REFERENCED_COLUMN_NAME, 
       rc.UPDATE_RULE, 
       rc.DELETE_RULE
FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu 
  ON rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME 
 AND rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
WHERE rc.CONSTRAINT_SCHEMA = '${SCHEMA_NAME}' 
  AND rc.TABLE_NAME = '${TABLE_NAME}';"

echo -e "${BOLD}${GREEN}[1] REFERENCES FROM TABLE (OUTBOUND PHYSICAL)${RESET}"
echo -e "Dependencies where ${YELLOW}${TABLE_NAME}${RESET} logically requires other tables:\n"

OUTBOUND_RES=$(run_mysql "${QUERY_OUTBOUND}")

if [[ -z "$OUTBOUND_RES" ]]; then
    echo -e "  ${DIM}No physical outbound foreign keys found.${RESET}\n"
else
    echo "$OUTBOUND_RES" | while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
        echo -e "  ${BOLD}FK Name:${RESET} ${GREEN}${c_name}${RESET}"
        echo -e "  ${BOLD}Mapping:${RESET} ${TABLE_NAME}(${col_name}) ${GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
        echo -e "  ${BOLD}Constraints:${RESET} ON UPDATE ${upd_rule} | ON DELETE ${del_rule}"
        echo -e "  --------------------------------------------------------"
    done
fi

# ---------------------------------------------------------
# 1.5 Virtual References FROM the table (Outbound Virtual FKs)
# ---------------------------------------------------------
echo -e "\n${BOLD}${L_GREEN}[1.5] VIRTUAL REFERENCES FROM TABLE (OUTBOUND LOGICAL)${RESET}"
echo -e "Dependencies where ${YELLOW}${TABLE_NAME}${RESET} logically references other tables:\n"

QUERY_VFK_OUT="
SELECT c1.COLUMN_NAME, t2.TABLE_NAME, c2.COLUMN_NAME, c1.COLUMN_TYPE,
       IF(EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS s WHERE s.TABLE_SCHEMA=c1.TABLE_SCHEMA AND s.TABLE_NAME=c1.TABLE_NAME AND s.COLUMN_NAME=c1.COLUMN_NAME), 1, 0) AS is_idx
FROM INFORMATION_SCHEMA.COLUMNS c1
JOIN INFORMATION_SCHEMA.TABLES t2 
  ON t2.TABLE_SCHEMA = c1.TABLE_SCHEMA 
  AND t2.TABLE_NAME = SUBSTRING(c1.COLUMN_NAME, 1, CHAR_LENGTH(c1.COLUMN_NAME) - 3)
JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 
  ON kcu2.TABLE_SCHEMA = t2.TABLE_SCHEMA 
  AND kcu2.TABLE_NAME = t2.TABLE_NAME 
  AND kcu2.CONSTRAINT_NAME = 'PRIMARY'
JOIN INFORMATION_SCHEMA.COLUMNS c2 
  ON c2.TABLE_SCHEMA = kcu2.TABLE_SCHEMA 
  AND c2.TABLE_NAME = kcu2.TABLE_NAME 
  AND c2.COLUMN_NAME = kcu2.COLUMN_NAME
LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu_phys 
  ON kcu_phys.TABLE_SCHEMA = c1.TABLE_SCHEMA 
  AND kcu_phys.TABLE_NAME = c1.TABLE_NAME 
  AND kcu_phys.COLUMN_NAME = c1.COLUMN_NAME 
  AND kcu_phys.REFERENCED_TABLE_NAME IS NOT NULL
WHERE c1.TABLE_SCHEMA = '${SCHEMA_NAME}'
  AND c1.TABLE_NAME = '${TABLE_NAME}'
  AND c1.COLUMN_NAME LIKE '%_id'
  AND c1.COLUMN_NAME != 'created_by'
  AND c1.DATA_TYPE NOT IN ('datetime', 'timestamp', 'date', 'time')
  AND c1.DATA_TYPE = c2.DATA_TYPE
  AND c2.COLUMN_NAME IN ('id', c1.COLUMN_NAME)
  AND kcu_phys.COLUMN_NAME IS NULL
GROUP BY c1.COLUMN_NAME, t2.TABLE_NAME, c2.COLUMN_NAME, c1.COLUMN_TYPE, is_idx;"

VFK_OUT_RES=$(run_mysql "${QUERY_VFK_OUT}")

if [[ -z "$VFK_OUT_RES" ]]; then
    echo -e "  ${DIM}No virtual outbound foreign keys detected.${RESET}\n"
else
    echo "$VFK_OUT_RES" | while IFS=$'\t' read -r col_name ref_tab ref_col col_type is_idx; do
        echo -e "  ${BOLD}V-FK Rule:${RESET} ${L_GREEN}[APPLICATION LAYER]${RESET}"
        echo -e "  ${BOLD}Mapping:${RESET}   ${TABLE_NAME}(${col_name}) ${L_GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
        if [[ "$is_idx" -eq 1 ]]; then
            echo -e "  ${BOLD}Verified:${RESET}  Type matches target PK (${col_type}). ${GREEN}[Indexed]${RESET}"
        else
            echo -e "  ${BOLD}Verified:${RESET}  Type matches target PK (${col_type}). ${RED}${BOLD}[WARNING: Column is NOT INDEXED]${RESET}"
        fi
        echo -e "  --------------------------------------------------------"
    done
    echo ""
fi

# ---------------------------------------------------------
# 2. References TO the table (Inbound Physical FKs)
# ---------------------------------------------------------
QUERY_INBOUND="
SELECT rc.CONSTRAINT_NAME, 
       rc.TABLE_NAME, 
       kcu.COLUMN_NAME, 
       kcu.REFERENCED_COLUMN_NAME, 
       rc.UPDATE_RULE, 
       rc.DELETE_RULE
FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu 
  ON rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME 
 AND rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
WHERE rc.CONSTRAINT_SCHEMA = '${SCHEMA_NAME}' 
  AND rc.REFERENCED_TABLE_NAME = '${TABLE_NAME}';"

echo -e "\n${BOLD}${MAGENTA}[2] REFERENCES TO TABLE (INBOUND PHYSICAL)${RESET}"
echo -e "Other tables that rely strictly on ${YELLOW}${TABLE_NAME}${RESET}:\n"

INBOUND_RES=$(run_mysql "${QUERY_INBOUND}")

if [[ -z "$INBOUND_RES" ]]; then
    echo -e "  ${DIM}No physical inbound foreign keys found.${RESET}\n"
else
    echo "$INBOUND_RES" | while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
        echo -e "  ${BOLD}FK Name:${RESET} ${MAGENTA}${c_name}${RESET}"
        echo -e "  ${BOLD}Mapping:${RESET} ${TABLE_NAME}(${ref_col}) ${MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})"
        echo -e "  ${BOLD}Constraints:${RESET} ON UPDATE ${upd_rule} | ON DELETE ${del_rule}"
        echo -e "  --------------------------------------------------------"
    done
fi

# ---------------------------------------------------------
# 2.5 Virtual References TO the table (Inbound Virtual FKs)
# ---------------------------------------------------------
echo -e "\n${BOLD}${L_MAGENTA}[2.5] VIRTUAL REFERENCES TO TABLE (INBOUND LOGICAL)${RESET}"
echo -e "Other tables that rely virtually on ${YELLOW}${TABLE_NAME}${RESET}:\n"

VFK_IN_RES=""
if [[ -n "$PK_COL" && -n "$PK_TYPE" ]]; then
    QUERY_VFK_IN="
    SELECT c1.TABLE_NAME, c1.COLUMN_NAME, c2.COLUMN_NAME,
           IF(EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS s WHERE s.TABLE_SCHEMA=c1.TABLE_SCHEMA AND s.TABLE_NAME=c1.TABLE_NAME AND s.COLUMN_NAME=c1.COLUMN_NAME), 1, 0) AS is_idx
    FROM INFORMATION_SCHEMA.COLUMNS c1
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 
      ON kcu2.TABLE_SCHEMA = c1.TABLE_SCHEMA 
      AND kcu2.TABLE_NAME = '${TABLE_NAME}' 
      AND kcu2.CONSTRAINT_NAME = 'PRIMARY'
    JOIN INFORMATION_SCHEMA.COLUMNS c2 
      ON c2.TABLE_SCHEMA = kcu2.TABLE_SCHEMA 
      AND c2.TABLE_NAME = kcu2.TABLE_NAME 
      AND c2.COLUMN_NAME = kcu2.COLUMN_NAME
    LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu_phys 
      ON kcu_phys.TABLE_SCHEMA = c1.TABLE_SCHEMA 
      AND kcu_phys.TABLE_NAME = c1.TABLE_NAME 
      AND kcu_phys.COLUMN_NAME = c1.COLUMN_NAME 
      AND kcu_phys.REFERENCED_TABLE_NAME IS NOT NULL
    WHERE c1.TABLE_SCHEMA = '${SCHEMA_NAME}'
      AND c1.TABLE_NAME != '${TABLE_NAME}'
      AND c1.COLUMN_NAME LIKE '%_id'
      AND c1.COLUMN_NAME != 'created_by'
      AND SUBSTRING(c1.COLUMN_NAME, 1, CHAR_LENGTH(c1.COLUMN_NAME) - 3) = '${TABLE_NAME}'
      AND c1.DATA_TYPE NOT IN ('datetime', 'timestamp', 'date', 'time')
      AND c1.DATA_TYPE = c2.DATA_TYPE
      AND c2.COLUMN_NAME IN ('id', c1.COLUMN_NAME)
      AND kcu_phys.COLUMN_NAME IS NULL
    GROUP BY c1.TABLE_NAME, c1.COLUMN_NAME, c2.COLUMN_NAME, is_idx;"

    VFK_IN_RES=$(run_mysql "${QUERY_VFK_IN}")
    
    if [[ -z "$VFK_IN_RES" ]]; then
        echo -e "  ${DIM}No virtual inbound foreign keys detected.${RESET}\n"
    else
        echo "$VFK_IN_RES" | while IFS=$'\t' read -r src_tab src_col ref_col is_idx; do
            echo -e "  ${BOLD}V-FK Rule:${RESET} ${L_MAGENTA}[APPLICATION LAYER]${RESET}"
            echo -e "  ${BOLD}Mapping:${RESET}   ${TABLE_NAME}(${ref_col}) ${L_MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})"
            if [[ "$is_idx" -eq 1 ]]; then
                echo -e "  ${BOLD}Verified:${RESET}  Type matches target PK. ${GREEN}[Indexed]${RESET}"
            else
                echo -e "  ${BOLD}Verified:${RESET}  Type matches target PK. ${RED}${BOLD}[WARNING: Column is NOT INDEXED]${RESET}"
            fi
            echo -e "  --------------------------------------------------------"
        done
        echo ""
    fi
else
    echo -e "  ${YELLOW}Skipped: Cannot compute virtual FKs without a valid Primary Key.${RESET}\n"
fi

# ---------------------------------------------------------
# 3. Cardinality Analysis (Safe Mode via Stats + Live PK Count)
# ---------------------------------------------------------
if [[ "$SHOW_CARDINALITY" -eq 1 ]]; then
    echo -e "\n${BOLD}${CYAN}[3] CARDINALITY & ROW ESTIMATES (STATISTICS)${RESET}"

    if [[ -z "$OUTBOUND_RES" && -z "$INBOUND_RES" && -z "$VFK_IN_RES" && -z "$VFK_OUT_RES" ]]; then
        echo -e "  ${DIM}Info:${RESET} Cardinality and row estimation skipped. No referential dependencies found."
    else
        # --- 3.1 Row Accounting: Live vs Dictionary ---
        echo -e "  ${BOLD}Evaluating Row Counts (Live vs Dictionary)...${RESET}"
        
        if [[ -z "$PK_COL" ]]; then
            COUNT_QUERY="SELECT COUNT(*) FROM \`${SCHEMA_NAME}\`.\`${TABLE_NAME}\`;"
        else
            COUNT_QUERY="SELECT COUNT(\`${PK_COL}\`) FROM \`${SCHEMA_NAME}\`.\`${TABLE_NAME}\`;"
        fi
        
        EXACT_COUNT=$(run_mysql "${COUNT_QUERY}")
        EST_COUNT=$(run_mysql "SELECT IFNULL(TABLE_ROWS, 0) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}';")
        
        if [[ "$EXACT_COUNT" -eq 0 && "$EST_COUNT" -eq 0 ]]; then
            DIFF_PCT=0.00
        elif [[ "$EXACT_COUNT" -eq 0 ]]; then
            DIFF_PCT=100.00
        else
            DIFF_PCT=$(awk -v exact="$EXACT_COUNT" -v est="$EST_COUNT" 'BEGIN { val = 100 * (exact - est) / exact; if (val < 0) val = -val; printf "%.2f", val }')
        fi
        
        IS_STALE=$(awk -v pct="$DIFF_PCT" 'BEGIN { if (pct > 10.0) print 1; else print 0 }')
        
        if [[ "$IS_STALE" -eq 1 ]]; then
            echo -e "  ${BOLD}Table Rows Displayed:${RESET} ${RED}${EXACT_COUNT}${RESET} (Live Count via PK)"
            echo -e "  ${YELLOW}Warning:${RESET} Dictionary stats are stale! (Estimate: ${EST_COUNT} | Diff: ${RED}${DIFF_PCT}%${RESET})"
            echo -e "  ${YELLOW}Recommendation:${RESET} Consider running 'ANALYZE TABLE \`${SCHEMA_NAME}\`.\`${TABLE_NAME}\`;'\n"
        else
            echo -e "  ${BOLD}Table Rows Displayed:${RESET} ${GREEN}${EST_COUNT}${RESET} (Dictionary Estimate)"
            echo -e "  ${CYAN}Info:${RESET} Stats are healthy. (Exact: ${EXACT_COUNT} | Diff: ${GREEN}${DIFF_PCT}%${RESET})\n"
        fi

        # --- 3.2 Index Cardinality For INVOLVED RELATIONS Only ---
        echo -e "  ${BOLD}[3.2] Index Cardinalities for Involved Columns (Physical & Virtual):${RESET}"
        
        CARD_DATA=""

        # Process Physical Outbound (Safe Subshell Pattern)
        if [[ -n "$OUTBOUND_RES" ]]; then
            OUT_BLOCK=$(echo "$OUTBOUND_RES" | while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${col_name}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${ref_tab}' AND COLUMN_NAME='${ref_col}';")
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"
                echo -e "OUTBOUND\t${c_name}\t${TABLE_NAME}.${col_name}\t${src_card}\t${ref_tab}.${ref_col}\t${tgt_card}"
            done)
            [[ -n "$OUT_BLOCK" ]] && CARD_DATA+="${OUT_BLOCK}\n"
        fi

        # Process Virtual Outbound (Safe Subshell Pattern)
        if [[ -n "$VFK_OUT_RES" ]]; then
            VOUT_BLOCK=$(echo "$VFK_OUT_RES" | while IFS=$'\t' read -r col_name ref_tab ref_col col_type is_idx; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${col_name}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${ref_tab}' AND COLUMN_NAME='${ref_col}';")
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"
                echo -e "VIRTUAL OUT\t[LOGICAL_FK]\t${TABLE_NAME}.${col_name}\t${src_card}\t${ref_tab}.${ref_col}\t${tgt_card}"
            done)
            [[ -n "$VOUT_BLOCK" ]] && CARD_DATA+="${VOUT_BLOCK}\n"
        fi

        # Process Physical Inbound (Safe Subshell Pattern)
        if [[ -n "$INBOUND_RES" ]]; then
            IN_BLOCK=$(echo "$INBOUND_RES" | while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${src_tab}' AND COLUMN_NAME='${src_col}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${ref_col}';")
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"
                echo -e "INBOUND\t${c_name}\t${src_tab}.${src_col}\t${src_card}\t${TABLE_NAME}.${ref_col}\t${tgt_card}"
            done)
            [[ -n "$IN_BLOCK" ]] && CARD_DATA+="${IN_BLOCK}\n"
        fi

        # Process Virtual Inbound (Safe Subshell Pattern)
        if [[ -n "$VFK_IN_RES" ]]; then
            VIN_BLOCK=$(echo "$VFK_IN_RES" | while IFS=$'\t' read -r src_tab src_col ref_col is_idx; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${src_tab}' AND COLUMN_NAME='${src_col}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${ref_col}';")
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"
                echo -e "VIRTUAL IN\t[LOGICAL_FK]\t${src_tab}.${src_col}\t${src_card}\t${TABLE_NAME}.${ref_col}\t${tgt_card}"
            done)
            [[ -n "$VIN_BLOCK" ]] && CARD_DATA+="${VIN_BLOCK}\n"
        fi

        # Feed the compiled data into awk for beautiful, aligned formatting
        echo -en "$CARD_DATA" | grep -v '^$' | awk -F'\t' '
        BEGIN {
            w1=12; w2=15; w3=18; w4=11; w5=18; w6=11;
        }
        {
            if(length($1)>w1) w1=length($1);
            if(length($2)>w2) w2=length($2);
            if(length($3)>w3) w3=length($3);
            if(length($4)>w4) w4=length($4);
            if(length($5)>w5) w5=length($5);
            if(length($6)>w6) w6=length($6);
            lines[NR] = $0
        }
        END {
            # Print Headers
            printf "  %-*s   %-*s   %-*s   %-*s   %-*s   %-*s\n", \
                   w1, "DIRECTION", w2, "CONSTRAINT NAME", w3, "SOURCE (TABLE.COL)", w4, "CARDINALITY", w5, "TARGET (TABLE.COL)", w6, "CARDINALITY"
            
            # Print Separators
            d1 = sprintf("%*s", w1, ""); gsub(/ /, "-", d1);
            d2 = sprintf("%*s", w2, ""); gsub(/ /, "-", d2);
            d3 = sprintf("%*s", w3, ""); gsub(/ /, "-", d3);
            d4 = sprintf("%*s", w4, ""); gsub(/ /, "-", d4);
            d5 = sprintf("%*s", w5, ""); gsub(/ /, "-", d5);
            d6 = sprintf("%*s", w6, ""); gsub(/ /, "-", d6);
            printf "  %-*s   %-*s   %-*s   %-*s   %-*s   %-*s\n", w1, d1, w2, d2, w3, d3, w4, d4, w5, d5, w6, d6
            
            # Print Data
            for (i=1; i<=NR; i++) {
                split(lines[i], f, "\t");
                
                # Colors based on Direction
                if (f[1] == "OUTBOUND") c_dir = "\033[0;32m";
                else if (f[1] == "INBOUND") c_dir = "\033[0;35m";
                else if (f[1] == "VIRTUAL OUT") c_dir = "\033[1;32m";
                else c_dir = "\033[1;35m"; # VIRTUAL IN
                
                c_reset = "\033[0m"; c_blue = "\033[0;34m"; c_yellow = "\033[1;33m"; c_cyan = "\033[0;36m";

                printf "  %s%-*s%s   %s%-*s%s   %s%-*s%s   %s%-*s%s   %s%-*s%s   %s%-*s%s\n", \
                    c_dir, w1, f[1], c_reset, \
                    c_blue, w2, f[2], c_reset, \
                    c_yellow, w3, f[3], c_reset, \
                    c_cyan, w4, f[4], c_reset, \
                    c_yellow, w5, f[5], c_reset, \
                    c_cyan, w6, f[6], c_reset;
            }
        }'

        # --- 3.3 Target Table Index Mapping ---
        echo -e "\n  ${BOLD}[3.3] Local Index Coverage (Compound Analysis for Involved Columns):${RESET}"
        
        # Consolidate all local table columns mapped in the FK logic
        LOCAL_COLS=""
        [[ -n "$OUTBOUND_RES" ]] && LOCAL_COLS+=$(echo "$OUTBOUND_RES" | awk -F'\t' '{print $2}')"\n"
        [[ -n "$VFK_OUT_RES" ]] && LOCAL_COLS+=$(echo "$VFK_OUT_RES" | awk -F'\t' '{print $1}')"\n"
        [[ -n "$INBOUND_RES" ]] && LOCAL_COLS+=$(echo "$INBOUND_RES" | awk -F'\t' '{print $4}')"\n"
        [[ -n "$VFK_IN_RES" ]] && LOCAL_COLS+=$(echo "$VFK_IN_RES" | awk -F'\t' '{print $3}')"\n"
        
        IN_CLAUSE=$(echo -e "$LOCAL_COLS" | grep -v '^$' | sort -u | awk '{printf "\x27%s\x27,", $1}' | sed 's/,$//')

        if [[ -n "$IN_CLAUSE" ]]; then
            QUERY_IDX_EXAMINER="
            SELECT s1.COLUMN_NAME, 
                   s1.INDEX_NAME, 
                   IF(s1.NON_UNIQUE=0, 'UNIQUE', 'NON-UNIQUE'),
                   s1.SEQ_IN_INDEX, 
                   (SELECT GROUP_CONCAT(s2.COLUMN_NAME ORDER BY s2.SEQ_IN_INDEX SEPARATOR ', ')
                    FROM INFORMATION_SCHEMA.STATISTICS s2 
                    WHERE s2.TABLE_SCHEMA=s1.TABLE_SCHEMA AND s2.TABLE_NAME=s1.TABLE_NAME AND s2.INDEX_NAME=s1.INDEX_NAME)
            FROM INFORMATION_SCHEMA.STATISTICS s1
            WHERE s1.TABLE_SCHEMA='${SCHEMA_NAME}' 
              AND s1.TABLE_NAME='${TABLE_NAME}'
              AND s1.COLUMN_NAME IN (${IN_CLAUSE})
            ORDER BY s1.COLUMN_NAME, s1.INDEX_NAME;"

            IDX_RES=$(run_mysql "$QUERY_IDX_EXAMINER")
            
            if [[ -n "$IDX_RES" ]]; then
                echo "$IDX_RES" | awk -F'\t' '
                BEGIN { w1=15; w2=25; w3=10; w4=4; }
                {
                    if(length($1)>w1) w1=length($1);
                    if(length($2)>w2) w2=length($2);
                    lines[NR] = $0
                }
                END {
                    printf "  %-*s   %-*s   %-*s   %-*s   %s\n", w1, "COLUMN", w2, "INDEX NAME", w3, "TYPE", w4, "POS", "FULL INDEX STRUCTURE"
                    
                    d1 = sprintf("%*s", w1, ""); gsub(/ /, "-", d1);
                    d2 = sprintf("%*s", w2, ""); gsub(/ /, "-", d2);
                    d3 = sprintf("%*s", w3, ""); gsub(/ /, "-", d3);
                    d4 = sprintf("%*s", w4, ""); gsub(/ /, "-", d4);
                    printf "  %-*s   %-*s   %-*s   %-*s   %s\n", w1, d1, w2, d2, w3, d3, w4, d4, "--------------------"
                    
                    for(i=1;i<=NR;i++) {
                        split(lines[i], f, "\t");
                        c_col="\033[1;33m"; c_idx="\033[0;34m"; c_pos="\033[0;36m"; c_full="\033[2m"; c_reset="\033[0m";
                        c_type = (f[3]=="UNIQUE") ? "\033[0;32m" : "\033[0;35m";
                        
                        printf "  %s%-*s%s   %s%-*s%s   %s%-*s%s   %s%-*s%s   %s%s%s\n",
                            c_col, w1, f[1], c_reset,
                            c_idx, w2, f[2], c_reset,
                            c_type, w3, f[3], c_reset,
                            c_pos, w4, f[4], c_reset,
                            c_full, f[5], c_reset;
                    }
                }'
            else
                echo -e "  ${RED}No indexes cover any of the foreign key columns on this table.${RESET}"
            fi
        else
            echo -e "  ${DIM}No mapped columns found to analyze.${RESET}"
        fi
    fi
fi

# ---------------------------------------------------------
# 4. Tree Representation
# ---------------------------------------------------------
if [[ "$SHOW_TREE" -eq 1 ]]; then
    echo -e "\n${BOLD}${CYAN}[4] DEPENDENCY TREE${RESET}\n"
    echo -e "${YELLOW}${TABLE_NAME}${RESET}"
    
    # Print Outbound Physical
    echo -e "├── ${BOLD}References (Outbound Physical)${RESET}"
    if [[ -n "$OUTBOUND_RES" ]]; then
        TOTAL_OUT=$(echo "$OUTBOUND_RES" | wc -l)
        CURR=0
        echo "$OUTBOUND_RES" | while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
            ((CURR++))
            if [[ $CURR -eq $TOTAL_OUT ]]; then
                echo -e "│   └── ${GREEN}${c_name}${RESET}: ${col_name} ${GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            else
                echo -e "│   ├── ${GREEN}${c_name}${RESET}: ${col_name} ${GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            fi
        done
    else
         echo -e "│   └── ${DIM}None${RESET}"
    fi

    # Print Outbound Virtual
    echo -e "├── ${BOLD}References (Outbound Virtual)${RESET}"
    if [[ -n "$VFK_OUT_RES" ]]; then
        TOTAL_VFK_OUT=$(echo "$VFK_OUT_RES" | wc -l)
        CURR=0
        echo "$VFK_OUT_RES" | while IFS=$'\t' read -r col_name ref_tab ref_col col_type is_idx; do
            warn_tag=""
            [[ "$is_idx" -eq 0 ]] && warn_tag=" ${RED}[UNINDEXED]${RESET}"
            
            ((CURR++))
            if [[ $CURR -eq $TOTAL_VFK_OUT ]]; then
                echo -e "│   └── ${L_GREEN}[LOGICAL]${RESET}: ${col_name}${warn_tag} ${L_GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            else
                echo -e "│   ├── ${L_GREEN}[LOGICAL]${RESET}: ${col_name}${warn_tag} ${L_GREEN}->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            fi
        done
    else
         echo -e "│   └── ${DIM}None${RESET}"
    fi

    # Print Inbound Physical
    echo -e "├── ${BOLD}Referenced By (Inbound Physical)${RESET}"
    if [[ -n "$INBOUND_RES" ]]; then
        TOTAL_IN=$(echo "$INBOUND_RES" | wc -l)
        CURR=0
        echo "$INBOUND_RES" | while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
            ((CURR++))
            if [[ $CURR -eq $TOTAL_IN ]]; then
                echo -e "│   └── ${MAGENTA}${c_name}${RESET}: ${ref_col} ${MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})"
            else
                echo -e "│   ├── ${MAGENTA}${c_name}${RESET}: ${ref_col} ${MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})"
            fi
        done
    else
         echo -e "│   └── ${DIM}None${RESET}"
    fi

    # Print Inbound Virtual
    echo -e "└── ${BOLD}Referenced By (Inbound Virtual)${RESET}"
    if [[ -n "$VFK_IN_RES" ]]; then
        TOTAL_VFK=$(echo "$VFK_IN_RES" | wc -l)
        CURR=0
        echo "$VFK_IN_RES" | while IFS=$'\t' read -r src_tab src_col ref_col is_idx; do
            warn_tag=""
            [[ "$is_idx" -eq 0 ]] && warn_tag=" ${RED}[UNINDEXED]${RESET}"
            
            ((CURR++))
            if [[ $CURR -eq $TOTAL_VFK ]]; then
                echo -e "    └── ${L_MAGENTA}[LOGICAL]${RESET}: ${ref_col} ${L_MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})${warn_tag}"
            else
                echo -e "    ├── ${L_MAGENTA}[LOGICAL]${RESET}: ${ref_col} ${L_MAGENTA}<-${RESET} ${YELLOW}${src_tab}${RESET}(${src_col})${warn_tag}"
            fi
        done
    else
         echo -e "    └── ${DIM}None${RESET}"
    fi
fi

echo -e "\n${BOLD}${CYAN}====================================================================${RESET}\n"