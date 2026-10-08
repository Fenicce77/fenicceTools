#!/usr/bin/env bash
# =============================================================================
# parity_check.sh - verifies that the bash and python implementations produce
# byte-identical artifacts from the same snapshots (offline, no DB access).
# =============================================================================
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HOME_DIR="$(cd "${HERE}/.." && pwd -P)"
SNAPSHOTS="${HERE}/fixtures/snapshots"
MAPPING="${HERE}/fixtures/mapping.txt"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; BOLD=""; RESET=""
fi

usage() {
  cat <<HELP_EOF
${BOLD}$(basename "$0")${RESET} - parity test between the bash and python implementations

USAGE
  $(basename "$0") [-s SNAPSHOT_DIR] [-m MAPPING_FILE] [-h]

OPTIONS
  -s DIR    snapshot directory (default: tests/fixtures/snapshots)
  -m FILE   mapping file (default: tests/fixtures/mapping.txt)
  -h        show this help

ENVIRONMENT
  BMN_JS_RUNTIME   mongosh | node (runtime used by the bash analyzer)

EXAMPLES
  $(basename "$0")
  BMN_JS_RUNTIME=node $(basename "$0") -s ./reports/20260930T101500Z/snapshots
HELP_EOF
}

while getopts ":s:m:h" opt; do
  case "${opt}" in
    s) SNAPSHOTS="${OPTARG}" ;;
    m) MAPPING="${OPTARG}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bmn_parity.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
export BMN_GENERATED_AT="2026-01-01T00:00:00Z" NO_COLOR=1

failures=0
for strategy in auto keep prefix; do
  py="${WORK}/py_${strategy}"; sh="${WORK}/sh_${strategy}"
  python3 "${HOME_DIR}/python/mongo_schema_normalizer.py" analyze -s "${SNAPSHOTS}" -m "${MAPPING}" \
    -n "${strategy}" -o "${py}" >/dev/null 2>&1 || true
  BMN_IMPLEMENTATION=python bash "${HOME_DIR}/bash/mongo_schema_normalizer.sh" analyze -s "${SNAPSHOTS}" \
    -m "${MAPPING}" -n "${strategy}" -o "${sh}" >/dev/null 2>&1 || true
  if diff -r "${py}" "${sh}" >"${WORK}/diff_${strategy}.txt"; then
    printf '%s[PASS]%s strategy=%s (%s files)\n' "${GREEN}" "${RESET}" "${strategy}" "$(ls "${py}" | wc -l | tr -d ' ')"
  else
    printf '%s[FAIL]%s strategy=%s\n' "${RED}" "${RESET}" "${strategy}"
    head -n 40 "${WORK}/diff_${strategy}.txt"
    failures=$((failures + 1))
  fi
done
exit "${failures}"
