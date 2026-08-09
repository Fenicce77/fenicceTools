#!/usr/bin/env bash
set -euo pipefail

initialize_defaults() {
    LOGIN_PATH=""
    VIEW="all"
    REFRESH_TIME=5
    MIN_AGE=0
    MYSQL_BIN=""
    MYSQL_BIN_OPTION=""
    USER_FILTER=""
    DATABASE_FILTER=""
    HOST_FILTER=""
    USER_FILTER_SQL=""
    DATABASE_FILTER_SQL=""
    HOST_FILTER_SQL=""
    TRANSACTION_FILTER_SQL=""
    OUTPUT_FILE=""
    NO_COLOR=false
    SMOKE_TEST=false
    LOGGING_ENABLED=false
    PAUSED=false
    QUERY_OUTPUT=""
    QUERY_ERROR=""
}

initialize_colors() {
    COLOR_TITLE=""
    COLOR_SECTION=""
    COLOR_OPTION=""
    COLOR_VALUE=""
    COLOR_WARNING=""
    COLOR_ERROR=""
    COLOR_SUCCESS=""
    COLOR_RESET=""
    if [[ "$NO_COLOR" == false && -t 1 && "${TERM:-dumb}" != dumb ]]; then
        COLOR_TITLE=$(printf '\033[1;36m')
        COLOR_SECTION=$(printf '\033[1;33m')
        COLOR_OPTION=$(printf '\033[0;32m')
        COLOR_VALUE=$(printf '\033[0;36m')
        COLOR_WARNING=$(printf '\033[0;33m')
        COLOR_ERROR=$(printf '\033[0;31m')
        COLOR_SUCCESS=$(printf '\033[0;32m')
        COLOR_RESET=$(printf '\033[0m')
    fi
}

show_help() {
    initialize_colors
    printf '%s%s%s\n\n' "$COLOR_TITLE" 'MySQL Transaction and Lock Monitor' "$COLOR_RESET"
    printf '%sUsage:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%s --login-path NAME [OPTIONS]%s\n\n' "$COLOR_VALUE" "$0" "$COLOR_RESET"

    printf '%sRequired:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%-28s%s %s%-26s%s %s\n\n' \
        "$COLOR_OPTION" '-l, --login-path' "$COLOR_RESET" "$COLOR_VALUE" 'NAME' "$COLOR_RESET" \
        'MySQL login-path for the target server'

    printf '%sViews and runtime:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--view' "$COLOR_RESET" "$COLOR_VALUE" 'transactions|locks|all' "$COLOR_RESET" 'Initial view (default: all)'
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--refresh-time' "$COLOR_RESET" "$COLOR_VALUE" 'SECONDS' "$COLOR_RESET" 'Refresh interval (default: 5)'
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--min-age' "$COLOR_RESET" "$COLOR_VALUE" 'SECONDS' "$COLOR_RESET" 'Minimum transaction or wait age (default: 0)'
    printf '  %s%-28s%s %s%-26s%s %s\n\n' "$COLOR_OPTION" '--smoke-test' "$COLOR_RESET" "$COLOR_VALUE" '' "$COLOR_RESET" 'Render one snapshot and exit'

    printf '%sFilters:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--user-filter' "$COLOR_RESET" "$COLOR_VALUE" 'USER[,USER...]' "$COLOR_RESET" 'Exact processlist users'
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--database-filter' "$COLOR_RESET" "$COLOR_VALUE" 'DB[,DB...]' "$COLOR_RESET" 'Exact processlist databases'
    printf '  %s%-28s%s %s%-26s%s %s\n\n' "$COLOR_OPTION" '--host-filter' "$COLOR_RESET" "$COLOR_VALUE" 'HOST[,HOST...]' "$COLOR_RESET" 'Exact processlist hosts, including port when present'

    printf '%sLogging:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%-28s%s %s%-26s%s %s\n\n' "$COLOR_OPTION" '-o, --output-file' "$COLOR_RESET" "$COLOR_VALUE" 'FILE' "$COLOR_RESET" 'Append timestamped ANSI-free snapshots'

    printf '%sClient and display:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--mysql-bin' "$COLOR_RESET" "$COLOR_VALUE" 'PATH' "$COLOR_RESET" 'Local MySQL client executable'
    printf '  %s%-28s%s %s%-26s%s %s\n' "$COLOR_OPTION" '--no-color' "$COLOR_RESET" "$COLOR_VALUE" '' "$COLOR_RESET" 'Disable ANSI colors'
    printf '  %s%-28s%s %s%-26s%s %s\n\n' "$COLOR_OPTION" '-h, --help' "$COLOR_RESET" "$COLOR_VALUE" '' "$COLOR_RESET" 'Show this help and exit'

    printf '%sInteractive controls:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %sv%s cycle view  %sp%s pause/resume  %sf%s edit filters  %sl%s toggle logging\n' \
        "$COLOR_OPTION" "$COLOR_RESET" "$COLOR_OPTION" "$COLOR_RESET" \
        "$COLOR_OPTION" "$COLOR_RESET" "$COLOR_OPTION" "$COLOR_RESET"
    printf '  %sk%s inspect and kill a manually entered connection  %sq%s quit\n\n' \
        "$COLOR_OPTION" "$COLOR_RESET" "$COLOR_OPTION" "$COLOR_RESET"

    printf '%sExamples:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '  %s%s --login-path production-db --view all%s\n' "$COLOR_VALUE" "$0" "$COLOR_RESET"
    printf '  %s%s -l staging-db --view transactions --min-age 30 --user-filter app,reporting%s\n' "$COLOR_VALUE" "$0" "$COLOR_RESET"
    printf '  %s%s -l production-db --host-filter host1:3306 -o mysql-trx.log%s\n\n' "$COLOR_VALUE" "$0" "$COLOR_RESET"

    printf '%sSafety:%s\n' "$COLOR_SECTION" "$COLOR_RESET"
    printf '%s  Monitoring and logging are read-only. No connection is killed automatically.%s\n' "$COLOR_WARNING" "$COLOR_RESET"
    printf '%s  Kill requires a numeric connection ID, target inspection, and exact confirmation.%s\n' "$COLOR_WARNING" "$COLOR_RESET"
}

