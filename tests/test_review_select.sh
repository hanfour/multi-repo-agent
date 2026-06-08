#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/review-select.sh"

errors=0
WS=$(mktemp -d)
for r in a b c; do
  mkdir -p "$WS/$r"
  git -C "$WS/$r" init -b main . &>/dev/null
  git -C "$WS/$r" config user.email t@t.t; git -C "$WS/$r" config user.name t
  git -C "$WS/$r" commit --allow-empty -m init &>/dev/null
done
# a: on a feature branch (off-default) -> selected via off-default
git -C "$WS/a" checkout -b feat/x &>/dev/null
# b: on main, passed as changed -> selected via changed
# c: on main, clean, not changed -> NOT selected

out=$(review_targets "$WS" b)
echo "$out" | grep -qx a || { echo "FAIL: 'a' (off-default) should be a target"; errors=$((errors+1)); }
echo "$out" | grep -qx b || { echo "FAIL: 'b' (changed) should be a target"; errors=$((errors+1)); }
if echo "$out" | grep -qx c; then echo "FAIL: 'c' (clean on-default, not changed) should NOT be a target"; errors=$((errors+1)); fi

# no changed args, only off-default selection
out2=$(review_targets "$WS")
echo "$out2" | grep -qx a || { echo "FAIL: 'a' should still be selected with no changed args"; errors=$((errors+1)); }
if echo "$out2" | grep -qx b; then echo "FAIL: 'b' should not be selected when not changed"; errors=$((errors+1)); fi
rm -rf "$WS"

if [[ $errors -eq 0 ]]; then
  echo "PASS: review-select tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
