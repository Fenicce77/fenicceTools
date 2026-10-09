#!/usr/bin/env bash
#
# build-dist.sh - Build the self-contained pbm-backup package:
#   dist/pbm-backup-<version>.tar.gz          (top directory pbm-backup-<version>/)
#   dist/pbm-backup-<version>.tar.gz.sha256   (sha256sum -c compatible)
#
# Runs the smoke tests first. Works on Linux (GNU tar) and macOS (bsdtar):
# no macOS metadata, owner root:root, files sorted. Run with --help.

set -euo pipefail

PROG=build-dist.sh
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT="${ROOT}/dist"
RUN_TESTS=1

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_GRN=$'\033[32m' C_RED=$'\033[31m' C_BLU=$'\033[34m' C_BLD=$'\033[1m' C_OFF=$'\033[0m'
else
    C_GRN='' C_RED='' C_BLU='' C_BLD='' C_OFF=''
fi
info() { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit "${2:-1}"; }

usage() {
    cat <<EOF
${C_BLD}${PROG}${C_OFF} - build the pbm-backup deployment package

${C_BLD}USAGE${C_OFF}
    packaging/${PROG} [--output DIR] [--skip-tests]

${C_BLD}OPTIONS${C_OFF}
    -o, --output DIR   Where to write the package (default: <tool>/dist)
        --skip-tests   Do not run tests/smoke.sh first
    -h, --help         Show this help

The version is read from bin/pbm-backup (VERSION=...). The package contains
everything install.sh needs; tests and fixtures are not included.

${C_BLD}EXAMPLES${C_OFF}
    packaging/${PROG}
    packaging/${PROG} --output /home/rmateos/releases
    sha256sum -c dist/pbm-backup-*.tar.gz.sha256
EOF
}

