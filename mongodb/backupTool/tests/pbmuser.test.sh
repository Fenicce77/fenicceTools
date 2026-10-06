#!/usr/bin/env bash
#
# pbmuser.test.sh - Scenario tests for mongodb/pbmuser.create.js, run in a
# real mongosh (--nodb) against a fake admin database. No MongoDB needed.
#
# Usage: tests/pbmuser.test.sh [-h|--help]
set -uo pipefail

case ${1:-} in
    -h|--help)
        sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="${ROOT}/mongodb/pbmuser.create.js"
command -v mongosh >/dev/null 2>&1 || { echo "mongosh not found: skipping"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pbmuser-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
unset PBM_USER PBM_PASSWORD_MODE PBM_ROTATE_PASSWORD PBM_SECRET_DIR PBM_HELP
export NO_COLOR=1

# Fake admin DB. Scenario from env FAKE_*:
#   FAKE_PRIMARY=0       not the primary
#   FAKE_USER_ROLES      JSON array of roles of an existing pbmuser ("" = no user)
#   FAKE_ROLE_PRIVS      JSON privileges of an existing pbmAnyAction ("" = no role)
#   FAKE_PROMPT          "a|b" answers returned by passwordPrompt, in order
FAKE='const E = process.env;
const answers = (E.FAKE_PROMPT || "").split("|");
globalThis.__pbmUserTest = {
  passwordPrompt: () => answers.shift(),
  adminDb: {
    runCommand: () => E.FAKE_PRIMARY === "0"
      ? { isWritablePrimary: false, primary: "n1:27017", setName: "rsTest", me: "n2:27017", hosts: ["n1:27017", "n2:27017"] }
      : { isWritablePrimary: true, setName: "rsTest", me: "n1:27017", hosts: ["n1:27017", "n2:27017", "n3:27017"] },
    getRole: () => E.FAKE_ROLE_PRIVS ? { role: "pbmAnyAction", privileges: JSON.parse(E.FAKE_ROLE_PRIVS), roles: [] } : null,
    createRole: (r) => print("CALL createRole"),
    updateRole: (n, d) => print("CALL updateRole " + JSON.stringify(d)),
    getUser: () => E.FAKE_USER_ROLES ? { user: "pbmuser", roles: JSON.parse(E.FAKE_USER_ROLES) } : null,
    createUser: (u, wc) => print("CALL createUser roles=" + u.roles.map((r) => r.role + "@" + r.db).join(",") + " w=" + wc.w),
    updateUser: (n, d) => print("CALL updateUser " + (d.pwd ? "pwd" : "") + (d.roles ? "roles=" + d.roles.map((r) => r.role).join(",") : "")),
  },
};
undefined;'

PBM_ROLES='[{"role":"readWrite","db":"admin"},{"role":"backup","db":"admin"},{"role":"clusterMonitor","db":"admin"},{"role":"restore","db":"admin"},{"role":"pbmAnyAction","db":"admin"}]'
OLD_ROLES='[{"role":"backup","db":"admin"},{"role":"clusterAdmin","db":"admin"},{"role":"clusterMonitor","db":"admin"},{"role":"readWriteAnyDatabase","db":"admin"},{"role":"userAdminAnyDatabase","db":"admin"},{"role":"restore","db":"admin"}]'
GOOD_PRIVS='[{"resource":{"anyResource":true},"actions":["anyAction"]}]'
WIDE_ROLES='CALL createUser roles=readWrite@admin,backup@admin,clusterMonitor@admin,restore@admin,pbmAnyAction@admin w=majority'

pass=0 fail=0
# run NAME WANT_RC [env assignments...] - runs the script; output in $OUT
run() {
    local name=$1 want=$2
    shift 2
    rm -rf "$WORK/sec"
    OUT=$(env PBM_SECRET_DIR="$WORK/sec" "$@" mongosh --nodb --quiet --eval "$FAKE" --file "$SCRIPT" 2>&1)
    RC=$?
    CUR=$name
    expect_rc "$want"
}
ok_()  { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko_()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       | /'; }
expect_rc() { [[ $RC == "$1" ]] && ok_ "$CUR: exit $1" || ko_ "$CUR: exit $RC, want $1"; }
has()    { grep -qE -- "$1" <<<"$OUT" && ok_ "$CUR: $2" || ko_ "$CUR: $2"; }
hasnt()  { grep -qE -- "$1" <<<"$OUT" && ko_ "$CUR: $2" || ok_ "$CUR: $2"; }
file_ok() { # regex description
    local f
    f=$(ls "$WORK"/sec/*.env 2>/dev/null | head -n 1)
    if [[ -n $f ]] && grep -qE -- "$1" "$f"; then ok_ "$CUR: $2"; else ko_ "$CUR: $2"; fi
}
no_file() { ls "$WORK"/sec/*.env >/dev/null 2>&1 && ko_ "$CUR: no secret file" || ok_ "$CUR: no secret file"; }
perms() {
    local f d fm dm
    f=$(ls "$WORK"/sec/*.env 2>/dev/null | head -n 1)
    fm=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)
    dm=$(stat -f '%Lp' "$WORK/sec" 2>/dev/null || stat -c '%a' "$WORK/sec" 2>/dev/null)
    [[ $fm == 600 && $dm == 700 ]] && ok_ "$CUR: file 0600, dir 0700" || ko_ "$CUR: file $fm, dir $dm (want 600/700)"
}

printf 'pbmuser.create.js tests (%s)\n' "$(mongosh --version)"

printf '\n[new user]\n'
run "generate" 0
has 'CALL createRole' "role created"
has "$WIDE_ROLES" "exactly the 5 PBM roles, w:majority"
has 'Password    : [A-Za-z0-9]{32}$' "32-char alphanumeric password shown"
has 'Password saved to: .*/sec/pbmuser\.rsTest\.[0-9]{8}T[0-9]{6}Z\.env' "file path shown"
perms
file_ok "^PBM_PASSWORD='[A-Za-z0-9]{32}'$" "password in file"
file_ok '^PBM_MONGODB_URI="mongodb://pbmuser:[A-Za-z0-9]{32}@n1:27017,n2:27017,n3:27017/\?authSource=admin&replicaSet=rsTest"$' "pbm-conf URI (seed list)"
file_ok '^#   PBM_MONGODB_URI="mongodb://pbmuser:[A-Za-z0-9]{32}@n3:27017/\?authSource=admin"$' "pbm-agent URI per member"

run "prompt with special characters" 0 PBM_PASSWORD_MODE=prompt "FAKE_PROMPT=Secr#t@pw/'x\$1|Secr#t@pw/'x\$1"
has "Password    : Secr#t@pw/'x\\\$1$" "typed password shown as is"
file_ok "^PBM_PASSWORD='Secr#t@pw/'\\\\''x\\\$1'$" "shell-quoted in file"
file_ok 'mongodb://pbmuser:Secr%23t%40pw%2F'"'"'x%241@' "percent-encoded in the URI"

run "prompt mismatch" 2 PBM_PASSWORD_MODE=prompt "FAKE_PROMPT=abcdefghijkl|abcdefghijkX"
hasnt 'CALL createUser' "user not created"
no_file

run "prompt too short" 2 PBM_PASSWORD_MODE=prompt "FAKE_PROMPT=short|short"
hasnt 'CALL createUser' "user not created"

run "custom user name" 0 PBM_USER=pbm_backup
file_ok "^PBM_USER='pbm_backup'$" "user name in file"

printf '\n[existing user]\n'
run "old over-privileged roles" 0 "FAKE_USER_ROLES=$OLD_ROLES" "FAKE_ROLE_PRIVS=$GOOD_PRIVS"
has 'CALL updateUser roles=readWrite,backup,clusterMonitor,restore,pbmAnyAction' "roles replaced"
has 'removed: clusterAdmin@admin, readWriteAnyDatabase@admin, userAdminAnyDatabase@admin' "removed roles reported"
has 'added: readWrite@admin, pbmAnyAction@admin' "added roles reported"
hasnt 'CALL updateUser pwd' "password not changed"
hasnt 'Password    :' "no password shown"
no_file

run "already correct" 0 "FAKE_USER_ROLES=$PBM_ROLES" "FAKE_ROLE_PRIVS=$GOOD_PRIVS"
hasnt 'CALL (updateUser|updateRole|createRole|createUser)' "nothing changed"
has 'already has exactly the PBM roles' "reported"

run "rotate password" 0 PBM_ROTATE_PASSWORD=1 "FAKE_USER_ROLES=$PBM_ROLES" "FAKE_ROLE_PRIVS=$GOOD_PRIVS"
has 'CALL updateUser pwd' "password changed"
has 'EVERY member' "warns to update every member"
file_ok "^PBM_PASSWORD='[A-Za-z0-9]{32}'$" "new password saved"

run "role with wrong privileges" 0 "FAKE_USER_ROLES=$PBM_ROLES" 'FAKE_ROLE_PRIVS=[{"resource":{"db":"admin","collection":""},"actions":["find"]}]'
has 'CALL updateRole' "role fixed"

printf '\n[errors / help]\n'
run "not primary" 1 FAKE_PRIMARY=0
has 'Not connected to the PRIMARY \(primary is n1:27017\)' "clear message"
hasnt 'CALL ' "nothing changed"

run "invalid mode" 2 PBM_PASSWORD_MODE=random
hasnt 'CALL ' "nothing changed"

run "invalid user name" 2 'PBM_USER=bad user'

run "help" 0 PBM_HELP=1
has 'pbmuser.create.js - Create or update' "header printed"
has 'PBM_ROTATE_PASSWORD' "variables documented"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
