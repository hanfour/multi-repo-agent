#!/usr/bin/env bash
# Verify review-JSON self-repair (A) + fence extraction handle the malformed
# output the synthesis model occasionally emits — specifically the live #173
# failure: an unescaped inner double-quote inside a comment body. The model
# call is mocked via MRA_CLAUDE_BIN (a script that echoes a canned fix).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/review.sh"
source "$MRA_DIR/lib/review-strategy.sh"
source "$MRA_DIR/lib/review-json.sh"

errors=0; pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

# The corrected JSON a repair model would return (inner quotes escaped).
FIXED_JSON='{"status":"CHANGES_REQUESTED","summary":"s","comments":[{"path":"a.ts","line":5,"body":"error message is \"id required\"","severity":"MEDIUM"}]}'
# The #173 failure shape: a RAW inner double-quote inside body (invalid JSON).
MALFORMED='{"status":"CHANGES_REQUESTED","summary":"s","comments":[{"path":"a.ts","line":5,"body":"error message is "id required" here","severity":"MEDIUM"}]}'

# A mock `claude` that ignores its args and prints $1 (a file's contents).
make_mock() { local out="$1" mock; mock="$(mktemp)"; printf '#!/usr/bin/env bash\ncat %q\n' "$out" > "$mock"; chmod +x "$mock"; echo "$mock"; }

# --- fixture sanity: MALFORMED really is invalid JSON ---
if echo "$MALFORMED" | jq . >/dev/null 2>&1; then
  fail_test "fixture should be INVALID json (unescaped inner quote)"
else
  pass_test "fixture is invalid like #173 (unescaped inner quote)"
fi

# --- _repair_review_json returns the model's corrected, valid JSON ---
fixed_file="$(mktemp)"; printf '%s' "$FIXED_JSON" > "$fixed_file"
mock="$(make_mock "$fixed_file")"
out=$(MRA_CLAUDE_BIN="$mock" _repair_review_json "$MALFORMED" "/tmp")
if echo "$out" | jq -e '.status=="CHANGES_REQUESTED"' >/dev/null 2>&1; then
  pass_test "_repair_review_json turns malformed input into valid JSON"
else
  fail_test "_repair_review_json should return valid JSON, got: $out"
fi

# --- repair output wrapped in a ```json fence still extracts cleanly ---
fenced_file="$(mktemp)"; printf '```json\n%s\n```\n' "$FIXED_JSON" > "$fenced_file"
mockf="$(make_mock "$fenced_file")"
out=$(extract_json "$(MRA_CLAUDE_BIN="$mockf" _repair_review_json "$MALFORMED" "/tmp")")
if echo "$out" | jq -e '.comments[0].severity=="MEDIUM"' >/dev/null 2>&1; then
  pass_test "extract_json strips a fence the repair model adds"
else
  fail_test "fenced repair output should extract to valid JSON, got: $out"
fi

# --- extract_json strips a fenced JSON block (read from a file to avoid
#     a literal triple-backtick inside $() — bash treats it as command-sub) ---
fenced="$(cat "$fenced_file")"
if echo "$(extract_json "$fenced")" | jq . >/dev/null 2>&1; then
  pass_test "extract_json strips a fenced JSON block"
else
  fail_test "extract_json should strip the fence"
fi

# --- empty input → repair is a no-op (never aborts) ---
if out=$(_repair_review_json "" "/tmp") && [[ -z "$out" ]]; then
  pass_test "_repair_review_json no-ops on empty input"
else
  fail_test "empty input should yield empty, no error"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
