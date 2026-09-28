#!/usr/bin/env bash

set -euo pipefail

initialize_colors() {
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''

    if [ "$COLOR_ENABLED" = true ] && [ -t 1 ]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m'
        BOLD=$'\033[1m'
        NC=$'\033[0m'
    fi
}

# --- CONFIGURATION DEFAULTS ---
TOP_LIMIT=20
TOP_LIMIT_PROVIDED=false
TABLE_FILTER=""
AWK_TABLE_PATTERN=""
USER_FILTER=""
AWK_USER_PATTERN=""
ANALYSIS_MODE="all"
OUTPUT_DIR=""
START_DATE=""
END_DATE=""
REPORT_MODE="file"
COLOR_ENABLED=true
FILES_TO_PROCESS=()
INPUT_DIRECTORIES=()
INPUT_PATTERNS=()

error_exit() {
    printf '%sERROR:%s %s\n\n' "$RED" "$NC" "$1" >&2
    show_help >&2
    exit 2
}

# --- HELP FUNCTION (BLINDADA CON HEREDOC) ---
show_help() {
    printf '%sUsage:%s %s (--dir DIRECTORY | --file FILE [FILE ...] | --pattern PATTERN) [OPTIONS]\n\n' "$BOLD" "$NC" "$(basename "$0")"
    cat << 'EOF'
Analyze SHOW ENGINE INNODB STATUS samples for deadlocks and persistent locks.
Input sample names must strictly follow: YYYYMMDD_HH.sample

Options:
  -d, --dir DIRECTORY        Analyze valid samples in DIRECTORY.
  -f, --file FILE [FILE...]  Analyze one or more explicit sample files; repeatable.
  -p, --pattern PATTERN      Analyze files matched by PATTERN; repeatable.
  -s, --start DATE           Start at YYYY-MM-DD [HH[:MM[:SS]]].
  -e, --end DATE             End at YYYY-MM-DD [HH[:MM[:SS]]].
  -n, --top NUMBER           Maximum global-summary rows (default: 20).
  -t, --table LIST           Comma-separated table patterns.
  -u, --user PATTERN         User pattern.
  -m, --mode MODE            all, deadlocks, or locks (default: all).
  -r, --report-mode MODE     screen, file, or both (default: file).
  -o, --output-dir DIR       Destination for reports and CSV files.
      --no-color             Disable ANSI colors.
  -h, --help                 Show this help and exit.

Examples:
  innodb_status_analyzer.sh -d /var/log/mysql/innodb -m all -r both
  innodb_status_analyzer.sh -f 20260928_10.sample --mode deadlocks --no-color
EOF
}

DATE_REGEX="^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}(:[0-9]{2}(:[0-9]{2})?)?)?$"
append_input() { FILES_TO_PROCESS+=("$1"); }

collect_input_files() {
    local candidate directory pattern sorted_file filename existing duplicate
    for directory in "${INPUT_DIRECTORIES[@]}"; do
        while IFS= read -r -d '' candidate; do append_input "$candidate"; done < <(find "$directory" -maxdepth 1 -type f -print0)
    done
    for pattern in "${INPUT_PATTERNS[@]}"; do
        for candidate in $pattern; do [ -f "$candidate" ] && append_input "$candidate"; done
    done
    VALIDATED_FILES=()
    while IFS= read -r sorted_file; do
        [ -n "$sorted_file" ] || continue
        filename=$(basename "$sorted_file")
        if [[ "$filename" =~ ^[0-9]{8}_[0-9]{2}\.sample$ ]]; then
            duplicate=false
            for existing in "${VALIDATED_FILES[@]}"; do
                [ "$existing" = "$sorted_file" ] && duplicate=true && break
            done
            if [ "$duplicate" = false ]; then
                VALIDATED_FILES+=("$sorted_file")
            fi
        else
            printf '%sWARNING:%s skipped invalid sample name: %s\n' "$YELLOW" "$NC" "$filename" >&2
        fi
    done < <(printf '%s\n' "${FILES_TO_PROCESS[@]}" | LC_ALL=C sort)
    FILES_TO_PROCESS=("${VALIDATED_FILES[@]}")
}

query_hash() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | cut -c1-12
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q | cut -c1-12
    else
        error_exit 'Neither md5sum nor md5 is available in PATH.'
    fi
}

