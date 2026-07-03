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
    echo -e "${bld}Hexon DB User Modifier - Fleet-wide User & Privilege Management${off}"
    echo -e "${cyn}==============================================================================================================${off}"
    echo -e "${yel}USAGE:${off}"
    echo -e "  $0 -u <user> [OPTIONS] [--dry-run | --execute]"
    echo -e ""
    echo -e "${yel}MANDATORY PARAMETERS:${off}"
    echo -e "  ${grn}-u, --user <name>${off}   Target MySQL username (e.g., 'app_user')."
    echo -e ""
    echo -e "${yel}OPTIONAL TARGETING:${off}"
    echo -e "  ${grn}-H, --host <host>${off}   Target MySQL host (e.g., '%', 'localhost'). ${blu}If omitted, script finds all hosts for the user.${off}"
    echo -e "  ${grn}-s, --server <ls>${off}   Executes ONLY in servers containing these strings (e.g., prod,master)."
    echo -e "  ${grn}-x, --exclude <ls>${off}  Ignores servers containing these strings (e.g., dev,test)."
    echo -e ""
    echo -e "${yel}MODIFICATION OPTIONS (Select at least one):${off}"
    echo -e "  ${grn}--max-conn <num>${off}    Sets MAX_USER_CONNECTIONS for the user."
    echo -e "  ${grn}--grant <privs>${off}     Grants specific privileges (e.g., 'SELECT, INSERT' or 'ALL PRIVILEGES')."
    echo -e "  ${grn}--revoke <privs>${off}    Revokes specific privileges."
    echo -e "  ${grn}--on <db.table>${off}     Required if using --grant or --revoke. Target database/table (e.g., 'test_db.*')."
    echo -e ""
    echo -e "${yel}EXECUTION (You must select one):${off}"
    echo -e "  ${grn}--dry-run${off}           Simulates the execution and prints the SQL without applying any changes."
    echo -e "  ${grn}--execute${off}           Prompts for confirmation interactively before applying changes to the databases."
    echo -e "  ${grn}--help${off}              Shows this help panel and exits."
    echo -e ""
    echo -e "${yel}EXAMPLES:${off}"
    echo -e "  ${wht}1. Dry-run a max connection limit for all instances of a user (auto-detects hosts):${off}"
    echo -e "     $0 -u my_app --max-conn 50 --dry-run"
    echo -e "  ${wht}2. Apply SELECT grants for a specific user@host on 'prod' servers (will prompt for confirmation):${off}"
    echo -e "     $0 -u reporting_usr -H '10.0.%' --grant \"SELECT\" --on \"sales_db.*\" -s prod --execute"
    echo -e "${cyn}==============================================================================================================${off}"
}

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# Initialize variables
DB_USER=""
DB_HOST=""
MAX_CONN=""
GRANT_PRIVS=""
REVOKE_PRIVS=""
TARGET_OBJ=""
CUSTOM_SERVERS=""
EXCLUDE_SERVERS=""
EXECUTE_MODE=0
DRY_RUN_MODE=0

# ==========================================
# Argument Parsing
# ==========================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--user) DB_USER="$2"; shift ;;
        -H|--host) DB_HOST="$2"; shift ;;
        --max-conn) MAX_CONN="$2"; shift ;;
        --grant) GRANT_PRIVS="$2"; shift ;;
        --revoke) REVOKE_PRIVS="$2"; shift ;;
        --on) TARGET_OBJ="$2"; shift ;;
        -s|--server) CUSTOM_SERVERS="$2"; shift ;;
        -x|--exclude) EXCLUDE_SERVERS="$2"; shift ;;
        --dry-run) DRY_RUN_MODE=1 ;;
        --execute) EXECUTE_MODE=1 ;;
        *) echo -e "${red}[ERROR] Unknown parameter: $1${off}\n"; show_help; exit 1 ;;
    esac
    shift
done

