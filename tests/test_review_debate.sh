#!/usr/bin/env bash
# Regression tests for lib/review-debate.sh verdict decision.
#
# Root cause guarded here (two layers, both live-confirmed against real PRs):
#   1. The debate path treated "0 findings" as APPROVED, so a silent agent
#      failure / max-turns cutoff produced a FALSE "APPROVED" green.
#   2. Inferring the verdict by regex-counting the agents' free-text findings is
#      fundamentally fragile: agents emit findings as bullets, bold "- **[MED]**",
#      or "### [HIGH]" headings — any format the counter misses → miscount 0 →
#      false green even with real findings present (observed live on #152).
#
# Fix: the agents declare an EXPLICIT verdict in their completion sentinel
# (===MRA-REVIEW-COMPLETE: APPROVED=== / : CHANGES_REQUESTED===). _debate_assess
# decides from that explicit signal, never from counting free text. Absence of a
# sentinel from both agents = an incomplete/failed review = ERROR, never APPROVE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/review-debate.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

OK="===MRA-REVIEW-COMPLETE: APPROVED==="
CR="===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED==="

# 1. Both agents produced no sentinel (silent failure / cutoff) -> ERROR.
assert_eq "both incomplete -> ERROR" "ERROR" "$(_debate_assess "" "")"

# 2. Both agents completed with APPROVED -> APPROVE (the only path to a clean green).
assert_eq "both APPROVED -> APPROVE" "APPROVE" "$(_debate_assess "looks clean $OK" "$OK")"

# 3. One agent reports CHANGES_REQUESTED -> PROCEED to synthesis.
assert_eq "one CHANGES_REQUESTED -> PROCEED" "PROCEED" "$(_debate_assess "$CR" "$OK")"

# 4. KEY: findings emitted as "### [HIGH]" headings (the live false-green format)
#    are IRRELEVANT — the explicit CHANGES_REQUESTED verdict drives PROCEED.
assert_eq "heading-format findings still PROCEED" "PROCEED" \
  "$(_debate_assess "### [HIGH] real bug invisible behind backdrop $CR" "$OK")"

# 5. One APPROVED, the other failed (no sentinel): cannot claim both clean -> ERROR.
assert_eq "one agent failed -> ERROR" "ERROR" "$(_debate_assess "$OK" "")"

# 6. CHANGES_REQUESTED + a failed other agent -> PROCEED (we still have findings to act on).
assert_eq "CR + failed other -> PROCEED" "PROCEED" "$(_debate_assess "$CR" "")"

# 7. Garbled non-empty output, no sentinel -> ERROR, never approve.
assert_eq "garbled no sentinel -> ERROR" "ERROR" "$(_debate_assess "I was analyzing the diff but" "")"

# --- Adversarial verify-before-approve (single skeptical 3rd reviewer) ---
# When both agents APPROVE, a verifier re-checks the diff. _debate_verify_gate
# maps its EXPLICIT verdict to the final action: confirm the approval, downgrade
# (it found something the two missed), or — if it did not complete — fall back to
# a fail-closed incomplete review rather than approving on verifier flakiness.
assert_eq "verifier APPROVED -> APPROVE"            "APPROVE"      "$(_debate_verify_gate "re-checked, genuinely clean $OK")"
assert_eq "verifier CHANGES_REQUESTED -> DOWNGRADE" "DOWNGRADE"    "$(_debate_verify_gate "- [HIGH] missed null deref at x.ts:5 $CR")"
assert_eq "verifier no verdict -> INCONCLUSIVE"     "INCONCLUSIVE" "$(_debate_verify_gate "")"
assert_eq "verifier cutoff/garbled -> INCONCLUSIVE" "INCONCLUSIVE" "$(_debate_verify_gate "I was checking the diff but ran")"

# Guard: the APPROVE path actually runs the verifier, gated by config.
grep -q 'run_agent_verify' "$SCRIPT_DIR/lib/review-debate.sh" \
  && ok "APPROVE path invokes the adversarial verifier" || fail "APPROVE path must invoke run_agent_verify"
grep -q 'adversarial approval verifier did not complete' "$SCRIPT_DIR/lib/review-debate.sh" \
  && ok "inconclusive verifier fails closed" || fail "inconclusive verifier must not approve"
grep -q 'MRA_REVIEW_VERIFY_APPROVE' "$SCRIPT_DIR/lib/review-debate.sh" \
  && ok "verify-before-approve is config-gated" || fail "must gate on MRA_REVIEW_VERIFY_APPROVE"

# 8. Routing helper (non-critical: only chooses synthesis-vs-voting depth) still
#    counts a finding bullet tolerantly.
[[ "$(_debate_count_findings "  - **[HIGH]** x")" == "1" ]] \
  && ok "count helper tolerates bold/indent" || fail "count helper should count bold/indented finding"

# 9. Regression guard: round-1 agents must honor MRA_REVIEW_AGENT_MAX_TURNS
#    rather than a hardcoded low cap (the cutoff that triggered the false-green).
refs=$(grep -c 'MRA_REVIEW_AGENT_MAX_TURNS' "$SCRIPT_DIR/lib/review-debate.sh")
[[ "$refs" -ge 2 ]] && ok "round-1 agents honor MRA_REVIEW_AGENT_MAX_TURNS" \
  || fail "round-1 agents must honor MRA_REVIEW_AGENT_MAX_TURNS (found $refs refs)"

# 10. Pool/count parity: _build_findings_pool MUST capture the same bold/indented
#     finding _debate_count_findings counts. A mismatch counts a finding (>5 →
#     enters voting) but pools 0 → empty pool → a FALSE APPROVED (round-2 hole).
bold_finding='- **[HIGH]** `x.ts:10` — real bug'
pool_out=$(_build_findings_pool "$bold_finding" "")
[[ "$pool_out" == *"[HIGH]"* ]] \
  && ok "pool captures a bold finding (count/pool regex parity)" \
  || fail "bold finding counted but NOT pooled -> empty-pool false-green: [$pool_out]"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all review-debate tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
