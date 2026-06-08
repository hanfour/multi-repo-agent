#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-diff.sh"
source "$SCRIPT_DIR/lib/review-prompt.sh"

errors=0
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

git -C "$TEST_DIR" init -b main repo &>/dev/null
R="$TEST_DIR/repo"
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
printf 'line1\n' > "$R/f.txt"
git -C "$R" add f.txt
git -C "$R" commit -m init &>/dev/null

# Working tree: clean => empty diff
out=$(review_diff_text "$R" working "")
if [[ -n "$out" ]]; then echo "FAIL: clean tree should yield empty working diff"; errors=$((errors+1)); fi

# Modify a tracked file (unstaged) => working diff captures it
printf 'line2\n' >> "$R/f.txt"
out=$(review_diff_text "$R" working "")
case "$out" in *line2*) : ;; *) echo "FAIL: working diff missing unstaged change"; errors=$((errors+1)) ;; esac
files=$(review_diff_files "$R" working "")
case "$files" in *f.txt*) : ;; *) echo "FAIL: working changed-files missing f.txt"; errors=$((errors+1)) ;; esac

# Staged change also captured (git diff HEAD covers staged + unstaged)
git -C "$R" add f.txt
out=$(review_diff_text "$R" working "")
case "$out" in *line2*) : ;; *) echo "FAIL: working diff missing staged change"; errors=$((errors+1)) ;; esac

# --- mode-aware prompt preamble ---
PRE_DIR=$(mktemp -d); git -C "$PRE_DIR" init -b main repo &>/dev/null
PR="$PRE_DIR/repo"
git -C "$PR" config user.email t@t.t; git -C "$PR" config user.name t
echo a > "$PR/f.txt"; git -C "$PR" add f.txt; git -C "$PR" commit -m c1 &>/dev/null
echo b >> "$PR/f.txt"

# working mode: preamble mentions working tree, not "pull request"
p=$(build_review_prompt repo "$PR" "" main unknown "" "" false "" terminal working "")
case "$p" in *"uncommitted working-tree"*) : ;; *) echo "FAIL: working preamble should mention working tree"; errors=$((errors+1)) ;; esac
case "$p" in *"pull request"*) echo "FAIL: working preamble should NOT say 'pull request'"; errors=$((errors+1)) ;; *) : ;; esac

# default (base...HEAD) keeps 'pull request'
p=$(build_review_prompt repo "$PR" "" main unknown "" "" false "" terminal range "main...HEAD")
case "$p" in *"pull request"*) : ;; *) echo "FAIL: default preamble should say 'pull request'"; errors=$((errors+1)) ;; esac
rm -rf "$PRE_DIR"

# --- explicit --range preamble wording ---
RG_DIR=$(mktemp -d); git -C "$RG_DIR" init -b main repo &>/dev/null
RGR="$RG_DIR/repo"
git -C "$RGR" config user.email t@t.t; git -C "$RGR" config user.name t
git -C "$RGR" commit --allow-empty -m c1 &>/dev/null
p=$(build_review_prompt repo "$RGR" "" main unknown "" "" false "" terminal range "aaa..bbb")
case "$p" in *"changes in 'aaa..bbb'"*) : ;; *) echo "FAIL: explicit range preamble should name the range"; errors=$((errors+1)) ;; esac
case "$p" in *"pull request"*) echo "FAIL: explicit range preamble should NOT say 'pull request'"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$RG_DIR"

if [[ $errors -eq 0 ]]; then
  echo "PASS: review-diff working-mode tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
