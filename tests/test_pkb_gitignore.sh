#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
errors=0
TEST_DIR=$(mktemp -d)

# pkb_init_meta should drop a self-ignoring .mra/.gitignore so the cache
# never pollutes the target project's git origin.
pkb_init_meta "$TEST_DIR" "demo-project"

if [[ ! -f "$TEST_DIR/.mra/.gitignore" ]]; then
  echo "FAIL: .mra/.gitignore not created"; errors=$((errors+1))
elif [[ "$(cat "$TEST_DIR/.mra/.gitignore")" != "*" ]]; then
  echo "FAIL: .mra/.gitignore should contain '*', got: $(cat "$TEST_DIR/.mra/.gitignore")"; errors=$((errors+1))
fi

# git must actually ignore the cache contents in a real repo.
git -C "$TEST_DIR" init -q 2>/dev/null
if ! git -C "$TEST_DIR" check-ignore -q .mra/pkb/meta.json; then
  echo "FAIL: git does not ignore .mra/pkb/meta.json"; errors=$((errors+1))
fi

# Idempotent: a pre-existing .gitignore is left untouched.
printf 'custom\n' > "$TEST_DIR/.mra/.gitignore"
pkb_ensure_gitignore "$TEST_DIR"
if [[ "$(cat "$TEST_DIR/.mra/.gitignore")" != "custom" ]]; then
  echo "FAIL: pkb_ensure_gitignore overwrote an existing .gitignore"; errors=$((errors+1))
fi

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all pkb gitignore tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
