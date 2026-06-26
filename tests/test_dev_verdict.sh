#!/usr/bin/env bash
# Verdict-channel tests: review.sh writes the canonical verdict to
# $MRA_REVIEW_RESULT_FILE; the dev loop trusts that file, NEVER the exit code.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

RF=$(mktemp); export MRA_REVIEW_RESULT_FILE="$RF"

# 1. A valid review_json is written verbatim (status readable).
_review_emit_verdict '{"status":"CHANGES_REQUESTED","comments":[{"path":"a.ts","line":5,"severity":"HIGH","body":"x"}]}' "/tmp"
assert_eq "valid json -> status readable" "CHANGES_REQUESTED" "$(jq -r .status "$RF")"

# 2. Empty/garbage that cannot be repaired -> synthetic REVIEW_INCOMPLETE (never APPROVED).
_review_emit_verdict 'not json at all {{{' "/tmp"
assert_eq "unparseable -> REVIEW_INCOMPLETE" "REVIEW_INCOMPLETE" "$(jq -r .status "$RF")"

# 3. APPROVED passes through (the loop, not this fn, applies the verifier gate).
_review_emit_verdict '{"status":"APPROVED","comments":[]}' "/tmp"
assert_eq "approved passes through" "APPROVED" "$(jq -r .status "$RF")"

# 4. Unset channel -> no-op, no crash, no file write.
RF2=$(mktemp); rm -f "$RF2"
( unset MRA_REVIEW_RESULT_FILE; _review_emit_verdict '{"status":"APPROVED"}' "/tmp" )
[[ ! -e "$RF2" ]] && ok "unset channel -> no-op" || fail "unset channel wrote a file"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-verdict tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
