#!/bin/bash

# --- COLOR DEFINITIONS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- CONFIGURATION DEFAULTS ---
TOP_LIMIT=20
TOP_LIMIT_PROVIDED=false
TABLE_FILTER=""
AWK_TABLE_PATTERN=""
USER_FILTER=""
AWK_USER_PATTERN=""
OPERATION_FILTER=""
AWK_OP_PATTERN=""
ANALYSIS_MODE="all"
OUTPUT_DIR=""
START_DATE=""
END_DATE=""
REPORT_MODE="file"

# --- HELP FUNCTION (BLINDADA CON HEREDOC) ---
show_help() {
    echo -e "${BOLD}Usage: $0 [OPTIONS]${NC}"
    cat << 'EOF'
Analyzes SHOW ENGINE INNODB STATUS logs to extract Deadlocks, persistent Locks, Active Operations, Users, IPs, Thread IDs, and Trx IDs.
Files MUST strictly follow the naming convention: YYYYMMDD_HH.sample

Options:
  -d, --dir <directory>      Processes all files within the specified directory.
  -f, --file <file...>       Processes one or multiple explicitly provided files.
  -p, --pattern <pattern>    Processes files using a wildcard pattern.
  -s, --start <date>         Process files from this date. Format: 'YYYY-MM-DD [HH[:MM[:SS]]]'
  -e, --end <date>           Process files up to this date. Format: 'YYYY-MM-DD [HH[:MM[:SS]]]'
  -n, --top <number>         Specifies the number of queries to show in the global summary (Default: 20).
  -t, --table <names>        Filters analysis to show queries containing these table names (Comma-separated).
  -u, --user <name>          Filters analysis to show only locks/deadlocks caused by this user.
  -op, --operation <types>   Filters analysis by operation type (Comma-separated: insert, update, delete).
  -m, --mode <mode>          Selects the analysis scope: 
                               'ops'       -> ONLY Operations count and Time Series.
                               'full'      -> Operations count AND Deadlocks/Locks.
                               'all'       -> ONLY Deadlocks and Locks (Default).
                               'deadlocks' -> ONLY Deadlocks.
                               'locks'     -> ONLY Locks.
  -r, --report-mode <mode>   Detail output destination: 'screen', 'file', or 'both'. (Default: file)
  -o, --output-dir <dir>     Directory to save generated CSV reports and logs.
  -h, --help                 Displays this help message.
EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

# --- ARGUMENT PARSING LOGIC ---
FILES_TO_PROCESS=()
DATE_REGEX="^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}(:[0-9]{2}(:[0-9]{2})?)?)?$"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--dir) shift; if [[ -n "$1" && -d "$1" ]]; then while IFS= read -r -d $'\0' file; do FILES_TO_PROCESS+=("$file"); done < <(find "$1" -maxdepth 1 -type f -print0 | sort -z); shift; else echo -e "${RED}Error: Missing directory for -d.${NC}"; exit 1; fi ;;
        -f|--file) shift; while [[ "$#" -gt 0 && ! "$1" =~ ^- ]]; do if [[ -f "$1" ]]; then FILES_TO_PROCESS+=("$1"); else echo -e "${YELLOW}Warning: File '$1' does not exist.${NC}"; fi; shift; done ;;
        -p|--pattern) shift; if [[ -n "$1" && ! "$1" =~ ^- ]]; then for file in $1; do if [[ -f "$file" ]]; then FILES_TO_PROCESS+=("$file"); fi; done; shift; else echo -e "${RED}Error: Missing pattern for -p.${NC}"; exit 1; fi ;;
        -s|--start) shift; if [[ "$1" =~ $DATE_REGEX ]]; then START_DATE="$1"; shift; else echo -e "${RED}Error: Invalid start date format.${NC}"; exit 1; fi ;;
        -e|--end) shift; if [[ "$1" =~ $DATE_REGEX ]]; then END_DATE="$1"; shift; else echo -e "${RED}Error: Invalid end date format.${NC}"; exit 1; fi ;;
        -n|--top) shift; if [[ -n "$1" && "$1" =~ ^[0-9]+$ ]]; then TOP_LIMIT="$1"; TOP_LIMIT_PROVIDED=true; shift; else echo -e "${RED}Error: -n requires a valid integer.${NC}"; exit 1; fi ;;
        -t|--table) shift; if [[ -n "$1" && ! "$1" =~ ^- ]]; then TABLE_FILTER="$1"; AWK_TABLE_PATTERN=$(echo "$TABLE_FILTER" | sed 's/[[:space:]]*,[[:space:]]*/|/g; s/\./\\./g; s/\*/.*/g; s/?/./g' | tr '[:upper:]' '[:lower:]'); shift; else echo -e "${RED}Error: Missing table name(s).${NC}"; exit 1; fi ;;
        -u|--user) shift; if [[ -n "$1" && ! "$1" =~ ^- ]]; then USER_FILTER="$1"; AWK_USER_PATTERN=$(echo "$USER_FILTER" | sed 's/\./\\./g; s/\*/.*/g; s/?/./g' | tr '[:upper:]' '[:lower:]'); shift; else echo -e "${RED}Error: Missing user name.${NC}"; exit 1; fi ;;
        -op|--operation) shift; if [[ -n "$1" && ! "$1" =~ ^- ]]; then OPERATION_FILTER="$1"; AWK_OP_PATTERN=$(echo "$OPERATION_FILTER" | sed 's/[[:space:]]*,[[:space:]]*/|/g' | tr '[:lower:]' '[:upper:]'); shift; else echo -e "${RED}Error: Missing operation type(s).${NC}"; exit 1; fi ;;
        -m|--mode) shift; if [[ -n "$1" && "$1" =~ ^(all|deadlocks|locks|ops|full)$ ]]; then ANALYSIS_MODE="$1"; shift; else echo -e "${RED}Error: Mode must be 'all', 'deadlocks', 'locks', 'ops', or 'full'.${NC}"; exit 1; fi ;;
        -r|--report-mode) shift; if [[ -n "$1" && "$1" =~ ^(screen|file|both)$ ]]; then REPORT_MODE="$1"; shift; else echo -e "${RED}Error: --report-mode must be 'screen', 'file', or 'both'.${NC}"; exit 1; fi ;;
        -o|--output-dir) shift; if [[ -n "$1" && ! "$1" =~ ^- ]]; then OUTPUT_DIR="$1"; shift; else echo -e "${RED}Error: Missing directory path for -o.${NC}"; exit 1; fi ;;
        -h|--help) show_help; exit 0 ;;
        *) echo -e "${RED}Unknown parameter: $1${NC}"; show_help; exit 1 ;;
    esac