# ==========================================
# Input Validation
# ==========================================
if [[ -z "$DB_USER" ]]; then
    echo -e "${red}[ERROR] Missing mandatory parameter: --user is required.${off}\n"
    exit 1
fi

if [[ -z "$MAX_CONN" ]] && [[ -z "$GRANT_PRIVS" ]] && [[ -z "$REVOKE_PRIVS" ]]; then
    echo -e "${red}[ERROR] No actions specified. Use --max-conn, --grant, or --revoke.${off}\n"
    exit 1
fi

if [[ -n "$GRANT_PRIVS" || -n "$REVOKE_PRIVS" ]] && [[ -z "$TARGET_OBJ" ]]; then
    echo -e "${red}[ERROR] Missing --on parameter required for --grant or --revoke.${off}\n"
    exit 1
fi

if [[ $EXECUTE_MODE -eq 0 ]] && [[ $DRY_RUN_MODE -eq 0 ]]; then
    echo -e "${red}[ERROR] Execution mode not specified. You must use either --dry-run or --execute.${off}\n"
    exit 1
fi

if [[ $EXECUTE_MODE -eq 1 ]] && [[ $DRY_RUN_MODE -eq 1 ]]; then
    echo -e "${red}[ERROR] Contradictory flags. You cannot use --dry-run and --execute at the same time.${off}\n"
    exit 1
fi

# ==========================================
# SQL Builder Function
# ==========================================
build_sql() {
    local u="$1"
    local h="$2"
    local sql=""
    
    if [[ -n "$MAX_CONN" ]]; then
        sql="${sql}ALTER USER '${u}'@'${h}' WITH MAX_USER_CONNECTIONS ${MAX_CONN}; "
    fi
    if [[ -n "$GRANT_PRIVS" ]]; then
        sql="${sql}GRANT ${GRANT_PRIVS} ON ${TARGET_OBJ} TO '${u}'@'${h}'; "
    fi
    if [[ -n "$REVOKE_PRIVS" ]]; then
        sql="${sql}REVOKE ${REVOKE_PRIVS} ON ${TARGET_OBJ} FROM '${u}'@'${h}'; "
    fi
    if [[ -n "$GRANT_PRIVS" || -n "$REVOKE_PRIVS" ]]; then
        sql="${sql}FLUSH PRIVILEGES; "
    fi
    
    echo "$sql"
}

# ==========================================
# Server Selection
# ==========================================
ERR_FILE=$(mktemp /tmp/tmp_usermod.XXXXXX)
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

declare -a SUCCESS_SERVERS FAILED_SERVERS FAILED_CONN_SERVERS

if [[ -n "$DB_HOST" ]]; then
    echo -e "${cyn}Target User :${off} '${DB_USER}'@'${DB_HOST}'"
else
    echo -e "${cyn}Target User :${off} '${DB_USER}' ${blu}(Hosts will be auto-detected per server)${off}"
fi

if [[ $DRY_RUN_MODE -eq 1 ]]; then
    echo -e "${yel}[!] DRY RUN MODE ENABLED. No changes will be applied.${off}\n"
else
    echo -e "${red}[!] EXECUTE MODE ENABLED. You will be prompted before each change...${off}\n"
fi

