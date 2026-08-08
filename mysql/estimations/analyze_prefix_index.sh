#!/usr/bin/env bash
set -euo pipefail

LOGIN_PATH='' DATABASE='' TABLE='' COLUMNS='' MAX_PREFIX=50 ENVIRONMENT='' MYSQL_BIN="${MYSQL_BIN:-}" QUERY_TIMEOUT='' ALLOW_PRODUCTION=0 NO_COLOR=0
MARGINAL_THRESHOLD=0.01 TARGET_RATIO=0.95
color=1; [[ -t 1 ]] || color=0

die() { printf 'Error: %s\n' "$1" >&2; exit "${2:-2}"; }
paint() { [[ $color -eq 1 ]] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
help() {
  paint '1;34' '=============================================================================='; printf '\n'
  paint '1;32' ' MySQL Optimal Index Prefix Analyzer'; printf '\n'
  paint '1;34' '=============================================================================='; printf '\n'
  paint '1;33' 'Usage:'; printf ' %s -l LOGIN_PATH -d DATABASE -t TABLE --environment ENVIRONMENT [OPTIONS]\n\n' "${0##*/}"
  printf 'Analyze leftmost index-prefix selectivity without changing the target server.\n\n'
  paint '1;33' 'Required options'; printf '\n'
  printf '  -l, --login-path NAME       MySQL login path\n  -d, --database NAME          Target database\n  -t, --table NAME             Target table\n  --environment NAME           development, test, staging, or production\n\n'
  paint '1;33' 'Optional options'; printf '\n'
  printf '  -c, --columns LIST          Comma-separated columns\n  -m, --max-prefix NUMBER      Maximum prefix length (default: 50)\n  --mysql-bin PATH             Local mysql client\n  --query-timeout MILLISECONDS  Optimizer execution-time hint\n  --allow-production            Required with production\n  --no-color                    Disable ANSI colors\n  -h, --help                    Show this help\n\n'
  paint '1;33' 'Examples'; printf '\n'
  printf '  %s -l reporting -d app -t users --environment test\n' "${0##*/}"
  printf '  %s -l reporting -d app -t users -c email,name -m 32 --environment staging\n' "${0##*/}"
  paint '1;34' '=============================================================================='; printf '\n'
}
need() { [[ $# -ge 2 && -n $2 ]] || die "Option $1 requires a value."; }
if [[ $# -eq 0 ]]; then help; exit 0; fi
while [[ $# -gt 0 ]]; do case $1 in
  -h|--help) help; exit 0;; -l|--login-path) need "$@"; LOGIN_PATH=$2; shift 2;; -d|--database) need "$@"; DATABASE=$2; shift 2;; -t|--table) need "$@"; TABLE=$2; shift 2;; -c|--columns) need "$@"; COLUMNS=$2; shift 2;; -m|--max-prefix) need "$@"; MAX_PREFIX=$2; shift 2;;
  --environment) need "$@"; ENVIRONMENT=$2; shift 2;; --mysql-bin) need "$@"; MYSQL_BIN=$2; shift 2;; --query-timeout) need "$@"; QUERY_TIMEOUT=$2; shift 2;; --allow-production) ALLOW_PRODUCTION=1; shift;; --no-color) NO_COLOR=1; color=0; shift;; *) die "Unknown option: $1";; esac; done

