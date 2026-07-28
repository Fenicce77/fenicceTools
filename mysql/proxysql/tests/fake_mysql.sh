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
        *"SELECT '__PXMON_POOL__'"*)
            printf '__PXMON_POOL__\n'
            ;;
        *stats.stats_mysql_connection_pool*)
            printf '10\tbackend:3306\tONLINE\t2\t3\t50\t1\n'
            ;;
        *"SELECT '__PXMON_PING__'"*)
            printf '__PXMON_PING__\n'
            ;;
        *monitor.mysql_server_ping_log*)
            printf 'backend\t2026-07-28 12:00:00\t500\t\n'
            ;;
    esac
done
