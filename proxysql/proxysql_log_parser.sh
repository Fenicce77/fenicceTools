#!/usr/bin/env bash

# ==============================================================================
# ProxySQL Log Parser & Behavior Analyzer
# ==============================================================================
# Author: Antigravity AI
# Description: Parses ProxySQL log files to identify log signatures, severity
#              levels, IP addresses, MySQL servers, users, and behavior changes
#              over time (especially before and after ProxySQL version upgrades).
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# Color Definitions (ANSI Escape Sequences)
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    COLOR_RESET=$'\e[0m'
    COLOR_BOLD=$'\e[1m'
    COLOR_DIM=$'\e[2m'
    COLOR_RED=$'\e[1;31m'
    COLOR_GREEN=$'\e[1;32m'
    COLOR_YELLOW=$'\e[1;33m'
    COLOR_BLUE=$'\e[1;34m'
    COLOR_MAGENTA=$'\e[1;35m'
    COLOR_CYAN=$'\e[1;36m'
    COLOR_WHITE=$'\e[1;37m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
    COLOR_WHITE=""
fi

# ------------------------------------------------------------------------------
# Script Parameters & Defaults
# ------------------------------------------------------------------------------
LOG_FILE=""
OUTPUT_FILE=""
START_DATE=""
END_DATE=""
CSV_DIR=""
TEMP_UNCOMPRESSED_FILE=""

# ------------------------------------------------------------------------------
# Cleanup Handler for Temporary Files in /tmp
# ------------------------------------------------------------------------------
cleanup() {
    if [[ -n "${TEMP_UNCOMPRESSED_FILE}" && -f "${TEMP_UNCOMPRESSED_FILE}" ]]; then
        rm -f "${TEMP_UNCOMPRESSED_FILE}"
    fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Help Screen Display
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF

${COLOR_CYAN}${COLOR_BOLD}==============================================================================${COLOR_RESET}
${COLOR_WHITE}${COLOR_BOLD}               ProxySQL Log Parser & Behavior Analyzer                        ${COLOR_RESET}
${COLOR_CYAN}${COLOR_BOLD}==============================================================================${COLOR_RESET}

${COLOR_YELLOW}${COLOR_BOLD}DESCRIPTION:${COLOR_RESET}
  Analyzes ProxySQL log files to detect message signatures, classify events,
  track MySQL servers, client IPs, and users, and identify ProxySQL behavior
  changes or new messages over time (especially before and after upgrades).

${COLOR_YELLOW}${COLOR_BOLD}USAGE:${COLOR_RESET}
  ${COLOR_GREEN}$0${COLOR_RESET} ${COLOR_BOLD}-f <log_file> -o <report_file> [OPTIONS]${COLOR_RESET}

${COLOR_YELLOW}${COLOR_BOLD}REQUIRED PARAMETERS:${COLOR_RESET}
  ${COLOR_GREEN}-f, --file <file>${COLOR_RESET}       Path to ProxySQL log file (plain text or compressed: .gz, .bz2, .xz, .zst)
  ${COLOR_GREEN}-o, --output <file>${COLOR_RESET}     Path where the plain text summary report will be saved

${COLOR_YELLOW}${COLOR_BOLD}OPTIONAL PARAMETERS:${COLOR_RESET}
  ${COLOR_GREEN}-s, --start-date <date>${COLOR_RESET} Filter logs starting from date/time (Format: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS")
  ${COLOR_GREEN}-e, --end-date <date>${COLOR_RESET}   Filter logs up to date/time (Format: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS")
  ${COLOR_GREEN}-c, --csv-dir <dir>${COLOR_RESET}     Directory to write CSV reports (defaults to output file directory)
  ${COLOR_GREEN}-h, --help${COLOR_RESET}             Show this friendly colored help banner and exit

${COLOR_YELLOW}${COLOR_BOLD}EXAMPLES:${COLOR_RESET}
  ${COLOR_DIM}# Analyze full log file and write report:${COLOR_RESET}
  ${COLOR_GREEN}$0 -f /var/log/proxysql.log -o /tmp/proxysql_report.txt${COLOR_RESET}

  ${COLOR_DIM}# Analyze compressed log within a date range:${COLOR_RESET}
  ${COLOR_GREEN}$0 -f /var/log/proxysql.log.gz -s "2026-08-01" -e "2026-08-10 23:59:59" -o ./report.txt -c ./csv_out${COLOR_RESET}

${COLOR_CYAN}${COLOR_BOLD}==============================================================================${COLOR_RESET}

EOF
}

# ------------------------------------------------------------------------------
# Error Handler
# ------------------------------------------------------------------------------
show_error() {
    local message="$1"
    echo -e "${COLOR_RED}${COLOR_BOLD}ERROR:${COLOR_RESET} ${COLOR_WHITE}${message}${COLOR_RESET}\n" >&2
    show_help
    exit 1
}

# ------------------------------------------------------------------------------
# Parse CLI Options
# ------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    show_error "No arguments provided."
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            if [[ -n "$2" && "$2" != -* ]]; then
                LOG_FILE="$2"
                shift 2
            else
                show_error "Option '$1' requires a valid file path argument."
            fi
            ;;
        -o|--output)
            if [[ -n "$2" && "$2" != -* ]]; then
                OUTPUT_FILE="$2"
                shift 2
            else
                show_error "Option '$1' requires an output file path argument."
            fi
            ;;
        -s|--start-date)
            if [[ -n "$2" && "$2" != -* ]]; then
                START_DATE="$2"
                shift 2
            else
                show_error "Option '$1' requires a date/time string argument."
            fi
            ;;
        -e|--end-date)
            if [[ -n "$2" && "$2" != -* ]]; then
                END_DATE="$2"
                shift 2
            else
                show_error "Option '$1' requires a date/time string argument."
            fi
            ;;
        -c|--csv-dir)
            if [[ -n "$2" && "$2" != -* ]]; then
                CSV_DIR="$2"
                shift 2
            else
                show_error "Option '$1' requires a directory path argument."
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            show_error "Unknown option or invalid parameter '$1'."
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Validate Required Inputs
# ------------------------------------------------------------------------------
if [[ -z "${LOG_FILE}" ]]; then
    show_error "Missing required parameter: -f / --file <log_file>"
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
    show_error "Missing required parameter: -o / --output <report_file>"
