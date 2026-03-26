#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/graph.sh"
errors=0
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"api":{"type":"rails-api","deps":{"infra":["mysql"]},"consumedBy":["frontend"]},"frontend":{"type":"node-frontend","deps":{"api":["api"]},"consumedBy":[]}}}
EOF
# Test terminal format
output=$(_graph_terminal "$TEST_DIR/.collab/dep-graph.json" 2>&1)
if [[ "$output" != *"api"* ]]; then echo "FAIL: terminal should show api"; ((errors++)); fi
if [[ "$output" != *"frontend"* ]]; then echo "FAIL: terminal should show frontend"; ((errors++)); fi
# Test mermaid
output=$(_graph_mermaid "$TEST_DIR/.collab/dep-graph.json" "$TEST_DIR" 2>&1)
if [[ "$output" != *"graph LR"* ]]; then echo "FAIL: mermaid should start with graph LR"; ((errors++)); fi
if [[ ! -f "$TEST_DIR/.collab/dep-graph.mmd" ]]; then echo "FAIL: mermaid file not created"; ((errors++)); fi
# Test dot
output=$(_graph_dot "$TEST_DIR/.collab/dep-graph.json" "$TEST_DIR" 2>&1)
if [[ "$output" != *"digraph"* ]]; then echo "FAIL: dot should contain digraph"; ((errors++)); fi
if [[ ! -f "$TEST_DIR/.collab/dep-graph.dot" ]]; then echo "FAIL: dot file not created"; ((errors++)); fi
rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all graph tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
