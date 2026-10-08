#!/usr/bin/env bash
# =============================================================================
# mongo_schema_normalizer.sh - betika_mongodb_normalized (bash implementation)
#
# Analyzes, compares and plans the centralization of MongoDB schemas across
# several instances. Collection runs through mongosh (lib/collector.js), the
# offline analysis through lib/analyzer.js (mongosh --nodb or node).
# Outputs are byte-identical to the Python implementation.
#
# Compatible with bash >= 3.2 (macOS default) and GNU/BSD userlands.
# =============================================================================
set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BMN_HOME="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly TEMPLATES_DIR="${BMN_HOME}/share/templates"
PROJECT_ROOT="${BMN_PROJECT_ROOT:-$(cd "${BMN_HOME}/.." && pwd -P)}"

# --- defaults -----------------------------------------------------------------
COMMAND="run"
CONF_DIR="${PROJECT_ROOT}/conf"
OUTPUT_DIR=""
SNAPSHOT_DIR=""
INSTANCES=""
TARGET=""
NAMING_STRATEGY="auto"
PREFIX_SEP="_"
MAPPING_FILE=""
SAMPLE_SIZE=100
MAX_DEPTH=5
INCLUDE_DBS=""
EXCLUDE_DBS=""
INCLUDE_SECURITY=0
PARALLEL=4
TIMEOUT=15
OP_TIMEOUT=120
CONNECT=0
ACTIVITY=1
OPLOG_WINDOW=0
OPLOG_TIMEOUT=600
ACTIVITY_SAMPLES=0
ACTIVITY_INTERVAL=10
MEMBER_STATS=0
MODIFIED_PATTERN="modif"
MODIFIED_SCAN=0
STALE_DAYS=180
VERBOSE=0
MONGOSH_BIN="${MONGOSH_BIN:-}"
TMP_DIR=""

readonly CONF_KEYS="INSTANCE_ALIAS MONGO_ROLE MONGO_URI MONGO_HOSTS MONGO_USER MONGO_AUTH_SOURCE MONGO_PASSWORD_ENV MONGO_PASSWORD_FILE MONGO_PASSWORD_CMD MONGO_PASSWORD MONGO_TLS MONGO_TLS_CA_FILE MONGO_TLS_CERT_KEY_FILE MONGO_TLS_ALLOW_INVALID_HOSTNAMES MONGO_READ_PREFERENCE"

# --- colors / logging ---------------------------------------------------------
setup_colors() {
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""
  fi
}
disable_colors() { RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""; export NO_COLOR=1; }
setup_colors