fi

if [[ ! -f "${LOG_FILE}" ]]; then
    show_error "Input log file does not exist: '${LOG_FILE}'"
fi

# Ensure parent directory of output file exists or can be created
OUTPUT_DIR=$(dirname "${OUTPUT_FILE}")
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}" || show_error "Cannot create output directory: '${OUTPUT_DIR}'"
fi

if [[ -z "${CSV_DIR}" ]]; then
    CSV_DIR="${OUTPUT_DIR}"
fi
if [[ ! -d "${CSV_DIR}" ]]; then
    mkdir -p "${CSV_DIR}" || show_error "Cannot create CSV directory: '${CSV_DIR}'"
fi

# ------------------------------------------------------------------------------
# Handle Compressed Files (Uncompress temporarily to /tmp)
# ------------------------------------------------------------------------------
TARGET_ANALYSIS_FILE="${LOG_FILE}"

check_compressed_and_extract() {
    local file="$1"
    local mime_type=""
    mime_type=$(file --brief --mime-type "${file}" 2>/dev/null || echo "unknown")

    local needs_decompress=0
    local decompress_cmd=""

    if [[ "${file}" =~ \.gz$ || "${file}" =~ \.tgz$ || "${mime_type}" == "application/gzip" || "${mime_type}" == "application/x-gzip" ]]; then
        needs_decompress=1
        decompress_cmd="gzip -dc"
    elif [[ "${file}" =~ \.bz2$ || "${mime_type}" == "application/x-bzip2" ]]; then
        needs_decompress=1
        decompress_cmd="bzip2 -dc"
    elif [[ "${file}" =~ \.xz$ || "${mime_type}" == "application/x-xz" ]]; then
        needs_decompress=1
        decompress_cmd="xz -dc"
    elif [[ "${file}" =~ \.zst$ || "${mime_type}" == "application/zstd" || "${mime_type}" == "application/x-zstd" ]]; then
        needs_decompress=1
        decompress_cmd="zstd -dc"
    fi

    if [[ ${needs_decompress} -eq 1 ]]; then
        echo -e "${COLOR_YELLOW}[*] Log file '${file}' is compressed.${COLOR_RESET}"
        echo -e "${COLOR_CYAN}[*] Decompressing temporarily to /tmp directory...${COLOR_RESET}"
        TEMP_UNCOMPRESSED_FILE=$(mktemp "${TMPDIR:-/tmp}/proxysql_parse_XXXXXX.log" 2>/dev/null || mktemp /tmp/proxysql_parse_XXXXXX.log)
        
        if ! ${decompress_cmd} "${file}" > "${TEMP_UNCOMPRESSED_FILE}"; then
            show_error "Failed to decompress file '${file}' into /tmp directory."
        fi
        TARGET_ANALYSIS_FILE="${TEMP_UNCOMPRESSED_FILE}"
        echo -e "${COLOR_GREEN}[+] Decompressed successfully: ${TARGET_ANALYSIS_FILE}${COLOR_RESET}"
    fi
}

check_compressed_and_extract "${LOG_FILE}"

