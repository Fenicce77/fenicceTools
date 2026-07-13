#!/usr/bin/env bash

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 1. Function to display help, usage, and use cases
show_help() {
    echo -e "${YELLOW}${BOLD}Usage:${NC} $0 <login_paths_file.txt>\n"
    
    echo -e "${CYAN}${BOLD}Description:${NC}"
    echo -e "  Reads a text file containing MySQL login-paths (one per line),"
    echo -e "  connects to each ProxySQL server, and outputs a dynamically"
    echo -e "  aligned, colorized table with the server versions.\n"
    
    echo -e "${CYAN}${BOLD}Options:${NC}"
    echo -e "  -h, --help    Show this help message and exit.\n"
    
    echo -e "${CYAN}${BOLD}Use Cases & Examples:${NC}"
    echo -e "  1. Basic execution:"
    echo -e "     $0 proxysql_servers.txt\n"
    echo -e "  2. Input file format (e.g., proxysql_servers.txt):"
    echo -e "     # Production endpoints"
    echo -e "     proxy-prod-01"
    echo -e "     proxy-prod-02"
    exit 0
}

# 2. Check if no parameters were passed or if help is requested
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

INPUT_FILE="$1"

# 3. Initial validations
if [[ ! -f "$INPUT_FILE" ]]; then
    echo -e "${RED}${BOLD}Error:${NC} The server file '$INPUT_FILE' does not exist."
    echo -e "Run '${YELLOW}$0 --help${NC}' for more information."
    exit 1
fi

if ! command -v mysql &> /dev/null; then
    echo -e "${RED}${BOLD}Error:${NC} The 'mysql' command is not installed or not found in the PATH."
    exit 1
fi

# 4. Calculate dynamic column width based on the longest login-path
COL_WIDTH=20 # Set a minimum column width
while IFS= read -r login_path || [[ -n "$login_path" ]]; do
    # Skip empty lines and comments
    if [[ -z "$login_path" ]] || [[ "$login_path" =~ ^# ]]; then
        continue
    fi
    
    # Trim whitespace to get accurate length
    login_path=$(echo "$login_path" | xargs)
    
    if [[ ${#login_path} -gt $COL_WIDTH ]]; then
        COL_WIDTH=${#login_path}
    fi
done < "$INPUT_FILE"

# Add a little padding to the maximum width found
COL_WIDTH=$((COL_WIDTH + 2))

# Define dynamic format strings for printf
FMT_HEADER="${CYAN}${BOLD}%-${COL_WIDTH}s | %-25s${NC}\n"
FMT_SUCCESS="${GREEN}%-${COL_WIDTH}s | %-25s${NC}\n"
FMT_ERROR="${RED}%-${COL_WIDTH}s | %-25s${NC}\n"

# 5. Print table header
printf "$FMT_HEADER" "Server (Login-Path)" "ProxySQL Version"

# Generate a dynamic separator line matching the column width
SEPARATOR=$(printf '%*s' "$COL_WIDTH" '' | tr ' ' '-')
printf "${CYAN}%s-+---------------------------${NC}\n" "$SEPARATOR"

# 6. Process the file to fetch versions
while IFS= read -r login_path || [[ -n "$login_path" ]]; do
    
    if [[ -z "$login_path" ]] || [[ "$login_path" =~ ^# ]]; then
        continue
    fi

    login_path=$(echo "$login_path" | xargs)

    # Execute connection
    # --connect-timeout=5: Prevents script from hanging on firewalled/dead nodes
    # tr -d '\r': Strips carriage returns that break terminal alignment
    #version=$(mysql --login-path="$login_path" --connect-timeout=5 -N -B -e "SELECT @@version;" 2>/dev/null | tr -d '\r' | xargs)
    version=$(mysql --login-path="$login_path" --connect-timeout=5 -N -B -e "SELECT @@admin-version;" 2>/dev/null | tr -d '\r' | xargs)

    # 7. Evaluate the result and format the output
    if [[ $? -eq 0 && -n "$version" ]]; then
        printf "$FMT_SUCCESS" "$login_path" "$version"
    else
        printf "$FMT_ERROR" "$login_path" "ERROR / CANNOT CONNECT"
    fi

done < "$INPUT_FILE"