cli_error() {
    printf 'ERROR: %s\nTry --help for usage.\n' "$1" >&2
    exit 2
}

runtime_error() {
    printf 'ERROR: %s\n' "$2" >&2
    exit "$1"
}

require_value() {
    [[ -n "${2-}" && "${2-}" != -* ]] || cli_error "Option $1 requires a value."
}

sql_escape_literal() {
    local escaped=$1
    escaped=${escaped//\\/\\\\}
    escaped=${escaped//\'/\'\'}
    SQL_ESCAPED_LITERAL="'$escaped'"
}

build_filter_list() {
    local option=$1 value=$2 remaining item separator="" last=false
    FILTER_SQL_LIST=""
    FILTER_ERROR=""
    remaining=$value
    while true; do
        case "$remaining" in
            *,*) item=${remaining%%,*}; remaining=${remaining#*,} ;;
            *) item=$remaining; remaining=""; last=true ;;
        esac
        if [[ -z "$item" ]]; then
            FILTER_ERROR="Invalid $option: empty list items are not allowed."
            return 1
        fi
        sql_escape_literal "$item"
        FILTER_SQL_LIST="${FILTER_SQL_LIST}${separator}${SQL_ESCAPED_LITERAL}"
        separator=","
        [[ "$last" == true ]] && break
    done
}

rebuild_transaction_filters() {
    local predicate separator=""
    TRANSACTION_FILTER_SQL=""
    for predicate in "$USER_FILTER_SQL" "$DATABASE_FILTER_SQL" "$HOST_FILTER_SQL"; do
        [[ -n "$predicate" ]] || continue
        TRANSACTION_FILTER_SQL="${TRANSACTION_FILTER_SQL}${separator} AND ${predicate}"
        separator=""
    done
}

set_user_filter() {
    local value=$1 candidate=""
    if [[ -n "$value" ]]; then
        build_filter_list '--user-filter' "$value" || return 1
        candidate="p.USER IN (${FILTER_SQL_LIST})"
    fi
    USER_FILTER=$value
    USER_FILTER_SQL=$candidate
    rebuild_transaction_filters
}

set_database_filter() {
    local value=$1 candidate=""
    if [[ -n "$value" ]]; then
        build_filter_list '--database-filter' "$value" || return 1
        candidate="p.DB IN (${FILTER_SQL_LIST})"
    fi
    DATABASE_FILTER=$value
    DATABASE_FILTER_SQL=$candidate
    rebuild_transaction_filters
}

set_host_filter() {
    local value=$1 candidate=""
    if [[ -n "$value" ]]; then
        build_filter_list '--host-filter' "$value" || return 1
        candidate="p.HOST IN (${FILTER_SQL_LIST})"
    fi
    HOST_FILTER=$value
    HOST_FILTER_SQL=$candidate
    rebuild_transaction_filters
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --login-path=*) LOGIN_PATH=${1#*=}; [[ -n "$LOGIN_PATH" ]] || cli_error 'Option --login-path requires a value.' ;;
            -l|--login-path) require_value "$1" "${2-}"; LOGIN_PATH=$2; shift ;;
            --view=*) VIEW=${1#*=}; [[ -n "$VIEW" ]] || cli_error 'Option --view requires a value.' ;;
            --view) require_value "$1" "${2-}"; VIEW=$2; shift ;;
            --refresh-time=*) REFRESH_TIME=${1#*=}; [[ -n "$REFRESH_TIME" ]] || cli_error 'Option --refresh-time requires a value.' ;;
            --refresh-time) require_value "$1" "${2-}"; REFRESH_TIME=$2; shift ;;
            --min-age=*) MIN_AGE=${1#*=}; [[ -n "$MIN_AGE" ]] || cli_error 'Option --min-age requires a value.' ;;
            --min-age) require_value "$1" "${2-}"; MIN_AGE=$2; shift ;;
            --user-filter=*)
                [[ -n "${1#*=}" ]] || cli_error 'Option --user-filter requires a value.'
                set_user_filter "${1#*=}" || cli_error "$FILTER_ERROR"
                ;;
            --user-filter)
                require_value "$1" "${2-}"
                set_user_filter "$2" || cli_error "$FILTER_ERROR"
                shift
                ;;
            --database-filter=*)
                [[ -n "${1#*=}" ]] || cli_error 'Option --database-filter requires a value.'
                set_database_filter "${1#*=}" || cli_error "$FILTER_ERROR"
                ;;
            --database-filter)
                require_value "$1" "${2-}"
                set_database_filter "$2" || cli_error "$FILTER_ERROR"
                shift
                ;;
            --host-filter=*)
                [[ -n "${1#*=}" ]] || cli_error 'Option --host-filter requires a value.'
                set_host_filter "${1#*=}" || cli_error "$FILTER_ERROR"
                ;;
            --host-filter)
                require_value "$1" "${2-}"
                set_host_filter "$2" || cli_error "$FILTER_ERROR"
                shift
                ;;
            --output-file=*) OUTPUT_FILE=${1#*=}; [[ -n "$OUTPUT_FILE" ]] || cli_error 'Option --output-file requires a value.' ;;
            -o|--output-file) require_value "$1" "${2-}"; OUTPUT_FILE=$2; shift ;;
            --mysql-bin=*) MYSQL_BIN_OPTION=${1#*=}; [[ -n "$MYSQL_BIN_OPTION" ]] || cli_error 'Option --mysql-bin requires a value.' ;;
            --mysql-bin) require_value "$1" "${2-}"; MYSQL_BIN_OPTION=$2; shift ;;
            --smoke-test) SMOKE_TEST=true ;;
            --no-color) NO_COLOR=true ;;
            --) shift; break ;;
            -*) cli_error "Unknown option: $1" ;;
            *) cli_error "Unexpected argument: $1" ;;
        esac
        shift
    done
}

