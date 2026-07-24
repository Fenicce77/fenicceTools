#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${GCP_GENERAL_LOG_MONITOR_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/gcp_general_log_monitor.sh}"
TEST_TMP_DIR="$(mktemp -d)"
STUB_DIR="${TEST_TMP_DIR}/bin"
TRACE_FILE="${TEST_TMP_DIR}/trace.log"
WORK_DIR="${TEST_TMP_DIR}/work"

cleanup() {
    rm -rf "${TEST_TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${STUB_DIR}" "${WORK_DIR}"

cat > "${STUB_DIR}/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'gcloud:%s\n' "$*" >> "${TEST_TRACE}"
if [[ "$1 $2 $3" == "sql instances describe" ]]; then
    if [[ "${STUB_DESCRIBE_FAILURE:-false}" == "true" ]]; then
        exit 71
    fi
    if [[ "${STUB_FLAG_STATE:-off}" == "on" ]]; then
        printf '%s\n' '{"settings":{"databaseFlags":[{"name":"general_log","value":"on"}]}}'
    else
        printf '%s\n' '{"settings":{"databaseFlags":[]}}'
    fi
elif [[ "$1 $2 $3" == "sql instances patch" ]]; then
    if [[ "$*" == *"general_log=on"* ]]; then
        printf 'patch:on\n' >> "${TEST_TRACE}"
    else
        printf 'patch:off\n' >> "${TEST_TRACE}"
    fi
elif [[ "$1 $2" == "logging read" ]]; then
    printf '%s\n' '[{"textPayload":"2026-07-23T12:01:55Z user[user] @ [10.10.10.1]15897 4226757038 Query SELECT 1"}]'
fi
EOF

cat > "${STUB_DIR}/mysql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mysql:%s\n' "$*" >> "${TEST_TRACE}"
cat >/dev/null
EOF

cat > "${STUB_DIR}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep:%s\n' "$*" >> "${TEST_TRACE}"
if [[ "${STUB_SLEEP_MODE:-return}" == "wait" ]]; then
    : > "${TEST_SLEEP_MARKER}"
    printf '%s\n' "${PPID}" > "${TEST_SCRIPT_PID}"
    while true; do
        /bin/sleep 1
    done
fi
EOF

chmod 700 "${STUB_DIR}/gcloud" "${STUB_DIR}/mysql" "${STUB_DIR}/sleep"

run_script() {
    (
        cd "${WORK_DIR}"
        exec env \
            PATH="${STUB_DIR}:/usr/bin:/bin" \
            TEST_TRACE="${TRACE_FILE}" \
            STUB_FLAG_STATE="${STUB_FLAG_STATE:-off}" \
            STUB_DESCRIBE_FAILURE="${STUB_DESCRIBE_FAILURE:-false}" \
            STUB_SLEEP_MODE="${STUB_SLEEP_MODE:-return}" \
            bash "${SCRIPT}" \
            --project test-project \
            --instance test-instance \
            --login-path test-login \
            --schema test_schema \
            "$@"
    )
}

reset_case() {
    : > "${TRACE_FILE}"
    rm -rf "${WORK_DIR}/tmp"
    unset STUB_DESCRIBE_FAILURE STUB_FLAG_STATE STUB_SLEEP_MODE TEST_SLEEP_MARKER
}

line_number() {
    grep -n -m1 -F "$1" "${TRACE_FILE}" | cut -d: -f1
}

help_output="$(PATH="${STUB_DIR}:/usr/bin:/bin" bash "${SCRIPT}" --help 2>&1 || true)"
if [[ "${help_output}" != *"-G, --generate-only"* ]]; then
    echo "help output does not document --generate-only" >&2
    exit 1
fi

reset_case
if STUB_DESCRIBE_FAILURE="true" run_script --generate-only --duration 0 >/dev/null 2>&1; then
    echo "describe failure unexpectedly continued" >&2
    exit 1
fi
if ! grep -q '^gcloud:sql instances describe' "${TRACE_FILE}"; then
    echo "describe failure did not reach flag inspection" >&2
    exit 1
fi
if grep -qE '^patch:|^gcloud:logging read|^mysql:' "${TRACE_FILE}"; then
    echo "describe failure continued to a mutating or retrieval operation" >&2
    exit 1
fi

reset_case
if run_script --dry-run --generate-only >/dev/null 2>&1; then
    echo "--dry-run --generate-only unexpectedly succeeded" >&2
    exit 1
fi
if [[ $(run_script --dry-run --generate-only >/dev/null 2>&1; echo $?) -ne 2 ]]; then
    echo "--dry-run --generate-only did not return status 2" >&2
    exit 1
fi
if [[ -s "${TRACE_FILE}" ]]; then
    echo "--dry-run --generate-only invoked an external command" >&2
    exit 1
fi

reset_case
run_script --fetch-only --generate-only >/dev/null
if ! grep -q '^gcloud:logging read' "${TRACE_FILE}"; then
    echo "fetch-only generate-only did not read Cloud Logging" >&2
    exit 1
fi
if grep -q '^mysql:' "${TRACE_FILE}"; then
    echo "fetch-only generate-only invoked mysql" >&2
    exit 1
fi
if ! grep -q "'user@10.10.10.1'" "${WORK_DIR}/tmp/gcp_general_log_capture.sql"; then
    echo "fetch-only generate-only did not create expected SQL" >&2
    exit 1
fi

python3 - "${WORK_DIR}/tmp/gcp_general_log_monitor.log" <<'PY'
import os
import stat
import sys

mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
if mode != 0o600:
    raise SystemExit(f"expected log mode 0600, got {mode:04o}")
PY

reset_case
run_script --generate-only --duration 0 >/dev/null
if grep -q '^mysql:' "${TRACE_FILE}"; then
    echo "generate-only invoked mysql" >&2
    exit 1
fi
on_line="$(line_number 'patch:on')"
off_line="$(line_number 'patch:off')"
read_line="$(line_number 'gcloud:logging read')"
if [[ -z "${on_line}" || -z "${off_line}" || -z "${read_line}" || ${on_line} -ge ${off_line} || ${off_line} -ge ${read_line} ]]; then
    echo "generate-only did not enable, restore, then read logs in order" >&2
    exit 1
fi

reset_case
run_script --duration 0 >/dev/null
if ! grep -q '^mysql:' "${TRACE_FILE}"; then
    echo "normal execution did not invoke mysql" >&2
    exit 1
fi

reset_case
STUB_FLAG_STATE="on" run_script --generate-only --duration 0 >/dev/null
if grep -q '^patch:' "${TRACE_FILE}"; then
    echo "an originally enabled general_log was modified" >&2
    exit 1
fi

reset_case
TEST_SLEEP_MARKER="${TEST_TMP_DIR}/sleep-started"
TEST_SCRIPT_PID="${TEST_TMP_DIR}/script-pid"
export TEST_SLEEP_MARKER
export TEST_SCRIPT_PID
STUB_SLEEP_MODE="wait" run_script --duration 60 >/dev/null 2>&1 &
script_pid=$!
for _ in $(seq 1 50); do
    [[ -e "${TEST_SLEEP_MARKER}" ]] && break
    /bin/sleep 0.1
done
if [[ ! -e "${TEST_SLEEP_MARKER}" ]]; then
    echo "interruption test did not reach capture sleep" >&2
    kill "${script_pid}" 2>/dev/null || true
    exit 1
fi
target_pid="$(<"${TEST_SCRIPT_PID}")"
kill -TERM "${target_pid}"
if wait "${script_pid}"; then
    echo "interrupted execution unexpectedly succeeded" >&2
    exit 1
fi
if ! grep -q '^patch:on' "${TRACE_FILE}" || ! grep -q '^patch:off' "${TRACE_FILE}"; then
    echo "interrupted execution did not restore general_log" >&2
    exit 1
fi
