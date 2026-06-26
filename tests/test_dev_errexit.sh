#!/usr/bin/env bash
# Production-faithful errexit smoke test for `mra dev` (CRITICAL-1 / CRITICAL-2).
# Does NOT pre-set MRA_REVIEW_RESULT_FILE — dev_project must create+export it.
# Runs dev_project under set -euo pipefail (same as bin/mra.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev-agent.sh"
source "$SCRIPT_DIR/lib/dev.sh"

errors=0
ok()       { echo "PASS: $1"; }
fail()     { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# ---- Stubs (side-effecting / external deps) ----
resolve_project_dir() { printf '%s' "$_TEST_TMP"; }
_dev_validate()   { return 0; }
_dev_branch()     { return 0; }
_dev_run_agent()  { printf '===MRA-DEV-DONE===\n'; }
_dev_progress()   { return 0; }
_dev_ensure_pkb() { return 0; }
mra_log()           { :; }
notify_escalation() { :; }

# Temp dir used as the fake project dir (resolve_project_dir echoes it).
_TEST_TMP=$(mktemp -d)

# Fixed env vars that mirror a typical invocation.
export DEV_NO_PR=true
export DEV_MAX_ROUNDS=3
export DEV_RETRY_CAP=2
export DEV_GLOBAL_CAP=12
export DEV_DRY_RUN=false
export DEV_RESUME=false
export DEV_AUTO_APPROVE=false
export DEV_BASE="origin/main"
export DEV_MODEL="sonnet"

# ====================================================================
# Test 1 — HAPPY PATH
# review_project writes APPROVED verdict to the (dev_project-exported)
# MRA_REVIEW_RESULT_FILE and returns; dev_project must exit 0.
# ====================================================================
review_project() {
  printf '{"status":"APPROVED","comments":[]}\n' > "$MRA_REVIEW_RESULT_FILE"
}
export -f review_project

_out1=$(mktemp)
( set -euo pipefail; dev_project ws proj "do a thing" ) > "$_out1" 2>&1
_rc1=$?
_content1=$(cat "$_out1"); rm -f "$_out1"

assert_eq "happy-path: rc=0" "0" "$_rc1"
[[ "$_content1" == *"status=APPROVED"* ]] \
  && ok "happy-path: output contains status=APPROVED" \
  || fail "happy-path: missing status=APPROVED — got: $_content1"

# MRA_REVIEW_RESULT_FILE must NOT leak into the parent after the subshell exits.
[[ -z "${MRA_REVIEW_RESULT_FILE:-}" ]] \
  && ok "happy-path: MRA_REVIEW_RESULT_FILE not leaked to parent" \
  || fail "happy-path: MRA_REVIEW_RESULT_FILE unexpectedly set in parent: $MRA_REVIEW_RESULT_FILE"

# ====================================================================
# Test 2 — ESCALATE PATH
# review_project always returns REVIEW_INCOMPLETE; with DEV_RETRY_CAP=1
# the loop escalates. dev_project must exit 2 and output ESCALATED.
# ====================================================================
export DEV_RETRY_CAP=1

review_project() {
  printf '{"status":"REVIEW_INCOMPLETE","comments":[]}\n' > "$MRA_REVIEW_RESULT_FILE"
}
export -f review_project

_out2=$(mktemp)
( set -euo pipefail; dev_project ws proj "do a thing" ) > "$_out2" 2>&1
_rc2=$?
_content2=$(cat "$_out2"); rm -f "$_out2"

assert_eq "escalate-path: rc=2" "2" "$_rc2"
[[ "$_content2" == *"status=ESCALATED"* ]] \
  && ok "escalate-path: output contains status=ESCALATED" \
  || fail "escalate-path: missing status=ESCALATED — got: $_content2"

# ---- Cleanup ----
rm -rf "$_TEST_TMP"

echo ""
if [[ $errors -eq 0 ]]; then
  echo "PASS: all dev-errexit tests passed"
else
  echo "FAIL: $errors test(s) failed"
  exit 1
fi
