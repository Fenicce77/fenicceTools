#!/usr/bin/env bash
# ==============================================================================
# Script: fk_analyzer.sh
# Role: Senior DBA Diagnostic Tool for MySQL 8.0.x / 8.4.x (GCP Cloud SQL)
# Description: Shows DDL, analyzes foreign key relationships (inbound/outbound),
#              and conditionally evaluates index cardinality/live PK counts 
#              ONLY if references exist.
# Environment: Linux/MacOS, bash. Requires mysql client and login-path.
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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
    echo -e "${BOLD}${CYAN}MySQL Foreign Key & Referential Topology Analyzer${RESET}"
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
# 0. Table DDL (SHOW CREATE TABLE)
# ---------------------------------------------------------
echo -e "${BOLD}${MAGENTA}[0] TABLE DDL${RESET}"
DDL_QUERY="SHOW CREATE TABLE \`${SCHEMA_NAME}\`.\`${TABLE_NAME}\`;"
# Extract the second column (the actual CREATE statement)
DDL_RES=$(run_mysql "${DDL_QUERY}" | cut -f2)

if [[ -n "$DDL_RES" ]]; then
    echo -e "${DIM}${CYAN}┌──────────────────────────────────────────────────────────────────┐${RESET}"
    # Use green to make the SQL visually distinct and readable
    echo -e "${GREEN}${DDL_RES}${RESET}"
    echo -e "${DIM}${CYAN}└──────────────────────────────────────────────────────────────────┘${RESET}\n"
else
    echo -e "  ${RED}Failed to retrieve DDL. Check table existence or permissions.${RESET}\n"
fi

# ---------------------------------------------------------
# 1. References FROM the table (Outbound Foreign Keys)
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

echo -e "${BOLD}${MAGENTA}[1] REFERENCES FROM TABLE (OUTBOUND)${RESET}"
echo -e "Dependencies where ${YELLOW}${TABLE_NAME}${RESET} relies on other tables:\n"

OUTBOUND_RES=$(run_mysql "${QUERY_OUTBOUND}")

if [[ -z "$OUTBOUND_RES" ]]; then
    echo -e "  ${GREEN}No outbound foreign keys found.${RESET}\n"
else
    echo "$OUTBOUND_RES" | while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
        echo -e "  ${BOLD}FK Name:${RESET} ${BLUE}${c_name}${RESET}"
        echo -e "  ${BOLD}Mapping:${RESET} ${TABLE_NAME}(${col_name}) ${GREEN}-->${RESET} ${YELLOW}${ref_tab}${RESET}(${ref_col})"
        echo -e "  ${BOLD}Constraints:${RESET} ON UPDATE ${upd_rule} | ON DELETE ${del_rule}"
        echo -e "  --------------------------------------------------------"
    done
fi

# ---------------------------------------------------------
# 2. References TO the table (Inbound Foreign Keys)
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

echo -e "\n${BOLD}${MAGENTA}[2] REFERENCES TO TABLE (INBOUND)${RESET}"
echo -e "Other tables that rely on ${YELLOW}${TABLE_NAME}${RESET}:\n"

INBOUND_RES=$(run_mysql "${QUERY_INBOUND}")

if [[ -z "$INBOUND_RES" ]]; then
    echo -e "  ${GREEN}No inbound foreign keys found. Safe to modify/drop rows without constraint violations.${RESET}\n"
else
    echo "$INBOUND_RES" | while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
        echo -e "  ${BOLD}FK Name:${RESET} ${BLUE}${c_name}${RESET}"
        echo -e "  ${BOLD}Mapping:${RESET} ${YELLOW}${src_tab}${RESET}(${src_col}) ${GREEN}-->${RESET} ${TABLE_NAME}(${ref_col})"
        echo -e "  ${BOLD}Constraints:${RESET} ON UPDATE ${upd_rule} | ON DELETE ${del_rule}"
        echo -e "  --------------------------------------------------------"
    done
fi