# Normalize dates for comparison (AWK string comparison YYYY-MM-DD HH:MM:SS)
NORM_START_DATE="${START_DATE}"
if [[ -n "${NORM_START_DATE}" && "${NORM_START_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    NORM_START_DATE="${NORM_START_DATE} 00:00:00"
fi

NORM_END_DATE="${END_DATE}"
if [[ -n "${NORM_END_DATE}" && "${NORM_END_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    NORM_END_DATE="${NORM_END_DATE} 23:59:59"
fi

echo -e "${COLOR_BLUE}${COLOR_BOLD}[*] Starting ProxySQL Log Analysis...${COLOR_RESET}"
if [[ -n "${START_DATE}" || -n "${END_DATE}" ]]; then
    echo -e "${COLOR_DIM}    Date filter: From '${NORM_START_DATE:-BEGINNING}' to '${NORM_END_DATE:-END}'${COLOR_RESET}"
fi

# ------------------------------------------------------------------------------
# Core Parsing Engine (AWK Script)
# ------------------------------------------------------------------------------
# Performs single-pass processing:
# 1. Date extraction & date range filtering
# 2. ProxySQL version upgrade detection
# 3. Log level severity classification
# 4. IP, MySQL Server, and User extraction
# 5. Message signature generation (normalizing dynamic tokens)
# 6. Timeline analysis (first seen, last seen, novel signature tracking)
# ------------------------------------------------------------------------------

AWK_SCRIPT=$(cat << 'EOF_AWK'
BEGIN {
    total_lines = 0;
    matched_lines = 0;
    upgrade_count = 0;
    latest_upgrade_idx = 0;
    in_table = 0;
    hostname_col = 0;
    port_col = 0;
    username_col = 0;
}

{
    total_lines++;
    line = $0;

    # Skip empty lines
    if (line ~ /^[ \t]*$/) {
        next;
    }

    # 1. Extract Timestamp (Formats: YYYY-MM-DD HH:MM:SS or YYYY-MM-DDTHH:MM:SS)
    # NOTE: timestamp is NOT reset here; continuation lines (stack traces, etc.)
    # inherit the parent log entry's timestamp for correct date-range filtering.
    is_new_log = 0;
    if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        timestamp = substr(line, RSTART, RLENGTH);
        gsub(/T/, " ", timestamp);
        is_new_log = 1;
        in_table = 0; # Reset table context on new timestamped log line
    }

    # If in table mode, parse or skip borders/rows
    if (in_table == 1) {
        if (line ~ /^[ \t]*\+[-+ \t]+\+$/) {
            next; # Skip table border/separator lines
        }
        if (line ~ /^[ \t]*\|.*\|[ \t]*$/) {
            num_fields = split(line, parts, "|");
            for (i = 1; i <= num_fields; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", parts[i]);
            }
            # Detect header column indices if not done yet
            if (hostname_col == 0 && port_col == 0 && username_col == 0) {
                for (i = 1; i <= num_fields; i++) {
                    val = tolower(parts[i]);
                    if (val == "hostname" || val == "host" || val == "address") {
                        hostname_col = i;
                    } else if (val == "port") {
                        port_col = i;
                    } else if (val == "username" || val == "user") {
                        username_col = i;
                    }
                }
                next; # Skip header row from further parsing/signatures
            }
            
            # If columns are detected, extract values
            if (hostname_col > 0 && port_col > 0) {
                host = parts[hostname_col];
                port = parts[port_col];
                if (host != "" && host !~ /^[ \t]*$/ && port ~ /^[0-9]+$/ && port > 0) {
                    servers[host ":" port]++;
                    # If host is an IP, also add to ips list
                    if (host ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                        split(host, octets, ".");
                        if (octets[1] <= 255 && octets[2] <= 255 && octets[3] <= 255 && octets[4] <= 255) {
                            ips[host]++;
                        }
                    }
                }
            }
            if (username_col > 0) {
                usr = parts[username_col];
                if (usr != "" && usr !~ /^[ \t]*$/ && usr != "NULL") {
                    users[usr]++;
                }
            }
            next; # Skip table data rows from being treated as log entry signatures
        }
    }

    # Date Range Filter
    if (start_date != "" && timestamp != "" && timestamp < start_date) {
        next;
    }
    if (end_date != "" && timestamp != "" && timestamp > end_date) {
        next;
    }

    matched_lines++;

    if (min_timestamp == "" || (timestamp != "" && timestamp < min_timestamp)) {
        min_timestamp = timestamp;
    }
    if (max_timestamp == "" || (timestamp != "" && timestamp > max_timestamp)) {
        max_timestamp = timestamp;
    }

    # 2. Check for ProxySQL Upgrade / Restart events
    if (line ~ /ProxySQL version [0-9.]+/ || line ~ /Starting ProxySQL/ || line ~ /ProxySQL.*started/) {
        upgrade_count++;
        upgrades[upgrade_count] = (timestamp != "" ? timestamp : "Unknown-Time") " | " line;
        latest_upgrade_idx = upgrade_count;
    }

    # Check for Dumping tables to set table context
    if (line ~ /Dumping [a-zA-Z0-9_]+/) {
        in_table = 1;
        hostname_col = 0;
        port_col = 0;
        username_col = 0;
    }

    # 3. Classify Log Level / Severity
    level = "INFO";
    if (line ~ /\[ERROR\]|\[FATAL\]|\[CRITICAL\]|\bERROR\b|\bFATAL\b|\bCRITICAL\b/) {
        level = "ERROR";
    } else if (line ~ /\[WARNING\]|\[WARN\]|\bWARNING\b|\bWARN\b/) {
        level = "WARNING";
    } else if (line ~ /\[DEBUG\]|\bDEBUG\b/) {
        level = "DEBUG";
    } else if (line ~ /\[INFO\]|\bINFO\b/) {
        level = "INFO";
    }
    level_counts[level]++;

    # Create a payload copy without the leading timestamp for entity extraction
    payload = line;
    gsub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/, "", payload);

    # 4. Entity Extraction
    # Extract MySQL Backend Servers (IP:Port or Host:Port e.g., 10.0.0.5:3306 or db1:3306)
    tmp_line = payload;
    while (match(tmp_line, /([a-zA-Z0-9_.-]+:[0-9]{2,5})/)) {
        srv = substr(tmp_line, RSTART, RLENGTH);
        # Exclude source file lines (e.g. Session.cpp:123), timestamps, common prefixes, or invalid ports
        if (srv !~ /\.(cpp|c|h|hpp):/ && srv !~ /^[0-9]{2,4}:[0-9]{2}$/ && srv !~ /^(Error|Warning|Note|Level|Status):/) {
            servers[srv]++;
        }
        tmp_line = substr(tmp_line, RSTART + RLENGTH);
    }

    # Extract IP Addresses (IPv4)
    tmp_line = payload;
    while (match(tmp_line, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
        ip = substr(tmp_line, RSTART, RLENGTH);
        # Filter valid IPv4 octets and ignore date prefixes
        split(ip, octets, ".");
        if (octets[1] <= 255 && octets[2] <= 255 && octets[3] <= 255 && octets[4] <= 255) {
            ips[ip]++;
        }
        tmp_line = substr(tmp_line, RSTART + RLENGTH);
    }

    # Extract MySQL Users (e.g. 'user'@'host', user 'app_user', User 'admin_user', User app_user)
    tmp_line = payload;
    while (match(tmp_line, /[uU]ser '[a-zA-Z0-9_.-]+'|[uU]ser [a-zA-Z0-9_.-]+|'[a-zA-Z0-9_.-]+'@/)) {
        m = substr(tmp_line, RSTART, RLENGTH);
        gsub(/['@]|[uU]ser /, "", m);
        if (m != "" && m != "YES" && m != "NO" && m != "NULL") {
            users[m]++;
        }
        tmp_line = substr(tmp_line, RSTART + RLENGTH);
    }

    # 5. Signature Generation (Template Abstraction)
    sig = line;

    # Normalize timestamp
    gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/, "<TIMESTAMP>", sig);

    # Normalize file & line numbers (e.g. MySQL_Session.cpp:123:handler():)
    gsub(/[a-zA-Z0-9_.-]+\.(cpp|c|h|hpp):[0-9]+:[a-zA-Z0-9_():]*/, "<SOURCE_CODE>", sig);
    gsub(/[a-zA-Z0-9_.-]+\.(cpp|c|h|hpp):[0-9]+/, "<FILE:LINE>", sig);

    # Normalize IP addresses and ports
    gsub(/([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+/, "<IP>:<PORT>", sig);
    gsub(/([0-9]{1,3}\.){3}[0-9]{1,3}/, "<IP>", sig);

    # Normalize Hex memory addresses / hashes
    gsub(/0x[0-9a-fA-F]+/, "<HEX>", sig);

    # Normalize quoted user strings / credentials
    gsub(/'[a-zA-Z0-9_.-]+'@'[a-zA-Z0-9_.-]+'/, "'<USER>'@'<HOST>'", sig);
    gsub(/'[a-zA-Z0-9_.-]+'/, "'<USER>'", sig);

    # Normalize remaining integers
    gsub(/[0-9]+/, "<INT>", sig);

    # Clean whitespace
    gsub(/[ \t]+/, " ", sig);

    # Track Signatures & Behavior Timeline
    sig_counts[sig]++;
    sig_level[sig] = level;

    if (sig_first_seen[sig] == "") {
        sig_first_seen[sig] = timestamp != "" ? timestamp : "Unknown";
        sig_after_upgrade[sig] = latest_upgrade_idx; # Tracks if signature appeared after upgrade N
    }
    sig_last_seen[sig] = timestamp != "" ? timestamp : "Unknown";
}

END {
    print "=== SUMMARY_START ===";
    print "TotalLines=" total_lines;
    print "MatchedLines=" matched_lines;
    print "MinTimestamp=" (min_timestamp != "" ? min_timestamp : "N/A");
    print "MaxTimestamp=" (max_timestamp != "" ? max_timestamp : "N/A");
    print "UpgradeCount=" upgrade_count;
    print "=== SUMMARY_END ===";

    print "=== UPGRADES_START ===";
    for (i = 1; i <= upgrade_count; i++) {
        print upgrades[i];
    }
    print "=== UPGRADES_END ===";

    print "=== LEVELS_START ===";
    for (lvl in level_counts) {
        print lvl "=" level_counts[lvl];
    }
    print "=== LEVELS_END ===";

    print "=== IPS_START ===";
    for (ip in ips) {
        print ips[ip] "\t" ip;
    }
    print "=== IPS_END ===";

    print "=== SERVERS_START ===";
    for (srv in servers) {
        print servers[srv] "\t" srv;
    }
    print "=== SERVERS_END ===";

    print "=== USERS_START ===";
    for (u in users) {
        print users[u] "\t" u;
    }
    print "=== USERS_END ===";

    print "=== SIGNATURES_START ===";
    for (sig in sig_counts) {
        print sig_counts[sig] "\t" sig_level[sig] "\t" sig_first_seen[sig] "\t" sig_last_seen[sig] "\t" sig_after_upgrade[sig] "\t" sig;
    }
    print "=== SIGNATURES_END ===";
}
EOF_AWK
)

# Run AWK script against log file
RAW_RESULTS=$(awk -v start_date="${NORM_START_DATE}" -v end_date="${NORM_END_DATE}" "${AWK_SCRIPT}" "${TARGET_ANALYSIS_FILE}")

# ------------------------------------------------------------------------------
# Process & Sectionize Analysis Output
# ------------------------------------------------------------------------------

# Extract Summary Variables
TOTAL_LINES=$(printf '%s\n' "${RAW_RESULTS}" | grep "^TotalLines=" | cut -d= -f2 || echo "0")
MATCHED_LINES=$(printf '%s\n' "${RAW_RESULTS}" | grep "^MatchedLines=" | cut -d= -f2 || echo "0")
MIN_TIMESTAMP=$(printf '%s\n' "${RAW_RESULTS}" | grep "^MinTimestamp=" | cut -d= -f2 || echo "N/A")
MAX_TIMESTAMP=$(printf '%s\n' "${RAW_RESULTS}" | grep "^MaxTimestamp=" | cut -d= -f2 || echo "N/A")
UPGRADE_COUNT=$(printf '%s\n' "${RAW_RESULTS}" | grep "^UpgradeCount=" | cut -d= -f2 || echo "0")

# Extract Sections
UPGRADES_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== UPGRADES_START ===/,/=== UPGRADES_END ===/p' | grep -v '===' || true)
LEVELS_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== LEVELS_START ===/,/=== LEVELS_END ===/p' | grep -v '===' || true)
IPS_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== IPS_START ===/,/=== IPS_END ===/p' | grep -v '===' | sort -rn -k1,1 | head -n 15 || true)
SERVERS_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== SERVERS_START ===/,/=== SERVERS_END ===/p' | grep -v '===' | sort -rn -k1,1 | head -n 15 || true)
USERS_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== USERS_START ===/,/=== USERS_END ===/p' | grep -v '===' | sort -rn -k1,1 | head -n 15 || true)

SIGNATURES_SECTION=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== SIGNATURES_START ===/,/=== SIGNATURES_END ===/p' | grep -v '===' || true)

# ------------------------------------------------------------------------------
# Write Plain Text Output Report File
# ------------------------------------------------------------------------------
{
    echo "==============================================================================="
    echo "                      ProxySQL Log Analysis Report                             "
    echo "==============================================================================="
    echo "Log File Analyzed : ${LOG_FILE}"
    echo "Report Generated  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Total Log Lines   : ${TOTAL_LINES}"
    echo "Matched Log Lines : ${MATCHED_LINES}"
    echo "Log Time Range    : ${MIN_TIMESTAMP}  -->  ${MAX_TIMESTAMP}"
    echo "Upgrades/Restarts : ${UPGRADE_COUNT}"
    echo "==============================================================================="
    echo ""

    if [[ -n "${UPGRADES_SECTION}" ]]; then
        echo "-------------------------------------------------------------------------------"
        echo "ProxySQL Version Upgrades & Restarts Detected"
        echo "-------------------------------------------------------------------------------"
        printf '%s\n' "${UPGRADES_SECTION}"
        echo ""
    fi

    echo "-------------------------------------------------------------------------------"
    echo "Log Message Severity Level Distribution"
    echo "-------------------------------------------------------------------------------"
    if [[ -n "${LEVELS_SECTION}" ]]; then
        printf '%s\n' "${LEVELS_SECTION}"
    else
        echo "No log levels categorized."
    fi
    echo ""

    echo "-------------------------------------------------------------------------------"
    echo "Top Client IP Addresses"
    echo "-------------------------------------------------------------------------------"
    printf "%-10s %s\n" "COUNT" "IP ADDRESS"
    printf "%-10s %s\n" "-----" "----------"
    if [[ -n "${IPS_SECTION}" ]]; then
        printf '%s\n' "${IPS_SECTION}" | awk '{printf "%-10s %s\n", $1, $2}'
    else
        echo "No IP addresses extracted."
    fi
    echo ""

    echo "-------------------------------------------------------------------------------"
    echo "Top MySQL Backend Servers"
    echo "-------------------------------------------------------------------------------"
    printf "%-10s %s\n" "COUNT" "MYSQL SERVER (HOST:PORT)"
    printf "%-10s %s\n" "-----" "------------------------"
    if [[ -n "${SERVERS_SECTION}" ]]; then
        printf '%s\n' "${SERVERS_SECTION}" | awk '{printf "%-10s %s\n", $1, $2}'
    else
        echo "No MySQL servers extracted."
    fi
    echo ""

    echo "-------------------------------------------------------------------------------"
    echo "Top MySQL Users"
    echo "-------------------------------------------------------------------------------"
    printf "%-10s %s\n" "COUNT" "USER NAME"
    printf "%-10s %s\n" "-----" "---------"
    if [[ -n "${USERS_SECTION}" ]]; then
        printf '%s\n' "${USERS_SECTION}" | awk '{printf "%-10s %s\n", $1, $2}'
    else
        echo "No users extracted."
    fi
    echo ""

    echo "-------------------------------------------------------------------------------"
    echo "Top Log Message Signatures (Frequency)"
    echo "-------------------------------------------------------------------------------"
    printf "%-8s %-8s %-20s %-20s %s\n" "COUNT" "LEVEL" "FIRST SEEN" "LAST SEEN" "SIGNATURE TEMPLATE"
    printf "%-8s %-8s %-20s %-20s %s\n" "-----" "-----" "----------" "---------" "------------------"
    if [[ -n "${SIGNATURES_SECTION}" ]]; then
        printf '%s\n' "${SIGNATURES_SECTION}" | sort -rn -k1,1 | head -n 25 | awk -F'\t' '{printf "%-8s %-8s %-20s %-20s %s\n", $1, $2, $3, $4, $6}'
    else
        echo "No signatures generated."
    fi
    echo ""

    echo "-------------------------------------------------------------------------------"
    echo "New Signatures / Behavior Changes Introduced (Post Upgrade or Timeline)"
    echo "-------------------------------------------------------------------------------"
    NEW_SIGS=$(printf '%s\n' "${SIGNATURES_SECTION}" | awk -F'\t' '$5 > 0' | sort -rn -k1,1)
    if [[ -n "${NEW_SIGS}" ]]; then
        printf "%-8s %-8s %-20s %-15s %s\n" "COUNT" "LEVEL" "FIRST SEEN" "AFTER UPGRADE" "SIGNATURE TEMPLATE"
        printf "%-8s %-8s %-20s %-15s %s\n" "-----" "-----" "----------" "-------------" "------------------"
        printf '%s\n' "${NEW_SIGS}" | awk -F'\t' '{printf "%-8s %-8s %-20s Upgrade #%-6s %s\n", $1, $2, $3, $5, $6}'
    else
        echo "No new log signatures detected strictly post-upgrade."
    fi
    echo ""
    echo "==============================================================================="
    echo "End of ProxySQL Log Report"
    echo "==============================================================================="
} > "${OUTPUT_FILE}"

# ------------------------------------------------------------------------------
# Export 5 CSV Reports to $CSV_DIR
# ------------------------------------------------------------------------------
echo -e "${COLOR_CYAN}[*] Exporting CSV reports to '${CSV_DIR}'...${COLOR_RESET}"

# 1. proxysql_signatures.csv
{
    echo "Count,Level,FirstSeen,LastSeen,AfterUpgradeIndex,SignatureTemplate"
    if [[ -n "${SIGNATURES_SECTION}" ]]; then
        printf '%s\n' "${SIGNATURES_SECTION}" | sort -rn -k1,1 -t$'\t' | awk -F'\t' '{
            count = $1;
            level = $2;
            first_seen = $3;
            last_seen = $4;
            after_upgrade = ($5 != "" ? $5 : 0);
            sig = $6;
            gsub(/"/, "\"\"", sig);
            printf "%s,%s,%s,%s,%s,\"%s\"\n", count, level, first_seen, last_seen, after_upgrade, sig;
        }'
    fi
} > "${CSV_DIR}/proxysql_signatures.csv"

# 2. proxysql_post_upgrade_changes.csv
{
    echo "Count,Level,FirstSeen,AfterUpgradeIndex,SignatureTemplate"
    if [[ -n "${SIGNATURES_SECTION}" ]]; then
        printf '%s\n' "${SIGNATURES_SECTION}" | awk -F'\t' '$5 > 0' | sort -rn -k1,1 -t$'\t' | awk -F'\t' '{
            count = $1;
            level = $2;
            first_seen = $3;
            after_upgrade = $5;
            sig = $6;
            gsub(/"/, "\"\"", sig);
            printf "%s,%s,%s,%s,\"%s\"\n", count, level, first_seen, after_upgrade, sig;
        }'
    fi
} > "${CSV_DIR}/proxysql_post_upgrade_changes.csv"

# 3. proxysql_ips.csv
ALL_IPS=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== IPS_START ===/,/=== IPS_END ===/p' | grep -v '===' || true)
{
    echo "Count,IPAddress"
    if [[ -n "${ALL_IPS}" ]]; then
        printf '%s\n' "${ALL_IPS}" | sort -rn -k1,1 -t$'\t' | awk -F'\t' '{
            printf "%s,%s\n", $1, $2;
        }'
    fi
} > "${CSV_DIR}/proxysql_ips.csv"

# 4. proxysql_servers.csv
ALL_SERVERS=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== SERVERS_START ===/,/=== SERVERS_END ===/p' | grep -v '===' || true)
{
    echo "Count,MySQLServer"
    if [[ -n "${ALL_SERVERS}" ]]; then
        printf '%s\n' "${ALL_SERVERS}" | sort -rn -k1,1 -t$'\t' | awk -F'\t' '{
            printf "%s,%s\n", $1, $2;
        }'
    fi
} > "${CSV_DIR}/proxysql_servers.csv"

# 5. proxysql_users.csv
ALL_USERS=$(printf '%s\n' "${RAW_RESULTS}" | sed -n '/=== USERS_START ===/,/=== USERS_END ===/p' | grep -v '===' || true)
{
    echo "Count,UserName"
    if [[ -n "${ALL_USERS}" ]]; then
        printf '%s\n' "${ALL_USERS}" | sort -rn -k1,1 -t$'\t' | awk -F'\t' '{
            printf "%s,%s\n", $1, $2;
        }'
    fi
} > "${CSV_DIR}/proxysql_users.csv"

# ------------------------------------------------------------------------------
# Print Friendly Colored Terminal Output
# ------------------------------------------------------------------------------

echo -e "\n${COLOR_CYAN}${COLOR_BOLD}==============================================================================${COLOR_RESET}"
echo -e "${COLOR_WHITE}${COLOR_BOLD}                      ProxySQL Log Analysis Summary                           ${COLOR_RESET}"
echo -e "${COLOR_CYAN}${COLOR_BOLD}==============================================================================${COLOR_RESET}"

echo -e "${COLOR_YELLOW}${COLOR_BOLD}Log File:${COLOR_RESET}        ${COLOR_WHITE}${LOG_FILE}${COLOR_RESET}"
echo -e "${COLOR_YELLOW}${COLOR_BOLD}Total Lines:${COLOR_RESET}     ${COLOR_WHITE}${TOTAL_LINES}${COLOR_RESET} (Matched Range: ${COLOR_GREEN}${MATCHED_LINES}${COLOR_RESET})"
echo -e "${COLOR_YELLOW}${COLOR_BOLD}Time Range:${COLOR_RESET}      ${COLOR_CYAN}${MIN_TIMESTAMP}${COLOR_RESET} --> ${COLOR_CYAN}${MAX_TIMESTAMP}${COLOR_RESET}"
echo -e "${COLOR_YELLOW}${COLOR_BOLD}Upgrades/Restarts:${COLOR_RESET} ${COLOR_MAGENTA}${UPGRADE_COUNT}${COLOR_RESET}"

if [[ -n "${UPGRADES_SECTION}" ]]; then
    echo -e "\n${COLOR_MAGENTA}${COLOR_BOLD}[!] ProxySQL Version Upgrades & Restarts Event Log:${COLOR_RESET}"
    printf '%s\n' "${UPGRADES_SECTION}" | while read -r line; do
        echo -e "  ${COLOR_MAGENTA}➜${COLOR_RESET} ${COLOR_WHITE}${line}${COLOR_RESET}"
    done
fi

echo -e "\n${COLOR_BLUE}${COLOR_BOLD}[+] Severity Level Breakdown:${COLOR_RESET}"
if [[ -n "${LEVELS_SECTION}" ]]; then
    printf '%s\n' "${LEVELS_SECTION}" | while read -r line; do
        lvl=$(echo "$line" | cut -d= -f1)
        cnt=$(echo "$line" | cut -d= -f2)
        case "$lvl" in
            ERROR)   color="${COLOR_RED}" ;;
            WARNING) color="${COLOR_YELLOW}" ;;
            INFO)    color="${COLOR_GREEN}" ;;
            DEBUG)   color="${COLOR_DIM}" ;;
            *)       color="${COLOR_WHITE}" ;;
        esac
        echo -e "  ${color}■ ${lvl}:${COLOR_RESET} ${COLOR_WHITE}${cnt}${COLOR_RESET}"
    done
