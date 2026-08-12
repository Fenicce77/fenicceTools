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

if [[ "${FAKE_MYSQL_EMULATE_HOST_NORMALIZATION:-false}" == true ]]; then
    normalized=false
    if [[ "$SQL" == *"SUBSTRING_INDEX(SUBSTRING_INDEX(HOST, ':', 1), '.', 4)"* &&
        "$SQL" == *"LOCATE(']:', HOST)"* &&
        "$SQL" == *"LENGTH(HOST) - LENGTH(REPLACE(HOST, ':', '')) > 1"* &&
        "$SQL" == *"LEFT(HOST, LENGTH(HOST) - LENGTH(SUBSTRING_INDEX(HOST, ':', -1)) - 1)"* &&
        "$SQL" == *"ORDER BY record_type, USER, DB, normalized_host"* ]]; then
        normalized=true
    fi

    if [[ "$normalized" == true ]]; then
        printf 'ROW\tapp\tbilling\t10.0.0.5\t2\n'
        printf 'ROW\tapp\tbilling\t2001:db8::1\t2\n'
    else
        printf 'ROW\tapp\tbilling\t10.0.0.5:41001\t1\n'
        printf 'ROW\tapp\tbilling\t10.0.0.5:41002\t1\n'
        printf 'ROW\tapp\tbilling\t[2001:db8::1]:41003\t1\n'
        printf 'ROW\tapp\tbilling\t2001:db8::1:41004\t1\n'
    fi
    printf 'TOTAL\t\t\t\t4\n'
    exit 0
fi

if [[ -n "${FAKE_MYSQL_REQUIRED_EXCLUSION_PREDICATE:-}" ]]; then
    grouped_sql=${SQL%%UNION ALL*}
    total_sql=${SQL#*UNION ALL}

    if [[ "$grouped_sql" == *"$FAKE_MYSQL_REQUIRED_EXCLUSION_PREDICATE"* ]]; then
        printf 'ROW\tapp\tbilling\tapi\t3\n'
    else
        printf 'ROW\troot\tmysql\tlocalhost\t1\n'
        printf 'ROW\tpmm_monitor\tNULL\tmonitor\t1\n'
        printf 'ROW\tapp\tbilling\tapi\t3\n'
    fi

    if [[ "$total_sql" == *"$FAKE_MYSQL_REQUIRED_EXCLUSION_PREDICATE"* ]]; then
        printf 'TOTAL\t\t\t\t3\n'
    else
        printf 'TOTAL\t\t\t\t5\n'
    fi
    exit 0
fi

printf '%s\n' "${FAKE_MYSQL_OUTPUT:-}"