validate_arguments() {
    [[ -n "$LOGIN_PATH" ]] || cli_error '--login-path is required.'
    case "$VIEW" in transactions|locks|all) : ;; *) cli_error "Invalid view: $VIEW" ;; esac
    [[ "$REFRESH_TIME" =~ ^[1-9][0-9]*$ ]] || cli_error 'Refresh time must be a positive integer.'
    [[ "$MIN_AGE" =~ ^[0-9]+$ ]] || cli_error 'Minimum age must be a nonnegative integer.'
    if [[ -n "$OUTPUT_FILE" ]]; then
        [[ ! -d "$OUTPUT_FILE" ]] || cli_error "Output file cannot be a directory: $OUTPUT_FILE"
        local output_parent
        output_parent=$(dirname "$OUTPUT_FILE")
        [[ -d "$output_parent" && -w "$output_parent" ]] || cli_error "Output directory is not writable: $output_parent"
        [[ ! -e "$OUTPUT_FILE" || -w "$OUTPUT_FILE" ]] || cli_error "Output file is not writable: $OUTPUT_FILE"
        LOGGING_ENABLED=true
    fi
}

resolve_mysql_bin() {
    if [[ -n "$MYSQL_BIN_OPTION" ]]; then
        MYSQL_BIN=$MYSQL_BIN_OPTION
    else
        MYSQL_BIN=$(command -v mysql 2>/dev/null || true)
    fi
    [[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]] || runtime_error 3 'MySQL client not found or not executable.'
}

