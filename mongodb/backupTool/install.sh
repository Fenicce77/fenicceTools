#!/usr/bin/env bash
#
# install.sh - Install, upgrade or remove pbm-backup on a replica set member
# (Linux + systemd).
#
# Run it on EVERY member: all members run the same timers and pbm-backup's
# election decides which one acts. When a version is already installed it is
# detected and the run becomes an upgrade (or reinstall / downgrade): a plan
# of the changes is shown first, the configuration files are backed up with
# a versioned name and the previous install options (scheme, metrics...) are
# kept unless given again. Run "install.sh --help" for usage.

set -euo pipefail

PROG=install.sh
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

PREFIX=/usr/local
SCHEME='' INCR_MIN='' METRICS='' LEGACY_WRAPPERS=''
ENABLE=0 DISABLE_LEGACY=0 DRY_RUN=0 UNINSTALL=0 UPGRADE=0
ALLOW_DOWNGRADE=0 FRESH_CONFIG=0 KEEP_CONFIG=0
DESTDIR='' SYSCONF_OPT=''
UNIT_DIR=/etc/systemd/system
TS=$(date -u '+%Y%m%dT%H%M%SZ')

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
${C_BLD}${PROG}${C_OFF} - install, upgrade or remove pbm-backup (bin, libraries, config, systemd units)

${C_BLD}USAGE${C_OFF}
    sudo ./${PROG} [OPTIONS]

${C_BLD}INSTALL / UPGRADE${C_OFF}
    If pbm-backup is already installed, its version is detected and the run
    becomes an upgrade (newer package), a reinstall (same version) or a
    downgrade (older package, needs --allow-downgrade). Before changing
    anything it prints a plan: files new / changed / removed / unchanged,
    configuration backups, install options and the CHANGES.md sections added
    since the installed version. Options not given again (--scheme,
    --incr-every-min, --metrics, --legacy-wrappers) keep their previous
    values. Configuration files are COPIED to
        <file>.<upgrade|reinstall|downgrade>.<installed version>.<UTC time>
    and kept in place, so backups keep working (--fresh-config renames them
    and installs the new templates instead).

${C_BLD}OPTIONS${C_OFF}
    --scheme physical|logical  Incremental schedule (default physical, or the installed one)
                                 physical: hourly at :15 (01:15..23:15)
                                 logical:  every --incr-every-min minutes
    --incr-every-min N         Logical scheme interval; must divide a day
                               (default: installed value, OPLOG_INCR_MIN, else 360)
    --metrics                  Install/enable the 5-minute metrics timer (set METRICS_DIR)
    --enable                   Enable and start the timers (an upgrade keeps their state)
    --legacy-wrappers          Also install the /etc/sysconfig/pbm-physical-*
                               and pbm-deletion wrappers used by the old units
    --disable-legacy           Disable and stop the old pbm-physical-full-base,
                               pbm-physical-incremental and pbm-deletion timers
    --upgrade                  Require an installed version (fail if there is none)
    --allow-downgrade          Allow installing an older version than the installed one
    --fresh-config             On upgrade: rename the configuration files (instead of
                               copying them) and install the new templates
    --uninstall                Stop and remove timers, units, binary, libraries and docs.
                               Configuration files are RENAMED to
                               <file>.uninstall.<version>.<UTC time>; logs are kept
    --keep-config              With --uninstall: leave the configuration files as they are
    --prefix DIR               Install prefix (default /usr/local)
    --destdir DIR              Install under DIR (staging root, e.g. to build an
                               image). No systemctl calls, no root needed.
    --sysconfdir DIR           Config directory (default /etc/sysconfig, or
                               /etc/default when it does not exist)
    -n, --dry-run              Print the plan and every action, change nothing
    -h, --help                 Show this help

${C_BLD}EXIT CODES${C_OFF}
    0 done, 1 an install step failed, 2 usage or environment error
    (not root, no systemd, invalid option, nothing to upgrade, refused downgrade).