# ---------------------------------------------------------
# 3. Cardinality Analysis (Safe Mode via Stats + Live PK Count)
# ---------------------------------------------------------
if [[ "$SHOW_CARDINALITY" -eq 1 ]]; then
    echo -e "\n${BOLD}${MAGENTA}[3] CARDINALITY & ROW ESTIMATES (STATISTICS)${RESET}"

    # ONLY proceed if there are actual foreign keys/dependencies
    if [[ -z "$OUTBOUND_RES" && -z "$INBOUND_RES" ]]; then
        echo -e "  ${CYAN}Info:${RESET} Cardinality and row estimation skipped. No referential dependencies (FKs) found for this table."
    else
        # --- 3.1 Row Accounting: Live vs Dictionary ---
        echo -e "  ${BOLD}Evaluating Row Counts (Live vs Dictionary)...${RESET}"
        
        PK_COL=$(run_mysql "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND CONSTRAINT_NAME='PRIMARY' LIMIT 1;")
        
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
        echo -e "  ${BOLD}Index Cardinalities for Involved Foreign Key Columns:${RESET}"
        
        CARD_DATA=""

        # Process Outbound
        if [[ -n "$OUTBOUND_RES" ]]; then
            while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${col_name}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${ref_tab}' AND COLUMN_NAME='${ref_col}';")
                
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"

                CARD_DATA+="OUTBOUND\t${c_name}\t${TABLE_NAME}.${col_name}\t${src_card}\t${ref_tab}.${ref_col}\t${tgt_card}\n"
            done <<< "$OUTBOUND_RES"
        fi

        # Process Inbound
        if [[ -n "$INBOUND_RES" ]]; then
            while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
                src_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${src_tab}' AND COLUMN_NAME='${src_col}';")
                tgt_card=$(run_mysql "SELECT IFNULL(MAX(CARDINALITY), 'N/A') FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND COLUMN_NAME='${ref_col}';")
                
                [[ -z "$src_card" || "$src_card" == "NULL" ]] && src_card="N/A"
                [[ -z "$tgt_card" || "$tgt_card" == "NULL" ]] && tgt_card="N/A"

                CARD_DATA+="INBOUND\t${c_name}\t${src_tab}.${src_col}\t${src_card}\t${TABLE_NAME}.${ref_col}\t${tgt_card}\n"
            done <<< "$INBOUND_RES"
        fi

        # Feed the compiled data into awk for beautiful, aligned, colorized formatting
        echo -en "$CARD_DATA" | grep -v '^$' | awk -F'\t' '
        BEGIN {
            w1=8; w2=15; w3=18; w4=11; w5=18; w6=11;
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
                   w1, "DIR", w2, "CONSTRAINT NAME", w3, "SOURCE (TABLE.COL)", w4, "CARDINALITY", w5, "TARGET (TABLE.COL)", w6, "CARDINALITY"
            
            # Print Separators dynamically
            d1 = sprintf("%*s", w1, ""); gsub(/ /, "-", d1);
            d2 = sprintf("%*s", w2, ""); gsub(/ /, "-", d2);
            d3 = sprintf("%*s", w3, ""); gsub(/ /, "-", d3);
            d4 = sprintf("%*s", w4, ""); gsub(/ /, "-", d4);
            d5 = sprintf("%*s", w5, ""); gsub(/ /, "-", d5);
            d6 = sprintf("%*s", w6, ""); gsub(/ /, "-", d6);
            printf "  %-*s   %-*s   %-*s   %-*s   %-*s   %-*s\n", w1, d1, w2, d2, w3, d3, w4, d4, w5, d5, w6, d6
            
            # Print Data with Colors
            for (i=1; i<=NR; i++) {
                split(lines[i], f, "\t");
                c_dir = (f[1] == "OUTBOUND") ? "\033[0;32m" : "\033[0;35m";
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
    fi
fi

# ---------------------------------------------------------
# 4. Tree Representation
# ---------------------------------------------------------
if [[ "$SHOW_TREE" -eq 1 ]]; then
    echo -e "\n${BOLD}${MAGENTA}[4] DEPENDENCY TREE${RESET}\n"
    echo -e "${YELLOW}${TABLE_NAME}${RESET}"
    
    # Print Outbound
    if [[ -n "$OUTBOUND_RES" ]]; then
        echo -e "├── ${BOLD}References (Outbound)${RESET}"
        TOTAL_OUT=$(echo "$OUTBOUND_RES" | wc -l)
        CURR=0
        echo "$OUTBOUND_RES" | while IFS=$'\t' read -r c_name col_name ref_tab ref_col upd_rule del_rule; do
            ((CURR++))
            if [[ $CURR -eq $TOTAL_OUT ]]; then
                echo -e "│   └── ${BLUE}${c_name}${RESET}: ${col_name} -> ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            else
                echo -e "│   ├── ${BLUE}${c_name}${RESET}: ${col_name} -> ${YELLOW}${ref_tab}${RESET}(${ref_col})"
            fi
        done
    else
         echo -e "├── ${BOLD}References (Outbound)${RESET} -> ${GREEN}None${RESET}"
    fi

    # Print Inbound
    if [[ -n "$INBOUND_RES" ]]; then
        echo -e "└── ${BOLD}Referenced By (Inbound)${RESET}"
        TOTAL_IN=$(echo "$INBOUND_RES" | wc -l)
        CURR=0
        echo "$INBOUND_RES" | while IFS=$'\t' read -r c_name src_tab src_col ref_col upd_rule del_rule; do
            ((CURR++))
            if [[ $CURR -eq $TOTAL_IN ]]; then
                echo -e "    └── ${BLUE}${c_name}${RESET}: ${YELLOW}${src_tab}${RESET}(${src_col}) -> ${ref_col}"
            else
                echo -e "    ├── ${BLUE}${c_name}${RESET}: ${YELLOW}${src_tab}${RESET}(${src_col}) -> ${ref_col}"
            fi
        done
    else
         echo -e "└── ${BOLD}Referenced By (Inbound)${RESET} -> ${GREEN}None${RESET}"
    fi
fi

echo -e "\n${BOLD}${CYAN}====================================================================${RESET}\n"