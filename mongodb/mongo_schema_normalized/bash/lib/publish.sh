# shellcheck shell=bash
# =============================================================================
# publish.sh - Jira / Confluence Data Center publisher (sourced by mongo_schema_normalizer.sh)
#
# Mirror of python/bmn/publish.py. HTTP through curl; the token travels in a
# private header file (-H @file, mode 600), never on the command line. JSON is
# built and parsed by lib/atlassian.js (mongosh --nodb or node): no jq needed.
# Requires the helpers of the main script: log_*, die, run_js, trim,
# unquote_value, expand_home, group_other_access, TMP_DIR.
# =============================================================================

readonly ATL_KEYS="JIRA_URL JIRA_USER JIRA_TOKEN_ENV JIRA_TOKEN_FILE JIRA_TOKEN_CMD JIRA_TOKEN JIRA_PROJECT JIRA_ISSUE_TYPE JIRA_ISSUE JIRA_SUMMARY JIRA_LABELS JIRA_COMPONENTS JIRA_ATTACH JIRA_COMMENT_VISIBILITY CONFLUENCE_URL CONFLUENCE_USER CONFLUENCE_TOKEN_ENV CONFLUENCE_TOKEN_FILE CONFLUENCE_TOKEN_CMD CONFLUENCE_TOKEN CONFLUENCE_SPACE CONFLUENCE_PARENT_ID CONFLUENCE_TITLE ATLASSIAN_CA_FILE ATLASSIAN_TIMEOUT"
readonly ATL_DEFAULT_ATTACHMENTS="report.md,centralization_plan.md,analysis.json"
readonly ATL_DEFAULT_TITLE="MongoDB schema centralization analysis"
ATL_WARNINGS=""
ATL_ERROR=""

atl() { eval "printf '%s' \"\${ATL_$1:-}\""; }
atl_warn() { ATL_WARNINGS="${ATL_WARNINGS}${1}"$'\n'; }

# atl_conf_parse <file>: KEY=VALUE parser (data only, never sourced).
atl_conf_parse() {
  local file="$1" line key raw value lineno=0 k
  local re='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  for k in ${ATL_KEYS}; do eval "ATL_${k}=''"; done
  ATL_CONF_FILE="${file}"
  [[ -f "${file}" ]] || return 0
  group_other_access "${file}" && atl_warn "${file} is accessible by group/others (chmod 600)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "${line}")"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    if ! [[ "${line}" =~ ${re} ]]; then
      atl_warn "$(basename "${file}"):${lineno}: not a KEY=VALUE assignment, ignored"; continue
    fi
    key="${BASH_REMATCH[2]}"; raw="${BASH_REMATCH[3]}"
    value="$(unquote_value "${raw}")"
    if [[ "${value}" == *'`'* || "${value}" == *'$('* ]]; then
      atl_warn "$(basename "${file}"):${lineno}: ${key} contains command substitution; ignored"; continue
    fi
    case " ${ATL_KEYS} " in
      *" ${key} "*) printf -v "ATL_${key}" '%s' "${value}" ;;
      *) atl_warn "$(basename "${file}"):${lineno}: unknown key ${key}" ;;
    esac
  done < "${file}"
  return 0
}