log_info()  { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*" >&2; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
log_debug() { [[ "${VERBOSE}" -eq 1 ]] && printf '%s[DBG ] %s%s\n' "${DIM}" "$*" "${RESET}" >&2 || true; }
log_title() { printf '%s==> %s%s\n' "${BOLD}${CYAN}" "$*" "${RESET}" >&2; }
die()       { log_error "$1"; exit "${2:-2}"; }

# --- help -----------------------------------------------------------------------
# Help goes to stdout, so its colors depend on stdout (logs use stderr).
help_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    H_TITLE=$'\033[1;36m'; H_OPT=$'\033[32m'; H_ARG=$'\033[33m'; H_REQ=$'\033[1;31m'
    H_DIM=$'\033[2m'; H_BOLD=$'\033[1m'; H_OFF=$'\033[0m'
  else
    H_TITLE=""; H_OPT=""; H_ARG=""; H_REQ=""; H_DIM=""; H_BOLD=""; H_OFF=""
  fi
}
h_section() {
  if [[ -n "${2:-}" ]]; then
    printf '\n%s%s%s  %s%s%s\n' "${H_TITLE}" "$1" "${H_OFF}" "${H_DIM}" "$2" "${H_OFF}"
  else
    printf '\n%s%s%s\n' "${H_TITLE}" "$1" "${H_OFF}"
  fi
}
h_req()     { printf '%s[required: %s]%s' "${H_REQ}" "$1" "${H_OFF}"; }
h_def()     { printf '%s(default: %s)%s' "${H_DIM}" "$1" "${H_OFF}"; }
h_optnl()   { printf '%s(optional)%s' "${H_DIM}" "${H_OFF}"; }
h_cmd() { # h_cmd <name> <description> [tag]
  if [[ -n "${3:-}" ]]; then
    printf '  %s%-9s%s %-50s %s\n' "${H_OPT}" "$1" "${H_OFF}" "$2" "$3"
  else
    printf '  %s%-9s%s %s\n' "${H_OPT}" "$1" "${H_OFF}" "$2"
  fi
}
h_opt() { # h_opt <flags> <arg> <description> <tag>
  local plain="$1${2:+ $2}" pad
  pad=$((31 - ${#plain}))
  [[ "${pad}" -lt 1 ]] && pad=1
  printf '  %s%s%s%s%s%s%s%*s' "${H_OPT}" "$1" "${H_OFF}" "${2:+ }" "${H_ARG}" "$2" "${H_OFF}" "${pad}" ""
  if [[ -n "${4:-}" ]]; then printf '%-50s %s\n' "$3" "$4"; else printf '%s\n' "$3"; fi
}

usage() {
  help_colors
  printf '%s%s%s v%s\n' "${H_BOLD}" "${SCRIPT_NAME}" "${H_OFF}" "${VERSION}"
  printf 'Analyze, compare and plan the centralization of MongoDB schemas across instances.\n'
  printf '%sRead-only on the instances: nothing is migrated; generated scripts default to dry-run.%s\n' "${H_DIM}" "${H_OFF}"

  h_section "USAGE"
  printf '  %s %s[COMMAND]%s %s[OPTIONS]%s\n' "${SCRIPT_NAME}" "${H_OPT}" "${H_OFF}" "${H_ARG}" "${H_OFF}"

  h_section "LEGEND"
  printf '  %s%-18s%s mandatory for the given command\n' "${H_REQ}" "[required: cmd]" "${H_OFF}"
  printf '  %s%-18s%s optional; this value is used when omitted\n' "${H_DIM}" "(default: value)" "${H_OFF}"
  printf '  %s%-18s%s optional; feature disabled when omitted\n' "${H_DIM}" "(optional)" "${H_OFF}"

  h_section "COMMANDS"
  h_cmd run     "Collect from every instance and analyze" "${H_DIM}(default command)${H_OFF}"
  h_cmd collect "Only collect snapshots into <output-dir>/snapshots"
  h_cmd analyze "Offline analysis of existing snapshots (no DB)" "$(h_req 'analyze') --snapshot-dir"
  h_cmd check   "Validate configuration files and secrets"

  h_section "GENERAL OPTIONS" "all commands"
  h_opt "-c, --conf-dir" "DIR" "Instance configuration directory (*.conf)" "$(h_def '<project_root>/conf')"
  h_opt "-i, --instances" "LIST" "Comma-separated instance names or aliases" "$(h_def 'all *.conf')"
  h_opt "-t, --target" "NAME" "Central (target) instance name or alias" "$(h_def 'conf with MONGO_ROLE=target')"
  h_opt "    --no-color" "" "Disable colored output" "$(h_optnl)"
  h_opt "-v, --verbose" "" "Verbose output" "$(h_optnl)"
  h_opt "-V, --version" "" "Show version and exit"
  h_opt "-h, --help" "" "Show this help and exit"

  h_section "OUTPUT OPTIONS" "run, collect, analyze"
  h_opt "-s, --snapshot-dir" "DIR" "Existing snapshot directory to analyze" "$(h_req 'analyze')"
  h_opt "-o, --output-dir" "DIR" "Output directory (analyze: snapshot parent)" "$(h_def '<project_root>/reports/<UTC ts>')"

  h_section "ANALYSIS OPTIONS" "run, analyze"
  h_opt "-n, --naming-strategy" "S" "Target database naming: auto | keep | prefix" "$(h_def 'auto')"
  h_opt "    --prefix-sep" "SEP" "Separator between alias and database" "$(h_def '_')"
  h_opt "-m, --mapping-file" "FILE" "Overrides <instance|alias>:<src_db>=<tgt_db>" "$(h_optnl)"

  h_section "COLLECTION OPTIONS" "run, collect  (--timeout also applies to check --connect)"
  h_opt "    --sample-size" "N" "Documents sampled per collection; 0 = no reads" "$(h_def '100')"
  h_opt "    --max-depth" "N" "Max nesting depth for field paths" "$(h_def '5')"
  h_opt "    --include-dbs" "REGEX" "Only databases matching REGEX" "$(h_optnl)"
  h_opt "    --exclude-dbs" "REGEX" "Skip databases matching REGEX" "$(h_optnl)"
  h_opt "    --include-security" "" "Collect users and custom roles" "$(h_optnl)"
  h_opt "-p, --parallel" "N" "Instances collected in parallel" "$(h_def '4')"
  h_opt "    --timeout" "SEC" "Connection timeout" "$(h_def '15')"
  h_opt "    --op-timeout" "SEC" "Per-operation maxTimeMS" "$(h_def '120')"

  h_section "ACTIVITY OPTIONS" "run, collect  (--stale-days: run, analyze)"
  h_opt "    --no-activity" "" "Skip _id and *modified* field dates" "$(h_optnl)"
  h_opt "    --modified-pattern" "REGEX" "Last-modification date fields (case-insens.)" "$(h_def 'modif')"
  h_opt "    --modified-scan" "" "Exact max of unindexed fields (COLLSCAN)" "$(h_optnl)"
  h_opt "    --stale-days" "N" "Flag collections idle for N days, 0 disables" "$(h_def '180')"
  h_opt "    --member-stats" "" "Per-member reads/writes since restart (top)" "$(h_optnl)"
  h_opt "    --oplog-window" "HOURS" "Analyze the last HOURS of oplog (writes, users)" "$(h_def '0 = disabled')"
  h_opt "    --oplog-timeout" "SEC" "maxTimeMS of the oplog aggregation" "$(h_def '600')"
  h_opt "    --activity-samples" "N" "Live \$currentOp sampling rounds" "$(h_def '0 = disabled')"
  h_opt "    --activity-interval" "SEC" "Seconds between sampling rounds" "$(h_def '10')"

  h_section "CHECK OPTIONS" "check"
  h_opt "    --connect" "" "Also test connectivity with every instance" "$(h_optnl)"

  h_section "NAMING STRATEGIES"
  printf '  %s%-7s%s keep the name; prefix <alias><sep><db> only when it conflicts\n' "${H_OPT}" auto "${H_OFF}"
  printf '  %s%-7s%s never rename (collisions are reported as blocking errors)\n' "${H_OPT}" keep "${H_OFF}"
  printf '  %s%-7s%s always prefix with the instance alias\n' "${H_OPT}" prefix "${H_OFF}"

  h_section "EXAMPLES"
  printf '  %s# validate configuration files and connectivity%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s check --connect\n' "${SCRIPT_NAME}"
  printf '  %s# preliminary report with low impact on the instances%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s run --sample-size 100 --op-timeout 30 --parallel 2\n' "${SCRIPT_NAME}"
  printf '  %s# metadata only: no document reads%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s run --sample-size 0 --parallel 1\n' "${SCRIPT_NAME}"
  printf '  %s# plan against the central instance, including users and roles%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s run --target central01 --include-security\n' "${SCRIPT_NAME}"
  printf '  %s# users to migrate: 24 h of oplog + 30 live samples (5 min)%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s run --include-security --oplog-window 24 --activity-samples 30 --activity-interval 10\n' "${SCRIPT_NAME}"
  printf '  %s# re-analyze existing snapshots with another strategy (no DB access)%s\n' "${H_DIM}" "${H_OFF}"
  printf '  %s analyze -s ./reports/20260930T101500Z/snapshots -n prefix\n' "${SCRIPT_NAME}"

  h_section "CONFIGURATION"
  printf '  run, collect and check need at least one *.conf in --conf-dir (KEY=VALUE, never sourced).\n'
  printf '  Template: %s\n' "${BMN_HOME}/conf.example/instance.conf.example"

  h_section "ENVIRONMENT"
  printf '  %s%-18s%s mongosh binary %s\n' "${H_ARG}" MONGOSH_BIN "${H_OFF}" "$(h_def 'from PATH')"
  printf '  %s%-18s%s analyzer runtime: mongosh | node %s\n' "${H_ARG}" BMN_JS_RUNTIME "${H_OFF}" "$(h_def 'mongosh')"
  printf '  %s%-18s%s project root %s\n' "${H_ARG}" BMN_PROJECT_ROOT "${H_OFF}" "$(h_def 'parent of betika_mongodb_normalized')"
  printf '  %s%-18s%s disable colors when set\n' "${H_ARG}" NO_COLOR "${H_OFF}"

  h_section "EXIT CODES"
  printf '  %s0%s ok   %s1%s blocking findings   %s2%s usage/config error   %s3%s collection errors\n' \
    "${H_OPT}" "${H_OFF}" "${H_REQ}" "${H_OFF}" "${H_REQ}" "${H_OFF}" "${H_REQ}" "${H_OFF}"
}

# --- helpers --------------------------------------------------------------------
cleanup() {
  local rc=$?
  local pid
  for pid in $(jobs -p 2>/dev/null); do kill "${pid}" 2>/dev/null || true; done
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  exit "${rc}"
}

require_int() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer (got '$2')"; }
utc_ts()  { date -u +%Y%m%dT%H%M%SZ; }
utc_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
trim()    { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s}"; }
sanitize_alias() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }
expand_home() { local p="$1"; [[ "${p}" == "~"* ]] && p="${HOME}${p#\~}"; printf '%s' "${p}"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"; }
group_other_access() { local m; m="$(file_mode "$1")"; [[ "${m}" != "?" && "${m: -2}" != "00" ]]; }
redact_uri() { printf '%s' "$1" | sed -E 's#(://)[^@/]+@#\1***@#'; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/ }"; s="${s//$'\r'/ }"; s="${s//$'\n'/ }"
  printf '%s' "${s}"
}

in_list() { # in_list <needle> <comma separated list>
  local needle="$1" item
  local IFS=','
  for item in $2; do [[ "$(trim "${item}")" == "${needle}" ]] && return 0; done
  return 1
}

# --- argument parsing -----------------------------------------------------------
parse_args() {
  local a
  for a in "$@"; do [[ "${a}" == "--no-color" ]] && disable_colors; done
  if [[ $# -gt 0 ]]; then
    case "$1" in
      run|collect|analyze|check) COMMAND="$1"; shift ;;
    esac
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--conf-dir) CONF_DIR="${2:?$1 requires a value}"; shift ;;
      -o|--output-dir) OUTPUT_DIR="${2:?$1 requires a value}"; shift ;;
      -s|--snapshot-dir) SNAPSHOT_DIR="${2:?$1 requires a value}"; shift ;;
      -i|--instances) INSTANCES="${2:?$1 requires a value}"; shift ;;
      -t|--target) TARGET="${2:?$1 requires a value}"; shift ;;
      -n|--naming-strategy) NAMING_STRATEGY="${2:?$1 requires a value}"; shift ;;
      --prefix-sep) PREFIX_SEP="${2?$1 requires a value}"; shift ;;
      -m|--mapping-file) MAPPING_FILE="${2:?$1 requires a value}"; shift ;;
      --sample-size) SAMPLE_SIZE="${2:?$1 requires a value}"; shift ;;
      --max-depth) MAX_DEPTH="${2:?$1 requires a value}"; shift ;;
      --include-dbs) INCLUDE_DBS="${2:?$1 requires a value}"; shift ;;
      --exclude-dbs) EXCLUDE_DBS="${2:?$1 requires a value}"; shift ;;
      --include-security) INCLUDE_SECURITY=1 ;;
      -p|--parallel) PARALLEL="${2:?$1 requires a value}"; shift ;;
      --timeout) TIMEOUT="${2:?$1 requires a value}"; shift ;;
      --op-timeout) OP_TIMEOUT="${2:?$1 requires a value}"; shift ;;
      --connect) CONNECT=1 ;;
      --no-activity) ACTIVITY=0 ;;
      --oplog-window) OPLOG_WINDOW="${2:?$1 requires a value}"; shift ;;
      --oplog-timeout) OPLOG_TIMEOUT="${2:?$1 requires a value}"; shift ;;
      --activity-samples) ACTIVITY_SAMPLES="${2:?$1 requires a value}"; shift ;;
      --activity-interval) ACTIVITY_INTERVAL="${2:?$1 requires a value}"; shift ;;
      --member-stats) MEMBER_STATS=1 ;;
      --modified-pattern) MODIFIED_PATTERN="${2?$1 requires a value}"; shift ;;
      --modified-scan) MODIFIED_SCAN=1 ;;
      --stale-days) STALE_DAYS="${2:?$1 requires a value}"; shift ;;
      --no-color) disable_colors ;;
      -v|--verbose) VERBOSE=1 ;;
      -V|--version) echo "betika_mongodb_normalized ${VERSION}"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "unknown argument: $1"
         printf "Run '%s%s --help%s' for usage.\n" "${BOLD}" "${SCRIPT_NAME}" "${RESET}" >&2; exit 2 ;;
    esac
    shift
  done
  case "${NAMING_STRATEGY}" in auto|keep|prefix) ;; *) die "--naming-strategy must be auto, keep or prefix" ;; esac
  require_int --sample-size "${SAMPLE_SIZE}"
  require_int --max-depth "${MAX_DEPTH}"
  require_int --parallel "${PARALLEL}"
  require_int --timeout "${TIMEOUT}"
  require_int --op-timeout "${OP_TIMEOUT}"
  require_int --oplog-window "${OPLOG_WINDOW}"
  require_int --oplog-timeout "${OPLOG_TIMEOUT}"
  require_int --activity-samples "${ACTIVITY_SAMPLES}"
  require_int --activity-interval "${ACTIVITY_INTERVAL}"
  require_int --stale-days "${STALE_DAYS}"
  if [[ "${ACTIVITY}" -eq 0 && ( "${OPLOG_WINDOW}" -gt 0 || "${ACTIVITY_SAMPLES}" -gt 0 \
        || "${MEMBER_STATS}" -eq 1 || "${MODIFIED_SCAN}" -eq 1 ) ]]; then
    die "--no-activity cannot be combined with other activity options"
  fi
  [[ "${PARALLEL}" -ge 1 ]] || PARALLEL=1
  [[ -z "${MAPPING_FILE}" || -r "${MAPPING_FILE}" ]] || die "mapping file not readable: ${MAPPING_FILE}"
}

