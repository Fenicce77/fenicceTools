#!/usr/bin/env bash
# =============================================================================
# publish_check.sh - verifies that the bash and python publishers send the same
# HTTP requests to Jira / Confluence Data Center (local mock server, no network).
# =============================================================================
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HOME_DIR="$(cd "${HERE}/.." && pwd -P)"
readonly TOKEN="test-pat-$$"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; BOLD=""; RESET=""
fi

usage() {
  cat <<HELP_EOF
${BOLD}$(basename "$0")${RESET} - publication parity test (bash vs python) against a local mock server

USAGE
  $(basename "$0") [-h]

Runs the same sequence with both implementations (dry-run, create, update,
bad token, unknown issue, missing configuration) and compares console output,
HTTP requests and publish.json. Requires python3 and curl; no network access.

ENVIRONMENT
  BMN_JS_RUNTIME   mongosh | node (runtime used by the bash helpers)

EXAMPLES
  $(basename "$0")
  BMN_JS_RUNTIME=node $(basename "$0")
HELP_EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bmn_publish.XXXXXX")"
MOCK_PID=""
stop_mock() { if [[ -n "${MOCK_PID}" ]]; then kill "${MOCK_PID}" 2>/dev/null || true; wait "${MOCK_PID}" 2>/dev/null || true; MOCK_PID=""; fi; }
trap 'stop_mock; rm -rf "${WORK}"' EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
start_mock() {
  python3 "${HERE}/mock_atlassian.py" "${PORT}" "$1" "${TOKEN}" >/dev/null 2>&1 &
  MOCK_PID=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/" && return 0
    sleep 0.3
  done
  echo "mock server did not start" >&2; exit 2
}

printf '%s\n' "${TOKEN}" > "${WORK}/confluence.pat"
cat > "${WORK}/atlassian.conf" <<CONF_EOF
JIRA_URL="http://127.0.0.1:${PORT}"
JIRA_TOKEN_ENV="BMN_TEST_JIRA_PAT"
JIRA_PROJECT="DBA"
JIRA_LABELS="mongodb, schema-centralization ,betika"
JIRA_COMPONENTS="Databases"
CONFLUENCE_URL="http://127.0.0.1:${PORT}/"
CONFLUENCE_TOKEN_FILE="${WORK}/confluence.pat"
CONFLUENCE_SPACE="DBA"
CONFLUENCE_PARENT_ID="4242"
CONFLUENCE_TITLE="MongoDB centralization (test)"
CONF_EOF
sed 's/^JIRA_PROJECT=.*/&\nJIRA_COMMENT_VISIBILITY="role:Developers"/' "${WORK}/atlassian.conf" > "${WORK}/visibility.conf"
sed 's/^JIRA_PROJECT=.*/&\nJIRA_COMMENT_VISIBILITY="team:dba"/' "${WORK}/atlassian.conf" > "${WORK}/badvis.conf"
chmod 600 "${WORK}/atlassian.conf" "${WORK}/visibility.conf" "${WORK}/badvis.conf" "${WORK}/confluence.pat"
export NO_COLOR=1 BMN_GENERATED_AT="2026-01-01T00:00:00Z" BMN_TEST_JIRA_PAT="${TOKEN}"

scenario() { # scenario <py|sh> <report_dir>
  local impl="$1" dir="$2" conf="${WORK}/atlassian.conf"
  local -a p
  if [[ "${impl}" == py ]]; then p=(python3 "${HOME_DIR}/python/mongo_schema_normalizer.py" publish)
  else p=(bash "${HOME_DIR}/bash/mongo_schema_normalizer.sh" publish); fi
  step() { local name="$1"; shift; echo "== ${name}"; "$@" 2>&1 | sed "s#${dir}#<DIR>#g" || true; }
  step "dry-run" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --publish-jira --publish-confluence --publish-dry-run --jira-attach
  step "create" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --publish-jira --publish-confluence --jira-attach
  step "update" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --publish-jira --publish-confluence
  BMN_TEST_JIRA_PAT=wrong step "bad token" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --publish-jira --jira-issue DBA-7
  step "unknown issue" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --publish-jira --jira-issue DBA-999
  step "missing conf" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}.missing" --publish-confluence
  step "comment dry-run" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --jira-comment --jira-issue DBA-7 --publish-dry-run
  step "comment + attach" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --jira-comment --jira-issue DBA-7 --jira-attach
  step "comment without key" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --jira-comment
  step "comment visibility" "${p[@]}" -o "${dir}" --atlassian-conf "${WORK}/visibility.conf" --jira-comment --jira-issue DBA-7
  step "comment bad visibility" "${p[@]}" -o "${dir}" --atlassian-conf "${WORK}/badvis.conf" --jira-comment --jira-issue DBA-7
  step "comment unknown issue" "${p[@]}" -o "${dir}" --atlassian-conf "${conf}" --jira-comment --jira-issue DBA-999
}

for impl in py sh; do
  python3 "${HOME_DIR}/python/mongo_schema_normalizer.py" analyze -s "${HERE}/fixtures/snapshots" \
    -m "${HERE}/fixtures/mapping.txt" -o "${WORK}/report_${impl}" >/dev/null 2>&1 || true
  start_mock "${WORK}/requests_${impl}.jsonl"
  scenario "${impl}" "${WORK}/report_${impl}" > "${WORK}/console_${impl}.txt"
  stop_mock
done

failures=0
if diff "${WORK}/console_py.txt" "${WORK}/console_sh.txt" >/dev/null; then
  printf '%s[PASS]%s console output\n' "${GREEN}" "${RESET}"
else
  printf '%s[FAIL]%s console output\n' "${RED}" "${RESET}"; diff "${WORK}/console_py.txt" "${WORK}/console_sh.txt" | head -20; failures=$((failures + 1))
fi
if python3 - "${WORK}" <<'PY_EOF'
import json, sys
w = sys.argv[1]
def load(impl):
    rows = []
    for line in open(f"{w}/requests_{impl}.jsonl"):
        e = json.loads(line)
        rows.append([e["method"], e["path"], e["query"], e["auth"], e["ctype"], e.get("xtoken"), e.get("file"), e["json"]])
    return rows
py, sh = load("py"), load("sh")
ok = py == sh and len(py) > 0
print(f"{len(py)} request(s) python, {len(sh)} request(s) bash")
pj = json.load(open(f"{w}/report_py/publish.json"))
sj = json.load(open(f"{w}/report_sh/publish.json"))
# commenting must never replace the issue created/updated by --publish-jira
kept = pj.get("jira", {}).get("issue") == "DBA-101" and pj.get("jira_comment", {}).get("issue") == "DBA-7"
print("publish.json: jira issue kept =", kept)
sys.exit(0 if ok and pj == sj and kept else 1)
PY_EOF
then
  printf '%s[PASS]%s HTTP requests and publish.json\n' "${GREEN}" "${RESET}"
else
  printf '%s[FAIL]%s HTTP requests or publish.json differ\n' "${RED}" "${RESET}"; failures=$((failures + 1))
fi
if grep -rq "${TOKEN}" "${WORK}/report_py" "${WORK}/report_sh" "${WORK}/console_py.txt" "${WORK}/console_sh.txt"; then
  printf '%s[FAIL]%s token found in outputs\n' "${RED}" "${RESET}"; failures=$((failures + 1))
else
  printf '%s[PASS]%s token never written to outputs\n' "${GREEN}" "${RESET}"
fi
exit "${failures}"
