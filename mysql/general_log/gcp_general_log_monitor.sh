#!/usr/bin/env bash
set -euo pipefail

# ANSI Color Codes
blk=$(tput blink || true)
bld=$(tput bold || true)
red=${bld}$(tput setaf 1 || true)
grn=${bld}$(tput setaf 2 || true)
yel=${bld}$(tput setaf 3 || true)
blu=${bld}$(tput setaf 4 || true)
cyn=${bld}$(tput setaf 6 || true)
off=$(tput sgr0 || true)

# Default Variables
DURATION="300"
PROJECT=""
INSTANCE=""
LOGIN_PATH=""
SCHEMA=""
DRY_RUN="false"
FETCH_ONLY="false"
LOCAL_TMP_DIR="$(pwd)/tmp"
OUTFILE="${LOCAL_TMP_DIR}/gcp_general_log_capture.sql"
LOGFILE="${LOCAL_TMP_DIR}/gcp_general_log_monitor.log"

usage() {
    cat <<EOF
${bld}NAME${off}
    gcp_general_log_monitor.sh - Capture GCP Cloud SQL general log telemetry

${bld}SYNOPSIS${off}
    ./gcp_general_log_monitor.sh -p <project> -i <instance> -l <login-path> -s <schema> [-d <duration>] [--fetch-only] [--dry-run]

${bld}DESCRIPTION${off}
    Evaluates current GCP Cloud SQL database flags to avoid unnecessary restarts. Enables general_log 
    only if disabled, captures traffic via Cloud Logging JSON API, parses payloads via typed Python, 
    and transactionally inserts into a target schema using mysql_config_editor login paths.

${bld}OPTIONS${off}
    -p, --project       GCP Project ID.
    -i, --instance      GCP Cloud SQL Instance name.
    -l, --login-path    MySQL login path for the target database.
    -s, --schema        Target database schema name.
    -d, --duration      Capture duration in seconds. Default: 300.
    -f, --fetch-only    Skip flag toggling and sleep; fetch full log history (ignores duration freshness).
    -D, --dry-run       Output commands to be executed without applying changes.
    -h, --help          Show this help message.

${bld}EXAMPLES${off}
    ${grn}su - rmateos${off}
    ./gcp_general_log_monitor.sh -p my-gcp-project -i my-prod-db -l target_monitor_node -s feniccedb -d 60 -f
EOF
    exit 1
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project) PROJECT="$2"; shift 2 ;;
        -i|--instance) INSTANCE="$2"; shift 2 ;;
        -l|--login-path) LOGIN_PATH="$2"; shift 2 ;;
        -s|--schema) SCHEMA="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        -f|--fetch-only) FETCH_ONLY="true"; shift 1 ;;
        -D|--dry-run) DRY_RUN="true"; shift 1 ;;
        -h|--help) usage ;;
        *) echo "${red}[ERROR] Unknown parameter passed: $1${off}"; usage ;;
    esac
done

if [[ -z "${PROJECT}" || -z "${INSTANCE}" || -z "${LOGIN_PATH}" || -z "${SCHEMA}" ]]; then
    echo "${red}[ERROR] Missing required parameters.${off}"
    usage
fi

mkdir -p "${LOCAL_TMP_DIR}"
> "${LOGFILE}"

log_msg() {
    local msg="$1"
    echo -e "${msg}" | tee -a "${LOGFILE}"
}

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log_msg "[$(timestamp)] ${blu}[INFO] Initiating general_log capture sequence for instance: ${INSTANCE} (Project: ${PROJECT})${off}"
log_msg "[$(timestamp)] ${blu}[INFO] Execution log: ${LOGFILE}${off}"

apply_flags() {
    local state=$1
    local new_flags
    local cmd

    if [[ -z "${CLEAN_FLAGS}" ]]; then
        new_flags="general_log=${state}"
    else
        new_flags="${CLEAN_FLAGS},general_log=${state}"
    fi

    cmd="gcloud sql instances patch \"${INSTANCE}\" --project=\"${PROJECT}\" --database-flags=\"${new_flags}\" --quiet"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_msg "[$(timestamp)] ${cyn}[DRY-RUN] COMMAND: ${cmd}${off}"
    else
        eval "${cmd}"
    fi
}

if [[ "${FETCH_ONLY}" == "true" ]]; then
    log_msg "[$(timestamp)] ${grn}[INFO] --fetch-only passed. Bypassing flag evaluation and traffic capture wait.${off}"
