#!/opt/homebrew/bin/bash

# ==========================================
# Color Configuration
# ==========================================
blk=$(tput blink)
bld=$(tput bold)
red=${bld}$(tput setaf 1)
grn=${bld}$(tput setaf 2)
yel=${bld}$(tput setaf 3)
blu=${bld}$(tput setaf 4)
mag=${bld}$(tput setaf 5)
cyn=${bld}$(tput setaf 6)
wht=${bld}$(tput setaf 7)
off=$(tput sgr0)

# ==========================================
# Help Function
# ==========================================
show_help() {
    echo -e "${cyn}==============================================================================================================${off}"
    echo -e "${bld}Hexon DB Search Tool v8.6 - Omnipresent Search in MySQL instances${off}"
    echo -e "${cyn}==============================================================================================================${off}"
    echo -e "${yel}USAGE:${off}"
    echo -e "  $0 <object_types> <term_or_list> [0|1] [OPTIONS]"
    echo -e ""
    echo -e "${yel}MANDATORY PARAMETERS:${off}"
    echo -e "  ${grn}<object_types>${off}      Comma-separated list of types, or '${bld}all${off}' to search everywhere:"
    echo -e "                      ${blu}s, schema${off}  | ${blu}t, table${off}   | ${blu}v, view${off} | ${blu}c, column${off} | ${blu}p, proc${off}"
    echo -e "                      ${blu}tr, trigger${off}| ${blu}e, event${off}   | ${blu}i, index${off}| ${blu}u, user${off} | ${bld}all${off} (Everything)"
    echo -e "                      ${wht}Example: 'table,view,proc' or 'all'${off}"
    echo -e "  ${grn}<term_or_list>${off}      Single string or comma-separated list (e.g., 'user1,user2', 'invoice')."
    echo -e ""
    echo -e "${yel}OPTIONAL POSITIONAL PARAMETER:${off}"
    echo -e "  ${grn}[0|1]${off}               Match mode (Must go right after the search term):"
    echo -e "                      ${blu}0${off} : Multiple partial search (Uses REGEXP) -> ${bld}DEFAULT${off}"
    echo -e "                      ${blu}1${off} : Multiple exact search (Uses IN (...))"
    echo -e ""
    echo -e "${yel}OPTIONS (FLAGS):${off}"
    echo -e "  ${grn}-r, --related${off}     Fetches related Triggers and Routines when searching for a Table (Requires Exact Match: 1)."
    echo -e "  ${grn}-d, --detailed${off}    Extracts advanced info (Full Privileges, Colorized Table Grants, Roles, Limits, etc.)."
    echo -e "  ${grn}-c, --csv${off}         Exports the results to a CSV file ('|' separator)."
    echo -e "  ${grn}-s, --server <ls>${off} Searches ONLY in servers containing these strings (e.g., prod,master)."
    echo -e "  ${grn}-x, --exclude <ls>${off} Ignores servers containing these strings (e.g., dev,test)."
    echo -e "  ${grn}--sys${off}               Includes system schemas (mysql, information_schema, sys...) in the search."
    echo -e "  ${grn}-h, --help${off}        Shows this help panel and exits."
    echo -e "${cyn}==============================================================================================================${off}"
}

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ -z "$1" ]] || [[ -z "$2" ]]; then
    echo -e "${red}[ERROR] Missing mandatory parameters.${off}\n"
    show_help
    exit 1
fi

ACTION=$1
TOSEARCH=$2
EXACT=0
CSV_EXPORT=0
DETAILED=0
RELATED=0
INCLUDE_SYS=0
CUSTOM_SERVERS=""
EXCLUDE_SERVERS=""

shift 2

while [[ "$#" -gt 0 ]]; do
    case $1 in
        0|1) EXACT=$1 ;;
        -c|--csv) CSV_EXPORT=1 ;;
        -s|--server) CUSTOM_SERVERS="$2"; shift ;;
        -x|--exclude) EXCLUDE_SERVERS="$2"; shift ;;
        -d|--detailed) DETAILED=1 ;;
        -r|--related) RELATED=1 ;;
        --sys) INCLUDE_SYS=1 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo -e "${red}[ERROR] Unknown parameter: $1${off}\n"; show_help; exit 1 ;;
    esac
    shift
