#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/deps.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Create test dep-graph
mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{
  "version": 1,
  "workspace": "test",
  "gitOrg": "git@github.com:test",
  "projects": {
    "api": {
      "type": "rails-api",
      "port": 4000,
      "deps": { "infra": ["mysql"] },
      "consumedBy": ["frontend"]
    },
    "frontend": {
      "type": "node-frontend",
      "port": 3000,
      "deps": { "api": ["api"] },
      "consumedBy": []
    }
  }
}
EOF

# Test get_project_deps
result=$(get_project_deps "api" "$TEST_DIR/.collab/dep-graph.json")
if [[ "$result" != *"mysql"* ]]; then
  echo "FAIL: api deps should include mysql, got $result"; ((errors++))
fi

# Test get_project_consumers
result=$(get_project_consumers "api" "$TEST_DIR/.collab/dep-graph.json")
if [[ "$result" != *"frontend"* ]]; then
  echo "FAIL: api consumers should include frontend, got $result"; ((errors++))
fi

# Test resolve_with_deps (depth 1)
result=$(resolve_with_deps "api" 1 "$TEST_DIR/.collab/dep-graph.json")
if [[ "$result" != *"frontend"* ]]; then
  echo "FAIL: with-deps should include frontend, got $result"; ((errors++))
fi

# Test list_all_projects
result=$(list_all_projects "$TEST_DIR/.collab/dep-graph.json")
if [[ "$result" != *"api"* || "$result" != *"frontend"* ]]; then
  echo "FAIL: list should include api and frontend, got $result"; ((errors++))
fi

rm -rf "$TEST_DIR"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all deps tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