run_query() {
    local sql=$1 query_result
    QUERY_OUTPUT=""
    QUERY_ERROR=""
    if query_result=$("$MYSQL_BIN" --login-path="$LOGIN_PATH" --batch --raw --skip-column-names -e "$sql" 2>&1); then
        QUERY_OUTPUT=$query_result
        return 0
    fi
    QUERY_ERROR=$query_result
    return 1
}

transaction_query_pfs() {
    printf '%s' "SELECT /* trx-monitor:transactions-pfs */
       p.ID,
       COALESCE(p.USER, '-'),
       COALESCE(p.HOST, '-'),
       COALESCE(p.DB, '-'),
       GREATEST(COALESCE(p.TIME, 0), COALESCE(CAST(et.TIMER_WAIT / 1000000000000 AS UNSIGNED), 0)),
       COALESCE(p.STATE, '-'),
       COALESCE(SUBSTRING(p.INFO, 1, 160), '-')
FROM information_schema.PROCESSLIST AS p
JOIN performance_schema.threads AS th
  ON th.PROCESSLIST_ID = p.ID
LEFT JOIN performance_schema.events_transactions_current AS et
  ON et.THREAD_ID = th.THREAD_ID
WHERE p.ID != CONNECTION_ID()
  AND (et.EVENT_ID IS NOT NULL OR p.COMMAND != 'Sleep')
  AND GREATEST(COALESCE(p.TIME, 0), COALESCE(CAST(et.TIMER_WAIT / 1000000000000 AS UNSIGNED), 0)) >= $MIN_AGE${TRANSACTION_FILTER_SQL}
ORDER BY 5 DESC;"
}

transaction_query_fallback() {
    printf '%s' "SELECT /* trx-monitor:transactions-fallback */
       p.ID,
       COALESCE(p.USER, '-'),
       COALESCE(p.HOST, '-'),
       COALESCE(p.DB, '-'),
       GREATEST(COALESCE(p.TIME, 0), COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)),
       COALESCE(p.STATE, '-'),
       COALESCE(SUBSTRING(p.INFO, 1, 160), '-')
FROM information_schema.PROCESSLIST AS p
LEFT JOIN information_schema.innodb_trx AS t
  ON p.ID = t.trx_mysql_thread_id
WHERE p.ID != CONNECTION_ID()
  AND (t.trx_id IS NOT NULL OR p.COMMAND != 'Sleep')
  AND GREATEST(COALESCE(p.TIME, 0), COALESCE(TIMESTAMPDIFF(SECOND, t.trx_started, NOW()), 0)) >= $MIN_AGE${TRANSACTION_FILTER_SQL}
ORDER BY 5 DESC;"
}