done

# ==========================================
# Object Types Resolution & Validation
# ==========================================
if [[ "$ACTION" =~ ^(all|any|a|\*)$ ]]; then
    ACTION_LIST="s t v p tr e u c i"
    OBJNAME_LABEL="ALL OBJECT TYPES"
else
    RAW_ACTIONS=$(echo "$ACTION" | tr ',' ' ')
    ACTION_LIST=""
    OBJNAME_LABEL=$(echo "$ACTION" | tr ',' '/' | tr '[:lower:]' '[:upper:]')
    
    for act in $RAW_ACTIONS; do
        case $act in
            's'|'schema'|'t'|'table'|'v'|'view'|'p'|'procedure'|'proc'|'tr'|'trigger'|'e'|'event'|'u'|'user'|'c'|'column'|'i'|'index')
                ACTION_LIST="$ACTION_LIST $act"
                ;;
            *) 
                echo -e "${red}[ERROR] Invalid object type: '${act}'. Please check the help menu.${off}\n"
                show_help
                exit 1
                ;;
        esac
    done
fi

# ==========================================
# Preparation of Multiple Search Pattern
# ==========================================
CLEAN_SEARCH=$(echo "$TOSEARCH" | tr -d ' ')

if [[ $EXACT -eq 1 ]]; then
    IN_VALUES=$(echo "$CLEAN_SEARCH" | sed "s/,/','/g")
    SEARCH_CLAUSE="IN ('$IN_VALUES')"
else
    REGEXP_VALUES=$(echo "$CLEAN_SEARCH" | tr ',' '|')
    SEARCH_CLAUSE="REGEXP '$REGEXP_VALUES'"
fi

# ==========================================
# INJECTION OF RELATED OBJECTS LOGIC
# ==========================================
if [[ $RELATED -eq 1 ]]; then
    if [[ $EXACT -eq 0 ]]; then
        echo -e "${yel}[WARNING] --related option requires Exact Match mode [1]. Related objects will not be fetched.${off}\n"
    else
        if [[ " $ACTION_LIST " =~ [[:space:]](t|table)[[:space:]] ]]; then
            ACTION_LIST="$ACTION_LIST tr_rel p_rel"
            OBJNAME_LABEL="$OBJNAME_LABEL + DEPENDENCIES"
        fi
    fi
fi

if [[ $INCLUDE_SYS -eq 1 ]]; then
    IGNORE_SCHEMAS="'__dummy_sys_schema__'"
else
    IGNORE_SCHEMAS="'mysql','information_schema','performance_schema','innodb','tmp','sys','percona_toolkit'"
fi

# ==========================================
# Server Selection
# ==========================================
ERR_FILE=$(mktemp /tmp/tmp_search.XXXXXX)
trap "rm -f $ERR_FILE" EXIT

BASEDIR="${HOME}/git/myrepos/myToolsBetika"
DBSERVERLIST="${BASEDIR}/lists/servers_login_list.hex.txt"

if [[ ! -f "$DBSERVERLIST" ]]; then
    echo -e "${red}[ERROR] File not found: $DBSERVERLIST${off}"
    exit 1
fi

RAW_SERVERS=$(grep -v '^[[:space:]]*$' "$DBSERVERLIST" | grep -v '^#')

if [[ -n "$CUSTOM_SERVERS" ]]; then
    INCLUDE_REGEX=$(echo "$CUSTOM_SERVERS" | tr ',' '|')
    RAW_SERVERS=$(echo "$RAW_SERVERS" | grep -iE "$INCLUDE_REGEX")
fi

if [[ -n "$EXCLUDE_SERVERS" ]]; then
    EXCLUDE_REGEX=$(echo "$EXCLUDE_SERVERS" | tr ',' '|')
    RAW_SERVERS=$(echo "$RAW_SERVERS" | grep -viE "$EXCLUDE_REGEX")
