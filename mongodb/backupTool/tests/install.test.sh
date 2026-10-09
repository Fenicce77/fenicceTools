#!/usr/bin/env bash
#
# install.test.sh - Lifecycle tests for install.sh in a staging root
# (--destdir): install, reinstall, upgrade (plan, config backups, kept
# options, stale files, what's new), options inferred from pre-0.6.6
# installs, downgrade, --fresh-config, scheme change, --dry-run, uninstall,
# configuration copies (confirmations, edited / unedited package copies,
# replace with backup, agent and storage files), log dirs and logrotate.
# No root, no systemd needed.
#
# Usage: tests/install.test.sh [-h|--help] [BASH_BINARY]
set -uo pipefail

case ${1:-} in
    -h|--help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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
LR=/etc/logrotate.d

pass=0 fail=0
inst() { "$BASH_BIN" "$ROOT/install.sh" --destdir "$R" --sysconfdir "$SC" --yes "$@" >"$WORK/out" 2>&1; RC=$?; }
ok_() { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko_() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; sed 's/^/       | /' "$WORK/out"; }
t_rc()   { [[ $RC == "$1" ]] && ok_ "$2" || ko_ "$2 (rc=$RC, want $1)"; }
t_out()  { grep -qE -- "$1" "$WORK/out" && ok_ "$2" || ko_ "$2"; }
t_nout() { grep -qE -- "$1" "$WORK/out" && ko_ "$2" || ok_ "$2"; }
t_file() { [[ -e $R$1 ]] && ok_ "$2" || ko_ "$2 (missing $1)"; }
t_nofile() { [[ ! -e $R$1 ]] && ok_ "$2" || ko_ "$2 ($1 exists)"; }
t_grep() { grep -qE -- "$2" "$R$1" 2>/dev/null && ok_ "$3" || ko_ "$3 ($1 !~ $2)"; }
# pinst ANSWERS ARGS... - install.sh of the editable package copy ($P),
# answering the confirmations with ANSWERS (one per line) on stdin.
pinst() {
    local a=$1
    shift
    printf '%b' "$a" | PBM_INSTALL_ASSUME_TTY=1 "$BASH_BIN" "$P/install.sh" --destdir "$R" --sysconfdir "$SC" "$@" >"$WORK/out" 2>&1
    RC=$?
}
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

printf '\n[confirmations: fresh install]\n'
rm -rf "$R"
P="$WORK/pkg"
mkdir -p "$P"
(cd "$ROOT" && cp -R install.sh bin lib etc sysconfig conf systemd mongodb tools README.md INSTALL.md CHANGES.md "$P/")
"$BASH_BIN" "$P/install.sh" --destdir "$R" --sysconfdir "$SC" </dev/null >"$WORK/out" 2>&1; RC=$?
t_rc 2 "no terminal and no --yes: refused"
t_out "Re-run with --yes" "explained"
t_nofile /usr/local/bin/pbm-backup "nothing installed"
pinst 'n\n'
t_rc 3 "first confirmation declined"
t_out "copy      sysconfig/pbm-conf -> $SC/pbm-conf \(0600\)  NOT EDITED" "plan: copy, not edited"
t_out "WARNING: these files would be copied WITHOUT being edited" "warning block"
t_out "Cancelled: nothing was changed" "explained"
t_nofile /usr/local/bin/pbm-backup "nothing installed"
pinst 'y\nn\n'
t_rc 3 "second confirmation (unedited files) declined"
t_out "Some of them are NOT edited" "second question"
t_nofile $SC/pbm-conf "nothing installed"
pinst 'y\ny\n'
t_rc 0 "both confirmed"
t_grep $SC/pbm-conf '<pbm_password>' "template copied"
t_out "EDIT these files on this member" "edit warning after install"
t_out "$SC/pbm-conf: PBM_MONGODB_URI" "  names pbm-conf"
t_out "$SC/pbm-backup has the package defaults" "defaults note for pbm-backup"
t_file /data/backup/pbm/logs "LOG_DIR created (default)"
t_grep $LR/pbm-backup '^/data/backup/pbm/logs/\*\.log \{' "logrotate for the default LOG_DIR"
t_grep $LR/pbm-backup 'Managed by pbm-backup install.sh' "logrotate marker"
t_grep $DOC/install.state '^LOGROTATE=1$' "state: logrotate"
[[ $(stat -f '%Lp' "$R/data/backup/pbm/logs" 2>/dev/null || stat -c '%a' "$R/data/backup/pbm/logs") == 750 ]] && ok_ "LOG_DIR mode 0750" || ko_ "LOG_DIR mode 0750"

printf '\n[package copy not edited: member files kept, no questions]\n'
sed -i.tmp 's|<pbm_user>:<pbm_password>|pbmuser:S3cret|; s|<replica_set>|rs44|' "$R$SC/pbm-conf" && rm -f "$R$SC/pbm-conf.tmp"
"$BASH_BIN" "$P/install.sh" --destdir "$R" --sysconfdir "$SC" </dev/null >"$WORK/out" 2>&1; RC=$?
t_rc 0 "reinstall without terminal: nothing to confirm"
t_out "keep      $SC/pbm-conf \(package copy sysconfig/pbm-conf not edited\)" "plan: keep"
t_out "same      $SC/pbm-backup" "plan: same"
t_grep $SC/pbm-conf 'pbmuser:S3cret' "member pbm-conf kept"
t_nout "EDIT these files" "no edit warning"

