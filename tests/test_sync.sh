#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Test get_default_branch
mkdir -p "$TEST_DIR/repo"
cd "$TEST_DIR/repo"
git init -b main . &>/dev/null
git commit --allow-empty -m "init" &>/dev/null
result=$(get_default_branch "$TEST_DIR/repo")
if [[ "$result" != "main" ]]; then
  echo "FAIL: default branch should be main, got $result"; ((errors++))
fi

# Test is_on_default_branch
result=$(is_on_default_branch "$TEST_DIR/repo")
if [[ $? -ne 0 ]]; then
  echo "FAIL: should be on default branch"; ((errors++))
fi

# Test is_on_default_branch (feature branch)
cd "$TEST_DIR/repo"
git checkout -b feature/test &>/dev/null
if is_on_default_branch "$TEST_DIR/repo"; then
  echo "FAIL: should NOT be on default branch"; ((errors++))
fi

# Test should_skip_dir (no .git)
mkdir -p "$TEST_DIR/no-git"
if ! should_skip_dir "$TEST_DIR/no-git"; then
  echo "FAIL: dir without .git should be skipped"; ((errors++))
fi

rm -rf "$TEST_DIR"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all sync tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
