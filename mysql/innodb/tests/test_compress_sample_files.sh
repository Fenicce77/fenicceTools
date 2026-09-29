#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/../compress.sample.files.sh"
TEMPLATE_CONFIG="$SCRIPT_DIR/../conf/compress.sample.files.template.cnf"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compress-samples.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

[ -r "$TEMPLATE_CONFIG" ] || { printf 'FAIL: missing configuration template\n' >&2; exit 1; }
grep -q '^logdir=/path/to/innodb/samples$' "$TEMPLATE_CONFIG"
grep -q '^dailytocompressret=2$' "$TEMPLATE_CONFIG"
grep -q '^toremovalretention=14$' "$TEMPLATE_CONFIG"

SAMPLE_ROOT="$TEST_DIR/samples root"
DAY_DIR="$SAMPLE_ROOT/20260925"
mkdir -p "$DAY_DIR"
printf 'sample payload\n' > "$DAY_DIR/20260925_10.sample"
touch -t 202609250000 "$DAY_DIR" "$DAY_DIR/20260925_10.sample"
cat > "$TEST_DIR/config.cnf" <<EOF
logdir=$SAMPLE_ROOT
dailytocompressret=1
toremovalretention=14
EOF

/bin/bash "$SCRIPT" --dry-run --config "$TEST_DIR/config.cnf" > "$TEST_DIR/dry-run.out"
[ -f "$DAY_DIR/20260925_10.sample" ]
[ ! -e "$DAY_DIR.tar.gz" ]
grep -q 'DRY-RUN' "$TEST_DIR/dry-run.out"

/bin/bash "$SCRIPT" --apply --config "$TEST_DIR/config.cnf" > "$TEST_DIR/apply.out"
[ -f "$DAY_DIR.tar.gz" ]
[ ! -e "$DAY_DIR" ]
tar -tzf "$DAY_DIR.tar.gz" | grep -q '20260925_10.sample'

printf 'PASS: dry-run and apply retention workflow\n'