# atl_token <JIRA|CONFLUENCE>: sets ATL_TOKEN_VALUE; returns 1 with ATL_ERROR on failure.
atl_token() {
  local p="$1" var file cmd
  ATL_TOKEN_VALUE=""
  if [[ -n "$(atl "${p}_TOKEN_ENV")" ]]; then
    var="$(atl "${p}_TOKEN_ENV")"
    [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { ATL_ERROR="invalid ${p}_TOKEN_ENV name"; return 1; }
    ATL_TOKEN_VALUE="${!var:-}"
    [[ -n "${ATL_TOKEN_VALUE}" ]] || { ATL_ERROR="${p}_TOKEN_ENV: environment variable ${var} is empty or not set"; return 1; }
  elif [[ -n "$(atl "${p}_TOKEN_FILE")" ]]; then
    file="$(expand_home "$(atl "${p}_TOKEN_FILE")")"
    [[ -f "${file}" ]] || { ATL_ERROR="${p}_TOKEN_FILE: ${file} not found"; return 1; }
    group_other_access "${file}" && atl_warn "token file ${file} is accessible by group/others (chmod 600)"
    IFS= read -r ATL_TOKEN_VALUE < "${file}" || true
    ATL_TOKEN_VALUE="$(trim "${ATL_TOKEN_VALUE%$'\r'}")"
  elif [[ -n "$(atl "${p}_TOKEN_CMD")" ]]; then
    cmd="$(atl "${p}_TOKEN_CMD")"
    if ! ATL_TOKEN_VALUE="$(bash -c "${cmd}" | head -n 1)"; then
      ATL_ERROR="${p}_TOKEN_CMD failed"; return 1
    fi
    ATL_TOKEN_VALUE="$(trim "${ATL_TOKEN_VALUE}")"
  elif [[ -n "$(atl "${p}_TOKEN")" ]]; then
    atl_warn "plaintext ${p}_TOKEN in ${ATL_CONF_FILE}; prefer ${p}_TOKEN_ENV/_FILE/_CMD"
    ATL_TOKEN_VALUE="$(atl "${p}_TOKEN")"
  else
    ATL_ERROR="no ${p} token configured (${p}_TOKEN_ENV, ${p}_TOKEN_FILE or ${p}_TOKEN_CMD)"; return 1
  fi
  return 0
}

# atl_session <JIRA|CONFLUENCE>: prepares ATL_BASE and the private header file ATL_HDR.
atl_session() {
  local p="$1" user auth
  ATL_BASE="$(atl "${p}_URL")"; ATL_BASE="${ATL_BASE%/}"
  atl_token "${p}" || return 1
  user="$(atl "${p}_USER")"
  if [[ -n "${user}" ]]; then
    auth="Basic $(printf '%s:%s' "${user}" "${ATL_TOKEN_VALUE}" | base64 | tr -d '\n')"
  else
    auth="Bearer ${ATL_TOKEN_VALUE}"
  fi
  ATL_HDR="${TMP_DIR}/atl_${p}.hdr"
  ( umask 077; printf 'Authorization: %s\n' "${auth}" > "${ATL_HDR}" )
  ATL_TOKEN_VALUE=""
  return 0
}

# atl_http <method> <path> [json-body-file]: sets ATL_CODE and ATL_RESP (response file).
atl_http() {
  local method="$1" path="$2" body="${3:-}" timeout ca err
  timeout="$(atl ATLASSIAN_TIMEOUT)"; timeout="${timeout:-60}"
  ca="$(expand_home "$(atl ATLASSIAN_CA_FILE)")"
  ATL_RESP="${TMP_DIR}/atl_resp.json"
  : > "${ATL_RESP}"
  local -a args=(-sS -o "${ATL_RESP}" -w '%{http_code}' --max-time "${timeout}" -X "${method}"
    -H @"${ATL_HDR}" -H 'Accept: application/json' -H "User-Agent: betika_mongodb_normalized/${VERSION}")
  [[ -n "${ca}" ]] && args+=(--cacert "${ca}")
  [[ -n "${body}" ]] && args+=(-H 'Content-Type: application/json' --data-binary @"${body}")
  if ! ATL_CODE="$(curl "${args[@]}" "${ATL_BASE}${path}" 2>"${TMP_DIR}/atl_curl.err")"; then
    err="$(tr '\n' ' ' < "${TMP_DIR}/atl_curl.err")"
    ATL_ERROR="${method} ${ATL_BASE}${path}: ${err:-curl failed}"
    return 1
  fi
  return 0
}

atl_attach() { # atl_attach <path> <file>
  local path="$1" file="$2" timeout ca
  timeout="$(atl ATLASSIAN_TIMEOUT)"; timeout="${timeout:-60}"
  ca="$(expand_home "$(atl ATLASSIAN_CA_FILE)")"
  ATL_RESP="${TMP_DIR}/atl_resp.json"
  local -a args=(-sS -o "${ATL_RESP}" -w '%{http_code}' --max-time "${timeout}" -X POST -H @"${ATL_HDR}"
    -H 'Accept: application/json' -H 'X-Atlassian-Token: no-check' -F "file=@${file}")
  [[ -n "${ca}" ]] && args+=(--cacert "${ca}")
  ATL_CODE="$(curl "${args[@]}" "${ATL_BASE}${path}" 2>"${TMP_DIR}/atl_curl.err")" || {
    ATL_ERROR="POST ${ATL_BASE}${path}: $(tr '\n' ' ' < "${TMP_DIR}/atl_curl.err")"; return 1; }
}

atl_js() { BMN_ATL_MODE="$1" run_js "${LIB_DIR}/atlassian.js"; }
atl_api_error() { BMN_IN="${ATL_RESP}" BMN_CODE="${ATL_CODE}" atl_js error; }
atl_get() { BMN_IN="${ATL_RESP}" BMN_FIELD="$1" atl_js get; }
atl_urlenc_path() { printf '%s' "$1" | sed 's#/#%2F#g; s# #%20#g'; }

atl_require() { # atl_require <product> <keys...>
  local product="$1" k missing="" where
  shift
  for k in "$@"; do [[ -n "$(atl "${k}")" ]] || missing="${missing:+${missing}, }${k}"; done
  [[ -z "${missing}" ]] && return 0
  where="${ATL_CONF_FILE}"; [[ -f "${where}" ]] || where="${where} (not found)"
  ATL_ERROR="${product}: missing ${missing} in ${where}"
  return 1
}

# jira_attach_files <report_dir> <issue>: uploads JIRA_ATTACH files, sets R_ATTACHMENTS.
jira_attach_files() {
  local dir="$1" issue="$2" names name f att_done=""
  names="$(atl JIRA_ATTACH)"; names="${names:-${ATL_DEFAULT_ATTACHMENTS}}"
  while IFS= read -r name; do
    name="$(trim "${name}")"
    [[ -z "${name}" ]] && continue
    f="${dir}/${name}"
    if [[ ! -f "${f}" ]]; then log_warn "Jira: attachment ${name} not found in ${dir}"; continue; fi
    if [[ "${DRY_RUN}" -eq 1 || -z "${issue}" ]]; then
      log_info "[dry-run] Jira: attach ${name} ($(wc -c < "${f}" | tr -d ' ') bytes)"; continue
    fi
    atl_attach "/rest/api/2/issue/$(atl_urlenc_path "${issue}")/attachments" "${f}" || return 1
    [[ "${ATL_CODE}" == "200" || "${ATL_CODE}" == "201" ]] || { ATL_ERROR="Jira attach ${name}: $(atl_api_error)"; return 1; }
    att_done="${att_done:+${att_done},}${name}"
    log_ok "Jira: attached ${name}"
  done <<<"$(printf '%s\n' "${names}" | tr ',' '\n')"
  R_ATTACHMENTS="${att_done}"
  return 0
}

# publish_jira_comment <report_dir> <issue> <attach 0|1>: report.jira.txt as a comment (issue fields untouched).
publish_jira_comment() {
  local dir="$1" issue="$2" attach="$3" base meta chars vis cid
  [[ -n "${issue}" ]] || { ATL_ERROR="--jira-comment requires an issue key (--jira-issue KEY or JIRA_ISSUE)"; return 1; }
  atl_require Jira JIRA_URL || return 1
  if ! meta="$(BMN_DESC_FILE="${dir}/report.jira.txt" BMN_OUT="${TMP_DIR}/jira_comment.json" \
      BMN_JIRA_COMMENT_VISIBILITY="$(atl JIRA_COMMENT_VISIBILITY)" atl_js jira-comment)"; then
    ATL_ERROR="${meta}"; return 1
  fi
  chars="$(printf '%s\n' "${meta}" | sed -n 's/^CHARS=//p')"
  vis="$(printf '%s\n' "${meta}" | sed -n 's/^VIS=//p')"
  atl_session JIRA || return 1
  base="${ATL_BASE}"
  atl_http GET "/rest/api/2/issue/$(atl_urlenc_path "${issue}")?fields=summary" || return 1
  [[ "${ATL_CODE}" == "200" ]] || { ATL_ERROR="Jira issue ${issue}: $(atl_api_error)"; return 1; }
  R_ISSUE="${issue}"; R_COMMENT_ID=""; R_URL="${base}/browse/${issue}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] Jira: POST ${base}/rest/api/2/issue/${issue}/comment (${chars} chars${vis})"
  else
    atl_http POST "/rest/api/2/issue/$(atl_urlenc_path "${issue}")/comment" "${TMP_DIR}/jira_comment.json" || return 1
    cid="$(atl_get id)"
    if [[ ( "${ATL_CODE}" != "200" && "${ATL_CODE}" != "201" ) || -z "${cid}" ]]; then
      ATL_ERROR="Jira comment on ${issue}: $(atl_api_error)"; return 1
    fi
    R_COMMENT_ID="${cid}"
    R_URL="${base}/browse/${issue}?focusedCommentId=${cid}#comment-${cid}"
    log_ok "Jira: commented on ${issue} (comment ${cid}${vis})"
  fi
  R_ATTACHMENTS=""
  if [[ "${attach}" -eq 1 ]]; then jira_attach_files "${dir}" "${issue}" || return 1; fi
  return 0
}

# publish_jira <report_dir> <issue> <attach 0|1>
publish_jira() {
  local dir="$1" issue="$2" attach="$3" base meta summary itype chars mode name f att_done=""
  if [[ -n "${issue}" ]]; then atl_require Jira JIRA_URL || return 1
  else atl_require Jira JIRA_URL JIRA_PROJECT || return 1; fi
  atl_session JIRA || return 1
  base="${ATL_BASE}"
  mode="jira-create"; [[ -n "${issue}" ]] && mode="jira-update"
  meta="$(BMN_ANALYSIS="${dir}/analysis.json" BMN_DESC_FILE="${dir}/report.jira.txt" BMN_OUT="${TMP_DIR}/jira_payload.json" \
    BMN_JIRA_PROJECT="$(atl JIRA_PROJECT)" BMN_JIRA_ISSUE_TYPE="$(atl JIRA_ISSUE_TYPE)" BMN_JIRA_SUMMARY="$(atl JIRA_SUMMARY)" \
    BMN_JIRA_LABELS="$(atl JIRA_LABELS)" BMN_JIRA_COMPONENTS="$(atl JIRA_COMPONENTS)" atl_js "${mode}")" || {
      ATL_ERROR="cannot build the Jira payload"; return 1; }
  summary="$(printf '%s\n' "${meta}" | sed -n 's/^SUMMARY=//p')"
  itype="$(printf '%s\n' "${meta}" | sed -n 's/^ISSUETYPE=//p')"
  chars="$(printf '%s\n' "${meta}" | sed -n 's/^CHARS=//p')"
  R_ISSUE="${issue}"; R_ACTION=""
  if [[ -n "${issue}" ]]; then
    atl_http GET "/rest/api/2/issue/$(atl_urlenc_path "${issue}")?fields=summary" || return 1
    [[ "${ATL_CODE}" == "200" ]] || { ATL_ERROR="Jira issue ${issue}: $(atl_api_error)"; return 1; }
    R_ACTION="update"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_info "[dry-run] Jira: PUT ${base}/rest/api/2/issue/${issue} (summary + description, ${chars} chars)"
    else
      atl_http PUT "/rest/api/2/issue/$(atl_urlenc_path "${issue}")" "${TMP_DIR}/jira_payload.json" || return 1
      [[ "${ATL_CODE}" == "200" || "${ATL_CODE}" == "204" ]] || { ATL_ERROR="Jira update ${issue}: $(atl_api_error)"; return 1; }
      log_ok "Jira: updated ${issue}"
    fi
  else
    R_ACTION="create"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_info "[dry-run] Jira: POST ${base}/rest/api/2/issue (project $(atl JIRA_PROJECT), type ${itype}, summary '${summary}', ${chars} chars)"
    else
      atl_http POST "/rest/api/2/issue" "${TMP_DIR}/jira_payload.json" || return 1
      issue="$(atl_get key)"
      if [[ ( "${ATL_CODE}" != "200" && "${ATL_CODE}" != "201" ) || -z "${issue}" ]]; then
        ATL_ERROR="Jira create: $(atl_api_error)"; return 1
      fi
      R_ISSUE="${issue}"
      log_ok "Jira: created ${issue}"
    fi
  fi
  R_URL=""; [[ -n "${R_ISSUE}" ]] && R_URL="${base}/browse/${R_ISSUE}"
  R_ATTACHMENTS=""
  if [[ "${attach}" -eq 1 ]]; then jira_attach_files "${dir}" "${R_ISSUE}" || return 1; fi
  return 0
}

# publish_confluence <report_dir> <title>
publish_confluence() {
  local dir="$1" title="$2" base query page pid="" pver="" chars what
  atl_require Confluence CONFLUENCE_URL CONFLUENCE_SPACE || return 1
  title="${title:-$(atl CONFLUENCE_TITLE)}"; title="${title:-${ATL_DEFAULT_TITLE}}"
  atl_session CONFLUENCE || return 1
  base="${ATL_BASE}"
  query="$(BMN_SPACE="$(atl CONFLUENCE_SPACE)" BMN_TITLE="${title}" atl_js confluence-query)"
  atl_http GET "/rest/api/content?${query}" || return 1
  [[ "${ATL_CODE}" == "200" ]] || { ATL_ERROR="Confluence search: $(atl_api_error)"; return 1; }
  page="$(BMN_IN="${ATL_RESP}" atl_js confluence-page)"
  if [[ -n "${page}" ]]; then pid="${page%% *}"; pver="${page##* }"; fi
  chars="$(BMN_ANALYSIS="${dir}/analysis.json" BMN_BODY_FILE="${dir}/report.confluence.xml" BMN_OUT="${TMP_DIR}/confluence_payload.json" \
    BMN_TITLE="${title}" BMN_SPACE="$(atl CONFLUENCE_SPACE)" BMN_PARENT_ID="$(atl CONFLUENCE_PARENT_ID)" \
    BMN_PAGE_ID="${pid}" BMN_PAGE_VERSION="${pver}" atl_js confluence | sed -n 's/^CHARS=//p')" || {
      ATL_ERROR="cannot build the Confluence payload"; return 1; }
  R_PAGE_ID="${pid}"; R_TITLE="${title}"; R_VERSION=""
  R_ACTION="create"; [[ -n "${pid}" ]] && R_ACTION="update"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ -n "${pid}" ]]; then
      what="PUT ${base}/rest/api/content/${pid} (version ${pver} -> $((pver + 1)))"
    else
      what="POST ${base}/rest/api/content (new page in space $(atl CONFLUENCE_SPACE)"
      if [[ -n "$(atl CONFLUENCE_PARENT_ID)" ]]; then what="${what}, parent $(atl CONFLUENCE_PARENT_ID))"; else what="${what})"; fi
    fi
    log_info "[dry-run] Confluence: ${what} '${title}', ${chars} chars"
  else
    if [[ -n "${pid}" ]]; then
      atl_http PUT "/rest/api/content/${pid}" "${TMP_DIR}/confluence_payload.json" || return 1
    else
      atl_http POST "/rest/api/content" "${TMP_DIR}/confluence_payload.json" || return 1
    fi
    R_PAGE_ID="$(atl_get id)"
    if [[ ( "${ATL_CODE}" != "200" && "${ATL_CODE}" != "201" ) || -z "${R_PAGE_ID}" ]]; then
      ATL_ERROR="Confluence ${R_ACTION}: $(atl_api_error)"; return 1
    fi
    R_VERSION="$(atl_get version.number)"; R_VERSION="${R_VERSION:-1}"
    log_ok "Confluence: ${R_ACTION}d page ${R_PAGE_ID} '${title}' (version ${R_VERSION})"
  fi
  R_URL=""; [[ -n "${R_PAGE_ID}" ]] && R_URL="${base}/pages/viewpage.action?pageId=${R_PAGE_ID}"
  return 0
}

