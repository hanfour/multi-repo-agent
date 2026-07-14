#!/usr/bin/env bash
# Verify lib/review.sh validates Claude output and caps APPROVE (TM-007).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/project-path.sh"
# review.sh sources several other libs at top of file via load order
# from bin/mra.sh; for unit testing we only need the two helper
# functions, which the file defines at the top.
source "$MRA_DIR/lib/review.sh"
source "$MRA_DIR/lib/review-post.sh"
source "$MRA_DIR/lib/review-pr-discussion.sh"
source "$MRA_DIR/lib/review-strategy.sh"
source "$MRA_DIR/lib/review-json.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

GOOD_JSON='{"status":"CHANGES_REQUESTED","summary":"x","comments":[{"path":"a.ts","line":1,"body":"b","severity":"HIGH"}]}'
APPROVED_JSON='{"status":"APPROVED","summary":"x","comments":[]}'

# --- _validate_review_json accepts a well-formed object ---
if _validate_review_json "$GOOD_JSON"; then
  pass_test "valid review JSON accepted"
else
  fail_test "valid review JSON wrongly rejected"
fi

# --- Reject malformed JSONs ---
for label_payload in \
    'missing status:{"summary":"x","comments":[]}' \
    'unknown status:{"status":"YOLO","summary":"x","comments":[]}' \
    'missing summary:{"status":"COMMENT","comments":[]}' \
    'comments not array:{"status":"COMMENT","summary":"x","comments":{}}' \
    'comment bad severity:{"status":"COMMENT","summary":"x","comments":[{"path":"a","line":1,"body":"b","severity":"WHATEVER"}]}' \
    'comment missing path:{"status":"COMMENT","summary":"x","comments":[{"line":1,"body":"b","severity":"HIGH"}]}' \
    'empty string:'; do
  label="${label_payload%%:*}"
  payload="${label_payload#*:}"
  if _validate_review_json "$payload"; then
    fail_test "should reject ($label): $payload"
  else
    pass_test "rejected ($label)"
  fi
done

# --- Status cap: APPROVED -> COMMENT by default ---
unset MRA_REVIEW_ALLOW_APPROVE || true
event=$(_review_event_for_status "APPROVED" 2>/dev/null)
if [[ "$event" == "COMMENT" ]]; then
  pass_test "APPROVED downgraded to COMMENT by default"
else
  fail_test "expected COMMENT, got '$event'"
fi

effective=$(_review_effective_status "APPROVED" "$APPROVED_JSON" 2>/dev/null)
if [[ "$effective" == "COMMENT" ]]; then
  pass_test "effective status matches default COMMENT event"
else
  fail_test "expected effective COMMENT, got '$effective'"
fi

# --- Override flag re-enables APPROVE ---
event=$(MRA_REVIEW_ALLOW_APPROVE=1 _review_event_for_status "APPROVED" 2>/dev/null)
if [[ "$event" == "APPROVE" ]]; then
  pass_test "MRA_REVIEW_ALLOW_APPROVE=1 keeps APPROVE"
else
  fail_test "expected APPROVE, got '$event'"
fi
effective=$(MRA_REVIEW_ALLOW_APPROVE=1 _review_effective_status "APPROVED" "$APPROVED_JSON" 2>/dev/null)
if [[ "$effective" == "APPROVED" ]]; then
  pass_test "allowApprove keeps effective APPROVED"
else
  fail_test "expected effective APPROVED, got '$effective'"
fi

# --- CHANGES_REQUESTED maps to REQUEST_CHANGES regardless of flag ---
event=$(_review_event_for_status "CHANGES_REQUESTED" 2>/dev/null)
if [[ "$event" == "REQUEST_CHANGES" ]]; then
  pass_test "CHANGES_REQUESTED maps to REQUEST_CHANGES"
else
  fail_test "expected REQUEST_CHANGES, got '$event'"
fi

# --- Unknown status falls back to COMMENT ---
event=$(_review_event_for_status "GARBAGE" 2>/dev/null)
if [[ "$event" == "COMMENT" ]]; then
  pass_test "unknown status falls back to COMMENT"