while (( $# > 0 )); do
    case $1 in
        -o|--output)  [[ $# -ge 2 ]] || die "--output needs a value" 2; OUT=$2; shift ;;
        --skip-tests) RUN_TESTS=0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "Unknown argument: $1" 2 ;;
    esac
    shift
done

VERSION=$(sed -n 's/^VERSION=//p' "${ROOT}/bin/pbm-backup" | head -n 1)
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot read VERSION from bin/pbm-backup (got '${VERSION}')"
NAME="pbm-backup-${VERSION}"

# Shipped files. Keep this list explicit: nothing else (tests, fixtures,
# CLAUDE.md, local files) ends up in the package.
FILES=(
    bin/pbm-backup
    lib/common.sh lib/compat.sh lib/metrics.sh lib/mongo.sh lib/pbm.sh lib/topology.sh
    etc/pbm-backup.conf etc/pbm-backup.conf.example
    conf/pbm-agent.yml conf/pbm-agent-config.conf conf/pbm-conf.yml
    conf/pbm-conf-gcp-hmac.yml conf/pbm-conf-gcs.yml
    sysconfig/pbm-agent sysconfig/pbm-conf
    sysconfig/pbm-physical-full-base sysconfig/pbm-physical-incremental sysconfig/pbm-deletion
    systemd/services/pbm-backup-full.service systemd/services/pbm-backup-incr.service
    systemd/services/pbm-backup-cleanup.service systemd/services/pbm-backup-metrics.service
    systemd/timers/pbm-backup-full.timer systemd/timers/pbm-backup-incr.timer
    systemd/timers/pbm-backup-cleanup.timer systemd/timers/pbm-backup-metrics.timer
    systemd/legacy/services/pbm-physical-full-base.service
    systemd/legacy/services/pbm-physical-incremental.service
    systemd/legacy/services/pbm-deletion.service
    systemd/legacy/timers/pbm-physical-full-base.timer
    systemd/legacy/timers/pbm-physical-incremental.timer
    systemd/legacy/timers/pbm-deletion.timer
    mongodb/pbmuser.create.js
    tools/gcs-hmac-test.py
    install.sh README.md INSTALL.md CHANGES.md
)
for f in "${FILES[@]}"; do
    [[ -f ${ROOT}/$f ]] || die "Missing file: $f"
done
# The package ships the editable copies unedited: install.sh tells edited
# from unedited copies (placeholders, or etc/pbm-backup.conf vs the example).
cmp -s "${ROOT}/etc/pbm-backup.conf" "${ROOT}/etc/pbm-backup.conf.example" \
    || die "etc/pbm-backup.conf differs from etc/pbm-backup.conf.example: the package must ship it unedited"
grep -q '<pbm_password>' "${ROOT}/sysconfig/pbm-conf" || die "sysconfig/pbm-conf has no placeholders: the package must ship the template"

if [[ $RUN_TESTS == 1 ]]; then
    info "Running tests/smoke.sh"
    if ! "${ROOT}/tests/smoke.sh" >"${TMPDIR:-/tmp}/pbm-backup-build-tests.log" 2>&1; then
        tail -n 20 "${TMPDIR:-/tmp}/pbm-backup-build-tests.log" >&2
        die "Tests failed (full log: ${TMPDIR:-/tmp}/pbm-backup-build-tests.log). Not packaging"
    fi
    ok "$(tail -n 1 "${TMPDIR:-/tmp}/pbm-backup-build-tests.log" | sed 's/\x1b\[[0-9;]*m//g')"
    info "Running tests/install.test.sh"
    if ! "${ROOT}/tests/install.test.sh" >"${TMPDIR:-/tmp}/pbm-backup-build-tests-install.log" 2>&1; then
        tail -n 20 "${TMPDIR:-/tmp}/pbm-backup-build-tests-install.log" >&2
        die "install.sh tests failed. Not packaging"
    fi
    ok "$(tail -n 1 "${TMPDIR:-/tmp}/pbm-backup-build-tests-install.log" | sed 's/\x1b\[[0-9;]*m//g')"
    info "Running tests/pbmuser.test.sh"
    if ! "${ROOT}/tests/pbmuser.test.sh" >"${TMPDIR:-/tmp}/pbm-backup-build-tests-js.log" 2>&1; then
        tail -n 20 "${TMPDIR:-/tmp}/pbm-backup-build-tests-js.log" >&2
        die "pbmuser.create.js tests failed. Not packaging"
    fi
    ok "$(tail -n 1 "${TMPDIR:-/tmp}/pbm-backup-build-tests-js.log" | sed 's/\x1b\[[0-9;]*m//g')"
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pbm-backup-dist.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "${STAGE}/${NAME}"
for f in "${FILES[@]}"; do
    mkdir -p "${STAGE}/${NAME}/$(dirname "$f")"
    cp "${ROOT}/$f" "${STAGE}/${NAME}/$f"
done
printf '%s\n' "$VERSION" >"${STAGE}/${NAME}/VERSION"
chmod 0755 "${STAGE}/${NAME}/bin/pbm-backup" "${STAGE}/${NAME}/install.sh" \
    "${STAGE}/${NAME}"/sysconfig/pbm-physical-* "${STAGE}/${NAME}/sysconfig/pbm-deletion"
find "${STAGE}/${NAME}" -type d -exec chmod 0755 {} +

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
TARBALL="${OUT}/${NAME}.tar.gz"

# Sorted file list; owner root, no macOS extended attributes/AppleDouble.
LIST="${STAGE}/files.txt"
(cd "$STAGE" && find "$NAME" -type f | LC_ALL=C sort >"$LIST")
if tar --version 2>/dev/null | grep -q bsdtar; then
    (cd "$STAGE" && COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 \
        -czf "$TARBALL" -T "$LIST")
else
    (cd "$STAGE" && tar --owner=0 --group=0 --numeric-owner -czf "$TARBALL" -T "$LIST")
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT" && sha256sum "${NAME}.tar.gz" >"${NAME}.tar.gz.sha256")
else
    (cd "$OUT" && shasum -a 256 "${NAME}.tar.gz" >"${NAME}.tar.gz.sha256")
fi

ok "Package: ${TARBALL} ($(wc -c <"$TARBALL" | tr -d ' ') bytes, $(wc -l <"$LIST" | tr -d ' ') files)"
ok "Checksum: ${TARBALL}.sha256 ($(cut -d' ' -f1 "${TARBALL}.sha256"))"
