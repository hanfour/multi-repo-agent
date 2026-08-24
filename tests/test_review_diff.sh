#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/review-diff.sh"

errors=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

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

# --- generated artifacts are summarised, not quoted ---------------------------
# A lockfile is a derivative of a file that IS reviewed, so quoting it buys no
# review and costs the whole budget. On 2026-08-14 acme/nest-monorepo-2.0#892 sent
# codex 1,087,072 characters against its 1,048,576 limit; pnpm-lock.yaml alone
# was 465,442 of them (46%). Dropping it outright would be worse than quoting
# it — the model must still learn the file changed — so the content goes and a
# one-line summary stays.
G="$TEST_DIR/gen"
git -C "$TEST_DIR" init -b main gen &>/dev/null
git -C "$G" config user.email t@t.t; git -C "$G" config user.name t
printf 'real code\n' > "$G/app.js"
printf 'lockfile v1\n' > "$G/pnpm-lock.yaml"
printf 'x\n' > "$G/bundle.min.js"
git -C "$G" add .; git -C "$G" commit -m c1 &>/dev/null
GA=$(git -C "$G" rev-parse HEAD)
printf 'real change\n' >> "$G/app.js"
printf 'LOCKFILE-CONTENT-MARKER\n' >> "$G/pnpm-lock.yaml"
printf 'MINIFIED-CONTENT-MARKER\n' >> "$G/bundle.min.js"
git -C "$G" add .; git -C "$G" commit -m c2 &>/dev/null
GB=$(git -C "$G" rev-parse HEAD)

gen_out=$(review_diff_text "$G" range "$GA..$GB")
case "$gen_out" in *'real change'*) : ;; *) echo "FAIL: reviewable code must still be quoted in full"; errors=$((errors+1)) ;; esac
case "$gen_out" in *LOCKFILE-CONTENT-MARKER*) echo "FAIL: lockfile content still quoted in the diff"; errors=$((errors+1)) ;; *) : ;; esac
case "$gen_out" in *MINIFIED-CONTENT-MARKER*) echo "FAIL: minified bundle content still quoted in the diff"; errors=$((errors+1)) ;; *) : ;; esac
# The model must not silently lose the fact that these files moved.
case "$gen_out" in *pnpm-lock.yaml*) : ;; *) echo "FAIL: omitted file must still be named: $gen_out"; errors=$((errors+1)) ;; esac
case "$gen_out" in *bundle.min.js*) : ;; *) echo "FAIL: omitted file must still be named: $gen_out"; errors=$((errors+1)) ;; esac

# The changed-files list is a manifest, not a quote — it stays complete.
gen_files=$(review_diff_files "$G" range "$GA..$GB")
for f in app.js pnpm-lock.yaml bundle.min.js; do
  case "$gen_files" in *"$f"*) : ;; *) echo "FAIL: changed-files list dropped $f: $gen_files"; errors=$((errors+1)) ;; esac
done

# A repo that changes nothing but generated files must not look like an empty
# review — the summary is the whole answer there.
printf 'lockfile v3\n' >> "$G/pnpm-lock.yaml"
git -C "$G" add .; git -C "$G" commit -m c3 &>/dev/null
GC=$(git -C "$G" rev-parse HEAD)
only_gen=$(review_diff_text "$G" range "$GB..$GC")
case "$only_gen" in *pnpm-lock.yaml*) : ;; *) echo "FAIL: generated-only change produced no account of itself: '$only_gen'"; errors=$((errors+1)) ;; esac

# Opt out: a caller that really wants the bytes can have them.
raw=$(MRA_REVIEW_QUOTE_GENERATED=1 review_diff_text "$G" range "$GA..$GB")
case "$raw" in *LOCKFILE-CONTENT-MARKER*) : ;; *) echo "FAIL: MRA_REVIEW_QUOTE_GENERATED=1 should restore full content"; errors=$((errors+1)) ;; esac

if [[ $errors -eq 0 ]]; then
  echo "PASS: review-diff range/working tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