fi

SERVERS_TO_CHECK="$RAW_SERVERS"

if [[ -z "$SERVERS_TO_CHECK" ]]; then
    echo -e "${yel}[WARNING] The server list to check is empty after applying filters.${off}"
    exit 0
fi

declare -a FOUND_SERVERS NOT_FOUND_SERVERS FAILED_CONN_SERVERS

if [[ $CSV_EXPORT -eq 1 ]]; then
    SAFE_FILENAME=$(echo "$CLEAN_SEARCH" | tr ',' '_')
    CSV_FILE="search_results_${SAFE_FILENAME}_$(date +%Y%m%d_%H%M%S).csv"
    echo "Hostname|Version|Schema/User|ObjectName|Type/Engine|Extra_Info" > "$CSV_FILE"
fi

if [[ $INCLUDE_SYS -eq 1 ]]; then
    echo -e "${cyn}Starting search (INCLUDING SYS SCHEMAS) across [${OBJNAME_LABEL}] for -> [${TOSEARCH}]...${off}\n"
else
    echo -e "${cyn}Starting search across [${OBJNAME_LABEL}] for -> [${TOSEARCH}]...${off}\n"
fi

# ==========================================
# Main Execution (Nested Loops)
# ==========================================
for s in $SERVERS_TO_CHECK; do
    RAW_VERSION=$(mysql --login-path="${s}" --connect-timeout=3 -Bse "SELECT version();" 2>/dev/null)
    if [[ -z "$RAW_VERSION" ]]; then FAILED_CONN_SERVERS+=("$s"); continue; fi
    MAJOR_VER=$(echo "$RAW_VERSION" | cut -d. -f1)
    
    SERVER_HAS_MATCH=0
    SERVER_PRINTED_HEADER=0

    for act in $ACTION_LIST; do
        case $act in
            's'|'schema')
                OBJNAME='Schema'
                QUERY="SELECT @@hostname, '$RAW_VERSION', SCHEMA_NAME, 'SCHEMA', 'SCHEMA', CONCAT('Char/Coll: ',DEFAULT_CHARACTER_SET_NAME,'/',DEFAULT_COLLATION_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME $SEARCH_CLAUSE;" ;;
            
            't'|'table')
                OBJNAME='Table'
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, TABLE_NAME, ENGINE, CONCAT('Rows: ', IFNULL(TABLE_ROWS,0), ' | Collation: ', IFNULL(TABLE_COLLATION,'N/A'), ' | Created: ', IFNULL(CREATE_TIME,'N/A'), ' | Updated: ', IFNULL(UPDATE_TIME,'N/A'), ' | Size: ', IFNULL(ROUND(((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024), 2), 0), ' MB') FROM information_schema.TABLES WHERE TABLE_NAME $SEARCH_CLAUSE AND TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, TABLE_NAME, ENGINE, CONCAT('Rows: ', IFNULL(TABLE_ROWS,0), ' | Collation: ', IFNULL(TABLE_COLLATION,'N/A'), ' | Created: ', IFNULL(CREATE_TIME,'N/A')) FROM information_schema.TABLES WHERE TABLE_NAME $SEARCH_CLAUSE AND TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
                
            'v'|'view')
                OBJNAME='View'
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, TABLE_NAME, 'VIEW', CONCAT('Created: ', IFNULL(CREATE_TIME,'N/A'), ' | Updated: ', IFNULL(UPDATE_TIME,'N/A')) FROM information_schema.TABLES WHERE TABLE_NAME $SEARCH_CLAUSE AND TABLE_TYPE = 'VIEW' AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, TABLE_NAME, 'VIEW', CONCAT('Created: ', IFNULL(CREATE_TIME,'N/A')) FROM information_schema.TABLES WHERE TABLE_NAME $SEARCH_CLAUSE AND TABLE_TYPE = 'VIEW' AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
            
            'p'|'procedure'|'proc')
                OBJNAME='Routine'
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, CONCAT('Definer: ', CAST(DEFINER AS CHAR), ' | Conn_Coll: ', IFNULL(COLLATION_CONNECTION,'N/A'), ' | DB_Coll: ', IFNULL(DATABASE_COLLATION,'N/A'), ' | Created: ', CREATED, ' | Modified: ', LAST_ALTERED) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME $SEARCH_CLAUSE AND ROUTINE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, CONCAT('Definer: ', CAST(DEFINER AS CHAR), ' | Created: ', CREATED, ' | Modified: ', LAST_ALTERED) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME $SEARCH_CLAUSE AND ROUTINE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
                
            'p_rel')
                OBJNAME='Routine (Dependency)'
                ROUTINE_LIKE_CLAUSE=""
                for tbl in $(echo "$CLEAN_SEARCH" | tr ',' ' '); do
                    if [[ -z "$ROUTINE_LIKE_CLAUSE" ]]; then
                        ROUTINE_LIKE_CLAUSE="ROUTINE_DEFINITION LIKE '%$tbl%'"
                    else
                        ROUTINE_LIKE_CLAUSE="$ROUTINE_LIKE_CLAUSE OR ROUTINE_DEFINITION LIKE '%$tbl%'"
                    fi
                done

                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, CONCAT('Acts on: [', '$CLEAN_SEARCH', '] | Definer: ', CAST(DEFINER AS CHAR), ' | Conn_Coll: ', IFNULL(COLLATION_CONNECTION,'N/A'), ' | DB_Coll: ', IFNULL(DATABASE_COLLATION,'N/A'), ' | Created: ', CREATED, ' | Modified: ', LAST_ALTERED) FROM INFORMATION_SCHEMA.ROUTINES WHERE ($ROUTINE_LIKE_CLAUSE) AND ROUTINE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, CONCAT('Acts on: [', '$CLEAN_SEARCH', '] | Definer: ', CAST(DEFINER AS CHAR), ' | Created: ', CREATED, ' | Modified: ', LAST_ALTERED) FROM INFORMATION_SCHEMA.ROUTINES WHERE ($ROUTINE_LIKE_CLAUSE) AND ROUTINE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
            
            'tr'|'trigger')
                OBJNAME='Trigger'
                IF_CREATED=$([[ "$MAJOR_VER" -ge 8 ]] && echo "IFNULL(CREATED,'N/A')" || echo "'N/A (v5.7)'")
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TRIGGER_SCHEMA, TRIGGER_NAME, 'TRIGGER', CONCAT('Definer: ', CAST(DEFINER AS CHAR), ' | Conn_Coll: ', IFNULL(COLLATION_CONNECTION,'N/A'), ' | DB_Coll: ', IFNULL(DATABASE_COLLATION,'N/A'), ' | Created: ', $IF_CREATED) FROM INFORMATION_SCHEMA.TRIGGERS WHERE TRIGGER_NAME $SEARCH_CLAUSE AND TRIGGER_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TRIGGER_SCHEMA, TRIGGER_NAME, 'TRIGGER', CONCAT('Definer: ', CAST(DEFINER AS CHAR), ' | Created: ', $IF_CREATED) FROM INFORMATION_SCHEMA.TRIGGERS WHERE TRIGGER_NAME $SEARCH_CLAUSE AND TRIGGER_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;

            'tr_rel')
                OBJNAME='Trigger (Dependency)'
                IF_CREATED=$([[ "$MAJOR_VER" -ge 8 ]] && echo "IFNULL(CREATED,'N/A')" || echo "'N/A (v5.7)'")
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TRIGGER_SCHEMA, TRIGGER_NAME, 'TRIGGER', CONCAT('Bound Table: ', CAST(EVENT_OBJECT_TABLE AS CHAR), ' | Definer: ', CAST(DEFINER AS CHAR), ' | Conn_Coll: ', IFNULL(COLLATION_CONNECTION,'N/A'), ' | DB_Coll: ', IFNULL(DATABASE_COLLATION,'N/A'), ' | Created: ', $IF_CREATED) FROM INFORMATION_SCHEMA.TRIGGERS WHERE EVENT_OBJECT_TABLE $SEARCH_CLAUSE AND TRIGGER_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TRIGGER_SCHEMA, TRIGGER_NAME, 'TRIGGER', CONCAT('Bound Table: ', CAST(EVENT_OBJECT_TABLE AS CHAR), ' | Definer: ', CAST(DEFINER AS CHAR), ' | Created: ', $IF_CREATED) FROM INFORMATION_SCHEMA.TRIGGERS WHERE EVENT_OBJECT_TABLE $SEARCH_CLAUSE AND TRIGGER_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
            
            'e'|'event')
                OBJNAME='Event'
                QUERY="SELECT @@hostname, '$RAW_VERSION', EVENT_SCHEMA, EVENT_NAME, 'EVENT', CONCAT('Created: ', CREATED, ' | Modified: ', LAST_ALTERED, ' | Status: ', STATUS) FROM INFORMATION_SCHEMA.EVENTS WHERE EVENT_NAME $SEARCH_CLAUSE AND EVENT_SCHEMA NOT IN ($IGNORE_SCHEMAS);" ;;
            
            'u'|'user')
                OBJNAME='User'
                if [[ $DETAILED -eq 1 ]]; then
                    # CASTS INYECTADOS PARA SOLUCIONAR COLLATION CLASH ENTRE MYSQL y INFORMATION_SCHEMA
                    GRANTEE_STR="CONCAT(CHAR(39), CAST(user AS CHAR), CHAR(39), '@', CHAR(39), CAST(host AS CHAR), CHAR(39))"
                    
                    # Macro Global 
                    SQL_GLOBAL_PRIVS="(SELECT IFNULL((SELECT IF(COUNT(PRIVILEGE_TYPE)>20, IF(SUM(IS_GRANTABLE='YES')>0, 'ALL GRANTS WITH GRANT OPTION', 'ALL GRANTS'), GROUP_CONCAT(CONCAT('~', CAST(PRIVILEGE_TYPE AS CHAR), '~') SEPARATOR ', ')) FROM information_schema.USER_PRIVILEGES WHERE CAST(GRANTEE AS CHAR) = TARGET_GRANTEE AND PRIVILEGE_TYPE != 'USAGE'), 'None'))"
                    
                    # Macro Esquema
                    SQL_SCHEMA_PRIVS="(SELECT IFNULL((SELECT CONCAT('__NEWLINE__', GROUP_CONCAT(CONCAT('__DB_BR__📂 ', CAST(TABLE_SCHEMA AS CHAR), ' [', privs, ']') SEPARATOR '')) FROM (SELECT GRANTEE, TABLE_SCHEMA, IF(COUNT(PRIVILEGE_TYPE)>14, IF(SUM(IS_GRANTABLE='YES')>0, 'ALL GRANTS WITH GRANT OPTION', 'ALL GRANTS'), GROUP_CONCAT(CONCAT('~', CAST(PRIVILEGE_TYPE AS CHAR), '~') SEPARATOR ', ')) as privs FROM information_schema.SCHEMA_PRIVILEGES GROUP BY GRANTEE, TABLE_SCHEMA) sp WHERE CAST(sp.GRANTEE AS CHAR) = TARGET_GRANTEE), 'None'))"

                    # Macro Tablas
                    SQL_TABLE_PRIVS="(SELECT IFNULL((SELECT CONCAT('__NEWLINE__', GROUP_CONCAT(CONCAT('__DB_BR__📂 Schema: ', CAST(TABLE_SCHEMA AS CHAR), tbl_privs) SEPARATOR '')) FROM (SELECT GRANTEE, TABLE_SCHEMA, GROUP_CONCAT(CONCAT('__TBL_ITM__📄 Table: ', CAST(TABLE_NAME AS CHAR), ' [', privs, ']') SEPARATOR '') as tbl_privs FROM (SELECT GRANTEE, TABLE_SCHEMA, TABLE_NAME, GROUP_CONCAT(CONCAT('~', CAST(PRIVILEGE_TYPE AS CHAR), '~') SEPARATOR ', ') as privs FROM information_schema.TABLE_PRIVILEGES GROUP BY GRANTEE, TABLE_SCHEMA, TABLE_NAME) tp GROUP BY GRANTEE, TABLE_SCHEMA) sp WHERE CAST(sp.GRANTEE AS CHAR) = TARGET_GRANTEE), 'None'))"

                    DIRECT_GLOBAL="${SQL_GLOBAL_PRIVS//TARGET_GRANTEE/$GRANTEE_STR}"
                    DIRECT_DB="${SQL_SCHEMA_PRIVS//TARGET_GRANTEE/$GRANTEE_STR}"
                    DIRECT_TABLE="${SQL_TABLE_PRIVS//TARGET_GRANTEE/$GRANTEE_STR}"
                    
                    LIMITS_STR="IF(max_questions=0 AND max_updates=0 AND max_connections=0 AND max_user_connections=0, '', CONCAT(' | Limits [', CONCAT_WS(', ', IF(max_questions>0, CONCAT(max_questions, ' Q/h'), NULL), IF(max_updates>0, CONCAT(max_updates, ' U/h'), NULL), IF(max_connections>0, CONCAT(max_connections, ' Conn/h'), NULL), IF(max_user_connections>0, CONCAT(max_user_connections, ' MaxConn'), NULL)), ']'))"

                    if [[ "$MAJOR_VER" -ge 8 ]]; then
                        ROLES_STR="IFNULL((SELECT GROUP_CONCAT(CONCAT(CAST(FROM_USER AS CHAR), '@', CAST(FROM_HOST AS CHAR))) FROM mysql.role_edges WHERE TO_USER = user AND TO_HOST = host), 'None')"
                        
                        ROLE_GRANTEE_STR="CONCAT(CHAR(39), CAST(FROM_USER AS CHAR), CHAR(39), '@', CHAR(39), CAST(FROM_HOST AS CHAR), CHAR(39))"
                        ROLE_GLOBAL="${SQL_GLOBAL_PRIVS//TARGET_GRANTEE/$ROLE_GRANTEE_STR}"
                        ROLE_DB="${SQL_SCHEMA_PRIVS//TARGET_GRANTEE/$ROLE_GRANTEE_STR}"
                        ROLE_TABLE="${SQL_TABLE_PRIVS//TARGET_GRANTEE/$ROLE_GRANTEE_STR}"
                        
                        ROLE_DETAILS_STR="IFNULL((SELECT GROUP_CONCAT(CONCAT('__ROLE_BR__', CAST(FROM_USER AS CHAR), '@', CAST(FROM_HOST AS CHAR), '__ROLE_DIV__Global: ', $ROLE_GLOBAL, ' | DB: ', $ROLE_DB, IF($ROLE_TABLE != 'None', CONCAT(' | Tables: ', $ROLE_TABLE), '')) SEPARATOR '') FROM mysql.role_edges WHERE TO_USER = user AND TO_HOST = host), '')"
                        
                        QUERY="SELECT @@hostname, '$RAW_VERSION', CAST(user AS CHAR), CAST(host AS CHAR), 'USER', CONCAT('Auth: ', CAST(plugin AS CHAR), ' | Roles: ', $ROLES_STR, ' | Direct Global: ', $DIRECT_GLOBAL, ' | Direct DB: ', $DIRECT_DB, IF($DIRECT_TABLE != 'None', CONCAT(' | Direct Tables: ', $DIRECT_TABLE), ''), $LIMITS_STR, $ROLE_DETAILS_STR, '__ROLE_END__') FROM mysql.user WHERE user $SEARCH_CLAUSE;"
                    else
                        QUERY="SELECT @@hostname, '$RAW_VERSION', CAST(user AS CHAR), CAST(host AS CHAR), 'USER', CONCAT('Auth: ', CAST(plugin AS CHAR), ' | Direct Global: ', $DIRECT_GLOBAL, ' | Direct DB: ', $DIRECT_DB, IF($DIRECT_TABLE != 'None', CONCAT(' | Direct Tables: ', $DIRECT_TABLE), ''), $LIMITS_STR) FROM mysql.user WHERE user $SEARCH_CLAUSE;"
                    fi
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', CAST(user AS CHAR), CAST(host AS CHAR), 'USER', CONCAT('Auth: ', CAST(plugin AS CHAR)) FROM mysql.user WHERE user $SEARCH_CLAUSE;"
                fi
                ;;
            
            'c'|'column')
                OBJNAME='Column'
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, COLUMN_NAME, COLUMN_TYPE, CONCAT('Table: ', TABLE_NAME, ' | Char/Coll: ', IFNULL(CONCAT(CHARACTER_SET_NAME, '/', COLLATION_NAME), '__NO_CHARSET__'), ' | Key: ', IFNULL(NULLIF(COLUMN_KEY, ''), 'None')) FROM information_schema.COLUMNS WHERE COLUMN_NAME $SEARCH_CLAUSE AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', TABLE_SCHEMA, COLUMN_NAME, COLUMN_TYPE, CONCAT('Table: ', TABLE_NAME, ' | Char/Coll: ', IFNULL(CONCAT(CHARACTER_SET_NAME, '/', COLLATION_NAME), '__NO_CHARSET__')) FROM information_schema.COLUMNS WHERE COLUMN_NAME $SEARCH_CLAUSE AND TABLE_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
            
            'i'|'index')
                OBJNAME='Index'
                VISIBILITY_SQL=$([[ "$MAJOR_VER" -ge 8 ]] && echo "' | Visible: ', s.IS_VISIBLE," || echo "")
                if [[ $DETAILED -eq 1 ]]; then
                    QUERY="SELECT @@hostname, '$RAW_VERSION', s.INDEX_SCHEMA, s.INDEX_NAME, 'INDEX', 
                           CONCAT('Table: ', s.TABLE_NAME, $VISIBILITY_SQL ' | Size: ', IFNULL(CONCAT(ROUND((i.stat_value * @@innodb_page_size)/1024/1024, 2), ' MB'), 'N/A')) 
                           FROM INFORMATION_SCHEMA.STATISTICS s 
                           LEFT JOIN mysql.innodb_index_stats i ON s.INDEX_SCHEMA = i.database_name AND s.TABLE_NAME = i.table_name AND s.INDEX_NAME = i.index_name AND i.stat_name = 'size' 
                           WHERE s.INDEX_NAME $SEARCH_CLAUSE AND s.INDEX_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                else
                    QUERY="SELECT @@hostname, '$RAW_VERSION', INDEX_SCHEMA, INDEX_NAME, 'INDEX', CONCAT('Table: ', TABLE_NAME $VISIBILITY_SQL) FROM INFORMATION_SCHEMA.STATISTICS s WHERE INDEX_NAME $SEARCH_CLAUSE AND INDEX_SCHEMA NOT IN ($IGNORE_SCHEMAS);"
                fi
                ;;
        esac

        RESULT=$(mysql --login-path="${s}" -Bse "$QUERY" 2>"$ERR_FILE")
        
        if [[ -s "$ERR_FILE" ]]; then
            ERROR=$(cat "$ERR_FILE")
            echo -e "${red}[ERROR in ${s} (v${RAW_VERSION}) searching ${OBJNAME}]${off} $ERROR" >&2
            > "$ERR_FILE"
        fi

        if [[ -n "$RESULT" ]]; then
            SERVER_HAS_MATCH=1
            
            if [[ $SERVER_PRINTED_HEADER -eq 0 ]]; then
                echo -e "${grn}[✓] Matches found in:${off} ${mag}${s}${off} ${wht}(v${RAW_VERSION})${off}"
                SERVER_PRINTED_HEADER=1
            fi
            
            echo -e "  ${blu}>> ${OBJNAME}(s):${off}"
            
            # MOTOR GRÁFICO AWK: Transforma los marcadores y aplica la paleta semántica de colores
            echo "$RESULT" | column -t -s $'\t' | awk '{
                gsub(/__NO_CHARSET__/, "'"${red}-${off}"'");
                
                # Jerarquía y Sangrías
                gsub(/__ROLE_BR__/, "\n          '"${yel}"'↳ [ROLE] ");
                gsub(/__ROLE_DIV__/, "'"${off}"' -> '"${cyn}"'");
                gsub(/__ROLE_END__/, "'"${off}"'");
                gsub(/__NEWLINE__/, "");
                gsub(/__DB_BR__/, "\n               ");
                gsub(/__TBL_ITM__/, "\n                   ↳ ");
                
                # Inyección de Color por Permiso (Peligro/Modificación/Inserción/Lectura)
                gsub(/~DELETE~/, "'"${red}"'DELETE'"${off}"'");
                gsub(/~DROP~/, "'"${red}"'DROP'"${off}"'");
                
                gsub(/~UPDATE~/, "'"${yel}"'UPDATE'"${off}"'");
                gsub(/~ALTER~/, "'"${yel}"'ALTER'"${off}"'");
                
                gsub(/~INSERT~/, "'"${blu}"'INSERT'"${off}"'");
                gsub(/~CREATE~/, "'"${blu}"'CREATE'"${off}"'");
                
                gsub(/~SELECT~/, "'"${grn}"'SELECT'"${off}"'");
                gsub(/~EXECUTE~/, "'"${grn}"'EXECUTE'"${off}"'");
                gsub(/~SHOW VIEW~/, "'"${grn}"'SHOW VIEW'"${off}"'");
                gsub(/~USAGE~/, "'"${grn}"'USAGE'"${off}"'");
                
                # Admin Mode
                gsub(/ALL GRANTS WITH GRANT OPTION/, "'"${red}"'ALL GRANTS WITH GRANT OPTION'"${off}"'");
                gsub(/ALL GRANTS/, "'"${red}"'ALL GRANTS'"${off}"'");
                
                # Limpieza de marcadores sobrantes
                gsub(/~/, "");
                
                print
            }' | sed 's/^/      /'
            echo ""
            
            # Formato Plano para CSV (Evita romper columnas en el excel)
            [[ $CSV_EXPORT -eq 1 ]] && echo "$RESULT" | awk '{
                gsub(/__NO_CHARSET__/, "-");
                gsub(/__ROLE_BR__/, " | [ROLE] ");
                gsub(/__ROLE_DIV__/, " -> ");
                gsub(/__ROLE_END__/, "");
                gsub(/__NEWLINE__/, "");
                gsub(/__DB_BR__/, " | ");
                gsub(/__TBL_ITM__/, " > ");
                gsub(/~/, "");
                print
            }' | sed 's/\t/|/g' >> "$CSV_FILE"
        fi
    done

    if [[ $SERVER_HAS_MATCH -eq 1 ]]; then
        FOUND_SERVERS+=("$s")
    else
        NOT_FOUND_SERVERS+=("$s")
    fi

done

# ==========================================
# Final Summary
# ==========================================
echo -e "${cyn}====================================================${off}"
echo -e "${cyn}                   FINAL SUMMARY                    ${off}"
echo -e "${cyn}====================================================${off}"

if [ ${#FOUND_SERVERS[@]} -gt 0 ]; then
    echo -e "${grn}[+] Matches found in (${#FOUND_SERVERS[@]}):${off} ${FOUND_SERVERS[*]}"
else
    echo -e "${yel}[-] Nothing found in any accessible server.${off}"
fi

if [ ${#NOT_FOUND_SERVERS[@]} -gt 0 ]; then
    echo -e "${yel}[-] No matches in (${#NOT_FOUND_SERVERS[@]}):${off} ${NOT_FOUND_SERVERS[*]}"
fi

if [ ${#FAILED_CONN_SERVERS[@]} -gt 0 ]; then
    echo -e "${red}[!] Connection error (${#FAILED_CONN_SERVERS[@]}):${off} ${FAILED_CONN_SERVERS[*]}"
fi
echo -e "${cyn}====================================================${off}"