# cmd_publish <report_dir>: returns 0 or 4.
cmd_publish() {
  local dir="$1" conf="${ATLASSIAN_CONF:-${CONF_DIR}/atlassian.conf}" failures=0 issue name w urls=""
  local state="${dir}/publish.json"
  for name in analysis.json $([[ "${PUBLISH_JIRA}" -eq 1 || "${JIRA_COMMENT_FLAG}" -eq 1 ]] && echo report.jira.txt) $([[ "${PUBLISH_CONFLUENCE}" -eq 1 ]] && echo report.confluence.xml); do
    [[ -f "${dir}/${name}" ]] || die "${dir}/${name} not found: run 'analyze' first"
  done
  command -v curl >/dev/null 2>&1 || die "curl not found in PATH" 4
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bmn.XXXXXX")"
  DRY_RUN="${PUBLISH_DRY_RUN}"
  log_title "publishing ${dir}$([[ "${DRY_RUN}" -eq 1 ]] && echo ' (dry-run)')"
  atl_conf_parse "${conf}"
  if [[ "${JIRA_COMMENT_FLAG}" -eq 1 ]]; then
    ATL_ERROR=""  # explicit key only: never comment on the issue remembered in publish.json by mistake
    if publish_jira_comment "${dir}" "${JIRA_ISSUE_KEY:-$(atl JIRA_ISSUE)}" "${JIRA_ATTACH_FLAG}"; then
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        BMN_STATE="${state}" BMN_PRODUCT=jira_comment BMN_R_ISSUE="${R_ISSUE}" BMN_R_COMMENT_ID="${R_COMMENT_ID}" \
          BMN_R_URL="${R_URL}" BMN_R_ATTACHMENTS="${R_ATTACHMENTS}" BMN_ANALYSIS="${dir}/analysis.json" atl_js state-set
        urls="${urls}$(printf '  %-10s: %s' Jira "${R_URL}")"$'\n'
      fi
    else
      failures=$((failures + 1)); log_error "Jira: ${ATL_ERROR}"
    fi
  elif [[ "${PUBLISH_JIRA}" -eq 1 ]]; then
    issue="${JIRA_ISSUE_KEY:-$(atl JIRA_ISSUE)}"
    [[ -n "${issue}" ]] || issue="$(BMN_STATE="${state}" BMN_FIELD=jira.issue atl_js state-get)"
    ATL_ERROR=""
    if publish_jira "${dir}" "${issue}" "${JIRA_ATTACH_FLAG}"; then
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        BMN_STATE="${state}" BMN_PRODUCT=jira BMN_R_ISSUE="${R_ISSUE}" BMN_R_ACTION="${R_ACTION}" BMN_R_URL="${R_URL}" \
          BMN_R_ATTACHMENTS="${R_ATTACHMENTS}" BMN_ANALYSIS="${dir}/analysis.json" atl_js state-set
        [[ -n "${R_URL}" ]] && urls="${urls}$(printf '  %-10s: %s' Jira "${R_URL}")"$'\n'
      fi
    else
      failures=$((failures + 1)); log_error "Jira: ${ATL_ERROR}"
    fi
  fi
  if [[ "${PUBLISH_CONFLUENCE}" -eq 1 ]]; then
    ATL_ERROR=""
    if publish_confluence "${dir}" "${CONFLUENCE_TITLE_OPT}"; then
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        BMN_STATE="${state}" BMN_PRODUCT=confluence BMN_R_PAGE_ID="${R_PAGE_ID}" BMN_R_TITLE="${R_TITLE}" BMN_R_ACTION="${R_ACTION}" \
          BMN_R_VERSION="${R_VERSION}" BMN_R_URL="${R_URL}" BMN_ANALYSIS="${dir}/analysis.json" atl_js state-set
        [[ -n "${R_URL}" ]] && urls="${urls}$(printf '  %-10s: %s' Confluence "${R_URL}")"$'\n'
      fi
    else
      failures=$((failures + 1)); log_error "Confluence: ${ATL_ERROR}"
    fi
  fi
  while IFS= read -r w; do
    if [[ -n "${w}" ]]; then log_warn "${w}"; fi
  done <<<"${ATL_WARNINGS}"
  rm -f "${TMP_DIR}"/atl_*.hdr
  [[ -n "${urls}" ]] && printf '%s' "${urls}"
  [[ "${failures}" -eq 0 ]] && return 0 || return 4
}
