#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main repo &>/dev/null
git -C "$WS/repo" config user.email t@t.t; git -C "$WS/repo" config user.name t
git -C "$WS/repo" commit --allow-empty -m c1 &>/dev/null

run() { if out=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" review repo "$@" 2>&1); then rc=0; else rc=$?; fi; }

run --range c1..HEAD --head HEAD
if [[ $rc -eq 0 ]]; then echo "FAIL: --range + --head should be rejected"; errors=$((errors+1)); fi
case "$out" in *"mutually exclusive"*) : ;; *) echo "FAIL: expected 'mutually exclusive': $out"; errors=$((errors+1)) ;; esac

run --range HEAD~0..HEAD --pr 1
if [[ $rc -eq 0 ]]; then echo "FAIL: --range + --pr should be rejected"; errors=$((errors+1)); fi

run --head HEAD --working
if [[ $rc -eq 0 ]]; then echo "FAIL: --head + --working should be rejected"; errors=$((errors+1)); fi

run --range HEAD~0..HEAD --working
if [[ $rc -eq 0 ]]; then echo "FAIL: --range + --working should be rejected"; errors=$((errors+1)); fi

run --range maim..HEAD
if [[ $rc -eq 0 ]]; then echo "FAIL: invalid range should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *invalid*) : ;; *) echo "FAIL: expected 'invalid' message: $out"; errors=$((errors+1)) ;; esac

run --range HEAD..HEAD
if [[ $rc -ne 0 ]]; then echo "FAIL: empty range should exit 0, got rc=$rc: $out"; errors=$((errors+1)); fi
case "$out" in *"no changes"*) : ;; *) echo "FAIL: expected 'no changes': $out"; errors=$((errors+1)) ;; esac

# --working + --pr is incoherent (working-tree changes have no PR line mapping)
run --working --pr 1
if [[ $rc -eq 0 ]]; then echo "FAIL: --working + --pr should be rejected"; errors=$((errors+1)); fi
case "$out" in *working*) : ;; *) echo "FAIL: expected message mentioning --working: $out"; errors=$((errors+1)) ;; esac

rm -rf "$WS"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review flag gates + range validation passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
