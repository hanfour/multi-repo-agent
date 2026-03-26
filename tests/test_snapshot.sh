#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Setup: create workspace with dep-graph and a git repo
mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"myapp":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/myapp"
cd "$TEST_DIR/myapp"
git init -b main . &>/dev/null
echo "v1" > file.txt
git add file.txt && git commit -m "v1" &>/dev/null
COMMIT_V1=$(git rev-parse HEAD)

# Test: create snapshot
create_snapshot "$TEST_DIR" "test-snap" 2>/dev/null
snapshots_file=$(get_snapshots_file "$TEST_DIR")
if [[ ! -f "$snapshots_file" ]]; then
  echo "FAIL: snapshots file not created"; ((errors++))
fi

snap_count=$(jq 'length' "$snapshots_file")
if [[ "$snap_count" != "1" ]]; then
  echo "FAIL: should have 1 snapshot, got $snap_count"; ((errors++))
fi

# Test: make changes, then rollback
cd "$TEST_DIR/myapp"
echo "v2" > file.txt
git add file.txt && git commit -m "v2" &>/dev/null
COMMIT_V2=$(git rev-parse HEAD)

if [[ "$COMMIT_V1" == "$COMMIT_V2" ]]; then
  echo "FAIL: commits should differ"; ((errors++))
fi

rollback_project "$TEST_DIR" "myapp" "test-snap" 2>/dev/null
COMMIT_AFTER=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
if [[ "$COMMIT_AFTER" != "$COMMIT_V1" ]]; then
  echo "FAIL: should be back to v1 commit, got $COMMIT_AFTER"; ((errors++))
fi

content=$(cat "$TEST_DIR/myapp/file.txt")
if [[ "$content" != "v1" ]]; then
  echo "FAIL: file should contain v1, got $content"; ((errors++))
fi

# Test: list snapshots
output=$(list_snapshots "$TEST_DIR" 2>&1)
if [[ "$output" != *"test-snap"* ]]; then
  echo "FAIL: list should show test-snap"; ((errors++))
fi

# Test: delete snapshot
delete_snapshot "$TEST_DIR" "test-snap" 2>/dev/null
snap_count=$(jq 'length' "$snapshots_file")
if [[ "$snap_count" != "0" ]]; then
  echo "FAIL: should have 0 snapshots after delete, got $snap_count"; ((errors++))
fi

rm -rf "$TEST_DIR"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all snapshot tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
