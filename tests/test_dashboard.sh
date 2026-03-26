#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"
source "$SCRIPT_DIR/lib/dashboard.sh"

errors=0
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.collab"

cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","lastScan":"2026-03-26T00:00:00Z","projects":{"api":{"type":"rails-api","deps":{"infra":["mysql"]},"consumedBy":["frontend"]},"frontend":{"type":"node-frontend","deps":{"api":["api"]},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/api" && cd "$TEST_DIR/api" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null
mkdir -p "$TEST_DIR/frontend" && cd "$TEST_DIR/frontend" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null

# Test render (non-interactive, just capture output)
output=$(render_dashboard "$TEST_DIR" 2>&1)
if [[ "$output" != *"PROJECTS"* ]]; then echo "FAIL: should show PROJECTS header"; ((errors++)); fi
if [[ "$output" != *"DEPENDENCY GRAPH"* ]]; then echo "FAIL: should show DEPENDENCY GRAPH header"; ((errors++)); fi
if [[ "$output" != *"api"* ]]; then echo "FAIL: should show api project"; ((errors++)); fi
if [[ "$output" != *"frontend"* ]]; then echo "FAIL: should show frontend project"; ((errors++)); fi
if [[ "$output" != *"DATABASES"* ]]; then echo "FAIL: should show DATABASES section"; ((errors++)); fi
if [[ "$output" != *"RECENT CHANGES"* ]]; then echo "FAIL: should show RECENT CHANGES"; ((errors++)); fi

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all dashboard tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