# --- dependencies ---------------------------------------------------------------
resolve_mongosh() {
  [[ -n "${MONGOSH_BIN}" ]] || MONGOSH_BIN="$(command -v mongosh 2>/dev/null || true)"
  [[ -n "${MONGOSH_BIN}" && -x "${MONGOSH_BIN}" ]] || die "mongosh not found (install it or set MONGOSH_BIN)"
  log_debug "mongosh: ${MONGOSH_BIN}"
}

run_js() { # run_js <script> : mongosh --nodb or node for offline scripts
  local script="$1" runtime="${BMN_JS_RUNTIME:-}"
  if [[ -z "${runtime}" ]]; then
    if [[ -n "${MONGOSH_BIN}" ]] || command -v mongosh >/dev/null 2>&1; then runtime="mongosh"
    elif command -v node >/dev/null 2>&1; then runtime="node"
    else die "neither mongosh nor node found in PATH"; fi
  fi
  case "${runtime}" in
    mongosh) "${MONGOSH_BIN:-mongosh}" --nodb --quiet --norc --file "${script}" ;;
    node) node "${script}" ;;
    *) die "BMN_JS_RUNTIME must be mongosh or node" ;;
  esac
}

# --- configuration files ---------------------------------------------------------
conf_reset() {
  local k
  for k in ${CONF_KEYS}; do eval "CFG_${k}=''"; done
  CONF_WARNINGS=""
}
conf_warn() { CONF_WARNINGS="${CONF_WARNINGS}${1}"$'\n'; }
cfg() { eval "printf '%s' \"\${CFG_$1:-}\""; }