${C_BLD}INSTALLS${C_OFF}
    \${PREFIX}/bin/pbm-backup
    \${PREFIX}/lib/pbm-backup/*.sh
    \${PREFIX}/share/doc/pbm-backup/{README.md,INSTALL.md,CHANGES.md,VERSION,install.state,
                                    pbm-backup.conf.example,pbmuser.create.js,gcs-hmac-test.py}
    /etc/sysconfig/pbm-backup  (or /etc/default/...; created if missing)
    /etc/sysconfig/pbm-conf    (PBM_MONGODB_URI template, 0600; created if missing; must be filled in)
    ${UNIT_DIR}/pbm-backup-{full,incr,cleanup,metrics}.{service,timer}

${C_BLD}EXAMPLES${C_OFF}
    # PSMDB member, migrate from the old units
    sudo ./${PROG} --enable --disable-legacy

    # Community member, oplog check every 6h, with metrics
    sudo ./${PROG} --scheme logical --incr-every-min 360 --metrics --enable

    # Upgrade: see the plan first, then apply (previous options are kept)
    sudo ./${PROG} --upgrade --dry-run
    sudo ./${PROG} --upgrade

    # Remove it (configuration files renamed, logs kept)
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

# vercmp A B - print -1, 0 or 1 for dotted versions (1.2.10 > 1.2.9).
vercmp() {
    local IFS=. i x y
    # shellcheck disable=SC2206
    local -a a=($1) b=($2)
    for (( i = 0; i < 3; i++ )); do
        x=${a[i]:-0} y=${b[i]:-0}
        x=$((10#${x//[!0-9]/})) y=$((10#${y//[!0-9]/}))
        if (( x < y )); then printf '%s\n' -1; return 0; fi
        if (( x > y )); then printf '%s\n' 1; return 0; fi
    done
    printf '%s\n' 0
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
        --upgrade)         UPGRADE=1 ;;
        --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
        --fresh-config)    FRESH_CONFIG=1 ;;
        --keep-config)     KEEP_CONFIG=1 ;;
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

[[ -z $SCHEME || $SCHEME == physical || $SCHEME == logical ]] || die "--scheme must be physical or logical" 2
[[ $KEEP_CONFIG == 0 || $UNINSTALL == 1 ]] || die "--keep-config only applies to --uninstall" 2
[[ $UNINSTALL == 0 || $UPGRADE == 0 ]] || die "--uninstall and --upgrade cannot be combined" 2

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
STATE="${DOCDIR}/install.state"
DROPIN="${UNIT_DIR}/pbm-backup-incr.timer.d"
PKG_VERSION=$(sed -n 's/^VERSION=//p' "${SRC}/bin/pbm-backup" | head -n 1)
LEGACY_NAMES="pbm-physical-full-base pbm-physical-incremental pbm-deletion"
WRAPPER_MARK='exec "${PBM_BACKUP_BIN:-/usr/local/bin/pbm-backup}"'

# ---------------------------------------------------------------------------
# What is installed now
# ---------------------------------------------------------------------------
# state_get KEY - value from install.state (written since 0.6.6), or empty.
state_get() {
    sed -n "s/^$1=//p" "${D}${STATE}" 2>/dev/null | tail -n 1
}

INSTALLED=''
if [[ -r ${D}${DOCDIR}/VERSION ]]; then
    INSTALLED=$(head -n 1 "${D}${DOCDIR}/VERSION")
elif [[ -x ${D}${BIN} ]]; then
    INSTALLED=$(sed -n 's/^VERSION=//p' "${D}${BIN}" | head -n 1)
fi

# Previous install options: install.state, or inferred from the files of
# installs older than 0.6.6 (no state file).
PREV_SCHEME='' PREV_INCR='' PREV_METRICS='' PREV_WRAPPERS=''
if [[ -n $INSTALLED ]]; then
    if [[ -r ${D}${STATE} ]]; then
        PREV_SCHEME=$(state_get SCHEME) PREV_INCR=$(state_get INCR_MIN)
        PREV_METRICS=$(state_get METRICS) PREV_WRAPPERS=$(state_get LEGACY_WRAPPERS)
    else
        if [[ -r ${D}${DROPIN}/schedule.conf ]]; then
            PREV_SCHEME=logical
            PREV_INCR=$(sed -n 's/.*every \([0-9][0-9]*\) minutes.*/\1/p' "${D}${DROPIN}/schedule.conf" | head -n 1)
        else
            PREV_SCHEME=physical
        fi
        PREV_METRICS=0
        if [[ -z $D ]] && systemctl is-enabled pbm-backup-metrics.timer >/dev/null 2>&1; then
            PREV_METRICS=1
        fi
        PREV_WRAPPERS=0
        for f in $LEGACY_NAMES; do
            grep -qsF "$WRAPPER_MARK" "${D}${SYSCONF}/$f" && PREV_WRAPPERS=1
        done
    fi