else
  fail_test "unknown status expected COMMENT, got '$event'"
fi

# --- _review_issues_display: incomplete reviews show N/A, not a misleading 0 ---
out=$(_review_issues_display "⚠️ REVIEW_INCOMPLETE — agent did not finish" "0")
if [[ "$out" == *"N/A"* ]]; then
  pass_test "REVIEW_INCOMPLETE shows N/A (not 0)"
else
  fail_test "incomplete review should show N/A, got '$out'"
fi
out=$(_review_issues_display "Found real problems" "3")
if [[ "$out" == "3" ]]; then
  pass_test "normal review shows the comment count"
else
  fail_test "normal review should show count, got '$out'"
fi
out=$(_review_issues_display "No issues found by either agent" "0")
if [[ "$out" == "0" ]]; then
  pass_test "genuine clean review shows 0"
else
  fail_test "clean review should show 0, got '$out'"
fi

# --- Review notification status normalization ---
notify_status=$(_review_status_for_notify '{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — agent did not finish","comments":[]}')
if [[ "$notify_status" == "REVIEW_INCOMPLETE" ]]; then
  pass_test "COMMENT REVIEW_INCOMPLETE normalizes for notifications"
else
  fail_test "expected REVIEW_INCOMPLETE notify status, got '$notify_status'"
fi
notify_status=$(_review_status_for_notify "$GOOD_JSON")
if [[ "$notify_status" == "CHANGES_REQUESTED" ]]; then
  pass_test "valid review status passes through for notifications"
else
  fail_test "expected CHANGES_REQUESTED notify status, got '$notify_status'"
fi
unset MRA_REVIEW_ALLOW_APPROVE || true
notify_status=$(_review_status_for_notify "$APPROVED_JSON")
[[ "$notify_status" == "COMMENT" ]] && pass_test "notification reports downgraded COMMENT without approval authorization" || fail_test "expected COMMENT notify status, got '$notify_status'"
notify_status=$(MRA_REVIEW_ALLOW_APPROVE=1 _review_status_for_notify "$APPROVED_JSON")
[[ "$notify_status" == "APPROVED" ]] && pass_test "notification reports APPROVED with authorization" || fail_test "expected APPROVED notify status, got '$notify_status'"

redacted=$(GH_TOKEN='ghp_abcdefghijklmnopqrstuvwxyz123456' _review_redact_secrets_json '{"status":"COMMENT","summary":"ghp_abcdefghijklmnopqrstuvwxyz123456","comments":[]}')
case "$redacted" in *"ghp_abcdefghijklmnopqrstuvwxyz123456"*) fail_test "review JSON leaked GitHub token" ;; *) pass_test "review JSON redacts GitHub tokens" ;; esac

_review_validate_expected_head abc abc abc && pass_test "matching expected/local/remote heads pass" || fail_test "matching heads should pass"
if _review_validate_expected_head abc abc def; then fail_test "changed remote head should fail"; else pass_test "changed remote head fails closed"; fi

# --- _review_strategy_turns: defaults + env overrides ---
unset MRA_REVIEW_STANDARD_MAX_TURNS MRA_REVIEW_LIGHT_MAX_TURNS || true
[[ "$(_review_strategy_turns standard)" == "6" ]] \
  && pass_test "standard default max-turns is 6" \
  || fail_test "standard default expected 6, got '$(_review_strategy_turns standard)'"
[[ "$(_review_strategy_turns light)" == "2" ]] \
  && pass_test "light default max-turns is 2" \
  || fail_test "light default expected 2, got '$(_review_strategy_turns light)'"
[[ "$(MRA_REVIEW_STANDARD_MAX_TURNS=12 _review_strategy_turns standard)" == "12" ]] \
  && pass_test "MRA_REVIEW_STANDARD_MAX_TURNS overrides standard" \
  || fail_test "standard override failed"
[[ "$(MRA_REVIEW_LIGHT_MAX_TURNS=4 _review_strategy_turns light)" == "4" ]] \
  && pass_test "MRA_REVIEW_LIGHT_MAX_TURNS overrides light" \
  || fail_test "light override failed"

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
