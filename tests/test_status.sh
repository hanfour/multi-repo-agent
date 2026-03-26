#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/status.sh"

errors=0
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","gitOrg":"git@github.com:test","lastScan":"2026-03-26T00:00:00Z","projects":{"alpha":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/alpha" && cd "$TEST_DIR/alpha" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null

output=$(show_status "$TEST_DIR" 2>&1)

if [[ "$output" != *"alpha"* ]]; then
  echo "FAIL: should show alpha"
  ((errors++))
fi

if [[ "$output" != *"rails-api"* ]]; then
  echo "FAIL: should show type"
  ((errors++))
fi

if [[ "$output" != *"main"* ]]; then
  echo "FAIL: should show branch"
  ((errors++))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all status tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
