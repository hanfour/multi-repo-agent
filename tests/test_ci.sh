#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/ci.sh"

errors=0
D=$(mktemp -d)   # a dir for the (cd "$repo_dir" ...) subshell to cd into

# CI_POLL_INTERVAL constant is defined and numeric
if ! [[ "${CI_POLL_INTERVAL:-}" =~ ^[0-9]+$ ]]; then echo "FAIL: CI_POLL_INTERVAL should be a number (got '${CI_POLL_INTERVAL:-}')"; errors=$((errors+1)); fi

# --- 1. all checks pass on first poll -> 0 ---
gh() { return 0; }
if wait_for_pr_checks "$D" feat/x 5 1; then : ; else echo "FAIL: all-pass should return 0"; errors=$((errors+1)); fi

# --- 2. pending,pending,pass across polls -> 0 (proves re-poll); pending uses gh exit 8 ---
CNT=$(mktemp); echo 0 > "$CNT"
gh() { local n; n=$(<"$CNT"); n=$((n+1)); echo "$n" > "$CNT"; case $n in 1|2) return 8 ;; *) return 0 ;; esac; }
if wait_for_pr_checks "$D" feat/x 10 0; then : ; else echo "FAIL: pending-then-pass should return 0"; errors=$((errors+1)); fi
n_final=$(<"$CNT"); if [[ "$n_final" -ne 3 ]]; then echo "FAIL: should have polled exactly 3 times (got $n_final)"; errors=$((errors+1)); fi
rm -f "$CNT"

# --- 3. a failed check (exit 1, not 8) -> 1 immediately (fail-fast) ---
gh() { return 1; }
if wait_for_pr_checks "$D" feat/x 60 1; then echo "FAIL: failed check should return non-zero"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 1 ]] || { echo "FAIL: failed check should return 1 (got $rc)"; errors=$((errors+1)); }; fi

# --- 4. always pending (exit 8) + tiny timeout -> 2 (timed out) ---
gh() { return 8; }
if wait_for_pr_checks "$D" feat/x 1 1; then echo "FAIL: timeout should return non-zero"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 2 ]] || { echo "FAIL: timeout should return 2 (got $rc)"; errors=$((errors+1)); }; fi

# --- 5. no checks reported (gh exits non-zero, non-8 e.g. 1) -> 1 (NOT silently green) ---
gh() { return 1; }
if wait_for_pr_checks "$D" feat/x 5 1; then echo "FAIL: no-checks (non-zero) must NOT be green"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 1 ]] || { echo "FAIL: no-checks should return 1 (got $rc)"; errors=$((errors+1)); }; fi

# --- regression: bare call under set -e must NOT abort internally on a pending (exit 8) poll ---
CNT2=$(mktemp); echo 0 > "$CNT2"
gh() { local n; n=$(<"$CNT2"); n=$((n+1)); echo "$n" > "$CNT2"; case $n in 1|2) return 8 ;; *) return 0 ;; esac; }
wait_for_pr_checks "$D" feat/x 10 0   # BARE (no `if`): returns 0; aborts here if the set -e bug is present
echo "BARE_OK reached" >/dev/null     # reaching this line at all proves no internal abort
rm -f "$CNT2"

unset -f gh
rm -rf "$D"

if [[ "$errors" -eq 0 ]]; then echo "PASS: ci poll tests passed"; else echo "=== ci: $errors failed ==="; exit 1; fi
