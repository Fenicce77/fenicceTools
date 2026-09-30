#!/bin/bash

print_help() {
    printf "\n\033[95m\033[1m=== MongoDB Live Activity Monitor (Percona 8.0.x) ===\033[0m\n\n"
    printf "\033[1mUSAGE:\033[0m\n"
    printf "  $0 [OPTIONS]\n\n"
    printf "\033[1mOPTIONS:\033[0m\n"
    printf "  \033[32m-d, --delay\033[0m    Refresh delay in seconds (Default: 2)\n"
    printf "  \033[32m-u, --user\033[0m     Initial filter for users, comma-separated (Default: ALL)\n"
    printf "  \033[32m-t, --time\033[0m     Initial filter for minimum execution time in seconds (Default: 0)\n"
    printf "  \033[32m-c, --config\033[0m   Path to custom config file (Default: searches locally for mongo_config.conf)\n"
    printf "  \033[32m-h, --help\033[0m     Show this colored help message and exit\n\n"
    printf "\033[1mEXAMPLES:\033[0m\n"
    printf "  $0 -d 3\n"
    printf "  $0 --user appUser1,appUser2 --time 5 --delay 2\n\n"
}

if [ "$#" -eq 0 ]; then
    print_help
    exit 0
fi

CONFIG_FILE=""
FILTER_USER=""
MIN_TIME=0
DELAY=2

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--config) CONFIG_FILE="$2"; shift ;;
        -u|--user) FILTER_USER="$2"; shift ;;
        -t|--time) MIN_TIME="$2"; shift ;;
        -d|--delay) 
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                DELAY="$2"; shift
            else
                DELAY=2
            fi
            ;;
        -h|--help) print_help; exit 0 ;;
        *) printf "\033[31mUnknown parameter passed: $1\033[0m\n"; print_help; exit 1 ;;
    esac
    shift
done

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "./mongo_config.conf" ]; then CONFIG_FILE="./mongo_config.conf"
    elif [ -f "$(dirname "$0")/mongo_config.conf" ]; then CONFIG_FILE="$(dirname "$0")/mongo_config.conf"
    else
        printf "\033[31mError: mongo_config.conf not found.\033[0m\n"
        exit 1
    fi
fi
source "$CONFIG_FILE"

IFS='/' read -r REPLSET NODES <<< "$MONGOHOST"
CONN_URI="mongodb://${MONGOADMINUSR}:${MONGOADMINPAS}@${NODES}/?authSource=${ADMINDB}&replicaSet=${REPLSET}"

while true; do
    clear

    JS_SCRIPT="
        const C_BLU = '\x1b[34m', C_GRN = '\x1b[32m', C_RED = '\x1b[31m', C_RST = '\x1b[0m', C_BLD = '\x1b[1m';
        const filterUserStr = '${FILTER_USER}';
        const minTime = ${MIN_TIME};
        
        // --- MULTI-USER PARSING (Split by comma, trim spaces, lowercase) ---
        const targetUsers = filterUserStr ? filterUserStr.split(',').map(u => u.trim().toLowerCase()).filter(u => u !== '') : [];
        
        const pipeline = [
            { \$currentOp: { allUsers: true, idleConnections: false } },
            { \$match: { active: true, ns: { \$ne: 'admin.\$cmd' } } }
        ];
        
        const ops = db.getSiblingDB('admin').aggregate(pipeline).toArray();
        
        print(C_BLD + 'OPID'.padEnd(10) + ' | ' + 'USER'.padEnd(15) + ' | ' + 'TIME(s)'.padEnd(7) + ' | ' + 'NAMESPACE'.padEnd(38) + ' | ' + 'TRX ID'.padEnd(36) + ' | ' + 'WAITING'.padEnd(7) + ' | COMMAND' + C_RST);
        print('-'.repeat(160));
        
        ops.forEach(op => {
            let user = (op.effectiveUsers && op.effectiveUsers.length > 0) ? op.effectiveUsers[0].user : 'System';
            let lowerUser = user.toLowerCase();
            
            if (lowerUser === 'system' || lowerUser === '__system') return;
            
            let timeSecs = op.secs_running || 0;
            
            // --- MULTI-USER FILTER LOGIC ---
            if (targetUsers.length > 0 && !targetUsers.includes(lowerUser)) return;
            if (timeSecs < minTime) return;
            
            let opid = String(op.opid).padEnd(10);
            let timeStr = String(timeSecs).padEnd(7);
            
            let rawNs = String(op.ns || '');
            let ns = rawNs.length > 38 ? (rawNs.substring(0, 35) + '...') : rawNs;
            ns = ns.padEnd(38);
            
            let trxId = (op.lsid && op.lsid.id) ? String(op.lsid.id.toUUID()).padEnd(36) : 'None'.padEnd(36);
            let waitLock = op.waitingForLock ? (C_RED + 'YES'.padEnd(7) + C_RST) : (C_GRN + 'NO'.padEnd(7) + C_RST);
            let cmd = op.command ? JSON.stringify(op.command).substring(0, 45) + '...' : 'N/A';
            
            print(opid + ' | ' + C_BLU + user.padEnd(15) + C_RST + ' | ' + timeStr + ' | ' + ns + ' | ' + trxId + ' | ' + waitLock + ' | ' + cmd);
        });
    "

    # Display users array nicely if provided
    DISPLAY_USERS=${FILTER_USER:-ALL}

    printf "\033[95m\033[1m=== MongoDB Live Activity Monitor (Percona 8.0.x) ===\033[0m\n"
    printf "Users Filter: \033[32m%s\033[0m | Min Time: \033[32m%ss\033[0m | Refresh: \033[32m%ss\033[0m\n" "$DISPLAY_USERS" "$MIN_TIME" "$DELAY"
    printf "%s\n" "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
    
    env NODE_NO_WARNINGS=1 $MONGOSHBINPATH "$CONN_URI" --quiet --eval "$JS_SCRIPT" 2>/dev/null
    
    printf "%s\n" "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
    printf "\033[1mInteractive Menu (Press Key):\033[0m [\033[33mu\033[0m] Set Users | [\033[33mt\033[0m] Min Time | [\033[33md\033[0m] Delay | [\033[33mq\033[0m] Quit\n"
    
    read -t $DELAY -n 1 choice
    
    if [ $? -eq 0 ]; then
        echo ""
        case $choice in
            u|U) read -p "Enter users to monitor (comma-separated, leave blank for all): " FILTER_USER ;;
            t|T) read -p "Enter minimum connection time (seconds): " MIN_TIME 
                 [[ "$MIN_TIME" =~ ^[0-9]+$ ]] || MIN_TIME=0 
                 ;;
            d|D) read -p "Enter refresh delay (seconds): " DELAY 
                 [[ "$DELAY" =~ ^[0-9]+$ ]] || DELAY=2
                 ;;
            q|Q) printf "\033[32mExiting gracefully...\033[0m\n"; exit 0 ;;
        esac
    fi
done