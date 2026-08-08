#!/usr/bin/env bash
set -euo pipefail
sql=''
while [[ $# -gt 0 ]]; do case "$1" in -e) sql=$2; shift 2;; *) shift;; esac; done
printf '%s\n' "$sql" >> "${FAKE_MYSQL_STORAGE_LOG:?}"
case "$sql" in
  *'SELECT VERSION()'*) printf '8.0.36\n' ;;
  *'innodb_buffer_pool_size'*) printf '8589934592\n' ;;
  *) printf 'users\t100\t3000\t1.0\t0.3\t1.3\t0.1%%\nTOTAL\t100\t3000\t1.0\t0.3\t1.3\t0.1%%\n' ;;
esac