[[ -n $LOGIN_PATH && -n $DATABASE && -n $TABLE && -n $ENVIRONMENT ]] || die 'login-path, database, table, and environment are required.'
[[ $ENVIRONMENT =~ ^(development|test|staging|production)$ ]] || die 'environment must be development, test, staging, or production.'
[[ $ENVIRONMENT != production || $ALLOW_PRODUCTION -eq 1 ]] || die 'production requires --allow-production.'
[[ $ENVIRONMENT == production || $ALLOW_PRODUCTION -eq 0 ]] || die '--allow-production is valid only with production.'
[[ $MAX_PREFIX =~ ^[1-9][0-9]*$ ]] || die 'max-prefix must be a positive integer.'
[[ -z $QUERY_TIMEOUT || $QUERY_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die 'query-timeout must be a positive integer.'
valid_id() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_$]*$ ]]; }
valid_id "$DATABASE" && valid_id "$TABLE" || die 'database and table must be valid SQL identifiers.'
if [[ -n $COLUMNS ]]; then IFS=',' read -r -a cols <<< "$COLUMNS"; for c in "${cols[@]}"; do c=${c//[[:space:]]/}; valid_id "$c" || die "invalid column identifier: $c"; done; fi
if [[ -n $MYSQL_BIN ]]; then [[ -x $MYSQL_BIN ]] || die "mysql client is not executable: $MYSQL_BIN" 3; else MYSQL_BIN=$(command -v mysql || true); fi
[[ -n $MYSQL_BIN ]] || die 'mysql client was not found.' 3
command -v bc >/dev/null 2>&1 || die "'bc' is not installed." 3

mysql_query() { "$MYSQL_BIN" "--login-path=$LOGIN_PATH" -sN -e "$1"; }
if [[ -z $COLUMNS ]]; then
  COLUMNS=$(mysql_query "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE' AND DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext');") || die 'failed to retrieve string columns.' 3
  COLUMNS=$(printf '%s' "$COLUMNS" | paste -sd, -)
fi
[[ -n $COLUMNS ]] || die 'no string columns found.' 4
printf '%s\n' "$(paint '33' "Analyzing $DATABASE.$TABLE in $ENVIRONMENT")"
IFS=',' read -r -a cols <<< "$COLUMNS"; result=0
for col in "${cols[@]}"; do
  col=${col//[[:space:]]/}; printf '%s\n' "Column: $col"
  lengths=$(mysql_query "SELECT CONCAT_WS(',',IFNULL(MIN(CHAR_LENGTH(\`$col\`)),0),IFNULL(MAX(CHAR_LENGTH(\`$col\`)),0)) FROM \`$DATABASE\`.\`$TABLE\` WHERE \`$col\` IS NOT NULL AND CAST(\`$col\` AS CHAR) != '';") || { printf 'Column error: %s\n' "$col" >&2; result=4; continue; }
  IFS=, read -r min max <<< "$lengths"; [[ ${max:-0} =~ ^[0-9]+$ && $max -gt 0 ]] || { printf 'Column empty: %s\n' "$col"; result=4; continue; }
  start=$min; [[ $start -ge 1 ]] || start=1; limit=$max; [[ $MAX_PREFIX -lt $limit ]] && limit=$MAX_PREFIX; [[ $limit -lt $start ]] && limit=$start
  select=''; for ((i=start;i<=limit;i++)); do select+="ROUND(COUNT(DISTINCT LEFT(\`$col\`,$i))/COUNT(*),4),"; done; select=${select%,}
  hint=''; [[ -n $QUERY_TIMEOUT ]] && hint="/*+ MAX_EXECUTION_TIME($QUERY_TIMEOUT) */ "
  values=$(mysql_query "SELECT $hint CONCAT_WS(',', $select) FROM \`$DATABASE\`.\`$TABLE\` WHERE \`$col\` IS NOT NULL AND CAST(\`$col\` AS CHAR) != '';") || { printf 'Column error: %s\n' "$col" >&2; result=4; continue; }
  IFS=, read -r -a sel <<< "$values"; maxsel=${sel[$((limit-start))]}; target=$(echo "$maxsel * $TARGET_RATIO" | bc -l); prev=0; optimal=''
  for ((i=start;i<=limit;i++)); do v=${sel[$((i-start))]}; gain=$(echo "$v - $prev" | bc -l); if [[ -z $optimal ]] && [[ $(echo "$v >= $target && $gain <= $MARGINAL_THRESHOLD" | bc) -eq 1 ]]; then optimal=$i; fi; prev=$v; done
  [[ -n $optimal ]] && printf 'Recommendation: %s(%s)\n' "$col" "$optimal" || printf 'Recommendation: full column or increase max-prefix.\n'
done
exit "$result"