unquote_value() {
  local raw
  local re_dq='^"((\\.|[^"\\])*)"[[:space:]]*(#.*)?$'
  local re_sq="^'([^']*)'[[:space:]]*(#.*)?\$"
  raw="$(trim "$1")"
  if [[ "${raw}" =~ ${re_dq} ]]; then
    raw="$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/\\(["\\$`])/\1/g')"
  elif [[ "${raw}" =~ ${re_sq} ]]; then
    raw="${BASH_REMATCH[1]}"
  else
    raw="$(printf '%s' "${raw}" | sed -E 's/[[:space:]]+#.*$//')"
  fi
  printf '%s' "${raw}"
}

# conf_parse <file>: KEY=VALUE parser. The file is data: it is never sourced.
conf_parse() {
  local file="$1" line key raw value lineno=0
  local re='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  conf_reset
  CFG_NAME="$(basename "${file}" .conf)"
  CFG_FILE="${file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "${line}")"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    if ! [[ "${line}" =~ ${re} ]]; then
      conf_warn "line ${lineno}: not a KEY=VALUE assignment, ignored"; continue
    fi
    key="${BASH_REMATCH[2]}"; raw="${BASH_REMATCH[3]}"
    [[ "${key}" == "MONGOSHBINPATH" ]] && continue
    value="$(unquote_value "${raw}")"
    if [[ "${value}" == *'`'* || "${value}" == *'$('* ]]; then
      conf_warn "line ${lineno}: ${key} contains command substitution; ignored (never executed)"; continue
    fi
    case "${key}" in
      MONGOHOST) key="MONGO_HOSTS" ;;
      MONGOADMINUSR) key="MONGO_USER" ;;
      MONGOADMINPAS) key="MONGO_PASSWORD" ;;
      ADMINDB) key="MONGO_AUTH_SOURCE" ;;
    esac
    case " ${CONF_KEYS} " in
      *" ${key} "*) printf -v "CFG_${key}" '%s' "${value}" ;;
      *) conf_warn "line ${lineno}: unknown key ${key}" ;;
    esac
  done < "${file}"
  CFG_ALIAS="$(sanitize_alias "$(cfg INSTANCE_ALIAS)")"
  [[ -n "${CFG_ALIAS}" ]] || CFG_ALIAS="$(sanitize_alias "${CFG_NAME}")"
  CFG_ROLE="$(printf '%s' "$(cfg MONGO_ROLE)" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${CFG_ROLE}" ]] || CFG_ROLE="source"
  case "${CFG_ROLE}" in source|target) ;; *) die "${file}: MONGO_ROLE must be 'source' or 'target'" ;; esac
  if [[ -n "$(cfg MONGO_PASSWORD)" ]] && group_other_access "${file}"; then
    conf_warn "${file} holds a plaintext password and is readable by group/others (chmod 600)"
  fi
}