# ==========================================
# Main Execution Loop
# ==========================================
for s in $SERVERS_TO_CHECK; do
    
    declare -a FOUND_HOSTS=()
    
    # 1. Determine the target hosts on this server
    if [[ -n "$DB_HOST" ]]; then
        USER_EXISTS=$(mysql --login-path="${s}" --connect-timeout=3 -Bse "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='${DB_HOST}';" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo -e "  ${blk}${red}[✗]${off} ${mag}${s}${off} -> ${red}Connection failed.${off}"
            FAILED_CONN_SERVERS+=("$s")
            continue
        fi
        if [[ -z "$USER_EXISTS" ]]; then
             echo -e "  ${yel}[!]${off} ${mag}${s}${off} -> User '${DB_USER}'@'${DB_HOST}' not found. Skipping."
             FAILED_SERVERS+=("$s (User missing)")
             continue
        fi
        FOUND_HOSTS=("$DB_HOST")
    else
        RAW_HOSTS=$(mysql --login-path="${s}" --connect-timeout=3 -Bse "SELECT Host FROM mysql.user WHERE User='${DB_USER}';" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo -e "  ${blk}${red}[✗]${off} ${mag}${s}${off} -> ${red}Connection failed.${off}"
            FAILED_CONN_SERVERS+=("$s")
            continue
        fi
        if [[ -z "$RAW_HOSTS" ]]; then
             echo -e "  ${yel}[!]${off} ${mag}${s}${off} -> No instances of user '${DB_USER}' found. Skipping."
             FAILED_SERVERS+=("$s (User missing)")
             continue
        fi
        FOUND_HOSTS=($RAW_HOSTS) # Split by spaces/newlines
    fi

    # 2. Iterate through each host found for the user on this server
    for h in "${FOUND_HOSTS[@]}"; do
        
        LOCAL_SQL=$(build_sql "$DB_USER" "$h")

        if [[ $DRY_RUN_MODE -eq 1 ]]; then
            # Color-coded dry-run prompt
            echo -e "  ${blu}[~] DRY RUN${off} | Srv: ${mag}${s}${off} | Target: ${cyn}'${DB_USER}'@'${h}'${off}"
            echo -e "      ${bld}${wht}COMMAND >${off} ${yel}${LOCAL_SQL}${off}"
            SUCCESS_SERVERS+=("$s ($h - Dry Run)")
        else
            # Execute Mode with Interactive Prompt
            echo -e "  ${yel}[?] READY${off} | Srv: ${mag}${s}${off} | Target: ${cyn}'${DB_USER}'@'${h}'${off}"
            echo -e "      ${bld}${wht}COMMAND >${off} ${red}${LOCAL_SQL}${off}"
            
            # Read confirmation directly from terminal device
            read -r -p "      >> Do you want to execute this command? (y/N): " confirm < /dev/tty
            
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                mysql --login-path="${s}" -e "${LOCAL_SQL}" 2>"$ERR_FILE"
                
                if [[ -s "$ERR_FILE" ]]; then
                    ERROR=$(cat "$ERR_FILE")
                    echo -e "      ${red}[✗] Error applying SQL:${off} $ERROR"
                    FAILED_SERVERS+=("$s ($h - SQL Error)")
                    > "$ERR_FILE"
                else
                    echo -e "      ${grn}[✓] Modifications applied successfully.${off}"
                    SUCCESS_SERVERS+=("$s ($h)")
                fi
            else
                echo -e "      ${blu}[-] Skipped by user.${off}"
                FAILED_SERVERS+=("$s ($h - User Skipped)")
            fi
        fi
    done
done

# ==========================================
# Final Summary
# ==========================================
echo -e "\n${cyn}====================================================${off}"
echo -e "${cyn}                   FINAL SUMMARY                    ${off}"
echo -e "${cyn}====================================================${off}"

if [ ${#SUCCESS_SERVERS[@]} -gt 0 ]; then
    echo -e "${grn}[+] Success/Dry-Run (${#SUCCESS_SERVERS[@]}):${off}"
    for srv in "${SUCCESS_SERVERS[@]}"; do echo "    - $srv"; done
fi

if [ ${#FAILED_SERVERS[@]} -gt 0 ]; then
    echo -e "${yel}[-] Skipped/Failed (${#FAILED_SERVERS[@]}):${off}"
    for srv in "${FAILED_SERVERS[@]}"; do echo "    - $srv"; done
fi

if [ ${#FAILED_CONN_SERVERS[@]} -gt 0 ]; then
    echo -e "${red}[!] Connection Errors (${#FAILED_CONN_SERVERS[@]}):${off} ${FAILED_CONN_SERVERS[*]}"
fi
echo -e "${cyn}====================================================${off}"