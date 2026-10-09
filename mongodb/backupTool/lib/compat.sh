# shellcheck shell=bash
#
# compat.sh - Phase 2: MongoDB version/edition detection, PBM version
# detection, PBM <-> MongoDB compatibility matrix and backup strategy choice.
#
# Requires: common.sh, mongo.sh, pbm.sh, jq.

# ---------------------------------------------------------------------------
# Compatibility matrix (edit here when PBM releases change support)
# ---------------------------------------------------------------------------
# Sources: project requirements (CLAUDE.md) and the PBM source code
# (pbm/version/version.go, FeatureSupport.PBMSupport):
#   - PBM 2.x is required by this tool (MongoDB 4.0 needs PBM 1.x).
#   - PBM 2.3.0 deprecated MongoDB 4.2; PBM 2.4.0 dropped it
#     (v2.4.0/v2.5.0: "PBM works with v4.4, v5.0, v6.0, v7.0").
#   - PBM 2.6.0 dropped MongoDB 4.4 ("PBM works with v5.0, v6.0, v7.0"):
#     PBM 2.5.0 is the last release for MongoDB 4.4.
#   - PBM 2.7.0 added MongoDB 8.0 ("v5.0, v6.0, v7.0, v8.0").
#   - PBM 2.11.0 dropped MongoDB 5.0 and 6.0 (supportedMajors {7, 8}):
#     PBM 2.10.0 is the last release for 5.0 / 6.0.
#   - The first release whose version gate lists MongoDB 7.0 is 2.4.0.
#   - Physical incremental backups need PSMDB >= the versions below.
# Items marked "verify" come from the PBM docs and were not tested here.
COMPAT_PBM_MIN=2.0.0
COMPAT_MONGO_MIN=4.2
COMPAT_PBM_DEPRECATES_42=2.3.0
COMPAT_PBM_DROPS_42=2.4.0
COMPAT_PBM_DROPS_44=2.6.0
COMPAT_PBM_DROPS_50_60=2.11.0
COMPAT_PBM_MIN_70=2.4.0
COMPAT_PBM_MIN_80=2.7.0
# PSMDB minimum versions for physical incremental backups (verify).
COMPAT_PSMDB_INCR_MIN_42=4.2.24-24
COMPAT_PSMDB_INCR_MIN_44=4.4.18-18
COMPAT_PSMDB_INCR_MIN_50=5.0.14-12
COMPAT_PSMDB_INCR_MIN_60=6.0.3-2

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
# vercmp A B - print -1, 0 or 1. Accepts "8.0.17-6", "v2.12.0", "4.4".
# The PSMDB "-N" suffix is compared as one more numeric field.
vercmp() {
    local a b i x y
    a=$(printf '%s' "$1" | sed 's/^v//; s/-/./g; s/[^0-9.].*$//')
    b=$(printf '%s' "$2" | sed 's/^v//; s/-/./g; s/[^0-9.].*$//')
    local IFS=.
    # shellcheck disable=SC2206
    local -a va=($a) vb=($b)
    local n=${#va[@]}
    (( ${#vb[@]} > n )) && n=${#vb[@]}
    for (( i = 0; i < n; i++ )); do
        x=${va[i]:-0}
        y=${vb[i]:-0}
        x=$((10#$x)) y=$((10#$y))
        if (( x < y )); then printf '%s\n' -1; return 0; fi
        if (( x > y )); then printf '%s\n' 1; return 0; fi
    done
    printf '%s\n' 0
}

# version_ge A B - true if A >= B.
version_ge() {
    [[ $(vercmp "$1" "$2") != -1 ]]
}

# major_minor VERSION - "8.0.17-6" -> "8.0"
major_minor() {
    printf '%s\n' "$1" | sed 's/^v//' | awk -F. '{ print $1 "." $2 }'
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
# detect_mongodb_json - print {"version","psmdb_version","edition","modules"}
# from buildInfo on the node PBM_MONGODB_URI connects to.
#   edition: psmdb      if buildInfo has psmdbVersion, or the version carries
#                       the PSMDB "-N" release suffix (e.g. 8.0.17-6)
#            enterprise if buildInfo.modules contains "enterprise"
#            community  otherwise
# MONGODB_VERSION / MONGODB_EDITION in the config override detection.
detect_mongodb_json() {
    if [[ -n ${MONGODB_VERSION:-} && -n ${MONGODB_EDITION:-} ]]; then
        jq -cn --arg v "$MONGODB_VERSION" --arg e "$MONGODB_EDITION" \
            '{version: $v, psmdb_version: null, edition: $e, modules: [], source: "config"}'
        return 0
    fi
    local js out
    js='var b = db.adminCommand({buildInfo: 1});'
    js+='print(JSON.stringify({version: String(b.version),'
    js+=' psmdbVersion: b.psmdbVersion ? String(b.psmdbVersion) : null,'
    js+=' modules: (b.modules || []).map(String)}));'
    out=$(mongo_eval "$js" 2>/dev/null) || return 1
    printf '%s\n' "$out" | grep '^{' | tail -n 1 | jq -c '
        . as $b
        | {
            version: $b.version,
            psmdb_version: $b.psmdbVersion,
            edition: (if $b.psmdbVersion != null or ($b.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$"))
                      then "psmdb"
                      elif ($b.modules | index("enterprise")) != null then "enterprise"
                      else "community" end),
            modules: $b.modules,
            source: "buildInfo"
          }'
}

# detect_pbm_version - print the pbm CLI version (e.g. 2.12.0).
detect_pbm_version() {
    local out
    out=$("$PBM_BIN" version 2>/dev/null) || return 1
    printf '%s\n' "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# ---------------------------------------------------------------------------
# Compatibility and strategy
# ---------------------------------------------------------------------------
# psmdb_incr_min MAJOR.MINOR - minimum PSMDB for physical incrementals, or
# empty if any version of that series is fine.
psmdb_incr_min() {
    case $1 in
        4.2) printf '%s\n' "$COMPAT_PSMDB_INCR_MIN_42" ;;
        4.4) printf '%s\n' "$COMPAT_PSMDB_INCR_MIN_44" ;;
        5.0) printf '%s\n' "$COMPAT_PSMDB_INCR_MIN_50" ;;
        6.0) printf '%s\n' "$COMPAT_PSMDB_INCR_MIN_60" ;;
        *)   printf '\n' ;;
    esac
}

# resolve_strategy EDITION VERSION - print "physical" or "logical".
# BACKUP_MODE=physical|logical in the config forces it; "auto" (default)
# picks physical only for PSMDB versions that support physical incrementals.
resolve_strategy() {
    local edition=$1 version=$2 min
    case ${BACKUP_MODE:-auto} in
        physical|logical) printf '%s\n' "$BACKUP_MODE"; return 0 ;;
    esac
    if [[ $edition == psmdb ]]; then
        min=$(psmdb_incr_min "$(major_minor "$version")")
        if [[ -z $min ]] || version_ge "$version" "$min"; then
            printf 'physical\n'
            return 0
        fi
    fi
    printf 'logical\n'
}

# compat_report MONGO_VERSION EDITION PBM_VERSION STRATEGY
#   Print one "LEVEL<TAB>message" line per finding (LEVEL = OK|WARN|ERROR).
#   Never logs directly, so it can be captured.
compat_report() {
    local mv=$1 ed=$2 pv=$3 st=$4 mm min
    mm=$(major_minor "$mv")

    if ! version_ge "$pv" "$COMPAT_PBM_MIN"; then
        printf 'ERROR\tPBM %s is not supported by this tool (requires PBM >= %s)\n' "$pv" "$COMPAT_PBM_MIN"
    fi
    if ! version_ge "$mv" "$COMPAT_MONGO_MIN"; then
        printf 'ERROR\tMongoDB %s needs PBM 1.x; this tool supports PBM 2.x only (MongoDB >= %s)\n' "$mv" "$COMPAT_MONGO_MIN"
        return 0
    fi
    case $mm in
        4.2|4.4)
            local drops=$COMPAT_PBM_DROPS_44
            [[ $mm == 4.2 ]] && drops=$COMPAT_PBM_DROPS_42
            if version_ge "$pv" "$drops"; then
                printf 'ERROR\tPBM %s does not support MongoDB %s (dropped in PBM %s). Install PBM < %s\n' \
                    "$pv" "$mm" "$drops" "$drops"
            elif [[ $mm == 4.2 ]] && version_ge "$pv" "$COMPAT_PBM_DEPRECATES_42"; then
                printf 'WARN\tMongoDB 4.2 is deprecated since PBM %s\n' "$COMPAT_PBM_DEPRECATES_42"
            fi
            printf 'WARN\tPin the PBM package on MongoDB %s nodes: "dnf versionlock add percona-backup-mongodb" or "apt-mark hold percona-backup-mongodb"\n' "$mm"
            ;;
        5.0|6.0)
            if version_ge "$pv" "$COMPAT_PBM_DROPS_50_60"; then
                printf 'ERROR\tPBM %s does not support MongoDB %s (dropped in PBM %s). Install PBM < %s\n' \
                    "$pv" "$mm" "$COMPAT_PBM_DROPS_50_60" "$COMPAT_PBM_DROPS_50_60"
            fi
            printf 'WARN\tPin the PBM package on MongoDB %s nodes: "dnf versionlock add percona-backup-mongodb" or "apt-mark hold percona-backup-mongodb"\n' "$mm"
            ;;
        7.*)
            if ! version_ge "$pv" "$COMPAT_PBM_MIN_70"; then
                printf 'ERROR\tMongoDB %s needs PBM >= %s (found %s)\n' "$mm" "$COMPAT_PBM_MIN_70" "$pv"
            fi
            ;;
        8.*)
            if ! version_ge "$pv" "$COMPAT_PBM_MIN_80"; then
                printf 'ERROR\tMongoDB %s needs PBM >= %s (found %s)\n' "$mm" "$COMPAT_PBM_MIN_80" "$pv"
            fi
            ;;
    esac

    if [[ $st == physical ]]; then
        if [[ $ed != psmdb ]]; then
            printf 'ERROR\tPhysical backups need Percona Server for MongoDB; this node runs MongoDB %s (%s). Use BACKUP_MODE=logical\n' "$mv" "$ed"
        else
            min=$(psmdb_incr_min "$mm")
            if [[ -n $min ]] && ! version_ge "$mv" "$min"; then
                printf 'ERROR\tPhysical incremental backups need PSMDB >= %s (found %s)\n' "$min" "$mv"
            fi
        fi
    fi
    printf 'OK\tMongoDB %s (%s), PBM %s, strategy %s\n' "$mv" "$ed" "$pv" "$st"
}