render_transactions() {
    local sql
    printf 'TRANSACTIONS\n'
    printf 'ID\tUSER\tHOST\tDATABASE\tAGE_S\tSTATE\tQUERY\n'
    sql=$(transaction_query_pfs)
    if run_query "$sql"; then
        [[ -z "$QUERY_OUTPUT" ]] || printf '%s\n' "$QUERY_OUTPUT"
        return 0
    fi
    sql=$(transaction_query_fallback)
    if run_query "$sql"; then
        [[ -z "$QUERY_OUTPUT" ]] || printf '%s\n' "$QUERY_OUTPUT"
        return 0
    fi
    printf 'TRANSACTIONS UNAVAILABLE: performance_schema and information_schema transaction views cannot be queried.\n'
}

render_locks() {
    local sql
    printf 'LOCK WAITS\n'
    printf 'BLOCKING_ID\tBLOCKING_ACCOUNT\tWAITING_ID\tWAITING_ACCOUNT\tLOCKED_TABLE\tWAIT_S\tBLOCKING_QUERY\tWAITING_QUERY\n'
    sql="SELECT /* trx-monitor:locks */
       blocking_pid,
       blocking_account,
       waiting_pid,
       waiting_account,
       locked_table,
       wait_age_secs,
       blocking_query,
       waiting_query
FROM sys.innodb_lock_waits
WHERE wait_age_secs >= $MIN_AGE
ORDER BY wait_age_secs DESC;"
    if run_query "$sql"; then
        [[ -z "$QUERY_OUTPUT" ]] || printf '%s\n' "$QUERY_OUTPUT"
        return 0
    fi
    printf 'LOCK WAITS UNAVAILABLE: sys.innodb_lock_waits cannot be queried.\n'
}

render_snapshot() {
    printf 'Snapshot: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    case "$VIEW" in
        transactions) render_transactions ;;
        locks) render_locks ;;
        all)
            render_transactions
            printf '\n'
            render_locks
            ;;
    esac
}

display_snapshot() {
    local snapshot=$1 line
    if [[ -z "$COLOR_RESET" ]]; then
        printf '%s\n' "$snapshot"
        return
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            Snapshot:*) printf '%s%s%s\n' "$COLOR_TITLE" "$line" "$COLOR_RESET" ;;
            TRANSACTIONS|LOCK\ WAITS) printf '%s%s%s\n' "$COLOR_SECTION" "$line" "$COLOR_RESET" ;;
            *UNAVAILABLE:*) printf '%s%s%s\n' "$COLOR_ERROR" "$line" "$COLOR_RESET" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <<EOF
$snapshot
EOF
}

append_snapshot() {
    local snapshot=$1
    [[ "$LOGGING_ENABLED" == true && -n "$OUTPUT_FILE" ]] || return 0
    {
        printf '%s\n\n' "$snapshot"
    } >> "$OUTPUT_FILE" || runtime_error 4 "Unable to append snapshot to $OUTPUT_FILE"
}

render_and_publish() {
    local snapshot
    snapshot=$(render_snapshot)
    display_snapshot "$snapshot"
    append_snapshot "$snapshot"
}

cycle_view() {
    case "$VIEW" in
        all) VIEW=transactions ;;
        transactions) VIEW=locks ;;
        locks) VIEW=all ;;
    esac
}

edit_filters() {
    local new_user new_database new_host candidate_user="" candidate_database="" candidate_host=""
    printf 'User filter (empty clears): '
    IFS= read -r new_user || return 1
    printf 'Database filter (empty clears): '
    IFS= read -r new_database || return 1
    printf 'Host filter (empty clears): '
    IFS= read -r new_host || return 1
    if [[ -n "$new_user" ]]; then
        build_filter_list '--user-filter' "$new_user" || {
            printf 'Invalid filters; existing filters retained. %s\n' "$FILTER_ERROR"
            return 0
        }
        candidate_user="p.USER IN (${FILTER_SQL_LIST})"
    fi
    if [[ -n "$new_database" ]]; then
        build_filter_list '--database-filter' "$new_database" || {
            printf 'Invalid filters; existing filters retained. %s\n' "$FILTER_ERROR"
            return 0
        }
        candidate_database="p.DB IN (${FILTER_SQL_LIST})"
    fi
    if [[ -n "$new_host" ]]; then
        build_filter_list '--host-filter' "$new_host" || {
            printf 'Invalid filters; existing filters retained. %s\n' "$FILTER_ERROR"
            return 0
        }
        candidate_host="p.HOST IN (${FILTER_SQL_LIST})"
    fi
    USER_FILTER=$new_user
    DATABASE_FILTER=$new_database
    HOST_FILTER=$new_host
    USER_FILTER_SQL=$candidate_user
    DATABASE_FILTER_SQL=$candidate_database
    HOST_FILTER_SQL=$candidate_host
    rebuild_transaction_filters
    printf 'Filters updated.\n'
}

