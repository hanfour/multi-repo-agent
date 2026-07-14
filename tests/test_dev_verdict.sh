#!/usr/bin/env bash
# Verdict-channel tests: review.sh writes the canonical verdict to
# $MRA_REVIEW_RESULT_FILE; the dev loop trusts that file, NEVER the exit code.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/review.sh"
source "$SCRIPT_DIR/lib/review-post.sh"
source "$SCRIPT_DIR/lib/review-pr-discussion.sh"
source "$SCRIPT_DIR/lib/review-strategy.sh"
source "$SCRIPT_DIR/lib/review-json.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

RF=$(mktemp); export MRA_REVIEW_RESULT_FILE="$RF"

# 1. A valid review_json is written verbatim (status readable).
_review_emit_verdict '{"status":"CHANGES_REQUESTED","summary":"blocker","comments":[{"path":"a.ts","line":5,"severity":"HIGH","body":"x"}]}' "/tmp"
assert_eq "valid json -> status readable" "CHANGES_REQUESTED" "$(jq -r .status "$RF")"

# 2. Empty/garbage that cannot be repaired -> synthetic REVIEW_INCOMPLETE (never APPROVED).
_review_emit_verdict 'not json at all {{{' "/tmp"
assert_eq "unparseable -> REVIEW_INCOMPLETE" "REVIEW_INCOMPLETE" "$(jq -r .status "$RF")"

# 3. APPROVED passes through (the loop, not this fn, applies the verifier gate).
_review_emit_verdict '{"status":"APPROVED","summary":"clean","comments":[]}' "/tmp"
assert_eq "approved passes through" "APPROVED" "$(jq -r .status "$RF")"

# 4. Unset channel -> no-op, no crash, no file write.
RF2=$(mktemp); rm -f "$RF2"
( unset MRA_REVIEW_RESULT_FILE; _review_emit_verdict '{"status":"APPROVED"}' "/tmp" )
[[ ! -e "$RF2" ]] && ok "unset channel -> no-op" || fail "unset channel wrote a file"

_review_emit_verdict '{"status":"APPROVED","summary":"bad severity","comments":[{"path":"a.ts","line":1,"severity":"high","body":"bad"}]}' "/tmp"
assert_eq "unknown severity -> REVIEW_INCOMPLETE" "REVIEW_INCOMPLETE" "$(jq -r .status "$RF")"

mismatch=$(_review_singlepass_body $'{"status":"APPROVED","summary":"clean","comments":[]}\n===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===')
assert_eq "sentinel/status mismatch -> REVIEW_INCOMPLETE" "COMMENT" "$(jq -r .status <<<"$mismatch")"

# --- _dev_read_status / _dev_fingerprint (source dev.sh) ---
source "$SCRIPT_DIR/lib/dev.sh"

printf '{"status":"APPROVED","comments":[]}' > "$RF"
assert_eq "read_status approved" "APPROVED" "$(_dev_read_status "$RF")"
: > "$RF"
assert_eq "read_status empty -> INCOMPLETE" "REVIEW_INCOMPLETE" "$(_dev_read_status "$RF")"
printf 'garbage' > "$RF"
assert_eq "read_status garbage -> INCOMPLETE" "REVIEW_INCOMPLETE" "$(_dev_read_status "$RF")"

printf '%s' '{"status":"CHANGES_REQUESTED","comments":[{"path":"b.ts","line":9,"severity":"HIGH","body":"y"},{"path":"a.ts","line":2,"severity":"LOW","body":"x"}]}' > "$RF"
assert_eq "fingerprint sorted" "a.ts:2:LOW,b.ts:9:HIGH," "$(_dev_fingerprint "$RF")"

# --- _dev_review_one reads ONLY the file, never the exit code (false-green firewall) ---
# Stub review_project: writes CHANGES_REQUESTED to RF but RETURNS 1 (the malformed-path
# return) — the loop must still see CHANGES_REQUESTED, not abort, under set -e.
review_project() { printf '%s' '{"status":"CHANGES_REQUESTED","comments":[]}' > "$MRA_REVIEW_RESULT_FILE"; return 1; }
out=$(DEV_AUTO_APPROVE=false _dev_review_one ws proj code main "")
assert_eq "review_one trusts file not exit code" "CHANGES_REQUESTED" "${out%%|*}"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-verdict tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
