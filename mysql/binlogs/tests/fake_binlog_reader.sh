#!/usr/bin/env bash
# Deterministic mysqlbinlog-compatible reader used by the report test suite.
set -euo pipefail

usage() {
    printf 'Usage: %s [mysqlbinlog options] FILE\n' "${0##*/}"
    printf 'Reads FILE and records the selected path when FAKE_BINLOG_READER_LOG is set.\n'
    printf 'Example: %s --base64-output=DECODE-ROWS --verbose mysql-bin.000001\n' "${0##*/}"
}

if [[ "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == '--version' ]]; then
    printf '%s Ver 8.0.0-test for test fixtures\n' "${0##*/}"
    exit 0
fi

if [[ "$#" -eq 0 ]]; then
    usage >&2
    exit 2
fi

input_file=${!#}
if [[ ! -r "$input_file" || ! -f "$input_file" ]]; then
    printf 'ERROR: fixture is not readable: %s\n' "$input_file" >&2
    exit 2
fi

if [[ -n "${FAKE_BINLOG_READER_LOG:-}" ]]; then
    printf 'READ\t%s\n' "$input_file" >> "$FAKE_BINLOG_READER_LOG"
fi

cat "$input_file"
