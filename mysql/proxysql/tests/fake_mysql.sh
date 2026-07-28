#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_MYSQL_STATE_DIR:?FAKE_MYSQL_STATE_DIR is required}"

printf '%s\n' "$$" >> "$FAKE_MYSQL_STATE_DIR/launches"

while IFS= read -r sql; do
    case "$sql" in
        *PXMON_BEGIN_*|*PXMON_END_*)
            marker=${sql#*\'}
            marker=${marker%%\'*}
            printf '%s\n' "$marker"
            ;;
        *TEST_CONNECTIONS*)
            printf 'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t4\n'
            ;;
        *TEST_SECOND_SAMPLE*)
            printf 'app\t10.0.0.10\t10.0.0.20:3306\tappdb\t6\n'
            ;;
    esac
done
