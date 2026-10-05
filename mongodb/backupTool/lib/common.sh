# shellcheck shell=bash
#
# common.sh - Shared helpers for pbm-backup: logging, configuration,
# dependency checks, locking and portable (GNU/BSD) date handling.
#
# This file is sourced, never executed. It must stay compatible with
# bash 3.2 (macOS /bin/bash): no associative arrays, no ${var,,}, no mapfile.

# ---------------------------------------------------------------------------
# Colors (only when stdout is a TTY, unless forced)
# ---------------------------------------------------------------------------
C_RED='' C_GRN='' C_YEL='' C_BLU='' C_BLD='' C_OFF=''

setup_colors() {
    local mode=${PBM_BACKUP_COLOR:-auto}
    if [[ $mode == always ]] || { [[ $mode == auto ]] && [[ -t 1 ]] && [[ -z ${NO_COLOR:-} ]]; }; then
        C_RED=$'\033[31m'
        C_GRN=$'\033[32m'
        C_YEL=$'\033[33m'
        C_BLU=$'\033[34m'
        C_BLD=$'\033[1m'
        C_OFF=$'\033[0m'
    else
        C_RED='' C_GRN='' C_YEL='' C_BLU='' C_BLD='' C_OFF=''
    fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# log LEVEL LABEL MESSAGE...
#   LEVEL: OK | INFO | WARN | ERROR
#   LABEL: bracketed tag chain, e.g. "[PSMB][BACKUP][INCREMENTAL][INIT]"
# Output format (kept from the original scripts so existing greps still work):
#   [YYYY-mm-dd HH:MM:SS][LABEL...][LEVEL] message
# The timestamp is taken when the line is written, not when the script starts.
# Colored output goes to the terminal; the log file always gets plain text.
log() {
    local level=$1 label=$2
    shift 2
    local ts color line
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        OK)    color=$C_GRN ;;
        INFO)  color=$C_BLU ;;
        WARN)  color=$C_YEL ;;
        ERROR) color=$C_RED ;;
        *)     color='' ;;
    esac
    line="[${ts}]${label}[${level}] $*"
    if [[ $level == ERROR ]]; then
        printf '%s%s%s\n' "$color" "$line" "$C_OFF" >&2
    else
        printf '%s%s%s\n' "$color" "$line" "$C_OFF"
    fi
    if [[ -n ${LOG_FILE:-} ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

# die MESSAGE [EXIT_CODE] - log an error and exit (default exit code 1).
die() {
    log ERROR "${LOG_LABEL:-[PBM-BACKUP]}" "$1"
    exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# load_config
#   1. PBM_BACKUP_CONF (default /etc/sysconfig/pbm-backup): tunables, optional.
#   2. PBM_ENV_FILE    (default /etc/sysconfig/pbm-conf): PBM_MONGODB_URI.
#      Always sourced when readable, as the original scripts did.
#   3. Defaults for anything still unset.
load_config() {
    local conf=${PBM_BACKUP_CONF:-/etc/sysconfig/pbm-backup}
    local envf=${PBM_ENV_FILE:-/etc/sysconfig/pbm-conf}

    if [[ -r $conf ]]; then
        # shellcheck disable=SC1090
        . "$conf"
    fi
    if [[ -r $envf ]]; then
        # shellcheck disable=SC1090
        . "$envf"
    fi

    : "${PBM_LOCAL_ROOT:=/data/backup/pbm}"
    : "${LOG_DIR:=${PBM_LOCAL_ROOT}/logs}"
    : "${RETENTION_DAYS:=7}"
    : "${WAIT_RUNNING_SEC:=1800}"
    : "${WAIT_POLL_SEC:=30}"
    : "${DEDUP_WINDOW_SEC:=600}"
    : "${LOCAL_NODE_NAMES:=}"
    : "${LOCK_DIR:=}"
    : "${PBM_BIN:=}"
    : "${MONGO_SHELL:=}"

    # Phase 2: detection / strategy
    : "${BACKUP_MODE:=auto}"
    : "${MONGODB_VERSION:=}"
    : "${MONGODB_EDITION:=}"

    # Phase 3: node election
    : "${PREFERRED_NODES:=}"
    : "${ALLOW_PRIMARY:=false}"
    : "${MAX_REPL_LAG_SEC:=60}"
    : "${MAX_QUEUE:=50}"
    : "${MAX_WT_DIRTY_PCT:=20}"
    : "${FALLBACK_DELAY_SEC:=120}"
    : "${PROBE_TIMEOUT_MS:=5000}"

    # Phase 4: logical scheme (Community)
    : "${OPLOG_INCR_MIN:=360}"
    : "${PITR_AUTOCONFIG:=true}"
    : "${PITR_LAG_MARGIN_SEC:=900}"
    : "${OPLOG_WINDOW_FACTOR:=2}"
    : "${OPLOG_WINDOW_ENFORCE:=true}"
    : "${EXPECTED_DUMP_SEC:=}"

    # Storage and compression (all schemes): always a bucket, always compressed
    : "${REQUIRED_STORAGE_TYPES:=GCS}"
    : "${BACKUP_COMPRESSION:=gzip}"
    : "${BACKUP_COMPRESSION_LEVEL=5}"   # empty = PBM default level
}

# validate_config - fail early on malformed tunables.
validate_config() {
    local v
    for v in RETENTION_DAYS WAIT_RUNNING_SEC WAIT_POLL_SEC DEDUP_WINDOW_SEC \
             MAX_REPL_LAG_SEC MAX_QUEUE MAX_WT_DIRTY_PCT FALLBACK_DELAY_SEC PROBE_TIMEOUT_MS \
             OPLOG_INCR_MIN PITR_LAG_MARGIN_SEC OPLOG_WINDOW_FACTOR; do
        is_uint "${!v}" || die "${v} must be a non-negative integer (got '${!v}')" 2
    done
    if [[ -n $EXPECTED_DUMP_SEC ]] && ! is_uint "$EXPECTED_DUMP_SEC"; then
        die "EXPECTED_DUMP_SEC must be empty or a non-negative integer (got '${EXPECTED_DUMP_SEC}')" 2
    fi
    (( OPLOG_INCR_MIN >= 1 )) || die "OPLOG_INCR_MIN must be >= 1" 2
    case $BACKUP_COMPRESSION in
        s2|gzip|pgzip|snappy|lz4|zstd) ;;
        *) die "BACKUP_COMPRESSION must be one of s2 gzip pgzip snappy lz4 zstd; 'none' is not allowed (got '${BACKUP_COMPRESSION}')" 2 ;;
    esac
    if [[ -n $BACKUP_COMPRESSION_LEVEL ]] && ! is_uint "$BACKUP_COMPRESSION_LEVEL"; then
        die "BACKUP_COMPRESSION_LEVEL must be empty or a non-negative integer (got '${BACKUP_COMPRESSION_LEVEL}')" 2
    fi
    [[ -n $REQUIRED_STORAGE_TYPES ]] || die "REQUIRED_STORAGE_TYPES must not be empty" 2
    for v in PITR_AUTOCONFIG OPLOG_WINDOW_ENFORCE; do
        case ${!v} in
            true|false) ;;
            *) die "${v} must be true or false (got '${!v}')" 2 ;;
        esac
    done
    case $BACKUP_MODE in
        auto|physical|logical) ;;
        *) die "BACKUP_MODE must be auto, physical or logical (got '${BACKUP_MODE}')" 2 ;;
    esac
    case $ALLOW_PRIMARY in
        true|false) ;;
        *) die "ALLOW_PRIMARY must be true or false (got '${ALLOW_PRIMARY}')" 2 ;;
    esac
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# require_cmd NAME [VAR] - fail if NAME is not in PATH; optionally store its
# absolute path in VAR (unless VAR is already set to an executable).
require_cmd() {
    local name=$1 var=${2:-} path
    if [[ -n $var ]]; then
        path=${!var:-}
        if [[ -n $path && -x $path ]]; then
            return 0
        fi
    fi
    path=$(command -v "$name" 2>/dev/null) || die "Required command not found in PATH: ${name}" 2
    if [[ -n $var ]]; then
        printf -v "$var" '%s' "$path"
    fi
}

