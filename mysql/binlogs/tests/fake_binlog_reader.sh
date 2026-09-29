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

if [[ "${0##*/}" == mysql ]]; then
    if [[ -n "${FAKE_MYSQL_CLIENT_LOG:-}" ]]; then
        for argument in "$@"; do
            printf 'DISCOVERY_ARG\t%s\n' "$argument" >> "$FAKE_MYSQL_CLIENT_LOG"
        done
    fi
    printf '%s\n' "${FAKE_MYSQL_IDENTITY:-11.4.2-custom	MariaDB Server	MIXED}"
    exit 0
fi

if [[ "$#" -eq 0 ]]; then
    usage >&2
    exit 2
fi

input_file=${!#}
if [[ " $* " == *' --read-from-remote-server '* ]]; then
    if [[ -n "${FAKE_BINLOG_READER_LOG:-}" ]]; then
        for argument in "$@"; do
            printf 'REMOTE_ARG\t%s\n' "$argument" >> "$FAKE_BINLOG_READER_LOG"
        done
    fi
    input_file=${FAKE_REMOTE_FIXTURE:-}
fi

if [[ ! -r "$input_file" || ! -f "$input_file" ]]; then
    printf 'ERROR: fixture is not readable: %s\n' "$input_file" >&2
    exit 2
fi

if [[ -n "${FAKE_BINLOG_READER_LOG:-}" && " $* " != *' --read-from-remote-server '* ]]; then
    printf 'READ\t%s\n' "$input_file" >> "$FAKE_BINLOG_READER_LOG"
fi

cat "$input_file"