done

ANALYSIS_MODE_UPPER=$(echo "$ANALYSIS_MODE" | tr '[:lower:]' '[:upper:]')
REPORT_MODE_UPPER=$(echo "$REPORT_MODE" | tr '[:lower:]' '[:upper:]')

# Deduplication
if [[ ${#FILES_TO_PROCESS[@]} -gt 0 ]]; then
    UNIQUE_FILES=()
    while IFS= read -r line; do UNIQUE_FILES+=("$line"); done < <(printf '%s\n' "${FILES_TO_PROCESS[@]}" | sort -u)
    FILES_TO_PROCESS=("${UNIQUE_FILES[@]}")
fi

# Strict Filename Enforcement
VALIDATED_FILES=()
for file in "${FILES_TO_PROCESS[@]}"; do
    filename=$(basename "$file")
    if [[ "$filename" =~ ^[0-9]{8}_[0-9]{2}\.sample$ ]]; then VALIDATED_FILES+=("$file")
    else echo -e "${YELLOW}Warning: File '$filename' ignored. Format must be 'YYYYMMDD_HH.sample'.${NC}"; fi
done
FILES_TO_PROCESS=("${VALIDATED_FILES[@]}")

if [[ ${#FILES_TO_PROCESS[@]} -eq 0 ]]; then echo -e "${RED}Error: No valid files found.${NC}"; exit 1; fi

# Output Logic
if [[ -n "$OUTPUT_DIR" ]]; then mkdir -p "$OUTPUT_DIR"; REPORT_FILE="${OUTPUT_DIR}/innodb_report_${ANALYSIS_MODE_UPPER}.log"; else REPORT_FILE="innodb_report_${ANALYSIS_MODE_UPPER}.log"; fi
out_always() { local tmp_out=$(mktemp); cat > "$tmp_out"; cat "$tmp_out"; if [[ "$REPORT_MODE" != "screen" ]]; then sed 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" >> "$REPORT_FILE"; fi; rm -f "$tmp_out"; }
out_detail() { local tmp_out=$(mktemp); cat > "$tmp_out"; if [[ "$REPORT_MODE" == "screen" || "$REPORT_MODE" == "both" ]]; then cat "$tmp_out"; fi; if [[ "$REPORT_MODE" == "file" || "$REPORT_MODE" == "both" ]]; then sed 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" >> "$REPORT_FILE"; fi; rm -f "$tmp_out"; }

# Date Filtering Logic
FULL_START_DATE="0000-00-00 00:00:00"; FULL_END_DATE="9999-99-99 99:99:99"
HAS_DATE_FILTER=false
if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then
    HAS_DATE_FILTER=true
    VALID_FILES=()
    if [[ -n "$START_DATE" && -z "$END_DATE" ]]; then END_DATE="${START_DATE:0:10}"; fi
    if [[ -z "$START_DATE" && -n "$END_DATE" ]]; then START_DATE="${END_DATE:0:10}"; fi

    FULL_START_DATE="$START_DATE"
    [[ ${#FULL_START_DATE} == 10 ]] && FULL_START_DATE="${FULL_START_DATE} 00:00:00"
    [[ ${#FULL_START_DATE} == 13 ]] && FULL_START_DATE="${FULL_START_DATE}:00:00"
    [[ ${#FULL_START_DATE} == 16 ]] && FULL_START_DATE="${FULL_START_DATE}:00"

    FULL_END_DATE="$END_DATE"
    [[ ${#FULL_END_DATE} == 10 ]] && FULL_END_DATE="${FULL_END_DATE} 23:59:59"
    [[ ${#FULL_END_DATE} == 13 ]] && FULL_END_DATE="${FULL_END_DATE}:59:59"
    [[ ${#FULL_END_DATE} == 16 ]] && FULL_END_DATE="${FULL_END_DATE}:59"

    NORM_START=$(echo "$START_DATE" | tr -d -- '- :'); while [ ${#NORM_START} -lt 14 ]; do NORM_START="${NORM_START}0"; done
    NORM_END=$(echo "$END_DATE" | tr -d -- '- :'); while [ ${#NORM_END} -lt 14 ]; do NORM_END="${NORM_END}9"; done
    
    for file in "${FILES_TO_PROCESS[@]}"; do
        filename=$(basename "$file")
        FILE_YMD=${filename:0:8}; FILE_HR=${filename:9:2}
        NORM_FILE="${FILE_YMD}${FILE_HR}0000"
        if [[ "$NORM_FILE" < "$NORM_START" || "$NORM_FILE" > "$NORM_END" ]]; then continue; fi
        VALID_FILES+=("$file")
    done
    FILES_TO_PROCESS=("${VALID_FILES[@]}")
    if [[ ${#FILES_TO_PROCESS[@]} -eq 0 ]]; then echo -e "${RED}Error: No files fall within the specified date range.${NC}"; exit 0; fi
fi

# Dynamic Time-Bucketing Decision (Hourly vs Daily)
GROUPING_MODE="HOURLY"
if [[ "$HAS_DATE_FILTER" == true ]]; then
    DIFF_SEC=$(awk -v s="$FULL_START_DATE" -v e="$FULL_END_DATE" '
    function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
        split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
        split("31 28 31 30 31 30 31 31 30 31 30 31", md, " "); if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
        days = 0; for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
        for (i = 1; i < m; i++) days += md[i]; days += d - 1; return days * 86400 + h * 3600 + mn * 60 + s;
    }
    BEGIN { s_ep = get_epoch(s); e_ep = get_epoch(e); print (e_ep - s_ep); }')
    
    if (( DIFF_SEC >= 86400 )); then GROUPING_MODE="DAILY"; fi
fi

# Naming params for output files
PARAM_STR=""
[[ -n "$TABLE_FILTER" ]] && PARAM_STR+="tbl-$(echo "$TABLE_FILTER" | tr -s ', *?' '_')"
[[ -n "$USER_FILTER" ]] && { [[ -n "$PARAM_STR" ]] && PARAM_STR+="_"; PARAM_STR+="usr-${USER_FILTER//[*?]/_}"; }
[[ -n "$OPERATION_FILTER" ]] && { [[ -n "$PARAM_STR" ]] && PARAM_STR+="_"; PARAM_STR+="op-$(echo "$OPERATION_FILTER" | tr -s ', ' '_')"; }
[[ -z "$PARAM_STR" ]] && PARAM_STR="no_filters"

DATE_STR_FOR_FILE=""
if [[ "$HAS_DATE_FILTER" == true ]]; then
    S_FILE=$(echo "$START_DATE" | tr -d ':-' | tr ' ' '_'); E_FILE=$(echo "$END_DATE" | tr -d ':-' | tr ' ' '_')
    DATE_STR_FOR_FILE="from_${S_FILE}_to_${E_FILE}_"
fi

# EXECUTION HEADER
{
    echo -e "${BLUE}${BOLD}==============================================================="
    echo "INNODB POST-MORTEM AGGREGATED REPORT (BATCH MODE)"
    echo "Files matched  : ${#FILES_TO_PROCESS[@]} file(s)"
    echo "Analysis Mode  : [ ${ANALYSIS_MODE_UPPER} ]"
    if [[ "$HAS_DATE_FILTER" == true ]]; then echo -e "Time Filter    : [ ${START_DATE} ] to [ ${END_DATE} ]"; fi
    if [[ -n "$TABLE_FILTER" ]]; then echo -e "Table Filter   : Active [ Pattern: \"$TABLE_FILTER\" ]"; fi
    if [[ -n "$OPERATION_FILTER" ]]; then echo -e "Operation Scope: Active [ Pattern: \"$OPERATION_FILTER\" ]"; fi
    echo "Grouping Mode  : [ ${GROUPING_MODE} ]"
    echo "Generated      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "===============================================================${NC}"
} | out_always

TMP_RAW=$(mktemp); TMP_DEADLOCKS=$(mktemp); TMP_LOCKS=$(mktemp); GLOBAL_TMP_RAW=$(mktemp); GLOBAL_UNIQUE_RAW=$(mktemp)
trap 'rm -f "$TMP_RAW" "$TMP_DEADLOCKS" "${TMP_DEADLOCKS}_agg" "$TMP_LOCKS" "${TMP_LOCKS}_agg" "$GLOBAL_TMP_RAW" "$GLOBAL_UNIQUE_RAW" "${GLOBAL_UNIQUE_RAW}_agg"' EXIT

generate_report_section() {
    local file=$1; local is_deadlock=$2
    if [[ "$is_deadlock" == "true" ]]; then
        awk -F'|' '{ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7; count[query]++; if(intervals[query]=="") intervals[query]=ts; else intervals[query]=intervals[query] "," ts; u_k=query "\034" user; if(!seen_u[u_k]++){users[query]=(users[query]==""?user:users[query]", "user);} t_k=query "\034" thread; if(!seen_t[t_k]++){threads[query]=(threads[query]==""?thread:threads[query]", "thread);} rx_k=query "\034" trx; if(!seen_rx[rx_k]++){trxs[query]=(trxs[query]==""?trx:trxs[query]", "trx);}} END { for(q in count) printf "%d\t%s\t%s\t%s\t%s\n", count[q], intervals[q], users[q], threads[q], q;}' "$file" | sort -nr > "${file}_agg"
        while IFS=$'\t' read -r freq timestamps users_list threads_list query; do
            hash=$(printf "%s" "$query" | md5sum | cut -c1-12)
            echo -e "${RED}---------------------------------------------------------------"
            echo -e "${BOLD}[CRITICAL (DEADLOCK)] HASH: $hash | Events: $freq${NC}${RED}"
            echo -e "Query Template : $query"; echo -e "Affected Users : $users_list"
            display_threads="$threads_list"; num_threads=$(echo "$threads_list" | awk -F', ' '{print NF}')
            if (( num_threads > 3 )); then display_threads=$(echo "$threads_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}'); display_threads="${display_threads} (+$((num_threads - 3)) more)"; fi
            echo -e "Thread IDs     : $display_threads"; echo -e "${NC}"
        done < "${file}_agg"
    else
        awk -F'|' 'function get_epoch(ts,a,y,m,d,h,mn,s,i,days,md){split(ts,a,/[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0; split("31 28 31 30 31 30 31 31 30 31 30 31", md, " "); if(y%4==0&&(y%100!=0||y%400==0)) md[2]=29; days=0; for(i=1970;i<y;i++){days+=365; if(i%4==0&&(i%100!=0||i%400==0)) days++;} for(i=1;i<m;i++) days+=md[i]; days+=d-1; return days*86400+h*3600+mn*60+s;} {ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7; count[query]++; u_k=query "\034" user; if(!seen_u[u_k]++){users[query]=(users[query]==""?user:users[query]", "user);} t_k=query "\034" thread; if(!seen_t[t_k]++){threads[query]=(threads[query]==""?thread:threads[query]", "thread);} epoch=get_epoch(ts); if(s_ts[query]==""){s_ts[query]=ts; s_ep[query]=epoch; l_ts[query]=ts; l_ep[query]=epoch;} else{gap=epoch-l_ep[query]; if(gap<=15){l_ts[query]=ts; l_ep[query]=epoch;}else{dur=l_ep[query]-s_ep[query]; r_str=dur "|" s_ts[query] "|" l_ts[query]; ranges[query]=(ranges[query]==""?r_str:ranges[query] ";" r_str); s_ts[query]=ts; s_ep[query]=epoch; l_ts[query]=ts; l_ep[query]=epoch;}}} END {for(q in count){dur=l_ep[q]-s_ep[q]; r_str=dur "|" s_ts[q] "|" l_ts[q]; ranges[q]=(ranges[q]==""?r_str:ranges[q] ";" r_str); printf "%d\t%s\t%s\t%s\t%s\n", count[q], ranges[q], users[q], threads[q], q;}}' "$file" | sort -nr > "${file}_agg"
        while IFS=$'\t' read -r freq range_data users_list threads_list query; do
            hash=$(printf "%s" "$query" | md5sum | cut -c1-12)
            max_dur=$(echo "$range_data" | tr ';' '\n' | cut -d'|' -f1 | sort -nr | head -n 1)
            color="${GREEN}"; severity_label="LOW (< 30s max contention)"
            if (( max_dur >= 60 )); then color="${RED}"; severity_label="HIGH (>= 60s max contention)"
            elif (( max_dur >= 30 )); then color="${YELLOW}"; severity_label="MEDIUM (30s-60s max contention)"; fi
            echo -e "${color}---------------------------------------------------------------"
            echo -e "${BOLD}[$severity_label] HASH: $hash | Total Samples: $freq${NC}${color}"
            echo -e "Query Template : $query"; echo -e "Affected Users : $users_list"
            display_threads="$threads_list"; num_threads=$(echo "$threads_list" | awk -F', ' '{print NF}')
            if (( num_threads > 3 )); then display_threads=$(echo "$threads_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}'); display_threads="${display_threads} (+$((num_threads - 3)) more)"; fi
            echo -e "Thread IDs     : $display_threads"; echo -e "${NC}"
        done < "${file}_agg"
    fi
}

for current_file in "${FILES_TO_PROCESS[@]}"; do
    FILE_NAME_BASE=$(basename "$current_file")
    { echo -e "\n${BLUE}${BOLD}==============================================================="; echo "ANALYZING FILE: $FILE_NAME_BASE"; echo -e "===============================================================${NC}"; } | out_detail
    > "$TMP_RAW"

    awk -v tbl_pat="$AWK_TABLE_PATTERN" -v usr_pat="$AWK_USER_PATTERN" -v op_pat="$AWK_OP_PATTERN" -v mode="$ANALYSIS_MODE" -v awk_start="$FULL_START_DATE" -v awk_end="$FULL_END_DATE" -v file_base="$FILE_NAME_BASE" '
    function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
        split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
        split("31 28 31 30 31 30 31 31 30 31 30 31", md, " "); if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
        days = 0; for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
        for (i = 1; i < m; i++) days += md[i]; days += d - 1; return days * 86400 + h * 3600 + mn * 60 + s;
    }
    BEGIN { 
        in_deadlock=0; in_trans=0; is_lock=0; expect_query=0; 
        current_ts=""; deadlock_ts=""; ignore_deadlock=0;
        current_dl_user="unknown"; current_dl_host="unknown"; current_dl_thread="unknown"; current_dl_trx="unknown";
        current_lock_user="unknown"; current_lock_host="unknown"; current_lock_thread="unknown"; current_lock_trx="unknown";
        if (match(file_base, /^[0-9]{8}_[0-9]{2}/)) { fallback_ts = substr(file_base, 1, 4) "-" substr(file_base, 5, 2) "-" substr(file_base, 7, 2) " " substr(file_base, 10, 2) ":00:00"; } 
        else { fallback_ts = "1970-01-01 00:00:00"; }
        fallback_epoch = get_epoch(fallback_ts);
    }
    FNR == 1 { in_deadlock = 0; in_trans = 0; deadlock_ts = ""; ignore_deadlock = 0; current_ts = fallback_ts; }
    /INNODB MONITOR OUTPUT/ { if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) current_ts = substr($0, RSTART, RLENGTH); }
    /TRANSACTION [0-9]+/ {
        trx = "unknown";
        for (i=1; i<=NF; i++) { if ($i ~ /TRANSACTION/ && $(i+1) ~ /^[0-9]+,?$/) { trx = $(i+1); sub(/,/, "", trx); break; } }
        if (trx != "unknown") { if (in_deadlock && !ignore_deadlock) current_dl_trx = trx; if (in_trans) current_lock_trx = trx; }
    }
    /^LATEST DETECTED DEADLOCK/ { in_deadlock=1; deadlock_ts=""; ignore_deadlock=0; next; }
    /^[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
        if (in_deadlock && deadlock_ts == "") {
            match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/); deadlock_ts = substr($0, RSTART, RLENGTH); dl_epoch = get_epoch(deadlock_ts);
            if (fallback_epoch > 0 && (fallback_epoch - dl_epoch) > 9000) ignore_deadlock = 1;
            if (awk_start != "0000-00-00 00:00:00" && deadlock_ts < awk_start) ignore_deadlock = 1;
            if (awk_end != "9999-99-99 99:99:99" && deadlock_ts > awk_end) ignore_deadlock = 1;
        }
    }
    in_deadlock && /^[A-Z ]+$/ && !/TRANSACTION|WAITING|GRANTED|RECORD/ { in_deadlock=0; ignore_deadlock=0; }
    /^TRANSACTIONS/ { in_trans=1; in_deadlock=0; ignore_deadlock=0; next; }
    in_trans && /^FILE I\/O/ { in_trans=0; next; }
    in_trans && /LOCK WAIT/ { is_lock=1; }
    /MySQL thread id/ {
        thread = $4; sub(/,/, "", thread); user = "unknown"; host = "unknown";
        for (i=1; i<=NF; i++) { if ($i == "query" && $(i+1) == "id") { if (NF >= i+4) { host = $(i+3); user = $(i+4); } break; } }
        if (in_deadlock && !ignore_deadlock) { current_dl_user = user; current_dl_host = host; current_dl_thread = thread; }
        if (in_trans) { current_lock_user = user; current_lock_host = host; current_lock_thread = thread; }
    }
    /query id/ { if ((in_deadlock && !ignore_deadlock) || in_trans) expect_query=1; next; }
    expect_query {
        query = $0; sub(/^[ \t]+/, "", query); expect_query = 0; 
        query_upper = toupper(query);
        if (match(query_upper, /^(INSERT|UPDATE|DELETE|SELECT|REPLACE)/)) {
            op = substr(query_upper, 1, RLENGTH);
            if (op_pat != "" && op !~ "^(" op_pat ")$") { is_lock = 0; next; }
            if (tbl_pat != "" && tolower(query) !~ tbl_pat) { is_lock = 0; next; }
            active_user = (in_deadlock && !ignore_deadlock) ? current_dl_user : current_lock_user;
            if (usr_pat != "" && tolower(active_user) !~ usr_pat) { is_lock = 0; next; }
            
            template = query; 
            gsub(/[^[:print:]]/, "", template); gsub(/_binary[ \t]*\047([^\047\\]|\\.)*\047/, "?", template); gsub(/_binary[ \t]*"([^"\\]|\\.)*"/, "?", template);
            gsub(/\047([^\047\\]|\\.)*\047/, "?", template); gsub(/"([^"\\]|\\.)*"/, "?", template); gsub(/0x[0-9a-fA-F]+/, "?", template);
            gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?)?/, "?", template); gsub(/\b([Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Uu][Ll][Ll])\b/, "?", template);
            gsub(/,/, " , ", template); gsub(/\(/, " ( ", template); gsub(/\)/, " ) ", template); gsub(/=/, " = ", template); gsub(/</, " < ", template); gsub(/>/, " > ", template);
            while (gsub(/(^|[ \t])-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?([ \t]|$)/, " ? ", template)) {}
            gsub(/[ \t]+,[ \t]+/, ", ", template); gsub(/[ \t]+\)/, ")", template); gsub(/\([ \t]+/, "(", template); gsub(/[ \t]+=[ \t]+/, " = ", template); gsub(/[ \t]+<[ \t]+/, " < ", template); gsub(/[ \t]+>[ \t]+/, " > ", template);
            gsub(/[ \t]+/, " ", template);
            
            if (in_deadlock && !ignore_deadlock) { print "DEADLOCK|" deadlock_ts "|" current_dl_user "|" current_dl_host "|" current_dl_thread "|" current_dl_trx "|" template; } 
            else if (in_trans) {
                if (is_lock) { print "LOCK|" current_ts "|" current_lock_user "|" current_lock_host "|" current_lock_thread "|" current_lock_trx "|" template; } 
                else { print "ACTIVE|" current_ts "|" current_lock_user "|" current_lock_host "|" current_lock_thread "|" current_lock_trx "|" template; }
            }
        }
        is_lock = 0; 
    }
    ' "$current_file" > "$TMP_RAW"

    cat "$TMP_RAW" >> "$GLOBAL_TMP_RAW"
    
    if [[ "$ANALYSIS_MODE" =~ ^(all|deadlocks|full)$ ]]; then grep "^DEADLOCK|" "$TMP_RAW" | sort -u > "$TMP_DEADLOCKS"; { echo -e "\n${RED}${BOLD}### [ DEADLOCKS - $FILE_NAME_BASE ] ###${NC}"; if [[ -s "$TMP_DEADLOCKS" ]]; then generate_report_section "$TMP_DEADLOCKS" "true"; else echo -e "${GREEN}No deadlocks detected.${NC}"; fi; } | out_detail; fi
    if [[ "$ANALYSIS_MODE" =~ ^(all|locks|full)$ ]]; then grep "^LOCK|" "$TMP_RAW" | sort -u > "$TMP_LOCKS"; { echo -e "\n${YELLOW}${BOLD}### [ LOCKS - $FILE_NAME_BASE ] ###${NC}"; if [[ -s "$TMP_LOCKS" ]]; then generate_report_section "$TMP_LOCKS" "false"; else echo -e "${GREEN}No locks detected.${NC}"; fi; } | out_detail; fi
done

# --- GLOBAL AGGREGATION ENGINE ---
sort -u "$GLOBAL_TMP_RAW" > "$GLOBAL_UNIQUE_RAW"

if [[ ! -s "$GLOBAL_UNIQUE_RAW" ]]; then { echo -e "\n${GREEN}No database operations matching the criteria found.${NC}"; } | out_always; exit 0; fi

LC_ALL=C awk -v grp_mode="$GROUPING_MODE" -F'|' '
function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
    split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
    split("31 28 31 30 31 30 31 31 30 31 30 31", md, " "); if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
    days = 0; for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
    for (i = 1; i < m; i++) days += md[i]; days += d - 1; return days * 86400 + h * 3600 + mn * 60 + s;
}
BEGIN { global_start="9999"; global_end="0000"; global_total_ops=0; }
{
    type=$1; ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7;
    epoch = get_epoch(ts);
    
    if (ts < global_start) global_start = ts; if (ts > global_end) global_end = ts;
    
    query_upper = toupper(query);
    if (match(query_upper, /^(INSERT|UPDATE|DELETE|SELECT|REPLACE)/)) { op = substr(query_upper, 1, RLENGTH); } else { op = "OTHER"; }
    
    # 1. GROUPING & TIME SERIES LOGIC
    bucket = (grp_mode == "DAILY") ? substr(ts, 1, 10) : substr(ts, 1, 13) ":00";
    op_time_b[bucket "\034" op]++;
    bucket_total[bucket]++;
    seen_bucket[bucket]=1;
    
    # 2. GLOBAL OP TOTALS
    op_count[op]++; 
    global_total_ops++;
    
    # 3. DETAILED QUERY METRICS
    op_occ[query]++;
    if (op_first[query] == "" || ts < op_first[query]) op_first[query] = ts;
    if (op_last[query] == "" || ts > op_last[query]) op_last[query] = ts;
    if (op_fepoch[query] == "" || epoch < op_fepoch[query]) op_fepoch[query] = epoch;
    if (op_lepoch[query] == "" || epoch > op_lepoch[query]) op_lepoch[query] = epoch;
    
    u_key = query "\034" user; if (!seen_ou[u_key]++) { op_users[query] = (op_users[query]=="" ? user : op_users[query] ", " user); }
    t_key = query "\034" thread; if (!seen_ot[t_key]++) { op_threads[query] = (op_threads[query]=="" ? thread : op_threads[query] ", " thread); }
    
    # 4. CONTENTION METRICS
    if (type == "DEADLOCK" || type == "LOCK") {
        key = type "\034" query; occurrences[key]++;
        if (first_seen[key] == "" || ts < first_seen[key]) first_seen[key] = ts;
        if (last_seen[key] == "" || ts > last_seen[key]) last_seen[key] = ts;
        u_k = key "\034" user; if (!seen_cu[u_k]++) { c_users[key] = (c_users[key]=="" ? user : c_users[key] ", " user); }
        t_k = key "\034" thread; if (!seen_ct[t_k]++) { c_threads[key] = (c_threads[key]=="" ? thread : c_threads[key] ", " thread); }
        
        if (type == "DEADLOCK") { dl_op_count[op]++; }
        if (type == "LOCK") {
            lk_op_count[op]++;
            if (start_epoch[key] == "") { start_epoch[key] = epoch; last_epoch_in[key] = epoch; } else {
                gap = epoch - last_epoch_in[key];
                if (gap <= 15) { last_epoch_in[key] = epoch; } 
                else { dur = last_epoch_in[key] - start_epoch[key]; total_dur[key] += dur; start_epoch[key] = epoch; last_epoch_in[key] = epoch; }
            }
        }
    }
}
END {
    print "TIMEFRAME|" global_start " to " global_end;
    global_start_epoch = get_epoch(global_start); global_end_epoch = get_epoch(global_end);
    global_dur_min = (global_end_epoch - global_start_epoch) / 60.0; if (global_dur_min < 1) global_dur_min = 1;
    
    print "GLOBAL_TOTAL|" global_total_ops;
    
    # Export OP Rates & Summary (with Accumulators for Total Row)
    total_dl = 0; total_lk = 0;
    for (o in op_count) {
        pct = (global_total_ops > 0) ? (op_count[o] / global_total_ops) * 100 : 0;
        dl_cnt = (dl_op_count[o] != "") ? dl_op_count[o] : 0; 
        lk_cnt = (lk_op_count[o] != "") ? lk_op_count[o] : 0;
        total_dl += dl_cnt; total_lk += lk_cnt;
        op_pm = op_count[o] / global_dur_min;
        printf "STAT_OP|%s|%d|%.2f|%.2f|%d|%d\n", o, op_count[o], pct, op_pm, dl_cnt, lk_cnt;
    }
    
    # Send the TOTAL row out
    total_op_pm = global_total_ops / global_dur_min;
    printf "STAT_TOTAL|TOTAL|%d|100.00|%.2f|%d|%d\n", global_total_ops, total_op_pm, total_dl, total_lk;
    
    # Export Time Series
    for (b in seen_bucket) {
        ins = op_time_b[b "\034" "INSERT"] + 0; upd = op_time_b[b "\034" "UPDATE"] + 0;
        del = op_time_b[b "\034" "DELETE"] + 0; sel = op_time_b[b "\034" "SELECT"] + 0;
        rep = op_time_b[b "\034" "REPLACE"] + 0; 
        oth = bucket_total[b] - (ins+upd+del+sel+rep);
        printf "TIME_SERIES|%s|%d|%d|%d|%d|%d|%d|%d\n", b, bucket_total[b]+0, ins, upd, del, sel, rep, oth;
    }

    # Detailed Queries
    for (q in op_occ) {
        dur_min = (op_lepoch[q] - op_fepoch[q]) / 60.0; if (dur_min < 1) dur_min = 1; op_pm = op_occ[q] / dur_min;
        printf "DATA_OP|%d|%.2f|%s|%s|%s\n", op_occ[q], op_pm, op_first[q], op_last[q], q;
    }
    for (k in occurrences) {
        split(k, arr, "\034"); type = arr[1]; q = arr[2]; occ = occurrences[k];
        if (type == "DEADLOCK") { printf "DATA_DL|%d|%s|%s|%s\n", occ, first_seen[k], last_seen[k], q; } 
        else if (type == "LOCK") { 
            if (start_epoch[k] != "") { dur = last_epoch_in[k] - start_epoch[k]; total_dur[k] += dur; } 
            printf "DATA_LK|%d|%d|%s|%s|%s\n", total_dur[k]+0, occ, first_seen[k], last_seen[k], q; 
        }
    }
}' "$GLOBAL_UNIQUE_RAW" > "${GLOBAL_UNIQUE_RAW}_agg"

TIMEFRAME_STR=$(grep "^TIMEFRAME|" "${GLOBAL_UNIQUE_RAW}_agg" | cut -d'|' -f2)
GLOBAL_TOTAL_OPS=$(grep "^GLOBAL_TOTAL|" "${GLOBAL_UNIQUE_RAW}_agg" | cut -d'|' -f2)
GLOBAL_TOTAL_OP_PM=$(grep "^STAT_TOTAL|" "${GLOBAL_UNIQUE_RAW}_agg" | cut -d'|' -f5)

# --- CLI PRINTER BLOCK ---
{
    echo -e "\n${BOLD}Execution Params  :${NC} Mode: ${ANALYSIS_MODE_UPPER} | Top: $TOP_LIMIT | Table: ${TABLE_FILTER:-N/A} | Operation: ${OPERATION_FILTER:-ALL}"
    echo -e "${BOLD}Analyzed Timeframe:${NC} $TIMEFRAME_STR\n"

    if [[ "$ANALYSIS_MODE" =~ ^(ops|full)$ ]]; then
        # 1. Global Rates Table
        echo -e "${BLUE}${BOLD}=================================================================================================="
        echo "          GLOBAL SUMMARY - OPERATIONS OVERVIEW (TOTAL LOGGED: $GLOBAL_TOTAL_OPS | AVG OP/MIN: $GLOBAL_TOTAL_OP_PM)"
        echo -e "==================================================================================================${NC}"
        printf "${BOLD}%-12s | %-12s | %-12s | %-12s | %-12s | %-12s${NC}\n" "OPERATION" "TOTAL OPS" "% OF TOTAL" "AVG OP/MIN" "DEADLOCKS" "LOCKS"
        echo "--------------------------------------------------------------------------------------------------"
        grep "^STAT_OP|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k3 -nr | while IFS='|' read -r _ op tot pct op_pm dl lk; do
            printf "%-12s | %-12s | %-12s | %-12s | %-12s | %-12s\n" "$op" "$tot" "${pct}%" "$op_pm" "$dl" "$lk"
        done
        echo "--------------------------------------------------------------------------------------------------"
        grep "^STAT_TOTAL|" "${GLOBAL_UNIQUE_RAW}_agg" | while IFS='|' read -r _ op tot pct op_pm dl lk; do
            printf "${BOLD}%-12s | %-12s | %-12s | %-12s | %-12s | %-12s${NC}\n" "$op" "$tot" "${pct}%" "$op_pm" "$dl" "$lk"
        done
        echo -e "==================================================================================================\n"

        # 2. Time Series Table
        echo -e "${CYAN}${BOLD}=================================================================================================="
        echo "                            TIME SERIES - GROUPED BY [ $GROUPING_MODE ]"
        echo -e "==================================================================================================${NC}"
        printf "${BOLD}%-19s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s${NC}\n" "TIME BUCKET" "TOTAL" "INSERT" "UPDATE" "DELETE" "SELECT" "OTHER"
        echo "--------------------------------------------------------------------------------------------------"
        grep "^TIME_SERIES|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 | while IFS='|' read -r _ bucket tot ins upd del sel rep oth; do
            final_oth=$((rep + oth))
            printf "%-19s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s\n" "$bucket" "$tot" "$ins" "$upd" "$del" "$sel" "$final_oth"
        done
        echo -e "==================================================================================================\n"
    fi

    # 3. Deadlocks Table
    if [[ "$ANALYSIS_MODE" =~ ^(all|deadlocks|full)$ ]]; then
        total_dl=$(grep -c "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" || true)
        if (( total_dl > 0 )); then
            echo -e "${RED}${BOLD}======================================================================================================================================="
            echo "                                            GLOBAL SUMMARY - TOP $TOP_LIMIT DEADLOCKS"
            echo -e "=======================================================================================================================================${NC}"
            printf "${BOLD}%-12s | %-19s | %-11s | %s${NC}\n" "HASH" "LAST_SEEN" "Deadlocks" "QUERY TEMPLATE"
            echo "---------------------------------------------------------------------------------------------------------------------------------------"
            grep "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | head -n "$TOP_LIMIT" | while IFS='|' read -r _ occ f_s l_s q; do
                hash=$(printf "%s" "$q" | md5sum | cut -c1-12); short_q=$(echo "$q" | cut -c1-80); [[ ${#q} -gt 80 ]] && short_q+="..."
                printf "${RED}%-12s | %-19.19s | %-11.11s | %s${NC}\n" "$hash" "$l_s" "$occ" "$short_q"
            done
            echo -e "=======================================================================================================================================\n"
        fi
    fi

    # 4. Persistent Locks Table
    if [[ "$ANALYSIS_MODE" =~ ^(all|locks|full)$ ]]; then
        total_lk=$(grep -c "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" || true)
        if (( total_lk > 0 )); then
            echo -e "${YELLOW}${BOLD}======================================================================================================================================="
            echo "                                            GLOBAL SUMMARY - TOP $TOP_LIMIT PERSISTENT LOCKS"
            echo -e "=======================================================================================================================================${NC}"
            printf "${BOLD}%-12s | %-19s | %-13s | %-11s | %s${NC}\n" "HASH" "LAST_SEEN" "LockTime" "Occurrences" "QUERY TEMPLATE"
            echo "---------------------------------------------------------------------------------------------------------------------------------------"
            grep "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | head -n "$TOP_LIMIT" | while IFS='|' read -r _ t_lock occ f_s l_s q; do
                hash=$(printf "%s" "$q" | md5sum | cut -c1-12); short_q=$(echo "$q" | cut -c1-70); [[ ${#q} -gt 70 ]] && short_q+="..."
                row_color="${NC}"; if (( t_lock >= 60 )); then row_color="${YELLOW}"; fi
                printf "${row_color}%-12s | %-19.19s | %-13.13s | %-11.11s | %s${NC}\n" "$hash" "$l_s" "${t_lock}s" "$occ" "$short_q"
            done
            echo -e "=======================================================================================================================================\n"
        fi
    fi
} | out_always

# --- FILE EXPORT BLOCK ---
if [[ -n "$OUTPUT_DIR" ]]; then
    if [[ "$ANALYSIS_MODE" =~ ^(ops|full)$ ]]; then
        TS_CSV="${OUTPUT_DIR}/operations_timeseries_${ANALYSIS_MODE_UPPER}_${DATE_STR_FOR_FILE}${PARAM_STR}.csv"
        echo "TimeBucket,TotalOps,Insert,Update,Delete,Select,Replace,Other" > "$TS_CSV"
        grep "^TIME_SERIES|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 | while IFS='|' read -r _ bucket tot ins upd del sel rep oth; do
            printf "%s,%s,%s,%s,%s,%s,%s,%s\n" "$bucket" "$tot" "$ins" "$upd" "$del" "$sel" "$rep" "$oth"
        done >> "$TS_CSV"
        
        OPS_CSV="${OUTPUT_DIR}/operations_recap_${ANALYSIS_MODE_UPPER}_${DATE_STR_FOR_FILE}${PARAM_STR}.csv"
        echo "Operation,Hash,TotalOccurrences,OpPerMin,FirstSeen,LastSeen,QueryTemplate" > "$OPS_CSV"
        grep "^DATA_OP|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | while IFS='|' read -r _ occ op_pm f_s l_s q; do
            hash=$(printf "%s" "$q" | md5sum | cut -c1-12); op=$(echo "$q" | awk '{print toupper($1)}')
            printf "%s,%s,%d,%.2f,%s,%s,\"%s\"\n" "$op" "$hash" "$occ" "$op_pm" "$f_s" "$l_s" "$q"
        done >> "$OPS_CSV"
        
        { echo -e "${CYAN}${BOLD}Time Series CSV generated:${NC} $TS_CSV"; echo -e "${BLUE}${BOLD}Operations Recap CSV generated:${NC} $OPS_CSV"; } | out_always
    fi

    if [[ "$ANALYSIS_MODE" =~ ^(all|deadlocks|locks|full)$ ]]; then
        CONT_CSV="${OUTPUT_DIR}/contentions_recap_${ANALYSIS_MODE_UPPER}_${DATE_STR_FOR_FILE}${PARAM_STR}.csv"
        echo "Type,Operation,Hash,FirstSeen,LastSeen,TotalMetric,Occurrences,QueryTemplate" > "$CONT_CSV"
        grep "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | while IFS='|' read -r _ occ f_s l_s q; do
            hash=$(printf "%s" "$q" | md5sum | cut -c1-12); op=$(echo "$q" | awk '{print toupper($1)}')
            printf "DEADLOCK,%s,%s,%s,%s,%d,%d,\"%s\"\n" "$op" "$hash" "$f_s" "$l_s" "$occ" "$occ" "$q"
        done >> "$CONT_CSV"
        grep "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | while IFS='|' read -r _ t_lock occ f_s l_s q; do
            hash=$(printf "%s" "$q" | md5sum | cut -c1-12); op=$(echo "$q" | awk '{print toupper($1)}')
            printf "LOCK,%s,%s,%s,%s,%ds,%d,\"%s\"\n" "$op" "$hash" "$f_s" "$l_s" "$t_lock" "$occ" "$q"
        done >> "$CONT_CSV"
        
        { echo -e "${RED}${BOLD}Contentions Recap CSV generated:${NC} $CONT_CSV\n"; } | out_always
    fi
fi
