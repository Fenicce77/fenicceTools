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
GENERATE_ONLY="false"
LOCAL_TMP_DIR="$(pwd)/tmp"
OUTFILE="${LOCAL_TMP_DIR}/gcp_general_log_capture.sql"
LOGFILE="${LOCAL_TMP_DIR}/gcp_general_log_monitor.log"

usage() {
    cat <<EOF
${bld}NAME${off}
    gcp_general_log_monitor.sh - Capture GCP Cloud SQL general log telemetry

${bld}SYNOPSIS${off}
    ./gcp_general_log_monitor.sh -p <project> -i <instance> -l <login-path> -s <schema> [-d <duration>] [--fetch-only] [--generate-only] [--dry-run]

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
    -G, --generate-only Generate the SQL file but do not import it into MySQL.
    -D, --dry-run       Output commands to be executed without applying changes.
    -h, --help          Show this help message.

${bld}EXAMPLES${off}
    ${grn}su - rmateos${off}
    ./gcp_general_log_monitor.sh -p my-gcp-project -i my-prod-db -l target_monitor_node -s feniccedb -d 60 -f
    ./gcp_general_log_monitor.sh -p my-gcp-project -i my-prod-db -l target_monitor_node -s feniccedb -G
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
        -G|--generate-only) GENERATE_ONLY="true"; shift 1 ;;
        -D|--dry-run) DRY_RUN="true"; shift 1 ;;
        -h|--help) usage ;;
        *) echo "${red}[ERROR] Unknown parameter passed: $1${off}"; usage ;;
    esac
done

if [[ -z "${PROJECT}" || -z "${INSTANCE}" || -z "${LOGIN_PATH}" || -z "${SCHEMA}" ]]; then
    echo "${red}[ERROR] Missing required parameters.${off}"
    usage
fi

if [[ "${DRY_RUN}" == "true" && "${GENERATE_ONLY}" == "true" ]]; then
    echo "${red}[ERROR] --dry-run and --generate-only cannot be used together.${off}" >&2
    exit 2
fi

umask 077
mkdir -p "${LOCAL_TMP_DIR}"
: > "${LOGFILE}"
chmod 600 "${LOGFILE}"
GENERAL_LOG_MODIFIED="false"
CAPTURE_PID=""

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

cleanup_general_log() {
    local exit_status=$?

    trap - EXIT
    if [[ "${GENERAL_LOG_MODIFIED}" == "true" ]]; then
        log_msg "[$(timestamp)] ${yel}[WARNING] Restoring general_log after interrupted execution...${off}"
        if ! apply_flags "off"; then
            log_msg "[$(timestamp)] ${red}[ERROR] Failed to restore general_log. Manual intervention is required.${off}"
            echo "[ERROR] Failed to restore general_log. Manual intervention is required." >&2
            if [[ ${exit_status} -eq 0 ]]; then
                exit_status=1
            fi
        fi
        GENERAL_LOG_MODIFIED="false"
    fi
    exit "${exit_status}"
}

handle_signal() {
    local signal_status=$1

    if [[ -n "${CAPTURE_PID}" ]]; then
        kill "${CAPTURE_PID}" 2>/dev/null || true
        wait "${CAPTURE_PID}" 2>/dev/null || true
        CAPTURE_PID=""
    fi
    exit "${signal_status}"
}

trap cleanup_general_log EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

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
            clean_flags.append("{}={}".format(f["name"], f["value"]))
            
    print(f"ALREADY_ENABLED={is_on}")
    print("CLEAN_FLAGS={}".format(",".join(clean_flags)))
except Exception:
    print("ALREADY_ENABLED=false")
    print("CLEAN_FLAGS=")
' <<< "${CURRENT_FLAGS_JSON}")

    if [[ "${ALREADY_ENABLED}" == "true" ]]; then
        log_msg "[$(timestamp)] ${grn}[INFO] general_log is already enabled. Bypassing patch operation.${off}"
    else
        log_msg "[$(timestamp)] ${blu}[INFO] general_log is disabled. Patching instance to enable...${off}"
        apply_flags "on"
        GENERAL_LOG_MODIFIED="true"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_msg "[$(timestamp)] ${cyn}[DRY-RUN] SLEEP: sleep ${DURATION}${off}"
    else
        log_msg "[$(timestamp)] ${yel}[INFO] Sleeping for ${DURATION} seconds while traffic is captured...${off}"
        sleep "${DURATION}" &
        CAPTURE_PID=$!
        wait "${CAPTURE_PID}"
        CAPTURE_PID=""
    fi

    if [[ "${ALREADY_ENABLED}" == "false" ]]; then
        log_msg "[$(timestamp)] ${blu}[INFO] Reverting general_log to disabled state...${off}"
        apply_flags "off"
        GENERAL_LOG_MODIFIED="false"
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
# PARSER_PYTHON_BEGIN
import json
import re
import sys
from typing import Any, Dict, List, TextIO

COMMAND_TYPES = (
    "Sleep", "Quit", "Init DB", "Query", "Field List", "Create DB",
    "Drop DB", "Refresh", "Shutdown", "Statistics", "Processlist",
    "Connect", "Kill", "Debug", "Ping", "Time", "Delayed insert",
    "Change user", "Binlog Dump", "Table Dump", "Connect Out",
    "Register Replica", "Register Slave", "Prepare", "Execute", "Long Data",
    "Close stmt", "Reset stmt", "Set option", "Fetch", "Daemon",
    "Binlog Dump GTID", "Reset Connection", "clone",
    "Group Replication Data Stream subscription", "Error",
)

