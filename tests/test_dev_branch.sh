#!/usr/bin/env bash
# Regression test for _dev_branch reattach-on-resume (FINDING 1).
# Plain bash, no bats. Exits 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0
ok()        { echo "PASS: $1"; }
fail()      { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# ── Setup: create a hermetic temp git repo ──────────────────────────────────
REPO=$(mktemp -d)
cleanup() { rm -rf "$REPO"; }
trap cleanup EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name  "Test"

# Initial commit on default branch
git -C "$REPO" commit --allow-empty -m "init" -q

# Detect the default branch name (main or master, depending on git version)
DEFAULT_BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)

# Create mra/x with an extra commit and record its SHA
git -C "$REPO" checkout -b "mra/x" -q
git -C "$REPO" commit --allow-empty -m "agent work" -q
ORIGINAL_SHA=$(git -C "$REPO" rev-parse HEAD)

# Switch back to a non-protected branch so _dev_validate is happy
git -C "$REPO" checkout -b "work" -q

# ── Source the library under test ───────────────────────────────────────────
# Provide minimal stubs for helpers _dev_branch depends on indirectly via log_*
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev-agent.sh"

# Stub log helpers so the library loads cleanly with no external deps
log_error()   { echo "[ERROR] $1" >&2; }
log_success() { :; }
log_info()    { :; }

source "$SCRIPT_DIR/lib/dev.sh"

# ── Test 1: DEV_RESUME=true → reattach, SHA preserved ───────────────────────
export DEV_RESUME=true
_dev_branch "$REPO" x "$DEFAULT_BRANCH"
rc=$?
assert_eq "resume returns 0" "0" "$rc"

AFTER_SHA=$(git -C "$REPO" rev-parse HEAD)
assert_eq "resume: extra commit SHA unchanged (no reset)" "$ORIGINAL_SHA" "$AFTER_SHA"

# Confirm we're on the right branch
CURRENT_BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)
assert_eq "resume: HEAD is mra/x" "mra/x" "$CURRENT_BRANCH"

# Switch back to work branch for next test
git -C "$REPO" checkout "work" -q

# ── Test 2: DEV_RESUME=false (or unset) + existing branch → non-zero ────────
export DEV_RESUME=false
_dev_branch "$REPO" x "$DEFAULT_BRANCH"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "no-resume + existing branch returns non-zero ($rc)"
else
  fail "no-resume + existing branch should have returned non-zero, got 0"
fi

# ── Test 3: fresh branch (does not exist) → creates branch ──────────────────
export DEV_RESUME=false
_dev_branch "$REPO" "new-slug" "$DEFAULT_BRANCH"
rc=$?
assert_eq "fresh branch creation returns 0" "0" "$rc"

FRESH_BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)
assert_eq "fresh: HEAD is mra/new-slug" "mra/new-slug" "$FRESH_BRANCH"

# ── Result ───────────────────────────────────────────────────────────────────
echo ""
echo "mra/x SHA before: $ORIGINAL_SHA"
echo "mra/x SHA after:  $AFTER_SHA"

if [[ "$errors" -gt 0 ]]; then
  echo "RESULT: $errors failure(s)"
  exit 1
else
  echo "RESULT: all tests passed"
fi
