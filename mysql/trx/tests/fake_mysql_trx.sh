#!/usr/bin/env bash
set -euo pipefail
sql=''; for arg in "$@"; do [[ "$arg" == *'SELECT'* || "$arg" == KILL* ]] && sql=$arg; done
printf '%s\n' "$sql" >> "${FAKE_MYSQL_TRX_LOG:?}"
case "$sql" in
  *'CONNECTION_ID()'*) printf '999\n' ;;
  *'innodb_lock_waits'*) printf '12\tapp\t34\treport\tapp.orders\t15\tUPDATE orders\tINSERT orders\n' ;;
  *'innodb_trx'*) printf '12\tapp\tlocalhost\tapp\t30\tRunning\tSELECT 1\n' ;;
  *'KILL CONNECTION'*) printf 'killed\n' ;;
  *) printf '8.0.36\n' ;;
esac
