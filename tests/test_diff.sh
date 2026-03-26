#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/diff-summary.sh"

errors=0
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"clean-repo":{"type":"node-frontend","deps":{},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/clean-repo" && cd "$TEST_DIR/clean-repo" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null

output=$(show_diff_summary "$TEST_DIR" 2>&1)

if [[ "$output" != *"clean"* ]]; then
  echo "FAIL: should show all clean"
  ((errors++))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all diff tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