# is_uint VALUE - true when VALUE is a non-negative integer.
is_uint() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Portable date helpers (GNU coreutils vs BSD/macOS)
# ---------------------------------------------------------------------------
_date_is_gnu() {
    date --version >/dev/null 2>&1
}

# date_days_ago N - print the date N days ago as YYYY-MM-DD.
date_days_ago() {
    if _date_is_gnu; then
        date -d "-$1 day" '+%Y-%m-%d'
    else
        date -v "-$1d" '+%Y-%m-%d'
    fi
}

# now_epoch - current UNIX time in seconds.
now_epoch() {
    date '+%s'
}

# ---------------------------------------------------------------------------
# Locking (one run per command and node at a time)
# ---------------------------------------------------------------------------
# acquire_lock NAME - returns 1 if another run of NAME holds the lock.
# Uses flock(1) when available (Linux), otherwise an atomic mkdir lock with
# stale-PID detection (macOS). The lock is released on exit.
_LOCK_MKDIR_PATH=''

_release_lock() {
    if [[ -n $_LOCK_MKDIR_PATH ]]; then
        rm -rf "$_LOCK_MKDIR_PATH" 2>/dev/null || true
    fi
}

acquire_lock() {
    local name=$1 dir=${LOCK_DIR:-}
    if [[ -z $dir ]]; then
        if [[ -d /run/lock && -w /run/lock ]]; then
            dir=/run/lock
        else
            dir=${TMPDIR:-/tmp}
        fi
    fi
    dir=${dir%/}
    local path="${dir}/pbm-backup-${name}.lock"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$path" || return 1
        flock -n 9 || return 1
        return 0
    fi

    local pid
    if ! mkdir "${path}.d" 2>/dev/null; then
        pid=$(cat "${path}.d/pid" 2>/dev/null || true)
        if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        # Stale lock left by a dead process: take it over.
        rm -rf "${path}.d"
        mkdir "${path}.d" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" >"${path}.d/pid"
    _LOCK_MKDIR_PATH="${path}.d"
    trap _release_lock EXIT
}