conf_base_uri() {
  local hosts
  if [[ -n "$(cfg MONGO_URI)" ]]; then cfg MONGO_URI; return 0; fi
  hosts="$(cfg MONGO_HOSTS)"
  [[ -n "${hosts}" ]] || return 1
  if [[ "${hosts}" == */* ]]; then
    printf 'mongodb://%s/?replicaSet=%s' "${hosts#*/}" "${hosts%%/*}"
  else
    printf 'mongodb://%s/' "${hosts}"
  fi
}

password_source() {
  local k
  for k in MONGO_PASSWORD_ENV MONGO_PASSWORD_FILE MONGO_PASSWORD_CMD MONGO_PASSWORD; do
    [[ -n "$(cfg "${k}")" ]] && { printf '%s' "${k}"; return 0; }
  done
  printf 'none'
}

# resolve_password: sets RESOLVED_PASSWORD, returns 1 (and sets CONF_ERROR) on failure.
resolve_password() {
  RESOLVED_PASSWORD=""; CONF_ERROR=""
  local var file cmd
  if [[ -n "$(cfg MONGO_PASSWORD_ENV)" ]]; then
    var="$(cfg MONGO_PASSWORD_ENV)"
    [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { CONF_ERROR="invalid MONGO_PASSWORD_ENV name"; return 1; }
    RESOLVED_PASSWORD="${!var:-}"
    [[ -n "${RESOLVED_PASSWORD}" ]] || { CONF_ERROR="environment variable ${var} is empty or not set"; return 1; }
  elif [[ -n "$(cfg MONGO_PASSWORD_FILE)" ]]; then
    file="$(expand_home "$(cfg MONGO_PASSWORD_FILE)")"
    [[ -r "${file}" ]] || { CONF_ERROR="password file ${file} not readable"; return 1; }
    group_other_access "${file}" && conf_warn "password file ${file} is accessible by group/others (chmod 600)"
    IFS= read -r RESOLVED_PASSWORD < "${file}" || true
    RESOLVED_PASSWORD="${RESOLVED_PASSWORD%$'\r'}"
  elif [[ -n "$(cfg MONGO_PASSWORD_CMD)" ]]; then
    cmd="$(cfg MONGO_PASSWORD_CMD)"
    if ! RESOLVED_PASSWORD="$(bash -c "${cmd}" | head -n 1)"; then
      CONF_ERROR="MONGO_PASSWORD_CMD failed"; return 1
    fi
  elif [[ -n "$(cfg MONGO_PASSWORD)" ]]; then
    conf_warn "plaintext password in config file; prefer MONGO_PASSWORD_ENV/_FILE/_CMD"
    RESOLVED_PASSWORD="$(cfg MONGO_PASSWORD)"
  elif [[ -n "$(cfg MONGO_USER)" ]]; then
    CONF_ERROR="MONGO_USER is set but no password source is configured"; return 1
  fi
  return 0
}

print_conf_warnings() {
  local w
  [[ -z "${CONF_WARNINGS}" ]] && return 0
  while IFS= read -r w; do
    if [[ -n "${w}" ]]; then log_warn "${CFG_NAME}: ${w}"; fi
  done <<<"${CONF_WARNINGS}"
  return 0
}

# discover_configs: fills CONF_FILES (selected) and resolves TARGET to an instance name.
discover_configs() {
  [[ -d "${CONF_DIR}" ]] || die "configuration directory not found: ${CONF_DIR}"
  local f names="" aliases="" role_targets="" matched=""
  CONF_FILES=()
  shopt -s nullglob
  local all=("${CONF_DIR}"/*.conf)
  shopt -u nullglob
  [[ ${#all[@]} -gt 0 ]] || die "no *.conf files found in ${CONF_DIR}"
  for f in "${all[@]}"; do
    conf_parse "${f}"
    if [[ -n "${INSTANCES}" ]]; then
      in_list "${CFG_NAME}" "${INSTANCES}" || in_list "${CFG_ALIAS}" "${INSTANCES}" || continue
      matched="${matched},${CFG_NAME},${CFG_ALIAS}"
    fi
    in_list "${CFG_ALIAS}" "${aliases}" && die "duplicate alias '${CFG_ALIAS}' (${f})"
    aliases="${aliases},${CFG_ALIAS}"
    names="${names},${CFG_NAME}"
    [[ "${CFG_ROLE}" == "target" ]] && role_targets="${role_targets},${CFG_NAME}"
    if [[ -n "${TARGET}" && ( "${TARGET}" == "${CFG_NAME}" || "${TARGET}" == "${CFG_ALIAS}" ) ]]; then
      TARGET="${CFG_NAME}"
    fi
    CONF_FILES+=("${f}")
  done
  if [[ -n "${INSTANCES}" ]]; then
    local item IFS=','
    for item in ${INSTANCES}; do
      item="$(trim "${item}")"
      [[ -z "${item}" ]] && continue
      in_list "${item}" "${matched}" || die "unknown instance: ${item}"
    done
    unset IFS
  fi
  [[ ${#CONF_FILES[@]} -gt 0 ]] || die "no instance selected"
  if [[ -n "${TARGET}" ]]; then
    in_list "${TARGET}" "${names}" || die "--target '${TARGET}' does not match any selected configuration"
  else
    local n
    n="$(printf '%s' "${role_targets}" | tr -cd ',' | wc -c | tr -d ' ')"
    [[ "${n}" -le 1 ]] || die "more than one config declares MONGO_ROLE=target; use --target"
  fi
}

effective_role() {
  if [[ -n "${TARGET}" ]]; then
    [[ "${CFG_NAME}" == "${TARGET}" ]] && echo "target" || echo "source"
  else
    echo "${CFG_ROLE}"
  fi
}

# --- commands ---------------------------------------------------------------------
write_error_snapshot() { # <file> <name> <alias> <role> <conf> <error>
  cat > "$1" <<EOF
{
  "tool": "betika_mongodb_normalized",
  "tool_version": "${VERSION}",
  "snapshot_format": 1,
  "collector": "bash",
  "instance": {"name": "$(json_escape "$2")", "alias": "$(json_escape "$3")", "role": "$4", "conf_file": "$(json_escape "$5")", "uri": ""},
  "collected_at": "$(utc_iso)",
  "status": "error",
  "error": "$(json_escape "$6")",
  "params": {"sample_size": ${SAMPLE_SIZE}, "max_depth": ${MAX_DEPTH}},
  "server": {},
  "databases": [],
  "database_listing": null,
  "security": null
}
EOF
}

# launch_collector <snapshot_file> <log_file> <mode>: background mongosh with a private env.
launch_collector() {
  local out="$1" log="$2" mode="$3" base_uri role
  base_uri="$(conf_base_uri || true)"
  role="$(effective_role)"
  (
    export BMN_MODE="${mode}" BMN_OUTPUT_FILE="${out}"
    export BMN_INSTANCE_NAME="${CFG_NAME}" BMN_INSTANCE_ALIAS="${CFG_ALIAS}" BMN_INSTANCE_ROLE="${role}"
    export BMN_CONF_FILE="${CFG_FILE}" BMN_BASE_URI="${base_uri}"
    export BMN_USER="$(cfg MONGO_USER)" BMN_PASSWORD="${RESOLVED_PASSWORD}"
    export BMN_AUTH_SOURCE="$(cfg MONGO_AUTH_SOURCE)" BMN_READ_PREFERENCE="$(cfg MONGO_READ_PREFERENCE)"
    export BMN_TLS="$(cfg MONGO_TLS)" BMN_TLS_CA_FILE="$(expand_home "$(cfg MONGO_TLS_CA_FILE)")"
    export BMN_TLS_CERT_KEY_FILE="$(expand_home "$(cfg MONGO_TLS_CERT_KEY_FILE)")"
    export BMN_TLS_ALLOW_INVALID_HOSTNAMES="$(cfg MONGO_TLS_ALLOW_INVALID_HOSTNAMES)"
    export BMN_TIMEOUT="${TIMEOUT}" BMN_OP_TIMEOUT="${OP_TIMEOUT}"
    export BMN_SAMPLE_SIZE="${SAMPLE_SIZE}" BMN_MAX_DEPTH="${MAX_DEPTH}"
    export BMN_INCLUDE_DBS="${INCLUDE_DBS}" BMN_EXCLUDE_DBS="${EXCLUDE_DBS}" BMN_INCLUDE_SECURITY="${INCLUDE_SECURITY}"
    export BMN_ACTIVITY="${ACTIVITY}" BMN_OPLOG_WINDOW="${OPLOG_WINDOW}" BMN_OPLOG_TIMEOUT="${OPLOG_TIMEOUT}"
    export BMN_ACTIVITY_SAMPLES="${ACTIVITY_SAMPLES}" BMN_ACTIVITY_INTERVAL="${ACTIVITY_INTERVAL}"
    export BMN_MEMBER_STATS="${MEMBER_STATS}" BMN_MODIFIED_PATTERN="${MODIFIED_PATTERN}" BMN_MODIFIED_SCAN="${MODIFIED_SCAN}"
    exec "${MONGOSH_BIN}" --nodb --quiet --norc --file "${LIB_DIR}/collector.js"
  ) >"${log}" 2>&1 &
  LAST_PID=$!
}

# finish_job <index>: waits for a collector and reports its outcome.
finish_job() {
  local i="$1" rc=0 err
  wait "${JOB_PIDS[$i]}" || rc=$?
  local name="${JOB_NAMES[$i]}" snap="${JOB_SNAPS[$i]}" log="${JOB_LOGS[$i]}"
  if [[ "${rc}" -eq 0 ]]; then
    log_ok "${name}: snapshot written ($(wc -c < "${snap}" | tr -d ' ') bytes)"
    return 0
  fi
  COLLECT_FAILURES=$((COLLECT_FAILURES + 1))
  if [[ ! -s "${snap}" ]]; then
    err="$(tail -n 3 "${log}" 2>/dev/null | tr '\n' ' ')"
    write_error_snapshot "${snap}" "${name}" "${JOB_ALIASES[$i]}" "${JOB_ROLES[$i]}" "${JOB_CONFS[$i]}" \
      "mongosh exited with code ${rc}: ${err:-no output}"
  fi
  err="$(sed -n 's/^  "error": "\(.*\)",$/\1/p' "${snap}" | head -n 1)"
  log_error "${name}: ${err:-collection failed (see ${log})}"
  [[ "${VERBOSE}" -eq 1 && -s "${log}" ]] && sed 's/^/    /' "${log}" >&2
  return 0
}

cmd_collect() {
  resolve_mongosh
  discover_configs
  local snap_dir="${OUTPUT_DIR}/snapshots" f i=0 next=0
  mkdir -p "${snap_dir}"
  chmod 700 "${OUTPUT_DIR}" 2>/dev/null || true
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bmn.XXXXXX")"
  log_title "collecting ${#CONF_FILES[@]} instance(s) -> ${snap_dir} (parallel=${PARALLEL})"
  JOB_PIDS=(); JOB_NAMES=(); JOB_ALIASES=(); JOB_ROLES=(); JOB_CONFS=(); JOB_SNAPS=(); JOB_LOGS=()
  COLLECT_FAILURES=0
  for f in "${CONF_FILES[@]}"; do
    conf_parse "${f}"
    local snap="${snap_dir}/${CFG_NAME}.json" log="${TMP_DIR}/${CFG_NAME}.log" role
    role="$(effective_role)"
    if ! resolve_password; then
      print_conf_warnings
      log_error "${CFG_NAME}: ${CONF_ERROR}"
      write_error_snapshot "${snap}" "${CFG_NAME}" "${CFG_ALIAS}" "${role}" "${f}" "${CONF_ERROR}"
      COLLECT_FAILURES=$((COLLECT_FAILURES + 1))
      continue
    fi
    if ! conf_base_uri >/dev/null; then
      log_error "${CFG_NAME}: MONGO_URI or MONGO_HOSTS (legacy MONGOHOST) is required"
      write_error_snapshot "${snap}" "${CFG_NAME}" "${CFG_ALIAS}" "${role}" "${f}" "missing MONGO_URI/MONGO_HOSTS"
      COLLECT_FAILURES=$((COLLECT_FAILURES + 1))
      continue
    fi
    print_conf_warnings
    rm -f "${snap}"
    log_info "${CFG_NAME} (alias=${CFG_ALIAS}, role=${role}): collecting..."
    launch_collector "${snap}" "${log}" collect
    RESOLVED_PASSWORD=""
    JOB_PIDS[i]="${LAST_PID}"; JOB_NAMES[i]="${CFG_NAME}"; JOB_ALIASES[i]="${CFG_ALIAS}"
    JOB_ROLES[i]="${role}"; JOB_CONFS[i]="${f}"; JOB_SNAPS[i]="${snap}"; JOB_LOGS[i]="${log}"
    i=$((i + 1))
    if [[ $((i - next)) -ge "${PARALLEL}" ]]; then
      finish_job "${next}"; next=$((next + 1))
    fi
  done
  while [[ "${next}" -lt "${i}" ]]; do
    finish_job "${next}"; next=$((next + 1))
  done
  [[ "${COLLECT_FAILURES}" -eq 0 ]] && return 0 || return 3
}

cmd_analyze() {
  local snap_dir="$1" out_dir="$2"
  [[ -d "${snap_dir}" ]] || die "snapshot directory not found: ${snap_dir}"
  [[ -f "${LIB_DIR}/analyzer.js" ]] || die "missing ${LIB_DIR}/analyzer.js"
  [[ -n "${MONGOSH_BIN}" ]] || MONGOSH_BIN="$(command -v mongosh 2>/dev/null || true)"
  mkdir -p "${out_dir}"
  log_title "analyzing snapshots from ${snap_dir}"
  local rc=0
  BMN_SNAPSHOT_DIR="${snap_dir}" BMN_OUTPUT_DIR="${out_dir}" BMN_TEMPLATES_DIR="${TEMPLATES_DIR}" \
  BMN_NAMING_STRATEGY="${NAMING_STRATEGY}" BMN_PREFIX_SEP="${PREFIX_SEP}" BMN_TARGET="${TARGET}" \
  BMN_MAPPING_FILE="${MAPPING_FILE}" BMN_GENERATED_AT="${BMN_GENERATED_AT:-$(utc_iso)}" \
  BMN_IMPLEMENTATION="${BMN_IMPLEMENTATION:-bash}" BMN_STALE_DAYS="${STALE_DAYS}" \
    run_js "${LIB_DIR}/analyzer.js" || rc=$?
  return "${rc}"
}

cmd_check() {
  discover_configs
  [[ "${CONNECT}" -eq 1 ]] && resolve_mongosh
  local f failures=0 base
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bmn.XXXXXX")"
  for f in "${CONF_FILES[@]}"; do
    conf_parse "${f}"
    log_title "${CFG_NAME} (alias=${CFG_ALIAS}, role=$(effective_role))"
    if ! base="$(conf_base_uri)"; then
      log_error "MONGO_URI or MONGO_HOSTS (legacy MONGOHOST) is required"
      failures=$((failures + 1)); continue
    fi
    log_info "uri: $(redact_uri "${base}")"
    log_info "user: $(cfg MONGO_USER | sed 's/^$/(no auth)/') | password source: $(password_source)"
    if ! resolve_password; then
      print_conf_warnings; log_error "${CONF_ERROR}"; failures=$((failures + 1)); continue
    fi
    if [[ "${CONNECT}" -eq 1 ]]; then
      local log="${TMP_DIR}/${CFG_NAME}.ping" rc=0
      launch_collector "/dev/null" "${log}" ping
      wait "${LAST_PID}" || rc=$?
      if [[ "${rc}" -eq 0 ]]; then log_ok "connected, $(tail -n 1 "${log}")"
      else log_error "connection failed: $(tail -n 1 "${log}")"; failures=$((failures + 1)); fi
    fi
    RESOLVED_PASSWORD=""
    print_conf_warnings
  done
  [[ "${failures}" -eq 0 ]] && return 0 || return 2
}

main() {
  trap cleanup EXIT
  trap 'log_error "interrupted"; exit 130' INT TERM
  parse_args "$@"
  umask 077
  case "${COMMAND}" in
    check) cmd_check; exit $? ;;
    analyze)
      [[ -n "${SNAPSHOT_DIR}" ]] || die "analyze requires --snapshot-dir"
      [[ -n "${OUTPUT_DIR}" ]] || OUTPUT_DIR="$(cd "${SNAPSHOT_DIR}/.." && pwd -P)"
      local rc=0; cmd_analyze "${SNAPSHOT_DIR}" "${OUTPUT_DIR}" || rc=$?; exit "${rc}" ;;
    collect|run)
      [[ -n "${OUTPUT_DIR}" ]] || OUTPUT_DIR="${PROJECT_ROOT}/reports/$(utc_ts)"
      local rc_c=0 rc_a=0
      cmd_collect || rc_c=$?
      if [[ "${COMMAND}" == "collect" ]]; then
        log_info "snapshots written to ${OUTPUT_DIR}/snapshots"; exit "${rc_c}"
      fi
      cmd_analyze "${OUTPUT_DIR}/snapshots" "${OUTPUT_DIR}" || rc_a=$?
      [[ "${rc_a}" -ne 0 ]] && exit "${rc_a}"
      exit "${rc_c}" ;;
  esac
}

main "$@"
