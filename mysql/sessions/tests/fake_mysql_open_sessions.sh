#!/usr/bin/env bash
set -euo pipefail

case "${1-}" in
    --version)
        printf 'fake-mysql\n'
        exit 0
        ;;
esac

printf '%s\n' "${*: -1}" >> "${FAKE_MYSQL_SQL_LOG:?}"
printf '%s\n' "${FAKE_MYSQL_OUTPUT:-}"