fi

# config_files - configuration files owned by pbm-backup that exist now
# (the legacy wrappers only when they are pbm-backup wrappers, never the
# original scripts).
config_files() {
    local f
    for f in pbm-backup pbm-conf; do
        [[ -e ${D}${SYSCONF}/$f ]] && printf '%s\n' "${SYSCONF}/$f"
    done
    for f in $LEGACY_NAMES; do
        grep -qsF "$WRAPPER_MARK" "${D}${SYSCONF}/$f" && printf '%s\n' "${SYSCONF}/$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ $UNINSTALL == 1 ]]; then
    info "Uninstalling pbm-backup ${INSTALLED:-(version unknown)} from ${PREFIX}${D:+ (staging root ${D})}"
    units="pbm-backup-full pbm-backup-incr pbm-backup-cleanup pbm-backup-metrics"
    for u in $units; do
        if [[ $DRY_RUN == 1 ]] || [[ -e ${D}${UNIT_DIR}/${u}.timer ]]; then
            sc disable --now "${u}.timer" || warn "Could not disable ${u}.timer"
        fi
    done
    for u in $units; do
        run rm -f "${D}${UNIT_DIR}/${u}.timer" "${D}${UNIT_DIR}/${u}.service"
    done
    run rm -rf "${D}${DROPIN}" "${D}${LIBDIR}" "${D}${DOCDIR}"
    run rm -f "${D}${BIN}"
    sc daemon-reload

    renamed=''
    if [[ $KEEP_CONFIG == 1 ]]; then
        info "--keep-config: configuration files left as they are"
    else
        while IFS= read -r f; do
            [[ -n $f ]] || continue
            dst="${f}.uninstall.${INSTALLED:-unknown}.${TS}"
            run mv "${D}${f}" "${D}${dst}"
            renamed="${renamed}    ${f} -> ${dst}"$'\n'
        done <<EOF
$(config_files)
EOF
    fi
    if [[ -n $renamed ]]; then
        info "Configuration files renamed (a reinstall starts from the templates; restore them with mv if needed):"
        printf '%s' "$renamed"
        if printf '%s' "$renamed" | grep -q 'pbm-conf'; then
            warn "The renamed pbm-conf still holds the PBM password (mode kept). Delete it if it is no longer needed"
        fi
    fi
    if [[ $DRY_RUN == 1 ]]; then
        info "[DRY-RUN] Nothing was changed"
    else
        ok "Uninstalled. Kept: logs, PBM itself and every backup in the bucket"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: install / upgrade / reinstall / downgrade
# ---------------------------------------------------------------------------
MODE=install
if [[ -n $INSTALLED ]]; then
    case $(vercmp "$PKG_VERSION" "$INSTALLED") in
        1)  MODE=upgrade ;;
        0)  MODE=reinstall ;;
        -1) MODE=downgrade ;;
    esac
fi
if [[ $UPGRADE == 1 && $MODE == install ]]; then
    die "--upgrade: pbm-backup is not installed under ${D}${PREFIX}. Run without --upgrade to install it" 2
fi
if [[ $MODE == downgrade && $ALLOW_DOWNGRADE == 0 ]]; then
    die "Installed version ${INSTALLED} is newer than this package (${PKG_VERSION}). Use --allow-downgrade to install it anyway" 2