command_pattern = "|".join(
    re.escape(command).replace(r"\ ", r"\s+")
    for command in sorted(COMMAND_TYPES, key=len, reverse=True)
)

GENERAL_LOG_PATTERN = re.compile(
    rf"""
    \A
    (?P<event_time>
        \d{{4}}-\d{{2}}-\d{{2}}T
        \d{{2}}:\d{{2}}:\d{{2}}
        (?:\.\d{{1,6}})?Z
    )
    \s+
    (?P<outer_username>[^\s\[\]]+)
    \[(?P<username>[^\]\r\n]+)\]
    \s*@\s*
    \[(?P<host>[^\]\r\n]+)\]
    \s*
    (?P<thread_id>\d+)
    \s+
    (?P<server_id>\d+)
    \s+
    (?P<command_type>{command_pattern})
    (?:\s+(?P<argument>.*))?
    \Z
    """,
    re.VERBOSE | re.DOTALL,
)


def log_rejection(rejection_log: TextIO, reason: str, raw_payload: str) -> None:
    rejection_log.write(f"[PARSER REJECT] {reason}\n")
    rejection_log.write("[PARSER RAW PAYLOAD BEGIN]\n")
    rejection_log.write(raw_payload)
    if not raw_payload.endswith("\n"):
        rejection_log.write("\n")
    rejection_log.write("[PARSER RAW PAYLOAD END]\n")


def parse_mysql_general_log(
    json_input: str,
    target_schema: str,
    rejection_log: TextIO,
) -> str:
    sql_batches: List[str] = ["SET autocommit=0;\n"]
    current_batch: List[str] = []
    batch_size = 500
    accepted = 0
    rejected = 0

    try:
        logs: List[Dict[str, Any]] = json.loads(json_input)
    except Exception as exc:
        rejection_log.write(f"[PARSER ERROR] invalid JSON: {type(exc).__name__}: {exc}\n")
        return ""

    if not isinstance(logs, list):
        rejection_log.write("[PARSER ERROR] top-level JSON value is not a list\n")
        return ""

    for entry in reversed(logs):
        raw_line = ""
        if isinstance(entry, dict):
            if isinstance(entry.get("textPayload"), str):
                raw_line = entry["textPayload"]
            elif isinstance(entry.get("jsonPayload"), dict):
                json_payload = entry["jsonPayload"]
                for field in ("message", "textPayload", "query"):
                    if isinstance(json_payload.get(field), str):
                        raw_line = json_payload[field]
                        break

        line = raw_line.strip()
        if not line:
            rejected += 1
            log_rejection(rejection_log, "empty payload", raw_line)
            continue

        match = GENERAL_LOG_PATTERN.fullmatch(line)
        if not match:
            rejected += 1
            log_rejection(rejection_log, "payload format mismatch", raw_line)
            continue

        raw_time = match.group("event_time")
        username = match.group("username").strip()
        host = match.group("host").strip()
        thread_id = match.group("thread_id")
        server_id = match.group("server_id")
        command_type = re.sub(r"\s+", " ", match.group("command_type"))
        argument = match.group("argument") or ""
        current_time = raw_time[:-1].replace("T", " ", 1)
        user_host = f"{username}@{host}"
        accepted += 1

        safe_arg = argument.replace("\\", "\\\\").replace("\x27", "\x27\x27").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
        safe_user_host = user_host.replace("\x27", "\x27\x27")
        insert_stmt = f"INSERT INTO {target_schema}.general_log_analysis (thread_id, user_host, server_id, command_type, argument, event_time) VALUES ({thread_id}, \x27{safe_user_host}\x27, {server_id}, \x27{command_type}\x27, \x27{safe_arg}\x27, \x27{current_time}\x27);"
        current_batch.append(insert_stmt)

        if len(current_batch) >= batch_size:
            sql_batches.append("START TRANSACTION;\n" + "\n".join(current_batch) + "\nCOMMIT;\n")
            current_batch = []

    rejection_log.write(f"[PARSER SUMMARY] accepted={accepted} rejected={rejected}\n")
    if accepted == 0:
        return ""

    if current_batch:
        sql_batches.append("START TRANSACTION;\n" + "\n".join(current_batch) + "\nCOMMIT;\n")
    sql_batches.append("SET autocommit=1;\n")
    return "\n".join(sql_batches)


if __name__ == "__main__":
    raw_data = sys.stdin.read()
    schema = sys.argv[1]
    log_path = sys.argv[2]
    with open(log_path, "a", encoding="utf-8", newline="") as parser_log:
        sql_output = parse_mysql_general_log(raw_data, schema, parser_log)
    if sql_output:
        print(sql_output, end="")
# PARSER_PYTHON_END
' "${SCHEMA}" "${LOGFILE}" <<< "$RAW_LOGS" > "${OUTFILE}" 2>>"${LOGFILE}"

if [[ -s "${OUTFILE}" ]] && grep -q "INSERT INTO" "${OUTFILE}"; then
    log_msg "[$(timestamp)] ${grn}[OK] Transactions insertion file generated at ${OUTFILE}${off}"

    if [[ "${GENERATE_ONLY}" == "true" ]]; then
        log_msg "[$(timestamp)] ${grn}[OK] --generate-only completed. MySQL import skipped.${off}"
        exit 0
    fi

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