parse_arguments() {
    [ "$#" -gt 0 ] || error_exit 'An input target is required.'
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -d|--dir) [ "$#" -ge 2 ] && [ -d "$2" ] || error_exit '--dir requires an existing directory.'; INPUT_DIRECTORIES+=("$2"); shift 2 ;;
            -f|--file) shift; [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ] || error_exit '--file requires at least one file.'; while [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; do [ -f "$1" ] && append_input "$1" || printf '%sWARNING:%s missing file: %s\n' "$YELLOW" "$NC" "$1" >&2; shift; done ;;
            -p|--pattern) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || error_exit '--pattern requires a pattern.'; INPUT_PATTERNS+=("$2"); shift 2 ;;
            -s|--start) [ "$#" -ge 2 ] && [[ "$2" =~ $DATE_REGEX ]] || error_exit '--start requires YYYY-MM-DD [HH[:MM[:SS]]].'; START_DATE="$2"; shift 2 ;;
            -e|--end) [ "$#" -ge 2 ] && [[ "$2" =~ $DATE_REGEX ]] || error_exit '--end requires YYYY-MM-DD [HH[:MM[:SS]]].'; END_DATE="$2"; shift 2 ;;
            -n|--top) [ "$#" -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || error_exit '--top requires a non-negative integer.'; TOP_LIMIT="$2"; TOP_LIMIT_PROVIDED=true; shift 2 ;;
            -t|--table) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || error_exit '--table requires a value.'; TABLE_FILTER="$2"; AWK_TABLE_PATTERN=$(printf '%s' "$2" | sed 's/[[:space:]]*,[[:space:]]*/|/g; s/\./\\./g; s/\*/.*/g; s/?/./g' | tr '[:upper:]' '[:lower:]'); shift 2 ;;
            -u|--user) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || error_exit '--user requires a value.'; USER_FILTER="$2"; AWK_USER_PATTERN=$(printf '%s' "$2" | sed 's/\./\\./g; s/\*/.*/g; s/?/./g' | tr '[:upper:]' '[:lower:]'); shift 2 ;;
            -m|--mode) [ "$#" -ge 2 ] && [[ "$2" =~ ^(all|deadlocks|locks)$ ]] || error_exit '--mode must be all, deadlocks, or locks.'; ANALYSIS_MODE="$2"; shift 2 ;;
            -r|--report-mode) [ "$#" -ge 2 ] && [[ "$2" =~ ^(screen|file|both)$ ]] || error_exit '--report-mode must be screen, file, or both.'; REPORT_MODE="$2"; shift 2 ;;
            -o|--output-dir) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || error_exit '--output-dir requires a directory.'; OUTPUT_DIR="$2"; shift 2 ;;
            --no-color) COLOR_ENABLED=false; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) error_exit "Unknown option: $1" ;;
        esac
    done
    collect_input_files
    [ "${#FILES_TO_PROCESS[@]}" -gt 0 ] || error_exit 'No valid input samples were selected.'
}

initialize_colors
parse_arguments "$@"

# Preparar variables en mayúsculas (Compatible con macOS/Bash 3.2)
ANALYSIS_MODE_UPPER=$(echo "$ANALYSIS_MODE" | tr '[:lower:]' '[:upper:]')
REPORT_MODE_UPPER=$(echo "$REPORT_MODE" | tr '[:lower:]' '[:upper:]')


# --- OUTPUT ROUTING LOGIC ---
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    REPORT_FILE="${OUTPUT_DIR}/innodb_report_${ANALYSIS_MODE_UPPER}.log"
else
    REPORT_FILE="innodb_report_${ANALYSIS_MODE_UPPER}.log"
fi

if [[ "$REPORT_MODE" == "file" || "$REPORT_MODE" == "both" ]]; then
    echo -e "${YELLOW}${BOLD}[AVISO] Los detalles de la ejecución se están volcando en el fichero: ${REPORT_FILE}${NC}\n"
fi

out_always() {
    local tmp_out=$(mktemp)
    cat > "$tmp_out"
    cat "$tmp_out"
    if [[ "$REPORT_MODE" != "screen" ]]; then
        sed 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" >> "$REPORT_FILE"
    fi
    rm -f "$tmp_out"
}

out_detail() {
    local tmp_out=$(mktemp)
    cat > "$tmp_out"
    if [[ "$REPORT_MODE" == "screen" || "$REPORT_MODE" == "both" ]]; then
        cat "$tmp_out"
    fi
    if [[ "$REPORT_MODE" == "file" || "$REPORT_MODE" == "both" ]]; then
        sed 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" >> "$REPORT_FILE"
    fi
    rm -f "$tmp_out"
}

# --- DATE FILTERING LOGIC (ULTRA-FAST FILENAME PARSING) ---
FULL_START_DATE="0000-00-00 00:00:00"
FULL_END_DATE="9999-99-99 99:99:99"