fi
if [[ $FRESH_CONFIG == 1 && $MODE == install ]]; then
    warn "--fresh-config has no effect on a fresh install"
fi

# Resolve the options: given now > installed before > defaults.
SCHEME=${SCHEME:-${PREV_SCHEME:-physical}}
METRICS=${METRICS:-${PREV_METRICS:-0}}
LEGACY_WRAPPERS=${LEGACY_WRAPPERS:-${PREV_WRAPPERS:-0}}
INCR_CAL=''
if [[ $SCHEME == logical ]]; then
    if [[ -z $INCR_MIN ]]; then
        INCR_MIN=${PREV_INCR:-}
    fi
    if [[ -z $INCR_MIN ]]; then
        INCR_MIN=$( { [[ -r ${D}${SYSCONF}/pbm-backup ]] && . "${D}${SYSCONF}/pbm-backup" >/dev/null 2>&1; printf '%s' "${OPLOG_INCR_MIN:-}"; } || true)
        INCR_MIN=${INCR_MIN:-360}
    fi
    [[ $INCR_MIN =~ ^[0-9]+$ ]] && (( INCR_MIN > 0 )) || die "--incr-every-min must be a positive integer" 2
    INCR_CAL=$(calendar_every "$INCR_MIN") || die "--incr-every-min ${INCR_MIN} must divide a day (e.g. 15, 30, 60, 120, 180, 240, 360, 480, 720)" 2
