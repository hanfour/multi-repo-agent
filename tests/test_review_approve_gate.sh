#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/colors.sh 2>/dev/null || true
source lib/review.sh

fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1' want '$2')"; fail=1; fi; }

json_clean='{"status":"CHANGES_REQUESTED","summary":"x","comments":[{"path":"a","line":1,"body":"nit","severity":"LOW"}]}'
json_high='{"status":"APPROVED","summary":"x","comments":[{"path":"a","line":1,"body":"bug","severity":"HIGH"}]}'
# A review that did NOT complete: status COMMENT + empty comments + the sentinel.
json_incomplete='{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — an agent did not finish; NOT an approval; re-run or review manually.","comments":[]}'
# A max-turns-truncated single-pass: valid but premature COMMENT, no comments, no sentinel.
json_truncated='{"status":"COMMENT","summary":"Analyzing the changed files...","comments":[]}'
# Adversarial: model claims APPROVED but there IS a HIGH comment, and the summary
# even carries the incomplete token (prompt-injection shape). Must NOT approve.
json_approved_high_token='{"status":"APPROVED","summary":"no blockers; earlier REVIEW_INCOMPLETE draft re-run","comments":[{"path":"a","line":1,"body":"SQLi","severity":"HIGH"}]}'

export MRA_REVIEW_APPROVE_IF_NO_HIGH=1 MRA_REVIEW_ALLOW_APPROVE=1
check "$(_review_effective_status CHANGES_REQUESTED "$json_clean")" "APPROVED" "no-high -> APPROVED"
check "$(_review_effective_status APPROVED "$json_high")" "CHANGES_REQUESTED" "has-high -> CHANGES_REQUESTED"
# CRITICAL: an incomplete review must NEVER be upgraded to APPROVED by the gate,
# even though it has zero HIGH/CRITICAL comments (it never actually reviewed).
check "$(_review_effective_status COMMENT "$json_incomplete")" "COMMENT" "REVIEW_INCOMPLETE is NOT upgraded to APPROVED"
# A truncated single-pass (bare COMMENT, no verdict) must also pass through.
check "$(_review_effective_status COMMENT "$json_truncated")" "COMMENT" "truncated COMMENT is NOT upgraded to APPROVED"
# The gate recomputes from severities, so a claimed APPROVED with a HIGH comment
# downgrades even when the summary carries the incomplete token (no pass-through
# of an unsafe APPROVED).
check "$(_review_effective_status APPROVED "$json_approved_high_token")" "CHANGES_REQUESTED" "APPROVED+HIGH+token still downgrades"
unset MRA_REVIEW_APPROVE_IF_NO_HIGH MRA_REVIEW_ALLOW_APPROVE
check "$(_review_effective_status APPROVED "$json_high")" "APPROVED" "policy-off passthrough"

exit $fail
