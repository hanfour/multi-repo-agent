#!/usr/bin/env bash
# Pure helpers + state-machine transitions for `mra dev`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev-agent.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- _dev_slugify ---
assert_eq "slugify lowercases + dashes"   "add-foo-bar"  "$(_dev_slugify 'Add Foo Bar!')"
assert_eq "slugify collapses separators"  "a-b"          "$(_dev_slugify '  a   ///  b  ')"

# --- _dev_parse_sentinel ---
assert_eq "DONE sentinel"        "DONE"               "$(_dev_parse_sentinel 'work done ===MRA-DEV-DONE===')"
assert_eq "BLOCKED carries reason" "BLOCKED:no docker" "$(_dev_parse_sentinel '===MRA-DEV-BLOCKED: no docker===')"
assert_eq "missing sentinel fail-safe" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'I analyzed but stopped')"
# DONE token must not be inferred from prose (false-green guard, mirrors review subsystem)
assert_eq "prose 'done' is not DONE" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'the task is done now')"

# --- loop transitions (source dev.sh; stub side-effects) ---
source "$SCRIPT_DIR/lib/dev.sh"
export MRA_REVIEW_RESULT_FILE="$(mktemp)"
DEV_BASE="origin/main"; DEV_MAX_ROUNDS=3; DEV_RETRY_CAP=2; DEV_GLOBAL_CAP=12
DEV_NO_PR=true; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false

# Stub all side-effecting / external calls.
resolve_project_dir() { printf '/fake/%s' "$2"; }
_dev_ensure_pkb() { return 0; }
mra_log()     { :; }
notify_escalation() { :; }
_dev_validate(){ return 0; }
_dev_branch()  { return 0; }
_dev_progress(){ return 0; }            # implement/fix always "made progress"
_dev_run_agent(){ printf '===MRA-DEV-DONE==='; }

# Scripted review verdicts: pop one per _dev_review_one call.
REVIEWS=(); RI=0
_dev_review_one() { local v="${REVIEWS[$RI]}"; RI=$((RI+1)); printf '%s' "$v"; }

run_dev() { RI=0; dev_project ws proj "do a thing"; }

# 1. First review APPROVED -> success, 0 rounds.
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "approved-first succeeds" "0" "$rc"
[[ "$out" == *"status=APPROVED"* ]] && ok "reports APPROVED" || fail "missing APPROVED: $out"

# 2. CHANGES_REQUESTED then APPROVED -> success after 1 fix round.
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "APPROVED|"); out=$(run_dev); rc=$?
assert_eq "changes->approved succeeds" "0" "$rc"

# 3. CHANGES_REQUESTED forever with max-rounds 2 -> ESCALATED, rc 2, no infinite loop.
DEV_MAX_ROUNDS=2
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "CHANGES_REQUESTED|b:2:HIGH," "CHANGES_REQUESTED|c:3:HIGH,")
out=$(run_dev); rc=$?
assert_eq "round cap escalates" "2" "$rc"
[[ "$out" == *"status=ESCALATED"* ]] && ok "reports ESCALATED" || fail "missing ESCALATED: $out"
DEV_MAX_ROUNDS=3

# 4. Identical fingerprint twice -> no-progress escalate (before burning rounds).
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "CHANGES_REQUESTED|a:1:HIGH,"); out=$(run_dev); rc=$?
assert_eq "no-progress escalates" "2" "$rc"
[[ "$out" == *"no progress"* ]] && ok "reports no-progress reason" || fail "missing no-progress: $out"

# 5. REVIEW_INCOMPLETE beyond retry cap -> escalate, NEVER approved.
DEV_RETRY_CAP=1
REVIEWS=("REVIEW_INCOMPLETE|" "REVIEW_INCOMPLETE|"); out=$(run_dev); rc=$?
assert_eq "incomplete escalates, never approves" "2" "$rc"
DEV_RETRY_CAP=2

# 6. Implement BLOCKED -> escalate before any review.
_dev_run_agent(){ printf '===MRA-DEV-BLOCKED: no creds==='; }
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "implement BLOCKED escalates" "2" "$rc"
[[ "$out" == *"no creds"* ]] && ok "carries BLOCKED reason" || fail "missing reason: $out"
_dev_run_agent(){ printf '===MRA-DEV-DONE==='; }

# 7. Implement empty diff -> escalate before review.
_dev_progress(){ return 1; }
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "empty diff escalates" "2" "$rc"
_dev_progress(){ return 0; }

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-state-machine tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