fi

echo -e "\n${COLOR_CYAN}${COLOR_BOLD}[+] Top Client IP Addresses:${COLOR_RESET}"
if [[ -n "${IPS_SECTION}" ]]; then
    printf '%s\n' "${IPS_SECTION}" | head -n 5 | while read -r cnt ip; do
        printf "  ${COLOR_GREEN}%-8s${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" "${cnt}" "${ip}"
    done
else
    echo -e "  ${COLOR_DIM}None detected${COLOR_RESET}"
fi

echo -e "\n${COLOR_CYAN}${COLOR_BOLD}[+] Top MySQL Backend Servers:${COLOR_RESET}"
if [[ -n "${SERVERS_SECTION}" ]]; then
    printf '%s\n' "${SERVERS_SECTION}" | head -n 5 | while read -r cnt srv; do
        printf "  ${COLOR_GREEN}%-8s${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" "${cnt}" "${srv}"
    done
else
    echo -e "  ${COLOR_DIM}None detected${COLOR_RESET}"
fi

echo -e "\n${COLOR_CYAN}${COLOR_BOLD}[+] Top Database Users:${COLOR_RESET}"
if [[ -n "${USERS_SECTION}" ]]; then
    printf '%s\n' "${USERS_SECTION}" | head -n 5 | while read -r cnt usr; do
        printf "  ${COLOR_GREEN}%-8s${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" "${cnt}" "${usr}"
    done
