#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/review-diff.sh"

errors=0
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

git -C "$TEST_DIR" init -b main repo &>/dev/null
R="$TEST_DIR/repo"
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'a\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -m c1 &>/dev/null
A=$(git -C "$R" rev-parse HEAD)
printf 'b\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -m c2 &>/dev/null
B=$(git -C "$R" rev-parse HEAD)

# range mode: A..B contains c2's change
out=$(review_diff_text "$R" range "$A..$B")
case "$out" in *'+b'*) : ;; *) echo "FAIL: range A..B should contain c2 change (+b): $out"; errors=$((errors+1)) ;; esac
files=$(review_diff_files "$R" range "$A..$B")
case "$files" in *f.txt*) : ;; *) echo "FAIL: range changed-files should list f.txt: $files"; errors=$((errors+1)) ;; esac

# range mode: empty range yields empty output (no error)
out=$(review_diff_text "$R" range "$B..$B")
if [[ -n "$out" ]]; then echo "FAIL: empty range should yield empty diff: $out"; errors=$((errors+1)); fi

# working mode unchanged (regression)
printf 'c\n' >> "$R/f.txt"
out=$(review_diff_text "$R" working "")
case "$out" in *'+c'*) : ;; *) echo "FAIL: working mode should capture unstaged change: $out"; errors=$((errors+1)) ;; esac

if [[ $errors -eq 0 ]]; then
  echo "PASS: review-diff range/working tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