printf '\n[edited package copies: replace with backup, LOG_DIR from the config]\n'
sed -i.tmp 's|<pbm_user>:<pbm_password>|pbmuser:N3w|; s|<replica_set>|rs44|' "$P/sysconfig/pbm-conf" && rm -f "$P/sysconfig/pbm-conf.tmp"
printf 'PBM_LOCAL_ROOT=/var/lib/pbm-backup\nLOG_DIR=/var/log/pbm-backup\n' >>"$P/etc/pbm-backup.conf"
pinst 'y\n'
t_rc 0 "one confirmation (everything edited)"
t_nout "NOT EDITED" "no unedited files"
t_out "replace   sysconfig/pbm-conf -> $SC/pbm-conf \(0600\); current file saved as $SC/pbm-conf.reinstall.$VER" "plan: replace, saved as the reinstall copy"
t_out "replace   etc/pbm-backup.conf -> $SC/pbm-backup" "plan: replace pbm-backup"
t_grep $SC/pbm-conf 'pbmuser:N3w' "pbm-conf replaced"
t_glob "$SC/pbm-conf.reinstall.$VER.*" "previous pbm-conf saved"
t_out "create    /var/log/pbm-backup  - LOG_DIR" "plan: new LOG_DIR"
t_file /var/log/pbm-backup "LOG_DIR from the edited config"
t_file /var/lib/pbm-backup "PBM_LOCAL_ROOT from the edited config"
t_grep $LR/pbm-backup '^/var/log/pbm-backup/\*\.log \{' "logrotate follows LOG_DIR"
t_out "changed   $LR/pbm-backup" "plan: logrotate changed"

printf '\n[agent and storage files]\n'
rm -f "$R$SC"/*.reinstall.*
printf 'old\n' >"$R/etc/pbm-storage.conf"
pinst 'y\ny\n' --pbm-agent-env --pbm-agent-yml --pbm-storage hmac
t_rc 0 "agent env, agent yml, HMAC storage"
t_out "copy      sysconfig/pbm-agent -> $SC/pbm-agent \(0640\)  NOT EDITED" "plan: agent env"
t_out "keep      /etc/pbm-storage.conf \(package copy conf/pbm-conf-gcp-hmac.yml not edited\)" "existing storage file kept (template not edited)"
t_grep /etc/pbm-agent.yml '<this_member_host>' "agent yml copied"
t_file $UD/pbm-agent.service.d/config.conf "agent drop-in copied"
t_file /data/log/pbm "agent log dir created"
t_grep $LR/pbm-agent '^/data/log/pbm/pbm.log \{' "agent logrotate"
t_grep $LR/pbm-agent 'copytruncate' "  copytruncate"
t_out "/etc/pbm-agent.yml: mongodb-uri of THIS member" "edit warning for the agent yml"
sed -e 's|"<bucket>"|"bkt"|; s|"<prefix, e.g. mongocluster/rs44>"|"mc/rs44"|; s|"<HMAC access id>"|"GOOG1EXAMPLE"|' \
    -e 's|"<HMAC secret>"|"secret"|; s|"<bucket location, e.g. europe-west3>"|"europe-west3"|' \
    "$P/conf/pbm-conf-gcp-hmac.yml" >"$WORK/hmac" && cp "$WORK/hmac" "$P/conf/pbm-conf-gcp-hmac.yml"
pinst 'y\n' --pbm-storage hmac
t_rc 0 "edited storage template"
t_out "replace   conf/pbm-conf-gcp-hmac.yml -> /etc/pbm-storage.conf \(0600\); current file saved as /etc/pbm-storage.conf.replaced" "plan: replace"
t_glob "/etc/pbm-storage.conf.replaced.*" "previous storage file saved"
t_grep /etc/pbm-storage.conf 'GOOG1EXAMPLE' "storage file replaced"
t_out "pbm config --file /etc/pbm-storage.conf" "next step shown"
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\necho "Version:   2.5.0"\n' >"$WORK/fakebin/pbm" && chmod +x "$WORK/fakebin/pbm"
PATH="$WORK/fakebin:$PATH" inst --pbm-agent-yml
t_rc 2 "--pbm-agent-yml refused with PBM 2.5.0"
t_out "Use --pbm-agent-env" "explained"
inst --pbm-storage s3
t_rc 2 "--pbm-storage: invalid value"

printf '\n[logrotate: --no-logrotate, files not written by install.sh, uninstall]\n'
inst --no-logrotate
t_rc 0 "--no-logrotate"
t_out "removed   $LR/pbm-backup" "plan: managed logrotate removed"
t_nofile $LR/pbm-backup "managed logrotate removed"
t_grep $DOC/install.state '^LOGROTATE=0$' "state: logrotate off"
printf '# mine\n' >"$R$LR/pbm-backup"
inst --logrotate
t_rc 0 "--logrotate"
t_out "was not written by install.sh: left as it is" "warned"
t_grep $LR/pbm-backup '^# mine$' "administrator file untouched"
rm -f "$R$LR/pbm-backup"
inst
t_file $LR/pbm-backup "logrotate written again (option kept)"
inst --uninstall
t_rc 0 "uninstall"
t_nofile $LR/pbm-backup "pbm-backup logrotate removed"
t_file $LR/pbm-agent "pbm-agent logrotate kept"
t_file /etc/pbm-agent.yml "agent yml kept"
t_file /var/log/pbm-backup "logs kept"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
