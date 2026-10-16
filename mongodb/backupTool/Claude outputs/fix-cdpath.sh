#!/usr/bin/env bash
# Insert "unset CDPATH" right after the first "set -...pipefail" line of each
# script (an exported CDPATH makes "cd DIR" print DIR, which corrupts
# $(cd ... && pwd -P) and $(cd ... && find ...)). Idempotent.
set -euo pipefail
for f in bin/pbm-backup install.sh packaging/build-dist.sh tests/install.test.sh tests/pbmuser.test.sh tests/smoke.sh; do
    grep -q '^unset CDPATH' "$f" && continue
    awk 'done == 0 && /^set -[a-z]+ pipefail/ { print; print "# An exported CDPATH makes \"cd DIR\" print DIR and corrupts $(cd ... && pwd)."; print "unset CDPATH"; done = 1; next } { print }' "$f" >"$f.new"
    cat "$f.new" >"$f"
    rm -f "$f.new"
    bash -n "$f"
    echo "patched $f"
done
