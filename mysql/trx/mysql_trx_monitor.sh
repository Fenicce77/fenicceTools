#!/usr/bin/env bash
set -euo pipefail
LOGIN_PATH='' VIEW=all REFRESH=5 MIN_AGE=0 MYSQL_BIN='' NO_COLOR=false SMOKE=false
help(){ printf 'MySQL Transaction and Lock Monitor\n\nUsage: %s --login-path NAME [OPTIONS]\n\nRequired:\n  --login-path PATH\n\nViews and runtime:\n  --view transactions|locks|all\n  --refresh-time SECONDS\n  --min-age SECONDS\n  --smoke-test\n  --mysql-bin PATH\n  --no-color\n  -h, --help\n\nInteractive: v view, p pause, k kill a manually entered connection ID, q quit.\n' "$0"; }
[[ $# -gt 0 ]] || { help; exit 0; }
while [[ $# -gt 0 ]]; do case "$1" in -h|--help) help; exit 0;; --login-path) LOGIN_PATH=${2:?}; shift 2;; --view) VIEW=${2:?}; shift 2;; --refresh-time) REFRESH=${2:?}; shift 2;; --min-age) MIN_AGE=${2:?}; shift 2;; --mysql-bin) MYSQL_BIN=${2:?}; shift 2;; --no-color) NO_COLOR=true; shift;; --smoke-test) SMOKE=true; shift;; *) printf 'ERROR: unknown option %s\n' "$1" >&2; exit 2;; esac; done
[[ -n $LOGIN_PATH ]] || { printf 'ERROR: --login-path is required\n' >&2; exit 2; }
[[ $VIEW =~ ^(transactions|locks|all)$ && $REFRESH =~ ^[1-9][0-9]*$ && $MIN_AGE =~ ^[0-9]+$ ]] || { printf 'ERROR: invalid view or numeric option\n' >&2; exit 2; }
[[ -n $MYSQL_BIN ]] || MYSQL_BIN=$(command -v mysql || true); [[ -x $MYSQL_BIN ]] || { printf 'ERROR: mysql client unavailable\n' >&2; exit 3; }
query(){ "$MYSQL_BIN" "--login-path=$LOGIN_PATH" -B -N -e "$1"; }
transactions(){ printf 'TRANSACTIONS\n'; query "SELECT p.ID,COALESCE(p.USER,'-'),COALESCE(p.HOST,'-'),COALESCE(p.DB,'-'),GREATEST(p.TIME,COALESCE(TIMESTAMPDIFF(SECOND,t.trx_started,NOW()),0)),COALESCE(p.STATE,'-'),COALESCE(SUBSTRING(p.INFO,1,80),'-') FROM information_schema.PROCESSLIST p LEFT JOIN information_schema.innodb_trx t ON p.ID=t.trx_mysql_thread_id WHERE p.ID != CONNECTION_ID() AND (t.trx_id IS NOT NULL OR p.COMMAND != 'Sleep') AND GREATEST(p.TIME,COALESCE(TIMESTAMPDIFF(SECOND,t.trx_started,NOW()),0)) >= $MIN_AGE ORDER BY 5 DESC;"; }
locks(){ printf 'LOCK WAITS\n'; query "SELECT blocking_pid,blocking_account,waiting_pid,waiting_account,locked_table,wait_age_secs,blocking_query,waiting_query FROM sys.innodb_lock_waits ORDER BY wait_age_secs DESC;"; }
render(){ [[ $VIEW == transactions || $VIEW == all ]] && transactions; [[ $VIEW == locks || $VIEW == all ]] && locks; }
if [[ $SMOKE == true ]]; then render; exit 0; fi
while true; do clear 2>/dev/null || true; render; printf '\n[v]iew [p]ause [k]ill [q]uit: '; read -r -n 1 key; printf '\n'; case "$key" in q) exit 0;; v) [[ $VIEW == transactions ]] && VIEW=locks || VIEW=transactions;; k) printf 'Connection ID: '; read -r id; [[ $id =~ ^[1-9][0-9]*$ ]] || continue; own=$(query 'SELECT CONNECTION_ID();'); [[ $id == "$own" ]] && { printf 'Refusing own connection.\n'; continue; }; printf 'Type kill %s to confirm: ' "$id"; read -r confirm; [[ $confirm == "kill $id" ]] && query "KILL CONNECTION $id";; *) sleep "$REFRESH";; esac; done