else
    echo -e "  ${COLOR_DIM}None detected${COLOR_RESET}"
fi

echo -e "\n${COLOR_YELLOW}${COLOR_BOLD}[★] Top Log Signatures (Frequency):${COLOR_RESET}"
printf "  ${COLOR_DIM}%-8s %-8s %-20s %s${COLOR_RESET}\n" "COUNT" "LEVEL" "FIRST SEEN" "SIGNATURE TEMPLATE"
printf "  ${COLOR_DIM}%-8s %-8s %-20s %s${COLOR_RESET}\n" "-----" "-----" "----------" "------------------"
if [[ -n "${SIGNATURES_SECTION}" ]]; then
    printf '%s\n' "${SIGNATURES_SECTION}" | sort -rn -k1,1 | head -n 8 | while IFS=$'\t' read -r cnt lvl fseen lseen upg sig; do
        case "$lvl" in
            ERROR)   lcolor="${COLOR_RED}" ;;
            WARNING) lcolor="${COLOR_YELLOW}" ;;
            *)       lcolor="${COLOR_GREEN}" ;;
        esac
        printf "  ${COLOR_WHITE}%-8s${COLOR_RESET} ${lcolor}%-8s${COLOR_RESET} ${COLOR_CYAN}%-20s${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" "${cnt}" "${lvl}" "${fseen}" "${sig}"
    done