else
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_msg "[$(timestamp)] ${cyn}[DRY-RUN] Fetching current database flags via gcloud API...${off}"
    fi

    CURRENT_FLAGS_JSON=$(gcloud sql instances describe "${INSTANCE}" --project="${PROJECT}" --format="json" 2>/dev/null || echo "{}")

    eval $(python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
    flags = data.get("settings", {}).get("databaseFlags", [])
    
    is_on = "false"
    clean_flags = []
    
    for f in flags:
        if f["name"] == "general_log":
            if f["value"] == "on":
                is_on = "true"
        else:
            clean_flags.append(f"{f[\"name\"]}={f[\"value\"]}")
            
    print(f"ALREADY_ENABLED={is_on}")
    print(f"CLEAN_FLAGS={','.join(clean_flags)}")
except Exception:
    print("ALREADY_ENABLED=false")
    print("CLEAN_FLAGS=")
' <<< "${CURRENT_FLAGS_JSON}")

    if [[ "${ALREADY_ENABLED}" == "true" ]]; then
        log_msg "[$(timestamp)] ${grn}[INFO] general_log is already enabled. Bypassing patch operation.${off}"
    else
        log_msg "[$(timestamp)] ${blu}[INFO] general_log is disabled. Patching instance to enable...${off}"
        apply_flags "on"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_msg "[$(timestamp)] ${cyn}[DRY-RUN] SLEEP: sleep ${DURATION}${off}"
    else
        log_msg "[$(timestamp)] ${yel}[INFO] Sleeping for ${DURATION} seconds while traffic is captured...${off}"
        sleep "${DURATION}"
    fi

    if [[ "${ALREADY_ENABLED}" == "false" ]]; then
        log_msg "[$(timestamp)] ${blu}[INFO] Reverting general_log to disabled state...${off}"
        apply_flags "off"
    else
        log_msg "[$(timestamp)] ${blu}[INFO] general_log was originally enabled. Leaving flag in 'on' state.${off}"
    fi
fi

FILTER_STR="resource.type=\"cloudsql_database\" AND logName=\"projects/${PROJECT}/logs/cloudsql.googleapis.com%2Fmysql-general.log\" AND resource.labels.database_id=\"${PROJECT}:${INSTANCE}\""

CMD_ARRAY=(gcloud logging read "${FILTER_STR}" --project="${PROJECT}" --format="json" --limit=100000)

if [[ "${FETCH_ONLY}" == "false" ]]; then
    CMD_ARRAY+=(--freshness="${DURATION}s")
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    log_msg "[$(timestamp)] ${cyn}[DRY-RUN] COMMAND: ${CMD_ARRAY[*]}${off}"
    log_msg "[$(timestamp)] ${cyn}[DRY-RUN] ACTION: Python parser translates Cloud Logging JSON output to single INSERTs wrapped in transactions at ${OUTFILE}${off}"
    log_msg "[$(timestamp)] ${cyn}[DRY-RUN] COMMAND: mysql --login-path=\"${LOGIN_PATH}\" \"${SCHEMA}\" < \"${OUTFILE}\"${off}"
    log_msg "[$(timestamp)] ${grn}[OK] Dry-run complete. Exiting.${off}"
    exit 0
fi

if [[ "${FETCH_ONLY}" == "true" ]]; then
    log_msg "[$(timestamp)] ${blu}[INFO] Extracting full log history from Cloud Logging JSON API...${off}"
else
    log_msg "[$(timestamp)] ${blu}[INFO] Extracting logs from Cloud Logging JSON API for the past ${DURATION}s...${off}"
fi

RAW_LOGS=$("${CMD_ARRAY[@]}")

if [[ -z "${RAW_LOGS}" || "${RAW_LOGS}" == "[]" ]]; then
    log_msg "[$(timestamp)] ${yel}[WARNING] No general log data captured from Cloud Logging. Exiting.${off}"
    exit 0
fi

log_msg "[$(timestamp)] ${blu}[INFO] Parsing JSON payload logs and generating INSERT statements...${off}"

python3 -c '
import sys
import json
import re
from typing import List, Dict, Any

def parse_mysql_general_log(json_input: str, target_schema: str) -> str:
    sql_batches: List[str] = ["SET autocommit=0;\n"]
    current_batch: List[str] = []
    batch_size: int = 500  
    
    try:
        logs: List[Dict[str, Any]] = json.loads(json_input)
    except Exception:
        return ""
        
    cmd_types = r"(Query|Execute|Prepare|Close\sstmt|Connect|Quit|Init\sDB|Sleep|Ping|Field\sList|Fetch|Reset\sstmt|Change\suser)"
    
    # Pattern constructed using standard concatenation. 
    # Group 1: Time (Optional)
    # Group 2: Raw User string
    # Group 3: Raw IP string
    # Group 4: Thread ID
    # Group 5: Server ID
    # Group 6: Command Type
    # Group 7: Argument (Optional to support argument-less commands like Quit)
    pattern_str = r"^(?:(\d{4}-\d{2}-\d{2}T.*?Z?)\s+)?(.*?)\s*@\s*\[(.*?)\]\s*(\d+)\s+(\d+)\s+" + cmd_types + r"(?:\s+(.*))?$"
    pattern = re.compile(pattern_str, re.DOTALL)
    
    for entry in reversed(logs):
        line: str = ""
        
        if "textPayload" in entry:
            line = entry["textPayload"]
        elif "jsonPayload" in entry and isinstance(entry["jsonPayload"], dict):
            jp = entry["jsonPayload"]
            line = jp.get("message", jp.get("textPayload", jp.get("query", "")))
            
        line = line.strip()
        if not line:
            continue
            
        match = pattern.search(line)
        if match:
            raw_time = match.group(1)
            raw_user = match.group(2).strip()
            raw_ip = match.group(3).strip()
            thread_id = match.group(4)
            server_id = match.group(5)
            command_type = match.group(6).strip()
            argument = match.group(7) or ""
            
            # Sub T/Z artifacts from standard MySQL log time
            current_time = raw_time.replace("T", " ").replace("Z", "") if raw_time else ""
            user_host = f"{raw_user}@{raw_ip}"
        else:
            thread_id = "0"
            user_host = "unknown"
            server_id = "1"
            command_type = "Query"
            argument = line
            current_time = ""
            
        # Natively map GCP log metadata timestamp as reliable fallback
        if not current_time:
            gcp_time = entry.get("timestamp", "1970-01-01T00:00:00.000000Z")
            current_time = re.sub(r"[TZ]", " ", gcp_time).strip()
            current_time = re.sub(r"[+-]\d{2}:\d{2}$", "", current_time).strip()
            
        # SQL Injection & newline escaping layer
        safe_arg = argument.replace("\\", "\\\\").replace("\x27", "\x27\x27").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
        safe_user_host = user_host.strip().replace("\x27", "\x27\x27")
        
        insert_stmt = f"INSERT INTO {target_schema}.general_log_analysis (thread_id, user_host, server_id, command_type, argument, event_time) VALUES ({thread_id}, \x27{safe_user_host}\x27, {server_id}, \x27{command_type}\x27, \x27{safe_arg}\x27, \x27{current_time}\x27);"
        
        current_batch.append(insert_stmt)
        
        # Enforce batch execution caps to respect MySQL max_allowed_packet configurations
        if len(current_batch) >= batch_size:
            sql_batches.append("START TRANSACTION;\n" + "\n".join(current_batch) + "\nCOMMIT;\n")
            current_batch = []
            
    if current_batch:
        sql_batches.append("START TRANSACTION;\n" + "\n".join(current_batch) + "\nCOMMIT;\n")
        
    if len(sql_batches) > 1:
        sql_batches.append("SET autocommit=1;\n")
        return "\n".join(sql_batches)
    return ""

raw_data = sys.stdin.read()
schema = sys.argv[1]
sql_output = parse_mysql_general_log(raw_data, schema)
if sql_output:
    print(sql_output, end="")
' "${SCHEMA}" <<< "$RAW_LOGS" > "${OUTFILE}"

if [[ -s "${OUTFILE}" ]] && grep -q "INSERT INTO" "${OUTFILE}"; then
    log_msg "[$(timestamp)] ${grn}[OK] Transactions insertion file generated at ${OUTFILE}${off}"
    
    log_msg "[$(timestamp)] ${blu}[INFO] Populating target schema ${SCHEMA} via login-path ${LOGIN_PATH}...${off}"
    if mysql --login-path="${LOGIN_PATH}" "${SCHEMA}" < "${OUTFILE}" 2>>"${LOGFILE}"; then
        log_msg "[$(timestamp)] ${grn}[OK] Telemetry successfully flushed to ${SCHEMA}.general_log_analysis.${off}"
    else
        log_msg "[$(timestamp)] ${red}[ERROR] FAILED TO LOAD DATA. Inspect ${LOGFILE} and ${OUTFILE}.${off}"
        exit 3
    fi
else
    log_msg "[$(timestamp)] ${red}[ERROR] Transaction file generation failed or no parsable events found. Exiting...${off}"
    exit 2
fi