toggle_logging() {
    if [[ -z "$OUTPUT_FILE" ]]; then
        printf 'Logging requires --output-file.\n'
        return
    fi
    if [[ "$LOGGING_ENABLED" == true ]]; then
        LOGGING_ENABLED=false
        printf 'Snapshot logging paused.\n'
    else
        LOGGING_ENABLED=true
        printf 'Snapshot logging enabled: %s\n' "$OUTPUT_FILE"
    fi
}

kill_connection() {
    local connection_id own_connection confirmation target_sql
    printf 'Connection ID: '
    IFS= read -r connection_id || return 1
    if [[ ! "$connection_id" =~ ^[1-9][0-9]*$ ]]; then
        printf 'Invalid connection ID.\n'
        return 0
    fi
    if ! run_query 'SELECT /* trx-monitor:connection-id */ CONNECTION_ID();'; then
        printf 'Unable to resolve the monitor connection ID: %s\n' "$QUERY_ERROR" >&2
        return 0
    fi
    own_connection=${QUERY_OUTPUT%%$'\n'*}
    if [[ "$connection_id" == "$own_connection" ]]; then
        printf 'Refusing to kill the monitor connection.\n'
        return 0
    fi
    target_sql="SELECT /* trx-monitor:kill-target */ ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO
FROM information_schema.PROCESSLIST
WHERE ID = $connection_id;"
    if ! run_query "$target_sql"; then
        printf 'Unable to inspect connection %s: %s\n' "$connection_id" "$QUERY_ERROR" >&2
        return 0
    fi
    if [[ -z "$QUERY_OUTPUT" ]]; then
        printf 'Connection %s no longer exists.\n' "$connection_id"
        return 0
    fi
    printf 'Target connection:\nID\tUSER\tHOST\tDATABASE\tCOMMAND\tTIME_S\tSTATE\tQUERY\n%s\n' "$QUERY_OUTPUT"
    printf 'Type kill %s to confirm: ' "$connection_id"
    IFS= read -r confirmation || return 1
    if [[ "$confirmation" != "kill $connection_id" ]]; then
        printf 'Kill cancelled.\n'
        return 0
    fi
    if run_query "KILL CONNECTION $connection_id"; then
        printf '%sConnection %s killed.%s\n' "$COLOR_SUCCESS" "$connection_id" "$COLOR_RESET"
    else
        printf 'Unable to kill connection %s: %s\n' "$connection_id" "$QUERY_ERROR" >&2
    fi
}

interactive_loop() {
    local key
    render_and_publish
    while true; do
        if [[ "$PAUSED" == true ]]; then
            printf '\n[PAUSED] [v]iew [p]resume [f]ilters [l]og [k]ill [q]uit: '
            IFS= read -r -n 1 key || return 0
        else
            printf '\n[v]iew [p]ause [f]ilters [l]og [k]ill [q]uit: '
            if ! IFS= read -r -n 1 -t "$REFRESH_TIME" key; then
                printf '\n'
                render_and_publish
                continue
            fi
        fi
        printf '\n'
        case "$key" in
            q) return 0 ;;
            v) cycle_view; render_and_publish ;;
            p)
                if [[ "$PAUSED" == true ]]; then PAUSED=false; else PAUSED=true; fi
                ;;
            f) edit_filters; render_and_publish ;;
            l) toggle_logging ;;
            k) kill_connection; render_and_publish ;;
            *) printf 'Unknown command: %s\n' "$key" ;;
        esac
    done
}

main() {
    initialize_defaults
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi
    parse_arguments "$@"
    validate_arguments
    resolve_mysql_bin
    initialize_colors
    if [[ "$SMOKE_TEST" == true ]]; then
        render_and_publish
        return 0
    fi
    interactive_loop
}

main "$@"