fi

NEW_SIGS=$(printf '%s\n' "${SIGNATURES_SECTION}" | awk -F'\t' '$5 > 0' | sort -rn -k1,1 || true)
if [[ -n "${NEW_SIGS}" ]]; then
    echo -e "\n${COLOR_RED}${COLOR_BOLD}[!] NEW Messages / Behavior Changes Introduced Post-Upgrade:${COLOR_RESET}"
    printf "  ${COLOR_DIM}%-8s %-8s %-12s %s${COLOR_RESET}\n" "COUNT" "LEVEL" "UPGRADE #" "SIGNATURE TEMPLATE"
    printf "  ${COLOR_DIM}%-8s %-8s %-12s %s${COLOR_RESET}\n" "-----" "-----" "---------" "------------------"
    printf '%s\n' "${NEW_SIGS}" | head -n 8 | while IFS=$'\t' read -r cnt lvl fseen lseen upg sig; do
        case "$lvl" in
            ERROR)   lcolor="${COLOR_RED}" ;;
            WARNING) lcolor="${COLOR_YELLOW}" ;;
            *)       lcolor="${COLOR_GREEN}" ;;
        esac
        printf "  ${COLOR_WHITE}%-8s${COLOR_RESET} ${lcolor}%-8s${COLOR_RESET} ${COLOR_MAGENTA}Upgrade #%-4s${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" "${cnt}" "${lvl}" "${upg}" "${sig}"
    done
fi

echo -e "\n${COLOR_GREEN}${COLOR_BOLD}[✓] Analysis complete! Full text report saved to:${COLOR_RESET} ${COLOR_WHITE}${OUTPUT_FILE}${COLOR_RESET}\n"
