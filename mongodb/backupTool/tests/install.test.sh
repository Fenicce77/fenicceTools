#!/usr/bin/env bash
#
# install.test.sh - Lifecycle tests for install.sh in a staging root
# (--destdir): install, reinstall, upgrade (plan, config backups, kept
# options, stale files, what's new), options inferred from pre-0.6.6
# installs, downgrade, --fresh-config, scheme change, --dry-run, uninstall.
# No root, no systemd needed.
#
# Usage: tests/install.test.sh [-h|--help] [BASH_BINARY]
set -uo pipefail

case ${1:-} in
    -h|--help)
        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac
BASH_BIN=${1:-bash}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pbm-backup-install-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export NO_COLOR=1
VER=$(sed -n 's/^VERSION=//p' "$ROOT/bin/pbm-backup" | head -n 1)
R="$WORK/root"
SC=/etc/sysconfig
DOC=/usr/local/share/doc/pbm-backup
UD=/etc/systemd/system

pass=0 fail=0
inst() { "$BASH_BIN" "$ROOT/install.sh" --destdir "$R" --sysconfdir "$SC" "$@" >"$WORK/out" 2>&1; RC=$?; }
ok_() { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko_() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; sed 's/^/       | /' "$WORK/out"; }
t_rc()   { [[ $RC == "$1" ]] && ok_ "$2" || ko_ "$2 (rc=$RC, want $1)"; }
t_out()  { grep -qE -- "$1" "$WORK/out" && ok_ "$2" || ko_ "$2"; }
t_nout() { grep -qE -- "$1" "$WORK/out" && ko_ "$2" || ok_ "$2"; }
t_file() { [[ -e $R$1 ]] && ok_ "$2" || ko_ "$2 (missing $1)"; }
t_nofile() { [[ ! -e $R$1 ]] && ok_ "$2" || ko_ "$2 ($1 exists)"; }
t_grep() { grep -qE -- "$2" "$R$1" 2>/dev/null && ok_ "$3" || ko_ "$3 ($1 !~ $2)"; }
t_glob() { # pattern description
    ls $R$1 >/dev/null 2>&1 && ok_ "$2" || ko_ "$2 (no $1)"
}
state() { sed -n "s/^$1=//p" "$R$DOC/install.state"; }

printf 'install.sh lifecycle tests (%s, package %s)\n' "$("$BASH_BIN" -c 'echo $BASH_VERSION')" "$VER"

printf '\n[fresh install]\n'
inst --scheme logical --incr-every-min 360 --metrics
t_rc 0 "fresh install"
t_out "Installing pbm-backup $VER \(nothing installed" "mode install"
t_file /usr/local/bin/pbm-backup "binary installed"
t_grep $UD/pbm-backup-incr.timer.d/schedule.conf '00/6:30:00' "logical drop-in"
t_grep $DOC/install.state '^SCHEME=logical$' "state: scheme"
t_grep $DOC/install.state '^INCR_MIN=360$' "state: interval"
t_grep $DOC/install.state '^METRICS=1$' "state: metrics"
t_grep $SC/pbm-conf '<pbm_password>' "pbm-conf from the template"
sed -i.tmp 's|<pbm_user>:<pbm_password>|pbmuser:S3cret|; s|<replica_set>|rs44|' "$R$SC/pbm-conf" && rm -f "$R$SC/pbm-conf.tmp"
printf 'RETENTION_DAYS=14\n' >>"$R$SC/pbm-backup"

printf '\n[reinstall, same version, no options]\n'
inst
t_rc 0 "reinstall"
t_out "REINSTALL of the same version" "mode reinstall"
t_out "scheme logical \(incr every 360 min" "previous scheme kept"
t_out "metrics timer on" "previous metrics kept"
t_file $UD/pbm-backup-incr.timer.d/schedule.conf "drop-in kept (was removed before 0.6.6)"
t_glob "$SC/pbm-conf.reinstall.$VER.*" "pbm-conf backup copy"
t_grep $SC/pbm-conf 'pbmuser:S3cret' "active pbm-conf kept"
t_grep $SC/pbm-backup '^RETENTION_DAYS=14$' "active pbm-backup kept"
t_out "Files: 0 new, 0 changed, 0 removed" "nothing to change"

