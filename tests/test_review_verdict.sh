#!/usr/bin/env bash
# Shared review verdict-sentinel primitives (lib/review-verdict.sh).
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/review-verdict.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# token value is stable
eq "token value" "MRA-REVIEW-COMPLETE" "$MRA_REVIEW_SENTINEL_TOKEN"

# review_verdict_of classification
eq "approved sentinel"  "APPROVED"          "$(review_verdict_of 'body ===MRA-REVIEW-COMPLETE: APPROVED===')"
eq "changes sentinel"   "CHANGES_REQUESTED" "$(review_verdict_of 'x ===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED=== ')"
sentinel_after_json="$(printf '%s\n%s' '{"status":"APPROVED","comments":[]}' '===MRA-REVIEW-COMPLETE: APPROVED===')"
eq "sentinel after json" "APPROVED"         "$(review_verdict_of "$sentinel_after_json")"
eq "no sentinel"        "NONE"              "$(review_verdict_of '{"status":"APPROVED","comments":[]}')"
eq "empty -> none"      "NONE"              "$(review_verdict_of '')"

# review_incomplete_json is valid, neutral, never approves
J="$(review_incomplete_json)"
eq "incomplete is valid json" "0" "$(echo "$J" | jq . >/dev/null 2>&1; echo $?)"
eq "incomplete status COMMENT" "COMMENT" "$(echo "$J" | jq -r .status)"
eq "incomplete no comments"    "0"       "$(echo "$J" | jq '.comments | length')"
case "$(echo "$J" | jq -r .summary)" in *REVIEW_INCOMPLETE*) ok "summary carries sentinel word";; *) fail "summary missing REVIEW_INCOMPLETE";; esac
# custom reason is carried
case "$(review_incomplete_json 'custom reason here.' | jq -r .summary)" in *"custom reason here."*) ok "custom reason carried";; *) fail "custom reason dropped";; esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
