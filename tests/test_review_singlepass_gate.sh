#!/usr/bin/env bash
# _review_singlepass_body: sentinel + validity gate for single-pass inline review.
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-verdict.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/review.sh"

errors=0; pass=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }
status_of(){ echo "$1" | jq -r .status 2>/dev/null; }

GOOD='{"status":"APPROVED","summary":"ok","comments":[]}'

# valid JSON WITH sentinel -> returned as-is (extracted)
out=$(_review_singlepass_body "$(printf '%s\n%s' "$GOOD" '===MRA-REVIEW-COMPLETE: APPROVED===')")
[[ "$(status_of "$out")" == "APPROVED" ]] && ok "sentinel+valid -> APPROVED body" || fail "sentinel+valid: got [$out]"

# valid JSON WITHOUT sentinel -> REVIEW_INCOMPLETE (never APPROVED)
out=$(_review_singlepass_body "$GOOD")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "no sentinel -> COMMENT" || fail "no sentinel: got [$out]"
case "$(echo "$out" | jq -r .summary)" in *REVIEW_INCOMPLETE*) ok "no sentinel -> REVIEW_INCOMPLETE";; *) fail "no sentinel summary: [$out]";; esac

# empty -> REVIEW_INCOMPLETE
out=$(_review_singlepass_body "")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "empty -> COMMENT" || fail "empty: got [$out]"

# sentinel present but unparseable body -> REVIEW_INCOMPLETE
out=$(_review_singlepass_body "$(printf '%s\n%s' 'not json at all' '===MRA-REVIEW-COMPLETE: APPROVED===')")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "sentinel+garbage -> COMMENT" || fail "sentinel+garbage: got [$out]"

# always emits exactly one valid JSON object
echo "$out" | jq . >/dev/null 2>&1 && ok "always valid json" || fail "not valid json: [$out]"

# wiring: review.sh actually calls the helper on the inline path
grep -q '_review_singlepass_body' "$MRA_DIR/lib/review.sh" && ok "inline path uses _review_singlepass_body" || fail "review.sh does not call _review_singlepass_body"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
