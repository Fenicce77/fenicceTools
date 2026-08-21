#!/usr/bin/env bash
set -euo pipefail

sql=''
while (($#)); do
    case "$1" in
        -e)
            sql=${2:?missing SQL after -e}
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "${FAKE_MYSQL_BP_RESIZE_LOG:-}" ]]; then
    printf '%s\n' "$sql" >> "$FAKE_MYSQL_BP_RESIZE_LOG"
fi

case "${FAKE_MYSQL_BP_RESIZE_MODE:-active}" in
    active) printf 'Resizing\t0\t42\t1073741824\n' ;;
    withdrawing) printf 'Withdrawing blocks\t3\t42\t8589934592\n' ;;
    complete) printf 'Complete\t0\t100\t2147483648\n' ;;
    failed) printf 'Failed\t7\t75\t536870912\n' ;;
    unavailable-numeric|unavailable_numeric) printf 'Resizing\t\t\t1073741824\n' ;;
    query-failure)
        printf '%s\n' 'resize status query failed' >&2
        exit 1
        ;;
    query-failure-7)
        printf '%s\n' 'resize status query failed with client status 7' >&2
        exit 7
        ;;
    *)
        printf 'unsupported fake resize mode: %s\n' "${FAKE_MYSQL_BP_RESIZE_MODE}" >&2
        exit 2
        ;;
esac
