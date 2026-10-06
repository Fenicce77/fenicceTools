#!/usr/bin/env bash
#
# install.sh - Install, upgrade or remove pbm-backup on a replica set member
# (Linux + systemd).
#
# Run it on EVERY member: all members run the same timers and pbm-backup's
# election decides which one acts. Safe to run again (upgrade): binaries,
# libraries and units are replaced, configuration files are never touched.
# Run "install.sh --help" for usage.

set -euo pipefail

PROG=install.sh
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

PREFIX=/usr/local
SCHEME=physical
INCR_MIN=''
METRICS=0
ENABLE=0
LEGACY_WRAPPERS=0
DISABLE_LEGACY=0
DRY_RUN=0
UNINSTALL=0
DESTDIR=''
SYSCONF_OPT=''
UNIT_DIR=/etc/systemd/system

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_RED=$'\033[31m' C_BLU=$'\033[34m' C_BLD=$'\033[1m' C_OFF=$'\033[0m'
else
    C_GRN='' C_YEL='' C_RED='' C_BLU='' C_BLD='' C_OFF=''
fi
info() { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit "${2:-1}"; }

usage() {
    cat <<EOF
${C_BLD}${PROG}${C_OFF} - install pbm-backup (bin, libraries, config, systemd units)

${C_BLD}USAGE${C_OFF}
    sudo ./${PROG} [OPTIONS]

${C_BLD}OPTIONS${C_OFF}
    --scheme physical|logical  Incremental schedule to install (default physical)
                                 physical: hourly at :15 (01:15..23:15)
                                 logical:  every --incr-every-min minutes
    --incr-every-min N         Logical scheme interval; must divide a day
                               (default: OPLOG_INCR_MIN from the config, else 360)
    --metrics                  Enable the 5-minute metrics timer (set METRICS_DIR)
    --enable                   Enable and start the timers (default: install only)
    --legacy-wrappers          Also install the /etc/sysconfig/pbm-physical-*
                               and pbm-deletion wrappers used by the old units
    --disable-legacy           Disable and stop the old pbm-physical-full-base,
                               pbm-physical-incremental and pbm-deletion timers
    --prefix DIR               Install prefix (default /usr/local)
    --uninstall                Stop and remove timers, units, binary, libraries
                               and docs. Configuration and logs are kept.
    --destdir DIR              Install under DIR (staging root, e.g. to build an
                               image). No systemctl calls, no root needed.
    --sysconfdir DIR           Config directory (default /etc/sysconfig, or
                               /etc/default when it does not exist)
    -n, --dry-run              Print what would be done, change nothing
    -h, --help                 Show this help

${C_BLD}EXIT CODES${C_OFF}
    0 done, 1 an install step failed, 2 usage or environment error
    (not root, no systemd, invalid option).

${C_BLD}INSTALLS${C_OFF}
    \${PREFIX}/bin/pbm-backup
    \${PREFIX}/lib/pbm-backup/*.sh
    \${PREFIX}/share/doc/pbm-backup/{README.md,INSTALL.md,CHANGES.md,VERSION,pbm-backup.conf.example,pbmuser.create.js}
    /etc/sysconfig/pbm-backup  (or /etc/default/pbm-backup; never overwritten)
    ${UNIT_DIR}/pbm-backup-{full,incr,cleanup,metrics}.{service,timer}

${C_BLD}EXAMPLES${C_OFF}
    # PSMDB member, migrate from the old units
    sudo ./${PROG} --enable --disable-legacy

    # Community member, oplog check every 6h, with metrics
    sudo ./${PROG} --scheme logical --incr-every-min 360 --metrics --enable

    # See what would happen
    ./${PROG} --scheme logical --dry-run

    # Remove it (configuration in /etc/sysconfig is kept)
    sudo ./${PROG} --uninstall
EOF
}

# run CMD... - execute, or print in --dry-run mode.
run() {
    if [[ $DRY_RUN == 1 ]]; then
        printf '  [DRY-RUN] %s\n' "$*"
    else
        "$@"
    fi
}

# calendar_every MINUTES - systemd OnCalendar for "every N minutes",
# aligned to midnight and offset to :30 when N is a whole number of hours.
calendar_every() {
    local n=$1 h
    if (( n >= 60 )); then
        (( n % 60 == 0 )) || return 1
        h=$(( n / 60 ))
        (( 24 % h == 0 )) || return 1
        if (( h == 24 )); then
            printf '*-*-* 00:30:00\n'
        else
            printf '*-*-* 00/%d:30:00\n' "$h"
        fi
    else
        (( 60 % n == 0 )) || return 1
        printf '*:00/%d:00\n' "$n"
    fi
}

while (( $# > 0 )); do
    case $1 in
        --scheme)          [[ $# -ge 2 ]] || die "--scheme needs a value" 2; SCHEME=$2; shift ;;
        --incr-every-min)  [[ $# -ge 2 ]] || die "--incr-every-min needs a value" 2; INCR_MIN=$2; shift ;;
        --metrics)         METRICS=1 ;;
        --enable)          ENABLE=1 ;;
        --legacy-wrappers) LEGACY_WRAPPERS=1 ;;
        --disable-legacy)  DISABLE_LEGACY=1 ;;
        --prefix)          [[ $# -ge 2 ]] || die "--prefix needs a value" 2; PREFIX=${2%/}; shift ;;
        --uninstall)       UNINSTALL=1 ;;
        --destdir)         [[ $# -ge 2 ]] || die "--destdir needs a value" 2; DESTDIR=${2%/}; shift ;;
        --sysconfdir)      [[ $# -ge 2 ]] || die "--sysconfdir needs a value" 2; SYSCONF_OPT=${2%/}; shift ;;
        -n|--dry-run)      DRY_RUN=1 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 usage >&2; die "Unknown argument: $1" 2 ;;
    esac
    shift
done

case $SCHEME in physical|logical) ;; *) die "--scheme must be physical or logical" 2 ;; esac
# D = staging root ("" for a real install). Target paths are "${D}<path>";
# paths written inside files (unit ExecStart) never include it.
D=$DESTDIR
if [[ -z $D ]]; then
    [[ $DRY_RUN == 1 || $(id -u) == 0 ]] || die "Run as root (or use --dry-run / --destdir)" 2
    [[ $DRY_RUN == 1 ]] || command -v systemctl >/dev/null 2>&1 || die "systemctl not found: this installer targets systemd hosts" 2
fi

# sc ARGS... - systemctl, skipped when installing into a staging root.
sc() {
    if [[ -n $D ]]; then
        printf '  [DESTDIR] skipped: systemctl %s\n' "$*"
        return 0
    fi
    run systemctl "$@"
}

if [[ -n $SYSCONF_OPT ]]; then
    SYSCONF=$SYSCONF_OPT
else
    SYSCONF=/etc/sysconfig
    [[ -d $SYSCONF ]] || SYSCONF=/etc/default
fi
LIBDIR="${PREFIX}/lib/pbm-backup"
DOCDIR="${PREFIX}/share/doc/pbm-backup"
BIN="${PREFIX}/bin/pbm-backup"
PKG_VERSION=$(sed -n 's/^VERSION=//p' "${SRC}/bin/pbm-backup" | head -n 1)

if [[ $UNINSTALL == 1 ]]; then
    info "Uninstalling pbm-backup from ${PREFIX} (configuration and logs are kept)"
    units=(pbm-backup-full pbm-backup-incr pbm-backup-cleanup pbm-backup-metrics)
    for u in "${units[@]}"; do
        if [[ $DRY_RUN == 1 ]] || [[ -e ${D}${UNIT_DIR}/${u}.timer ]]; then
            sc disable --now "${u}.timer" || warn "Could not disable ${u}.timer"
        fi
    done
    for u in "${units[@]}"; do
        run rm -f "${D}${UNIT_DIR}/${u}.timer" "${D}${UNIT_DIR}/${u}.service"
    done
    run rm -rf "${D}${UNIT_DIR}/pbm-backup-incr.timer.d" "${D}${LIBDIR}" "${D}${DOCDIR}"
    run rm -f "${D}${BIN}"
    sc daemon-reload
    for f in pbm-physical-full-base pbm-physical-incremental pbm-deletion; do
        if grep -qs 'exec "${PBM_BACKUP_BIN:-/usr/local/bin/pbm-backup}"' "${D}${SYSCONF}/$f"; then
            warn "${SYSCONF}/$f is a pbm-backup wrapper and now points to a removed binary: restore the original script before re-enabling the old timers"
        fi
    done
    if [[ $DRY_RUN == 1 ]]; then
        info "[DRY-RUN] Nothing was changed"
    else
        ok "Uninstalled. Kept: ${SYSCONF}/pbm-backup, ${SYSCONF}/pbm-conf, logs and PBM itself"
    fi
    exit 0
fi

# Interval for the logical scheme: CLI > config > 360.
if [[ $SCHEME == logical && -z $INCR_MIN ]]; then
    INCR_MIN=$( { [[ -r ${D}${SYSCONF}/pbm-backup ]] && . "${D}${SYSCONF}/pbm-backup" >/dev/null 2>&1; printf '%s' "${OPLOG_INCR_MIN:-}"; } || true)
    INCR_MIN=${INCR_MIN:-360}
fi
if [[ $SCHEME == logical ]]; then
    [[ $INCR_MIN =~ ^[0-9]+$ ]] && (( INCR_MIN > 0 )) || die "--incr-every-min must be a positive integer" 2
    INCR_CAL=$(calendar_every "$INCR_MIN") || die "--incr-every-min ${INCR_MIN} must divide a day (e.g. 15, 30, 60, 120, 180, 240, 360, 480, 720)" 2
fi

info "pbm-backup ${PKG_VERSION:-?} from ${SRC}, prefix ${PREFIX}, config dir ${SYSCONF}, scheme ${SCHEME}${INCR_CAL:+ (incr: ${INCR_CAL})}${D:+, staging root ${D}}"
if [[ -r ${D}${DOCDIR}/VERSION ]]; then
    info "Currently installed: $(cat "${D}${DOCDIR}/VERSION") (upgrade in place)"
fi

# --- dependencies (warnings only: the node may be prepared later) ----------
for c in pbm jq; do
    command -v "$c" >/dev/null 2>&1 || warn "'$c' not found in PATH (required at run time)"
done
command -v mongosh >/dev/null 2>&1 || command -v mongo >/dev/null 2>&1 \
    || warn "Neither mongosh nor mongo found in PATH (required at run time)"

# --- files -------------------------------------------------------------------
run install -d -m 0755 "${D}${PREFIX}/bin" "${D}${LIBDIR}" "${D}${DOCDIR}" "${D}${SYSCONF}" "${D}${UNIT_DIR}"
run install -m 0755 "${SRC}/bin/pbm-backup" "${D}${BIN}"
for f in "${SRC}"/lib/*.sh; do
    run install -m 0644 "$f" "${D}${LIBDIR}/$(basename "$f")"
done
for f in README.md INSTALL.md CHANGES.md; do
    if [[ -r ${SRC}/$f ]]; then
        run install -m 0644 "${SRC}/$f" "${D}${DOCDIR}/$f"
    fi
done
if [[ $DRY_RUN == 1 ]]; then
    printf '  [DRY-RUN] write %s/VERSION: %s\n' "$DOCDIR" "${PKG_VERSION:-unknown}"
else
    printf '%s\n' "${PKG_VERSION:-unknown}" >"${D}${DOCDIR}/VERSION"
fi
run install -m 0644 "${SRC}/etc/pbm-backup.conf.example" "${D}${DOCDIR}/pbm-backup.conf.example"
if [[ -r ${SRC}/mongodb/pbmuser.create.js ]]; then
    run install -m 0644 "${SRC}/mongodb/pbmuser.create.js" "${D}${DOCDIR}/pbmuser.create.js"
fi
if [[ -e ${D}${SYSCONF}/pbm-backup ]]; then
    info "Keeping existing ${SYSCONF}/pbm-backup (example in ${DOCDIR})"
else
    run install -m 0640 "${SRC}/etc/pbm-backup.conf.example" "${D}${SYSCONF}/pbm-backup"
fi
[[ -e ${D}${SYSCONF}/pbm-conf ]] || warn "${SYSCONF}/pbm-conf (PBM_MONGODB_URI) does not exist: create it from ${SRC}/sysconfig/pbm-conf"

if [[ $LEGACY_WRAPPERS == 1 ]]; then
    for f in pbm-physical-full-base pbm-physical-incremental pbm-deletion; do
        run install -m 0700 "${SRC}/sysconfig/$f" "${D}${SYSCONF}/$f"
    done
fi

# --- systemd -----------------------------------------------------------------
for f in "${SRC}"/systemd/services/pbm-backup-*.service "${SRC}"/systemd/timers/pbm-backup-*.timer; do
    dst="${D}${UNIT_DIR}/$(basename "$f")"
    if [[ $PREFIX == /usr/local ]]; then
        run install -m 0644 "$f" "$dst"
    elif [[ $DRY_RUN == 1 ]]; then
        printf '  [DRY-RUN] install %s -> %s (ExecStart prefix %s)\n' "$f" "$dst" "$PREFIX"
    else
        sed "s|/usr/local/bin/pbm-backup|${BIN}|; s|/usr/local/share/doc|${PREFIX}/share/doc|" "$f" >"$dst"
        chmod 0644 "$dst"
    fi
done

dropin="${D}${UNIT_DIR}/pbm-backup-incr.timer.d"
if [[ $SCHEME == logical ]]; then
    run install -d -m 0755 "$dropin"
    if [[ $DRY_RUN == 1 ]]; then
        printf '  [DRY-RUN] write %s/schedule.conf: OnCalendar=%s\n' "$dropin" "$INCR_CAL"
    else
        printf '# Written by install.sh: logical scheme, every %s minutes.\n[Timer]\nOnCalendar=\nOnCalendar=%s\n' \
            "$INCR_MIN" "$INCR_CAL" >"${dropin}/schedule.conf"
    fi
elif [[ -e ${dropin}/schedule.conf ]]; then
    run rm -f "${dropin}/schedule.conf"
fi
sc daemon-reload

if [[ $DISABLE_LEGACY == 1 ]]; then
    for t in pbm-physical-full-base.timer pbm-physical-incremental.timer pbm-deletion.timer; do
        if [[ $DRY_RUN == 1 || -n $D ]] || systemctl list-unit-files "$t" >/dev/null 2>&1; then
            sc disable --now "$t" || warn "Could not disable $t"
        fi
    done
fi

timers=(pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer)
[[ $METRICS == 1 ]] && timers+=(pbm-backup-metrics.timer)
if [[ $ENABLE == 1 ]]; then
    sc enable --now "${timers[@]}"
    [[ $DRY_RUN == 1 || -n $D ]] || ok "Timers enabled: ${timers[*]}"
else
    info "Timers installed but not enabled. Enable with: systemctl enable --now ${timers[*]}"
fi
[[ $METRICS == 1 ]] && info "Metrics timer: set METRICS_DIR in ${SYSCONF}/pbm-backup"

if [[ $DRY_RUN == 1 ]]; then
    info "[DRY-RUN] Nothing was changed"
else
    ok "pbm-backup ${PKG_VERSION:-?} installed. Next: '${BIN} check' on this member (read-only), then on the others"
fi
