#!/usr/bin/env bash

# Default input file. You can pass it as the first argument to the script.
INPUT_FILE="${1:-proxysql_servers.txt}"

# 1. Initial validations
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: The server file '$INPUT_FILE' does not exist."
    echo "Usage: $0 [servers_file.txt]"
    exit 1
fi

if ! command -v mysql &> /dev/null; then
    echo "Error: The 'mysql' command is not installed or not found in the PATH."
    exit 1
fi

# 2. Print table header
printf "%-35s | %-25s\n" "Server (Login-Path)" "ProxySQL Version"
printf "%s\n" "------------------------------------+---------------------------"

# 3. Process the file line by line
# IFS= prevents leading/trailing whitespace from being stripped by read
# || [[ -n "$login_path" ]] ensures the last line is read even if it lacks a newline
while IFS= read -r login_path || [[ -n "$login_path" ]]; do
    
    # Skip empty lines and lines starting with # (comments)
    if [[ -z "$login_path" ]] || [[ "$login_path" =~ ^# ]]; then
        continue
    fi

    # Trim leading and trailing whitespace (useful in mixed macOS/Linux environments)
    login_path=$(echo "$login_path" | xargs)

    # 4. Execute the connection and fetch the version
    # -N: Skip column headers
    # -B: Batch mode (tab-separated, prevents mysql from drawing ascii tables)
    # 2>/dev/null: Redirect connection errors to avoid cluttering the standard output
    version=$(mysql --login-path="$login_path" -N -B -e "SELECT @@version;" 2>/dev/null)

    # 5. Evaluate the result and format the output
    if [[ $? -eq 0 && -n "$version" ]]; then
        printf "%-35s | %-25s\n" "$login_path" "$version"
    else
        printf "%-35s | %-25s\n" "$login_path" "ERROR / CANNOT CONNECT"
    fi

done < "$INPUT_FILE"