fi

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pbm-backup-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Render everything that will be installed into $WORK/stage (same relative
# paths as on the member), then compare it with what is there now.
STAGE="$WORK/stage"
mkdir -p "${STAGE}${PREFIX}/bin" "${STAGE}${LIBDIR}" "${STAGE}${DOCDIR}" "${STAGE}${UNIT_DIR}"
cp "${SRC}/bin/pbm-backup" "${STAGE}${BIN}"
cp "${SRC}"/lib/*.sh "${STAGE}${LIBDIR}/"
for f in README.md INSTALL.md CHANGES.md; do
    [[ -r ${SRC}/$f ]] && cp "${SRC}/$f" "${STAGE}${DOCDIR}/$f"
done
cp "${SRC}/etc/pbm-backup.conf.example" "${STAGE}${DOCDIR}/pbm-backup.conf.example"
[[ -r ${SRC}/mongodb/pbmuser.create.js ]] && cp "${SRC}/mongodb/pbmuser.create.js" "${STAGE}${DOCDIR}/"
[[ -r ${SRC}/tools/gcs-hmac-test.py ]] && cp "${SRC}/tools/gcs-hmac-test.py" "${STAGE}${DOCDIR}/"
printf '%s\n' "${PKG_VERSION:-unknown}" >"${STAGE}${DOCDIR}/VERSION"
for f in "${SRC}"/systemd/services/pbm-backup-*.service "${SRC}"/systemd/timers/pbm-backup-*.timer; do
    sed "s|/usr/local/bin/pbm-backup|${BIN}|; s|/usr/local/share/doc|${PREFIX}/share/doc|" "$f" >"${STAGE}${UNIT_DIR}/$(basename "$f")"
done
if [[ $SCHEME == logical ]]; then
    mkdir -p "${STAGE}${DROPIN}"
    printf '# Written by install.sh: logical scheme, every %s minutes.\n[Timer]\nOnCalendar=\nOnCalendar=%s\n' \
        "$INCR_MIN" "$INCR_CAL" >"${STAGE}${DROPIN}/schedule.conf"
fi
if [[ $LEGACY_WRAPPERS == 1 ]]; then
    mkdir -p "${STAGE}${SYSCONF}"
    for f in $LEGACY_NAMES; do
        cp "${SRC}/sysconfig/$f" "${STAGE}${SYSCONF}/$f"
    done
fi

N_NEW=0 N_CHANGED=0 N_SAME=0 N_REMOVED=0
PLAN_FILES=''
while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    if [[ ! -e ${D}${rel} ]]; then
        PLAN_FILES="${PLAN_FILES}    new       ${rel}"$'\n'; N_NEW=$((N_NEW + 1))
    elif cmp -s "${STAGE}${rel}" "${D}${rel}"; then
        N_SAME=$((N_SAME + 1))
    else
        PLAN_FILES="${PLAN_FILES}    changed   ${rel}"$'\n'; N_CHANGED=$((N_CHANGED + 1))
    fi
done <<EOF
$(cd "$STAGE" && find . -type f | sed 's|^\.||' | LC_ALL=C sort)
EOF

# Files of the installed version that this package no longer has.
STALE=''
for f in "${D}${LIBDIR}"/*.sh "${D}${UNIT_DIR}"/pbm-backup-*.service "${D}${UNIT_DIR}"/pbm-backup-*.timer "${D}${DROPIN}/schedule.conf"; do
    [[ -e $f ]] || continue
    rel=${f#"$D"}
    if [[ ! -e ${STAGE}${rel} ]]; then
        STALE="${STALE}${rel}"$'\n'
        PLAN_FILES="${PLAN_FILES}    removed   ${rel}"$'\n'; N_REMOVED=$((N_REMOVED + 1))
    fi
done

case $MODE in
    install)   info "Installing pbm-backup ${PKG_VERSION} (nothing installed under ${D}${PREFIX})" ;;
    upgrade)   info "Installed version ${INSTALLED} detected: UPGRADE ${INSTALLED} -> ${PKG_VERSION}" ;;
    reinstall) info "Installed version ${INSTALLED} detected: REINSTALL of the same version" ;;
    downgrade) warn "Installed version ${INSTALLED} detected: DOWNGRADE ${INSTALLED} -> ${PKG_VERSION} (--allow-downgrade)" ;;
esac
info "Source ${SRC}, prefix ${PREFIX}, config dir ${SYSCONF}${D:+, staging root ${D}}"

printf '%s\n' "${C_BLD}Plan${C_OFF}"
if [[ $MODE != install ]]; then
    printf '  Options (given now > installed before):\n'
    printf '    scheme %s%s, metrics timer %s, legacy wrappers %s\n' "$SCHEME" "${INCR_CAL:+ (incr every ${INCR_MIN} min: ${INCR_CAL})}" \
        "$([[ $METRICS == 1 ]] && echo on || echo off)" "$([[ $LEGACY_WRAPPERS == 1 ]] && echo on || echo off)"
    if [[ -n $PREV_SCHEME && $PREV_SCHEME != "$SCHEME" ]]; then
        warn "Scheme changes from ${PREV_SCHEME} to ${SCHEME}"
    fi
fi
printf '  Files: %d new, %d changed, %d removed, %d unchanged\n' "$N_NEW" "$N_CHANGED" "$N_REMOVED" "$N_SAME"
printf '%s' "$PLAN_FILES"

CFG_LIST=$(config_files)
if [[ $MODE != install && -n $CFG_LIST ]]; then
    if [[ $FRESH_CONFIG == 1 ]]; then
        printf '  Configuration: RENAMED to <file>.%s.%s.%s and replaced by the new templates (--fresh-config):\n' "$MODE" "$INSTALLED" "$TS"
    else
        printf '  Configuration: kept in place; a copy is saved as <file>.%s.%s.%s:\n' "$MODE" "$INSTALLED" "$TS"
    fi
    printf '%s\n' "$CFG_LIST" | sed 's/^/    /'
fi

# New tunables: variables in the new example that the installed one lacks.
if [[ $MODE != install && -r ${D}${DOCDIR}/pbm-backup.conf.example ]]; then
    newvars=$(comm -13 \
        <(sed -n 's/^#\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "${D}${DOCDIR}/pbm-backup.conf.example" | LC_ALL=C sort -u) \
        <(sed -n 's/^#\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "${SRC}/etc/pbm-backup.conf.example" | LC_ALL=C sort -u) | tr '\n' ' ')
    if [[ -n ${newvars// /} ]]; then
        printf '  New settings available (see %s/pbm-backup.conf.example): %s\n' "$DOCDIR" "$newvars"
    fi
fi

# What changed since the installed version: CHANGES.md sections "(x.y.z)".
if [[ $MODE == upgrade && -r ${SRC}/CHANGES.md ]]; then
    whatsnew=''
    while IFS= read -r line; do
        v=$(printf '%s\n' "$line" | sed -n 's/.*(\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\))[[:space:]]*$/\1/p')
        [[ -n $v ]] || continue
        if [[ $(vercmp "$v" "$INSTALLED") == 1 ]]; then
            whatsnew="${whatsnew}    ${line#\#\# }"$'\n'
        fi
    done <<EOF
$(grep '^## ' "${SRC}/CHANGES.md")
EOF
    if [[ -n $whatsnew ]]; then
        printf '  Changes since %s (CHANGES.md):\n%s' "$INSTALLED" "$whatsnew"
    fi
fi

if [[ $DRY_RUN == 1 ]]; then
    printf '%s\n' "${C_BLD}Actions${C_OFF}"
fi

# ---------------------------------------------------------------------------
# Dependencies (warnings only: the node may be prepared later)
# ---------------------------------------------------------------------------
for c in pbm jq; do
    command -v "$c" >/dev/null 2>&1 || warn "'$c' not found in PATH (required at run time)"
done
command -v mongosh >/dev/null 2>&1 || command -v mongo >/dev/null 2>&1 \
    || warn "Neither mongosh nor mongo found in PATH (required at run time)"

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
# 1. Configuration backups (before anything is replaced)
BACKUPS=''
if [[ $MODE != install && -n $CFG_LIST ]]; then
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        dst="${f}.${MODE}.${INSTALLED}.${TS}"
        if [[ $FRESH_CONFIG == 1 ]]; then
            run mv "${D}${f}" "${D}${dst}"
        else
            run cp -p "${D}${f}" "${D}${dst}"
        fi
        BACKUPS="${BACKUPS}    ${dst}"$'\n'
    done <<EOF
$CFG_LIST
EOF
fi

# 2. Files that this version no longer ships
if [[ -n $STALE ]]; then
    while IFS= read -r rel; do
        [[ -n $rel ]] && run rm -f "${D}${rel}"
    done <<EOF
$STALE
EOF
fi

# 3. Binary, libraries, docs
run install -d -m 0755 "${D}${PREFIX}/bin" "${D}${LIBDIR}" "${D}${DOCDIR}" "${D}${SYSCONF}" "${D}${UNIT_DIR}"
run install -m 0755 "${STAGE}${BIN}" "${D}${BIN}"
for f in "${STAGE}${LIBDIR}"/*.sh; do
    run install -m 0644 "$f" "${D}${LIBDIR}/$(basename "$f")"
done
for f in README.md INSTALL.md CHANGES.md VERSION pbm-backup.conf.example pbmuser.create.js; do
    [[ -r ${STAGE}${DOCDIR}/$f ]] && run install -m 0644 "${STAGE}${DOCDIR}/$f" "${D}${DOCDIR}/$f"
done
[[ -r ${STAGE}${DOCDIR}/gcs-hmac-test.py ]] && run install -m 0755 "${STAGE}${DOCDIR}/gcs-hmac-test.py" "${D}${DOCDIR}/gcs-hmac-test.py"

# 4. Configuration: created from the templates when missing, never
#    overwritten. pbm-conf (0600) will hold the PBM password; pbm-backup
#    refuses to run while its template placeholders are still there.
if [[ -e ${D}${SYSCONF}/pbm-backup ]]; then
    info "Keeping ${SYSCONF}/pbm-backup"
else
    run install -m 0640 "${SRC}/etc/pbm-backup.conf.example" "${D}${SYSCONF}/pbm-backup"
fi
if [[ -e ${D}${SYSCONF}/pbm-conf ]]; then
    info "Keeping ${SYSCONF}/pbm-conf"
else
    run install -m 0600 "${SRC}/sysconfig/pbm-conf" "${D}${SYSCONF}/pbm-conf"
    warn "${SYSCONF}/pbm-conf created from the template: set PBM_MONGODB_URI (user, password, replica set) before using pbm-backup"
fi
if [[ $LEGACY_WRAPPERS == 1 ]]; then
    for f in $LEGACY_NAMES; do
        run install -m 0700 "${STAGE}${SYSCONF}/$f" "${D}${SYSCONF}/$f"
    done
fi

# 5. systemd units and the logical-scheme drop-in
for f in "${STAGE}${UNIT_DIR}"/pbm-backup-*.service "${STAGE}${UNIT_DIR}"/pbm-backup-*.timer; do
    run install -m 0644 "$f" "${D}${UNIT_DIR}/$(basename "$f")"
done
if [[ $SCHEME == logical ]]; then
    run install -d -m 0755 "${D}${DROPIN}"
    run install -m 0644 "${STAGE}${DROPIN}/schedule.conf" "${D}${DROPIN}/schedule.conf"
fi

# 6. Version and install options (read back by the next upgrade)
if [[ $DRY_RUN == 1 ]]; then
    printf '  [DRY-RUN] write %s and %s\n' "${DOCDIR}/VERSION" "$STATE"
else
    {
        printf '# Written by install.sh. Read back by the next install/upgrade.\n'
        printf 'VERSION=%s\nSCHEME=%s\nINCR_MIN=%s\nMETRICS=%s\nLEGACY_WRAPPERS=%s\nINSTALLED_AT=%s\nPREVIOUS_VERSION=%s\n' \
            "$PKG_VERSION" "$SCHEME" "${INCR_MIN:-}" "$METRICS" "$LEGACY_WRAPPERS" "$TS" "${INSTALLED:-}"
    } >"${D}${STATE}"
    chmod 0644 "${D}${STATE}"
fi
sc daemon-reload

if [[ $DISABLE_LEGACY == 1 ]]; then
    for t in pbm-physical-full-base.timer pbm-physical-incremental.timer pbm-deletion.timer; do
        if [[ $DRY_RUN == 1 || -n $D ]] || systemctl list-unit-files "$t" >/dev/null 2>&1; then
            sc disable --now "$t" || warn "Could not disable $t"
        fi
    done
fi

timers="pbm-backup-full.timer pbm-backup-incr.timer pbm-backup-cleanup.timer"
[[ $METRICS == 1 ]] && timers="$timers pbm-backup-metrics.timer"
if [[ $ENABLE == 1 ]]; then
    # shellcheck disable=SC2086
    sc enable --now $timers
    [[ $DRY_RUN == 1 || -n $D ]] || ok "Timers enabled: ${timers}"
elif [[ $MODE == install ]]; then
    info "Timers installed but not enabled. Enable with: systemctl enable --now ${timers}"
else
    info "Timers keep their previous state (enabled timers stay enabled)"
fi
[[ $METRICS == 1 ]] && info "Metrics timer: set METRICS_DIR in ${SYSCONF}/pbm-backup"

if [[ $DRY_RUN == 1 ]]; then
    info "[DRY-RUN] Nothing was changed"
    exit 0
fi
if [[ -n $BACKUPS ]]; then
    if [[ $FRESH_CONFIG == 1 ]]; then
        info "Previous configuration renamed (fill in the new ${SYSCONF}/pbm-conf):"
    else
        info "Configuration backups:"
    fi
    printf '%s' "$BACKUPS"
fi
case $MODE in
    install)   ok "pbm-backup ${PKG_VERSION} installed. Next: '${BIN} check' on this member (read-only), then on the others" ;;
    upgrade)   ok "pbm-backup upgraded ${INSTALLED} -> ${PKG_VERSION}. Next: '${BIN} check'" ;;
    reinstall) ok "pbm-backup ${PKG_VERSION} reinstalled. Next: '${BIN} check'" ;;
    downgrade) ok "pbm-backup downgraded ${INSTALLED} -> ${PKG_VERSION}. Next: '${BIN} check'" ;;
esac
