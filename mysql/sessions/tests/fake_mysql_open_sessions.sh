#!/usr/bin/env bash
set -euo pipefail

case "${1-}" in
    --version)
        printf 'fake-mysql\n'
        exit 0
        ;;
esac

SQL=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--execute)
            [[ $# -ge 2 ]] || {
                printf 'ERROR: %s requires a SQL statement.\n' "$1" >&2
                exit 2
            }
            SQL=$2
            shift 2
            ;;
        --execute=*)
            SQL=${1#*=}
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "${FAKE_MYSQL_READY_FILE:-}" ]]; then
    : > "$FAKE_MYSQL_READY_FILE"
    while [[ ! -e "${FAKE_MYSQL_RELEASE_FILE:?}" ]]; do
        sleep 0.05
    done
fi

printf '%s\n' "$SQL" >> "${FAKE_MYSQL_SQL_LOG:?}"
printf '%s\n' "${FAKE_MYSQL_OUTPUT:-}"
