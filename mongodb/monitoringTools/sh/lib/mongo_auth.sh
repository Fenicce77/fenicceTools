# shellcheck shell=bash
# =============================================================================
# mongo_auth.sh - credential resolution and safe mongosh invocation for the
# monitoringTools bash scripts. Sourced (not executed) after the config file.
#
# Password sources (first one defined wins):
#   MONGOADMINPAS_ENV   name of an environment variable holding the password
#   MONGOADMINPAS_FILE  file whose first line is the password (chmod 600)
#   MONGOADMINPAS_CMD   command printing the password (Keychain, pass, vault...)
#   MONGOADMINPAS       plaintext password (legacy, still accepted, warned)
#
# The password is never placed on a command line: mongosh receives it through
# the MT_MONGO_PASSWORD environment variable, which the JS prelude reads and
# removes before running the script (ps/proc cmdline only show the host list).
# =============================================================================

MT_C_RED=$'\033[91m'
MT_C_YEL=$'\033[93m'
MT_C_RST=$'\033[0m'

mt_die() { printf '%sError: %s%s\n' "${MT_C_RED}" "$*" "${MT_C_RST}" >&2; exit 2; }
mt_warn() { printf '%sWarning: %s%s\n' "${MT_C_YEL}" "$*" "${MT_C_RST}" >&2; }

mt_expand_home() {
    local p="$1"
    if [[ "${p}" == "~" || "${p}" == "~/"* ]]; then p="${HOME}${p:1}"; fi
    printf '%s' "${p}"
}

# True when group/others have any permission on the file (GNU and BSD stat).
mt_group_other_access() {
    local mode
    mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo 600)"
    (( (8#${mode} & 8#077) != 0 ))
}

# mt_resolve_password: sets MT_PASSWORD from the configured source (exit 2 on error).
mt_resolve_password() {
    MT_PASSWORD=""
    local var file cmd
    if [[ -n "${MONGOADMINPAS_ENV:-}" ]]; then
        var="${MONGOADMINPAS_ENV}"
        [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || mt_die "invalid MONGOADMINPAS_ENV name '${var}'"
        MT_PASSWORD="${!var:-}"
        [[ -n "${MT_PASSWORD}" ]] || mt_die "environment variable ${var} (MONGOADMINPAS_ENV) is empty or not set"
    elif [[ -n "${MONGOADMINPAS_FILE:-}" ]]; then
        file="$(mt_expand_home "${MONGOADMINPAS_FILE}")"
        [[ -r "${file}" ]] || mt_die "password file ${file} (MONGOADMINPAS_FILE) is not readable"
        if mt_group_other_access "${file}"; then
            mt_warn "password file ${file} is accessible by group/others (chmod 600 ${file})"
        fi
        IFS= read -r MT_PASSWORD < "${file}" || true
        MT_PASSWORD="${MT_PASSWORD%$'\r'}"
        [[ -n "${MT_PASSWORD}" ]] || mt_die "password file ${file} is empty"
    elif [[ -n "${MONGOADMINPAS_CMD:-}" ]]; then
        cmd="${MONGOADMINPAS_CMD}"
        MT_PASSWORD="$(bash -c "${cmd}" | head -n 1)" || mt_die "MONGOADMINPAS_CMD failed"
        [[ -n "${MT_PASSWORD}" ]] || mt_die "MONGOADMINPAS_CMD returned an empty password"
    elif [[ -n "${MONGOADMINPAS:-}" ]]; then
        if [[ -z "${MT_QUIET_PLAINTEXT_WARNING:-}" ]]; then
            mt_warn "plaintext MONGOADMINPAS in config; prefer MONGOADMINPAS_ENV/_FILE/_CMD"
        fi
        MT_PASSWORD="${MONGOADMINPAS}"
    elif [[ -n "${MONGOADMINUSR:-}" ]]; then
        mt_die "MONGOADMINUSR is set but no password source is configured (MONGOADMINPAS_ENV/_FILE/_CMD)"
    fi
}

# mt_check_config: validates the connection settings and resolves the password.
mt_check_config() {
    [[ -n "${MONGOHOST:-}" ]] || mt_die "MONGOHOST is not defined in the config file"
    MONGOSHBINPATH="${MONGOSHBINPATH:-$(command -v mongosh || true)}"
    [[ -n "${MONGOSHBINPATH}" && -x "${MONGOSHBINPATH}" ]] || mt_die "mongosh not found (set MONGOSHBINPATH in the config file)"
    ADMINDB="${ADMINDB:-admin}"
    mt_resolve_password
}

# mt_js_prelude: JS that connects using MT_* environment variables and sets `db`.
# MONGOHOST accepts "rsName/node1,node2" (replica set) or "host[:port][,host...]".
mt_js_prelude() {
    cat <<'JS'
const MT_DB = (() => {
  const e = process.env;
  const pwd = e.MT_MONGO_PASSWORD || '';
  delete process.env.MT_MONGO_PASSWORD;
  const host = e.MT_MONGO_HOST || '';
  const slash = host.indexOf('/');
  const nodes = slash >= 0 ? host.slice(slash + 1) : host;
  const params = [];
  if (slash >= 0) params.push(`replicaSet=${encodeURIComponent(host.slice(0, slash))}`);
  let creds = '';
  if (e.MT_MONGO_USER) {
    creds = `${encodeURIComponent(e.MT_MONGO_USER)}:${encodeURIComponent(pwd)}@`;
    params.push(`authSource=${encodeURIComponent(e.MT_MONGO_AUTHDB || 'admin')}`);
  }
  return connect(`mongodb://${creds}${nodes}/admin${params.length ? '?' + params.join('&') : ''}`);
})();
db = MT_DB;
JS
}

# mt_mongosh <mongosh args...>: runs mongosh --nodb with the credentials in the
# environment of that single process only. Bash prefix assignments are used on
# purpose: `env VAR=value cmd` would expose the value in env's own argv.
mt_mongosh() {
    NODE_NO_WARNINGS=1 NO_UPDATE_NOTIFIER=true DISABLE_UPDATE_NOTIFIER=true \
        MT_MONGO_HOST="${MONGOHOST}" MT_MONGO_USER="${MONGOADMINUSR:-}" \
        MT_MONGO_AUTHDB="${ADMINDB}" MT_MONGO_PASSWORD="${MT_PASSWORD}" \
        "${MONGOSHBINPATH}" --nodb "$@"
}