printf '\n[upgrade from an older version]\n'
rm -f "$R$SC"/*.reinstall.*
printf '0.6.0\n' >"$R$DOC/VERSION"
sed -i.tmp 's/^VERSION=.*/VERSION=0.6.0/' "$R$DOC/install.state" && rm -f "$R$DOC/install.state.tmp"
printf '# old\n' >>"$R/usr/local/lib/pbm-backup/pbm.sh"
printf '# stale\n' >"$R/usr/local/lib/pbm-backup/old.sh"
sed -i.tmp '/^#METRICS_DIR=/d' "$R$DOC/pbm-backup.conf.example" && rm -f "$R$DOC/pbm-backup.conf.example.tmp"
inst --dry-run
t_rc 0 "upgrade --dry-run"
t_out "UPGRADE 0.6.0 -> $VER" "dry-run shows the upgrade"
t_file /usr/local/lib/pbm-backup/old.sh "dry-run changes nothing (stale file still there)"
t_grep $DOC/VERSION '^0.6.0$' "dry-run keeps the version file"
inst --upgrade
t_rc 0 "upgrade"
t_out "changed   /usr/local/lib/pbm-backup/pbm.sh" "plan: changed library"
t_out "removed   /usr/local/lib/pbm-backup/old.sh" "plan: stale library"
t_out "changed   $DOC/VERSION" "plan: version file"
t_out "New settings available .*METRICS_DIR" "plan: new settings"
t_out "Changes since 0.6.0 \(CHANGES.md\)" "plan: what's new header"
t_out "pbm-conf on install \(0.6.2\)" "plan: lists a 0.6.2 section"
t_nout "Packaging \(0.6.0\)" "plan: not the installed version's section"
t_nofile /usr/local/lib/pbm-backup/old.sh "stale library removed"
t_glob "$SC/pbm-conf.upgrade.0.6.0.*" "pbm-conf copied as .upgrade.0.6.0.<ts>"
t_glob "$SC/pbm-backup.upgrade.0.6.0.*" "pbm-backup copied as .upgrade.0.6.0.<ts>"
t_grep $SC/pbm-conf 'pbmuser:S3cret' "active pbm-conf kept"
t_grep $DOC/VERSION "^$VER$" "version file updated"
t_grep $DOC/install.state '^PREVIOUS_VERSION=0.6.0$' "state: previous version"
t_out "upgraded 0.6.0 -> $VER" "summary"

printf '\n[upgrade from a pre-0.6.6 install (no install.state)]\n'
rm -f "$R$DOC/install.state" "$R$SC"/*.upgrade.*
printf '0.6.4\n' >"$R$DOC/VERSION"
inst
t_rc 0 "upgrade without state file"
t_out "scheme logical \(incr every 360 min" "scheme and interval inferred from the drop-in"
t_file $UD/pbm-backup-incr.timer.d/schedule.conf "drop-in kept"

printf '\n[downgrade]\n'
printf '9.9.9\n' >"$R$DOC/VERSION"
inst
t_rc 2 "older package refused"
t_out "newer than this package" "explained"
inst --allow-downgrade
t_rc 0 "--allow-downgrade"
t_out "DOWNGRADE 9.9.9 -> $VER" "mode downgrade"
t_glob "$SC/pbm-conf.downgrade.9.9.9.*" "pbm-conf copied as .downgrade.9.9.9.<ts>"

printf '\n[--fresh-config]\n'
rm -f "$R$SC"/*.downgrade.*
inst --fresh-config
t_rc 0 "fresh-config"
t_glob "$SC/pbm-conf.reinstall.$VER.*" "old pbm-conf renamed"
t_grep $SC/pbm-conf '<pbm_password>' "new pbm-conf from the template"
t_out "Previous configuration renamed" "explained"

printf '\n[scheme change]\n'
inst --scheme physical
t_rc 0 "logical -> physical"
t_out "Scheme changes from logical to physical" "warned"
t_out "removed   $UD/pbm-backup-incr.timer.d/schedule.conf" "plan: drop-in removed"
t_nofile $UD/pbm-backup-incr.timer.d/schedule.conf "drop-in removed"
t_grep $DOC/install.state '^SCHEME=physical$' "state updated"

printf '\n[legacy wrappers and uninstall]\n'
inst --legacy-wrappers
t_rc 0 "legacy wrappers installed"
t_grep $DOC/install.state '^LEGACY_WRAPPERS=1$' "state: wrappers"
rm -f "$R$SC"/*.reinstall.*
inst --uninstall --dry-run
t_rc 0 "uninstall --dry-run"
t_file /usr/local/bin/pbm-backup "dry-run keeps the binary"
t_file $SC/pbm-conf "dry-run keeps the configuration"
inst --uninstall
t_rc 0 "uninstall"
t_nofile /usr/local/bin/pbm-backup "binary removed"
t_nofile $DOC "doc dir removed"
t_nofile $SC/pbm-conf "pbm-conf renamed away"
t_glob "$SC/pbm-conf.uninstall.$VER.*" "pbm-conf.uninstall.<version>.<ts>"
t_glob "$SC/pbm-backup.uninstall.$VER.*" "pbm-backup.uninstall.<version>.<ts>"
t_glob "$SC/pbm-deletion.uninstall.$VER.*" "legacy wrapper renamed"
t_out "still holds the PBM password" "password warning"

printf '\n[uninstall --keep-config, option errors]\n'
inst --scheme logical
inst --uninstall --keep-config
t_rc 0 "uninstall --keep-config"
t_file $SC/pbm-conf "pbm-conf left in place"
inst --upgrade
t_rc 2 "--upgrade with nothing installed"
inst --keep-config
t_rc 2 "--keep-config without --uninstall"
printf '# original\nexec /usr/bin/true\n' >"$R$SC/pbm-physical-full-base"
inst
inst --uninstall
t_file $SC/pbm-physical-full-base "an original (non-wrapper) script is never renamed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