if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then
    echo -e "${BLUE}Filtering files by date range...${NC}"
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

    NORM_START=$(echo "$START_DATE" | tr -d -- '- :')
    while [ ${#NORM_START} -lt 14 ]; do NORM_START="${NORM_START}0"; done
    
    NORM_END=$(echo "$END_DATE" | tr -d -- '- :')
    while [ ${#NORM_END} -lt 14 ]; do NORM_END="${NORM_END}9"; done
    
    for file in "${FILES_TO_PROCESS[@]}"; do
        filename=$(basename "$file")
        FILE_YMD=${filename:0:8}
        FILE_HR=${filename:9:2}
        NORM_FILE="${FILE_YMD}${FILE_HR}0000"
        
        if [[ "$NORM_FILE" < "$NORM_START" || "$NORM_FILE" > "$NORM_END" ]]; then continue; fi
        VALID_FILES+=("$file")
    done
    FILES_TO_PROCESS=("${VALID_FILES[@]}")
    
    if [[ ${#FILES_TO_PROCESS[@]} -eq 0 ]]; then
        echo -e "${RED}Error: No files fall within the specified date range.${NC}"
        exit 0
    fi
fi

# Build Parameters String for Filenames
PARAM_STR=""
[[ -n "$TABLE_FILTER" ]] && PARAM_STR+="tbl-$(echo "$TABLE_FILTER" | tr -s ', *?' '_')"
[[ -n "$USER_FILTER" ]] && { [[ -n "$PARAM_STR" ]] && PARAM_STR+="_"; PARAM_STR+="usr-${USER_FILTER//[*?]/_}"; }
[[ -z "$PARAM_STR" ]] && PARAM_STR="no_filters"

HAS_DATE_FILTER=false
DATE_STR_FOR_FILE=""
if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then
    HAS_DATE_FILTER=true
    S_FILE=$(echo "$START_DATE" | tr -d ':-' | tr ' ' '_')
    E_FILE=$(echo "$END_DATE" | tr -d ':-' | tr ' ' '_')
    DATE_STR_FOR_FILE="from_${S_FILE}_to_${E_FILE}_"
fi

# EXECUTION HEADER
{
    echo -e "${BLUE}${BOLD}==============================================================="
    echo "INNODB POST-MORTEM AGGREGATED REPORT (BATCH MODE)"
    echo "Files matched  : ${#FILES_TO_PROCESS[@]} file(s)"
    for f in "${FILES_TO_PROCESS[@]}"; do
        echo "  - $(basename "$f")"
    done
    echo "Analysis Mode  : [ ${ANALYSIS_MODE_UPPER} ]"
    if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then 
        echo -e "Time Filter    : [ ${START_DATE} ] to [ ${END_DATE} ]"
    fi
    if [[ -n "$TABLE_FILTER" ]]; then echo -e "Table Filter   : Active [ Pattern: \"$TABLE_FILTER\" ]"; fi
    if [[ -n "$USER_FILTER" ]]; then echo -e "User Filter    : Active [ Pattern: \"$USER_FILTER\" ]"; fi
    if [[ -n "$OUTPUT_DIR" ]]; then echo "CSV Output Dir : [ $OUTPUT_DIR ]"; fi
    echo "Report Mode    : [ ${REPORT_MODE_UPPER} ]"
    if [[ "$REPORT_MODE" != "screen" ]]; then echo "Log Append File: [ $REPORT_FILE ]"; fi
    echo "Generated      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "===============================================================${NC}"
} | out_always

# --- TEMPORARY FILES ---
TMP_RAW=$(mktemp)
TMP_DEADLOCKS=$(mktemp)
TMP_LOCKS=$(mktemp)
GLOBAL_TMP_RAW=$(mktemp)
GLOBAL_UNIQUE_RAW=$(mktemp)
GLOBAL_DETAILS_TMP=$(mktemp)
trap 'rm -f "$TMP_RAW" "$TMP_DEADLOCKS" "${TMP_DEADLOCKS}_agg" "$TMP_LOCKS" "${TMP_LOCKS}_agg" "$GLOBAL_TMP_RAW" "$GLOBAL_UNIQUE_RAW" "${GLOBAL_UNIQUE_RAW}_agg" "$GLOBAL_DETAILS_TMP"' EXIT

# Configuración del CSV Global si hay filtrado por fechas
GLOBAL_DETAILS_CSV=""
if [[ -n "$OUTPUT_DIR" && "$HAS_DATE_FILTER" == true ]]; then
    GLOBAL_DETAILS_CSV="${OUTPUT_DIR}/global_analysis_${ANALYSIS_MODE_UPPER}_${DATE_STR_FOR_FILE}${PARAM_STR}.csv"
fi

# --- INDIVIDUAL REPORT FUNCTION ---
generate_report_section() {
    local file=$1
    local is_deadlock=$2

    if [[ "$is_deadlock" == "true" ]]; then
        awk -F'|' '
        {
            ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7; count[query]++;
            if(intervals[query]=="") intervals[query]=ts; else intervals[query]=intervals[query] "," ts;
            user_key = query "\034" user;
            if (!seen_user[user_key]++) { if (users[query] == "") users[query] = user; else users[query] = users[query] ", " user; }
            host_key = query "\034" host;
            if (!seen_host[host_key]++) { if (hosts[query] == "") hosts[query] = host; else hosts[query] = hosts[query] ", " host; }
            thread_key = query "\034" thread;
            if (!seen_thread[thread_key]++) { if (threads[query] == "") threads[query] = thread; else threads[query] = threads[query] ", " thread; }
            trx_key = query "\034" trx;
            if (!seen_trx[trx_key]++) { if (trxs[query] == "") trxs[query] = trx; else trxs[query] = trxs[query] ", " trx; }
        } 
        END { for (q in count) printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", count[q], intervals[q], users[q], hosts[q], threads[q], trxs[q], q; }
        ' "$file" | sort -nr > "${file}_agg"
        
        while IFS=$'\t' read -r freq timestamps users_list hosts_list threads_list trxs_list query; do
            hash=$(query_hash "$query")
            echo -e "${RED}---------------------------------------------------------------"
            echo -e "${BOLD}[CRITICAL (DEADLOCK)] HASH: $hash | Events: $freq${NC}${RED}"
            echo -e "Query Template : $query"
            echo -e "Affected Users : $users_list"
            echo -e "Source Hosts   : $hosts_list"
            
            display_threads="$threads_list"
            num_threads=$(echo "$threads_list" | awk -F', ' '{print NF}')
            if (( num_threads > 3 )); then
                display_threads=$(echo "$threads_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}')
                display_threads="${display_threads} (+$((num_threads - 3)) more)"
            fi
            echo -e "Thread IDs     : $display_threads"
            
            display_trxs="$trxs_list"
            num_trxs=$(echo "$trxs_list" | awk -F', ' '{print NF}')
            if (( num_trxs > 3 )); then
                display_trxs=$(echo "$trxs_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}')
                display_trxs="${display_trxs} (+$((num_trxs - 3)) more)"
            fi
            echo -e "Transaction IDs: $display_trxs"
            
            IFS=',' read -ra ts_array <<< "$timestamps"; total_ts=${#ts_array[@]}
            first_ts=$(echo "${ts_array[0]}" | xargs); last_ts=$(echo "${ts_array[$((total_ts - 1))]}" | xargs)
            if (( total_ts == 1 )); then echo -e "Detected Period: [$first_ts]"
            else echo -e "Detected Period: [$first_ts] to [$last_ts]"; fi
            echo -e "${NC}"
        done < "${file}_agg"
    else
        awk -F'|' '
        function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
            split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
            split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ");
            if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
            days = 0;
            for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
            for (i = 1; i < m; i++) days += md[i];
            days += d - 1;
            return days * 86400 + h * 3600 + mn * 60 + s;
        }
        {
            ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7; count[query]++;
            user_key = query "\034" user;
            if (!seen_user[user_key]++) { if (users[query] == "") users[query] = user; else users[query] = users[query] ", " user; }
            host_key = query "\034" host;
            if (!seen_host[host_key]++) { if (hosts[query] == "") hosts[query] = host; else hosts[query] = hosts[query] ", " host; }
            thread_key = query "\034" thread;
            if (!seen_thread[thread_key]++) { if (threads[query] == "") threads[query] = thread; else threads[query] = threads[query] ", " thread; }
            trx_key = query "\034" trx;
            if (!seen_trx[trx_key]++) { if (trxs[query] == "") trxs[query] = trx; else trxs[query] = trxs[query] ", " trx; }
            
            epoch = get_epoch(ts);
            
            if(start_ts[query]=="") { start_ts[query]=ts; start_epoch[query]=epoch; last_ts[query]=ts; last_epoch[query]=epoch; }
            else {
                gap = epoch - last_epoch[query];
                if(gap<=15) { last_ts[query]=ts; last_epoch[query]=epoch; }
                else {
                    dur = last_epoch[query] - start_epoch[query]; r_str = dur "|" start_ts[query] "|" last_ts[query];
                    if(ranges[query]=="") ranges[query]=r_str; else ranges[query]=ranges[query] ";" r_str;
                    start_ts[query]=ts; start_epoch[query]=epoch; last_ts[query]=ts; last_epoch[query]=epoch;
                }
            }
        }
        END {
            for(q in count) {
                dur = last_epoch[q] - start_epoch[q]; r_str = dur "|" start_ts[q] "|" last_ts[q];
                if(ranges[q]=="") ranges[q]=r_str; else ranges[q]=ranges[q] ";" r_str;
                printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", count[q], ranges[q], users[q], hosts[q], threads[q], trxs[q], q;
            }
        }
        ' "$file" | sort -nr > "${file}_agg"
        
        while IFS=$'\t' read -r freq range_data users_list hosts_list threads_list trxs_list query; do
            hash=$(query_hash "$query")
            max_dur=$(echo "$range_data" | tr ';' '\n' | cut -d'|' -f1 | sort -nr | head -n 1)
            color="${GREEN}"; severity_label="LOW (< 30s max contention)"
            if (( max_dur >= 60 )); then color="${RED}"; severity_label="HIGH (>= 60s max contention)"
            elif (( max_dur >= 30 )); then color="${YELLOW}"; severity_label="MEDIUM (30s-60s max contention)"; fi
            echo -e "${color}---------------------------------------------------------------"
            echo -e "${BOLD}[$severity_label] HASH: $hash | Total Samples: $freq${NC}${color}"
            echo -e "Query Template : $query"
            echo -e "Affected Users : $users_list"
            echo -e "Source Hosts   : $hosts_list"
            
            display_threads="$threads_list"
            num_threads=$(echo "$threads_list" | awk -F', ' '{print NF}')
            if (( num_threads > 3 )); then
                display_threads=$(echo "$threads_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}')
                display_threads="${display_threads} (+$((num_threads - 3)) more)"
            fi
            echo -e "Thread IDs     : $display_threads"
            
            display_trxs="$trxs_list"
            num_trxs=$(echo "$trxs_list" | awk -F', ' '{print NF}')
            if (( num_trxs > 3 )); then
                display_trxs=$(echo "$trxs_list" | awk -F', ' '{for(i=1;i<=3;i++) printf "%s%s", $i, (i==3?"":", ")}')
                display_trxs="${display_trxs} (+$((num_trxs - 3)) more)"
            fi
            echo -e "Transaction IDs: $display_trxs"
            
            echo -e "Top Longest Lock Periods (Max 5):"
            top_ranges=$(echo "$range_data" | tr ';' '\n' | sort -t'|' -k1 -nr | head -n 5)
            while IFS='|' read -r dur start end; do
                if (( dur == 0 )); then echo -e "  > [${start}] (isolated snapshot, < 5s duration)"
                else echo -e "  > [${start} to ${end}] (${dur} seconds)"; fi
            done <<< "$top_ranges"
            echo -e "${NC}"
        done < "${file}_agg"
    fi
}

# --- INDIVIDUAL FILE PROCESSING ---
for current_file in "${FILES_TO_PROCESS[@]}"; do
    FILE_NAME_BASE=$(basename "$current_file")
    
    {
        echo -e "\n${BLUE}${BOLD}==============================================================="
        echo "ANALYZING FILE: $FILE_NAME_BASE"
        echo -e "===============================================================${NC}"
    } | out_detail
    
    > "$TMP_RAW"

    awk -v tbl_pat="$AWK_TABLE_PATTERN" -v usr_pat="$AWK_USER_PATTERN" -v mode="$ANALYSIS_MODE" -v awk_start="$FULL_START_DATE" -v awk_end="$FULL_END_DATE" -v file_base="$FILE_NAME_BASE" '
    function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
        split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
        split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ");
        if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
        days = 0;
        for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
        for (i = 1; i < m; i++) days += md[i];
        days += d - 1;
        return days * 86400 + h * 3600 + mn * 60 + s;
    }
    
    BEGIN { 
        in_deadlock=0; in_trans=0; is_lock=0; expect_query=0; 
        current_ts=""; deadlock_ts=""; ignore_deadlock=0;
        current_dl_user="unknown"; current_dl_host="unknown"; current_dl_thread="unknown"; current_dl_trx="unknown";
        current_lock_user="unknown"; current_lock_host="unknown"; current_lock_thread="unknown"; current_lock_trx="unknown";
        
        # Obtenemos la fecha infalible directamente del nombre del archivo (YYYYMMDD_HH.sample)
        if (match(file_base, /^[0-9]{8}_[0-9]{2}/)) {
            yr = substr(file_base, 1, 4);
            mo = substr(file_base, 5, 2);
            da = substr(file_base, 7, 2);
            hr = substr(file_base, 10, 2);
            fallback_ts = yr "-" mo "-" da " " hr ":00:00";
        } else {
            fallback_ts = "1970-01-01 00:00:00";
        }
        fallback_epoch = get_epoch(fallback_ts);
    }
    
    FNR == 1 { 
        in_deadlock = 0; in_trans = 0; deadlock_ts = ""; ignore_deadlock = 0; 
        current_ts = fallback_ts; # Iniciamos siempre con la fecha 100% segura del archivo
    }
    
    /INNODB MONITOR OUTPUT/ {
        if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            current_ts = substr($0, RSTART, RLENGTH);
        }
    }
    
    # Captura robusta del ID de transaccion para locks persistentes y deadlocks
    /TRANSACTION [0-9]+/ {
        trx = "unknown";
        for (i=1; i<=NF; i++) {
            # Búsqueda parcial para que atrape tanto "TRANSACTION" como "---TRANSACTION"
            if ($i ~ /TRANSACTION/ && $(i+1) ~ /^[0-9]+,?$/) {
                trx = $(i+1);
                sub(/,/, "", trx);
                break;
            }
        }
        if (trx != "unknown") {
            if (in_deadlock && !ignore_deadlock) current_dl_trx = trx;
            if (in_trans) current_lock_trx = trx;
        }
    }

    /^LATEST DETECTED DEADLOCK/ {
        in_deadlock=1;
        deadlock_ts=""; 
        ignore_deadlock=0;
        next;
    }
    
    # Análisis de la fecha del Deadlock detectado
    /^[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
        if (in_deadlock && deadlock_ts == "") {
            match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/);
            deadlock_ts = substr($0, RSTART, RLENGTH);
            
            dl_epoch = get_epoch(deadlock_ts);
            
            # Filtro Matemático Anti-Fantasmas: 
            # Si el deadlock es más de 2.5h (9000s) más viejo que el log que lo contiene, es un "fantasma" que InnoDB no ha purgado
            if (fallback_epoch > 0 && (fallback_epoch - dl_epoch) > 9000) {
                ignore_deadlock = 1;
            }
            
            # Filtro estricto del usuario
            if (awk_start != "0000-00-00 00:00:00" && deadlock_ts < awk_start) ignore_deadlock = 1;
            if (awk_end != "9999-99-99 99:99:99" && deadlock_ts > awk_end) ignore_deadlock = 1;
        }
    }
    
    in_deadlock && /^[A-Z ]+$/ && !/TRANSACTION|WAITING|GRANTED|RECORD/ { in_deadlock=0; ignore_deadlock=0; }
    /^TRANSACTIONS/ { in_trans=1; in_deadlock=0; ignore_deadlock=0; next; }
    in_trans && /^FILE I\/O/ { in_trans=0; next; }
    in_trans && /LOCK WAIT/ { is_lock=1; }
    
    /MySQL thread id/ {
        thread = $4; sub(/,/, "", thread);
        user = "unknown"; host = "unknown";
        for (i=1; i<=NF; i++) {
            if ($i == "query" && $(i+1) == "id") {
                if (NF >= i+4) { host = $(i+3); user = $(i+4); }
                break;
            }
        }
        if (in_deadlock && !ignore_deadlock) { current_dl_user = user; current_dl_host = host; current_dl_thread = thread; }
        if (in_trans) { current_lock_user = user; current_lock_host = host; current_lock_thread = thread; }
    }
    
    /query id/ { if ((in_deadlock && !ignore_deadlock) || is_lock) expect_query=1; next; }
    
    expect_query {
        query = $0; sub(/^[ \t]+/, "", query);
        expect_query = 0; 
        
        if (query ~ /^[Ii][Nn][Ss][Ee][Rr][Tt]|[Uu][Pp][Dd][Aa][Tt][Ee]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Ss][Ee][Ll][Ee][Cc][Tt]|[Rr][Ee][Pp][Ll][Aa][Cc][Ee]/) {
            
            if (tbl_pat != "" && tolower(query) !~ tbl_pat) { is_lock = 0; next; }
            active_user = (in_deadlock && !ignore_deadlock) ? current_dl_user : current_lock_user;
            if (usr_pat != "" && tolower(active_user) !~ usr_pat) { is_lock = 0; next; }

            template = query; 
            
            # --- MOTOR DE LIMPIEZA TOTAL ---
            gsub(/[^[:print:]]/, "", template);
            gsub(/_binary[ \t]*\047([^\047\\]|\\.)*\047/, "?", template);
            gsub(/_binary[ \t]*"([^"\\]|\\.)*"/, "?", template);
            gsub(/\047([^\047\\]|\\.)*\047/, "?", template);
            gsub(/"([^"\\]|\\.)*"/, "?", template);
            gsub(/0x[0-9a-fA-F]+/, "?", template);
            gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?)?/, "?", template);
            gsub(/\b([Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Uu][Ll][Ll])\b/, "?", template);
            
            gsub(/,/, " , ", template);
            gsub(/\(/, " ( ", template);
            gsub(/\)/, " ) ", template);
            gsub(/=/, " = ", template);
            gsub(/</, " < ", template);
            gsub(/>/, " > ", template);
            
            while (gsub(/(^|[ \t])-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?([ \t]|$)/, " ? ", template)) {}
            
            gsub(/[ \t]+,[ \t]+/, ", ", template);
            gsub(/[ \t]+\)/, ")", template);
            gsub(/\([ \t]+/, "(", template);
            gsub(/[ \t]+=[ \t]+/, " = ", template);
            gsub(/[ \t]+<[ \t]+/, " < ", template);
            gsub(/[ \t]+>[ \t]+/, " > ", template);
            gsub(/[ \t]+/, " ", template);
            
            if (in_deadlock && !ignore_deadlock && mode != "locks") {
                print "DEADLOCK|" deadlock_ts "|" current_dl_user "|" current_dl_host "|" current_dl_thread "|" current_dl_trx "|" template;
            } else if (is_lock && mode != "deadlocks") { 
                print "LOCK|" current_ts "|" current_lock_user "|" current_lock_host "|" current_lock_thread "|" current_lock_trx "|" template; 
            }
        }
        is_lock = 0; 
    }
    ' "$current_file" > "$TMP_RAW"

    cat "$TMP_RAW" >> "$GLOBAL_TMP_RAW"
    
    # --- GENERACION DE CSV CON "LIMPIEZA VISUAL" (BLANQUEANDO TEMPLATES REPETIDOS) ---
    if [[ -n "$OUTPUT_DIR" ]]; then
        if [[ "$HAS_DATE_FILTER" == true ]]; then
            while IFS='|' read -r type ts user host thread trx q; do
                hash=$(query_hash "$q")
                printf "%s,%s,%s,%s,%s,%s,%s\034%s\n" "$type" "$hash" "$ts" "$user" "$host" "$thread" "$trx" "$q"
            done < "$TMP_RAW" >> "$GLOBAL_DETAILS_TMP"
        else
            OUTPUT_CSV="${OUTPUT_DIR}/${FILE_NAME_BASE}.analysis_${ANALYSIS_MODE_UPPER}_${PARAM_STR}.csv"
            echo "Type,Hash,Timestamp,User,Host,ThreadID,TransactionID,QueryTemplate" > "$OUTPUT_CSV"
            while IFS='|' read -r type ts user host thread trx q; do
                hash=$(query_hash "$q")
                printf "%s,%s,%s,%s,%s,%s,%s\034%s\n" "$type" "$hash" "$ts" "$user" "$host" "$thread" "$trx" "$q"
            done < "$TMP_RAW" | awk -F'\034' '{
                split($1, meta, ","); hash = meta[2];
                if (!seen[hash]++) { printf "%s,\"%s\"\n", $1, $2 }
                else { printf "%s,\"\"\n", $1 }
            }' >> "$OUTPUT_CSV"
            echo -e "${GREEN}  > [CSV Output Generated]: $OUTPUT_CSV${NC}" | out_detail
        fi
    fi

    if [[ "$ANALYSIS_MODE" =~ ^(all|deadlocks)$ ]]; then
        { grep "^DEADLOCK|" "$TMP_RAW" || true; } | sort -u > "$TMP_DEADLOCKS"
        {
            echo -e "\n${RED}${BOLD}### [ DEADLOCKS - $FILE_NAME_BASE ] ###${NC}"
            if [[ -s "$TMP_DEADLOCKS" ]]; then generate_report_section "$TMP_DEADLOCKS" "true"
            else echo -e "${GREEN}No matching deadlocks detected in the active timeframe of this file.${NC}"; fi
        } | out_detail
    fi

    if [[ "$ANALYSIS_MODE" =~ ^(all|locks)$ ]]; then
        { grep "^LOCK|" "$TMP_RAW" || true; } | sort -u > "$TMP_LOCKS"
        {
            echo -e "\n${YELLOW}${BOLD}### [ LOCKS - $FILE_NAME_BASE ] ###${NC}"
            if [[ -s "$TMP_LOCKS" ]]; then generate_report_section "$TMP_LOCKS" "false"
            else echo -e "${GREEN}No matching locks detected in this file.${NC}"; fi
        } | out_detail
    fi
done

# Procesamiento final del CSV global aplicando la limpieza visual de las queries repetidas
if [[ -n "$OUTPUT_DIR" && "$HAS_DATE_FILTER" == true ]]; then
    echo "Type,Hash,Timestamp,User,Host,ThreadID,TransactionID,QueryTemplate" > "$GLOBAL_DETAILS_CSV"
    if [[ -s "$GLOBAL_DETAILS_TMP" ]]; then
        awk -F'\034' '{
            split($1, meta, ","); hash = meta[2];
            if (!seen[hash]++) { printf "%s,\"%s\"\n", $1, $2 }
            else { printf "%s,\"\"\n", $1 }
        }' "$GLOBAL_DETAILS_TMP" >> "$GLOBAL_DETAILS_CSV"
    fi
    {
        echo -e "${GREEN}\n  > [Global Details CSV Generated]: $GLOBAL_DETAILS_CSV${NC}"
    } | out_always
fi

# --- GLOBAL SUMMARY ---
if [[ ${#FILES_TO_PROCESS[@]} -gt 1 || "$HAS_DATE_FILTER" == true ]]; then
    
    sort -u "$GLOBAL_TMP_RAW" > "$GLOBAL_UNIQUE_RAW"

    if [[ ! -s "$GLOBAL_UNIQUE_RAW" ]]; then
        {
            echo -e "\n${GREEN}No contention incidents recorded matching the criteria across the analyzed files.${NC}"
        } | out_always
        exit 0
    fi

    # Nuevo Motor de Agregación Separado por Tipo
    awk -F'|' '
    function get_epoch(ts,    a, y, m, d, h, mn, s, i, days, md) {
        split(ts, a, /[- :]/); y=a[1]+0; m=a[2]+0; d=a[3]+0; h=a[4]+0; mn=a[5]+0; s=a[6]+0;
        split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ");
        if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) md[2] = 29;
        days = 0;
        for (i = 1970; i < y; i++) { days += 365; if (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) days++; }
        for (i = 1; i < m; i++) days += md[i];
        days += d - 1;
        return days * 86400 + h * 3600 + mn * 60 + s;
    }
    BEGIN { global_start="9999"; global_end="0000" }
    {
        type=$1; ts=$2; user=$3; host=$4; thread=$5; trx=$6; query=$7;
        if (ts < global_start) global_start = ts;
        if (ts > global_end) global_end = ts;
        
        # Generar clave única combinando el tipo (Deadlock/Lock) y la query
        key = type "\034" query;
        occurrences[key]++;
        
        if (first_seen[key] == "" || ts < first_seen[key]) first_seen[key] = ts;
        if (last_seen[key] == "" || ts > last_seen[key]) last_seen[key] = ts;
        
        user_key = key "\034" user;
        if (!seen_user[user_key]++) { if (users[key] == "") users[key] = user; else users[key] = users[key] ", " user; }
        
        thread_key = key "\034" thread;
        if (!seen_thread[thread_key]++) { if (threads[key] == "") threads[key] = thread; else threads[key] = threads[key] ", " thread; }
        
        trx_key = key "\034" trx;
        if (!seen_trx[trx_key]++) { if (trxs[key] == "") trxs[key] = trx; else trxs[key] = trxs[key] ", " trx; }
        
        if (type == "LOCK") {
            epoch = get_epoch(ts);
            if (start_epoch[key] == "") { start_epoch[key] = epoch; last_epoch[key] = epoch; } 
            else {
                gap = epoch - last_epoch[key];
                if (gap <= 15) { last_epoch[key] = epoch; } 
                else {
                    dur = last_epoch[key] - start_epoch[key]; total_dur[key] += dur;
                    start_epoch[key] = epoch; last_epoch[key] = epoch;
                }
            }
        }
    }
    END {
        print "TIMEFRAME|" global_start " to " global_end;
        for (k in occurrences) {
            split(k, arr, "\034"); type = arr[1]; q = arr[2];
            occ = occurrences[k];
            
            num_t = split(threads[k], t_arr, ", ");
            if (num_t > 3) {
                t_str = t_arr[1];
                for(i=2; i<=3; i++) t_str = t_str ", " t_arr[i];
                t_str = t_str " (+" (num_t - 3) " more)";
            } else { t_str = threads[k]; }
            
            num_trx = split(trxs[k], trx_arr, ", ");
            if (num_trx > 3) {
                trx_str = trx_arr[1];
                for(i=2; i<=3; i++) trx_str = trx_str ", " trx_arr[i];
                trx_str = trx_str " (+" (num_trx - 3) " more)";
            } else { trx_str = trxs[k]; }

            if (type == "DEADLOCK") {
                printf "DATA_DL|%d|%s|%s|%s|%s|%s|%s\n", occ, users[k], t_str, trx_str, first_seen[k], last_seen[k], q;
            } else if (type == "LOCK") {
                if (start_epoch[k] != "") { dur = last_epoch[k] - start_epoch[k]; total_dur[k] += dur; }
                td = total_dur[k] + 0;
                printf "DATA_LK|%d|%d|%s|%s|%s|%s|%s|%s\n", td, occ, users[k], t_str, trx_str, first_seen[k], last_seen[k], q;
            }
        }
    }' "$GLOBAL_UNIQUE_RAW" > "${GLOBAL_UNIQUE_RAW}_agg"

    TIMEFRAME_STR=$(grep "^TIMEFRAME|" "${GLOBAL_UNIQUE_RAW}_agg" | cut -d'|' -f2)
    
    # BEGIN ALWAYS OUTPUT BLOCK (Summary Tables go to Screen and Log File)
    {
        # --- TABLA 1: DEADLOCKS ---
        if [[ "$ANALYSIS_MODE" =~ ^(all|deadlocks)$ ]]; then
            total_dl=$(grep -c "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" || true)
            if (( total_dl > 0 )); then
                echo -e "\n\n${CYAN}${BOLD}======================================================================================================================================================================================================================================================================"
                echo "                                                                                                 GLOBAL SUMMARY - TOP $TOP_LIMIT DEADLOCKS"
                echo -e "======================================================================================================================================================================================================================================================================${NC}"
                echo -e "${BOLD}Execution Params  :${NC} Mode: ${ANALYSIS_MODE_UPPER} | Top: $TOP_LIMIT | Table: ${TABLE_FILTER:-N/A} | User: ${USER_FILTER:-N/A}"
                echo -e "${BOLD}Analyzed Timeframe:${NC} $TIMEFRAME_STR"
                echo -e "${BOLD}Sorting Metric    :${NC} Total Deadlock Occurrences.\n"

                printf "${BOLD}%-12s | %-19s | %-19s | %-11s | %-25s | %-32s | %-32s | %s${NC}\n" "HASH" "FIRST_SEEN" "LAST_SEEN" "Deadlocks" "USERS" "THREADS" "TRX_IDs" "QUERY TEMPLATE"
                echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

                grep "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | head -n "$TOP_LIMIT" | while IFS='|' read -r _ occ users_list threads_list trxs_list first_seen last_seen q; do
                    hash=$(query_hash "$q")
                    row_color="${RED}"

                    short_q=$(echo "$q" | cut -c1-50); [[ ${#q} -gt 50 ]] && short_q+="..."
                    short_users=$(echo "$users_list" | cut -c1-22); [[ ${#users_list} -gt 22 ]] && short_users+="..."
                    visual_threads=$(echo "$threads_list" | cut -c1-29); [[ ${#threads_list} -gt 29 ]] && visual_threads+="..."
                    visual_trxs=$(echo "$trxs_list" | cut -c1-29); [[ ${#trxs_list} -gt 29 ]] && visual_trxs+="..."

                    printf "${row_color}%-12s | %-19.19s | %-19.19s | %-11.11s | %-25.25s | %-32.32s | %-32.32s | %s${NC}\n" "$hash" "$first_seen" "$last_seen" "$occ" "$short_users" "$visual_threads" "$visual_trxs" "$short_q"
                done
                echo -e "======================================================================================================================================================================================================================================================================\n"
            elif [[ "$ANALYSIS_MODE" == "deadlocks" ]]; then
                echo -e "\n${GREEN}No deadlocks were recorded during the analyzed timeframe.${NC}\n"
            fi
        fi

        # --- TABLA 2: PERSISTENT LOCKS ---
        if [[ "$ANALYSIS_MODE" =~ ^(all|locks)$ ]]; then
            total_lk=$(grep -c "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" || true)
            if (( total_lk > 0 )); then
                echo -e "\n\n${YELLOW}${BOLD}======================================================================================================================================================================================================================================================================"
                echo "                                                                                                 GLOBAL SUMMARY - TOP $TOP_LIMIT PERSISTENT LOCKS"
                echo -e "======================================================================================================================================================================================================================================================================${NC}"
                echo -e "${BOLD}Execution Params  :${NC} Mode: ${ANALYSIS_MODE_UPPER} | Top: $TOP_LIMIT | Table: ${TABLE_FILTER:-N/A} | User: ${USER_FILTER:-N/A}"
                echo -e "${BOLD}Analyzed Timeframe:${NC} $TIMEFRAME_STR"
                echo -e "${BOLD}Sorting Metric    :${NC} Total Contention Lock Time.\n"

                printf "${BOLD}%-12s | %-19s | %-19s | %-13s | %-11s | %-25s | %-32s | %-32s | %s${NC}\n" "HASH" "FIRST_SEEN" "LAST_SEEN" "LockTime" "Occurrences" "USERS" "THREADS" "TRX_IDs" "QUERY TEMPLATE"
                echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

                grep "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | head -n "$TOP_LIMIT" | while IFS='|' read -r _ t_lock occ users_list threads_list trxs_list first_seen last_seen q; do
                    hash=$(query_hash "$q")
                    row_color="${NC}"
                    if (( t_lock >= 60 )); then row_color="${YELLOW}"; fi

                    short_q=$(echo "$q" | cut -c1-50); [[ ${#q} -gt 50 ]] && short_q+="..."
                    short_users=$(echo "$users_list" | cut -c1-22); [[ ${#users_list} -gt 22 ]] && short_users+="..."
                    visual_threads=$(echo "$threads_list" | cut -c1-29); [[ ${#threads_list} -gt 29 ]] && visual_threads+="..."
                    visual_trxs=$(echo "$trxs_list" | cut -c1-29); [[ ${#trxs_list} -gt 29 ]] && visual_trxs+="..."

                    printf "${row_color}%-12s | %-19.19s | %-19.19s | %-13.13s | %-11.11s | %-25.25s | %-32.32s | %-32.32s | %s${NC}\n" "$hash" "$first_seen" "$last_seen" "${t_lock}s" "$occ" "$short_users" "$visual_threads" "$visual_trxs" "$short_q"
                done
                echo -e "======================================================================================================================================================================================================================================================================\n"
            elif [[ "$ANALYSIS_MODE" == "locks" ]]; then
                echo -e "\n${GREEN}No persistent locks were recorded during the analyzed timeframe.${NC}\n"
            fi
        fi

        if [[ "$TOP_LIMIT_PROVIDED" == false ]]; then
            echo -e "${YELLOW}[Notice] No --top parameter provided. Defaulting the global summaries to the top $TOP_LIMIT entries.${NC}\n"
        fi
        
    } | out_always
    
    # Exportación Full Recap (Unificado pero con columna 'Type' al principio)
    if [[ -n "$OUTPUT_DIR" ]]; then
        RECAP_CSV="${OUTPUT_DIR}/full_recap_${ANALYSIS_MODE_UPPER}_${DATE_STR_FOR_FILE}${PARAM_STR}.csv"
        echo "Type,Hash,FirstSeen,LastSeen,TotalMetric,Occurrences,Users,Threads,TransactionIDs,QueryTemplate" > "$RECAP_CSV"
        
        # Añadir bloque de Deadlocks al CSV
        grep "^DATA_DL|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | while IFS='|' read -r _ occ users threads trxs f_seen l_seen q; do
            hash=$(query_hash "$q")
            printf "DEADLOCK,%s,%s,%s,%d,%d,\"%s\",\"%s\",\"%s\",\"%s\"\n" "$hash" "$f_seen" "$l_seen" "$occ" "$occ" "$users" "$threads" "$trxs" "$q"
        done >> "$RECAP_CSV"
        
        # Añadir bloque de Locks al CSV
        grep "^DATA_LK|" "${GLOBAL_UNIQUE_RAW}_agg" | sort -t'|' -k2 -nr | while IFS='|' read -r _ t_lock occ users threads trxs f_seen l_seen q; do
            hash=$(query_hash "$q")
            printf "LOCK,%s,%s,%s,%ds,%d,\"%s\",\"%s\",\"%s\",\"%s\"\n" "$hash" "$f_seen" "$l_seen" "$t_lock" "$occ" "$users" "$threads" "$trxs" "$q"
        done >> "$RECAP_CSV"
        
        {
            echo -e "${CYAN}${BOLD}Final Recap CSV generated (Full Export):${NC} $RECAP_CSV\n"
        } | out_always
    fi
fi
