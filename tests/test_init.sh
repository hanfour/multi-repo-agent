#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/detect-type.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/repos.sh"
source "$SCRIPT_DIR/lib/init.sh"

errors=0
TEST_DIR=$(mktemp -d)
TEST_CONFIG=$(mktemp)
cat > "$TEST_CONFIG" <<'EOF'
{ "autoScan": true, "depthDefault": 1, "aliases": {} }
EOF

# Create fake workspace with git repos
mkdir -p "$TEST_DIR/workspace/project-a"
cd "$TEST_DIR/workspace/project-a" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null

mkdir -p "$TEST_DIR/workspace/project-b"
cd "$TEST_DIR/workspace/project-b" && git init -b main . &>/dev/null && git commit --allow-empty -m "init" &>/dev/null

# Non-git dir should be ignored
mkdir -p "$TEST_DIR/workspace/not-a-repo"

# Test init_workspace
MRA_CONFIG="$TEST_CONFIG" init_workspace "$TEST_DIR/workspace" "git@github.com:test"

# Check .collab dir created
if [[ ! -d "$TEST_DIR/workspace/.collab" ]]; then
  echo "FAIL: .collab dir not created"; ((errors++))
fi

# Check dep-graph.json created
if [[ ! -f "$TEST_DIR/workspace/.collab/dep-graph.json" ]]; then
  echo "FAIL: dep-graph.json not created"; ((errors++))
fi

# Check projects in dep-graph
project_count=$(jq '.projects | length' "$TEST_DIR/workspace/.collab/dep-graph.json")
if [[ "$project_count" != "2" ]]; then
  echo "FAIL: should have 2 projects, got $project_count"; ((errors++))
fi

# Check alias was created
alias_workspace=$(jq -r '.aliases.workspace.workspace' "$TEST_CONFIG")
if [[ "$alias_workspace" != "$TEST_DIR/workspace" ]]; then
  echo "FAIL: alias not created, got $alias_workspace"; ((errors++))
fi

rm -rf "$TEST_DIR" "$TEST_CONFIG"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all init tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
