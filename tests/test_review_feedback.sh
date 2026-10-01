#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/review-feedback.sh"
FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures/review-feedback"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  [[ "${MRA_TEST_GH_UNAUTHENTICATED:-0}" != "1" ]] || exit 1
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  [[ "$*" == *"--paginate"* ]] || exit 2
  printf '%s\n' "$*" >> "$MRA_TEST_GH_CALLS"
  case "${MRA_TEST_GH_MODE:-sample}" in
    sample)
      first_page="$(cat "$MRA_TEST_FIXTURES/page-1.json")"
      second_page="$(cat "$MRA_TEST_FIXTURES/page-2.json")"
      printf '%s%s' "$first_page" "$second_page"
      ;;
    unanswered)
      cat "$MRA_TEST_FIXTURES/unanswered.json"
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
exit 2
SHIM
cat > "$TMP/bin/claude" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == "-p" && $# -eq 1 ]] || exit 2
printf '%s\n' "$*" >> "$MRA_TEST_CLASSIFIER_ARGS"
cat > "$MRA_TEST_CLASSIFIER_STDIN"
printf 'called\n' >> "$MRA_TEST_CLASSIFIER_INVOCATIONS"
printf 'classifier diagnostic from stub\n' >&2
cat "${MRA_TEST_CLASSIFIER_RESPONSE:-$MRA_TEST_FIXTURES/classifications.json}"
SHIM
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export MRA_TEST_FIXTURES="$FIXTURE_DIR"
export MRA_TEST_GH_CALLS="$TMP/gh-calls.log"
export MRA_TEST_CLASSIFIER_ARGS="$TMP/classifier-args.log"
export MRA_TEST_CLASSIFIER_STDIN="$TMP/classifier-stdin.txt"
export MRA_TEST_CLASSIFIER_INVOCATIONS="$TMP/classifier-invocations.log"
unset MRA_REVIEW_FEEDBACK_DIR MRA_TEST_GH_MODE MRA_TEST_GH_UNAUTHENTICATED MRA_TEST_CLASSIFIER_RESPONSE

errors=0
pass=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }
eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1 — expected [$2] got [$3]"
  fi
}

DEFAULT_OUT="$HOME/.mra/review-feedback/acme__legacy-api"
if output="$("$SCRIPT" --repo acme/legacy-api --bot-login review-bot --since 2026-09-01 2>&1)"; then
  ok "collector handles concatenated paginated arrays"
else
  fail "collector handles concatenated paginated arrays — $output"
fi
[[ -f "$DEFAULT_OUT/comments.jsonl" ]] && ok "default output is under the temporary HOME" \
  || fail "default output missing under the temporary HOME"
case "$DEFAULT_OUT" in
  "$SCRIPT_DIR"/*) fail "default output points inside the repository" ;;
  *) ok "default output does not point inside the repository" ;;
esac
eq "eight bot top-level comments are retained" "8" "$(jq -s 'length' "$DEFAULT_OUT/comments.jsonl")"
eq "paginated API query includes since and per_page" \
  "1" "$(grep -F -c 'api --paginate repos/acme/legacy-api/pulls/comments?since=2026-09-01&per_page=100' "$MRA_TEST_GH_CALLS")"
eq "classifier receives one batch for six answered comments" \
  "1" "$(wc -l < "$MRA_TEST_CLASSIFIER_INVOCATIONS" | tr -d ' ')"
eq "classifier receives -p with no positional prompt" \
  "-p" "$(tail -n 1 "$MRA_TEST_CLASSIFIER_ARGS")"
if grep -Fq 'BEGIN_UNTRUSTED_REVIEW_DATA' "$MRA_TEST_CLASSIFIER_STDIN" \
  && grep -Fq 'END_UNTRUSTED_REVIEW_DATA' "$MRA_TEST_CLASSIFIER_STDIN"; then
  ok "classifier prompt delimits untrusted review data"
else
  fail "classifier prompt delimits untrusted review data"
fi
if grep -Fq 'BEGIN_UNTRUSTED_REVIEW_DATA' "$MRA_TEST_CLASSIFIER_STDIN" \
  && ! grep -Fq 'BEGIN_UNTRUSTED_REVIEW_DATA' "$MRA_TEST_CLASSIFIER_ARGS"; then
  ok "classifier receives the delimited prompt on stdin"
else
  fail "classifier receives the delimited prompt on stdin"
fi
eq "reply on another page is grouped under its bot comment" \
  "1" "$(jq -s '[.[] | select(.comment_id == 101)][0].human_replies | length' "$DEFAULT_OUT/comments.jsonl")"
eq "bot's own reply is ignored" \
  "0" "$(jq -s '[.[] | select(.comment_id == 104)][0].human_replies | length' "$DEFAULT_OUT/comments.jsonl")"
eq "user.type Bot reply is ignored" \
  "0" "$(jq -s '[.[] | select(.comment_id == 108)][0].human_replies | length' "$DEFAULT_OUT/comments.jsonl")"
eq "top-level human comment is excluded" \
  "0" "$(jq -s '[.[] | select(.comment_id == 299)] | length' "$DEFAULT_OUT/comments.jsonl")"
eq "severity tag is parsed" \
  "CRITICAL" "$(jq -s -r '[.[] | select(.comment_id == 101)][0].severity' "$DEFAULT_OUT/comments.jsonl")"
eq "severity without a leading tag is unknown" \
  "unknown" "$(jq -s -r '[.[] | select(.comment_id == 107)][0].severity' "$DEFAULT_OUT/comments.jsonl")"
eq "classifier labels are mapped by comment id" \
  "rejected" "$(jq -s -r '[.[] | select(.comment_id == 102)][0].label' "$DEFAULT_OUT/comments.jsonl")"
eq "classifier maps accepted label by id" \
  "accepted" "$(jq -s -r '[.[] | select(.comment_id == 107)][0].label' "$DEFAULT_OUT/comments.jsonl")"
eq "classifier maps disputed-scope label by id" \
  "disputed-scope" "$(jq -s -r '[.[] | select(.comment_id == 105)][0].label' "$DEFAULT_OUT/comments.jsonl")"
eq "accepted count" "3" "$(jq -r '.labels.accepted' "$DEFAULT_OUT/summary.json")"
eq "rejected count" "1" "$(jq -r '.labels.rejected' "$DEFAULT_OUT/summary.json")"
eq "unanswered count" "2" "$(jq -r '.labels.unanswered' "$DEFAULT_OUT/summary.json")"
eq "precision is 0.75" "0.75" "$(jq -r '.precision.value' "$DEFAULT_OUT/summary.json")"
eq "precision denominator is accepted plus rejected" "4" "$(jq -r '.precision.denominator' "$DEFAULT_OUT/summary.json")"
eq "severity precision is included" "0" "$(jq -r '.by_severity.HIGH.precision.value' "$DEFAULT_OUT/summary.json")"
eq "rejected and disputed comments are listed" "2" "$(jq '.rejected_comments | length' "$DEFAULT_OUT/summary.json")"
if grep -Fq 'Overall precision: 0.75 (3/4)' "$DEFAULT_OUT/summary.md"; then
  ok "summary markdown shows precision with denominator"
else
  fail "summary markdown shows precision with denominator"
fi
if grep -Fq 'PR #42' "$DEFAULT_OUT/summary.md" && grep -Fq 'PR #45' "$DEFAULT_OUT/summary.md"; then
  ok "summary markdown lists rejected and disputed comments"
else
  fail "summary markdown lists rejected and disputed comments"
fi
if grep -Fq 'classified: 6, classifier-failed: 0' <<<"$output"; then
  ok "successful classifier totals are reported"
else
  fail "successful classifier totals are reported"
fi

FENCED_OUT="$TMP/fenced"
MRA_TEST_CLASSIFIER_RESPONSE="$FIXTURE_DIR/fenced-response.txt" \
  "$SCRIPT" --repo acme/legacy-api --bot-login review-bot --out "$FENCED_OUT" >/dev/null 2>&1
eq "fenced classifier reply is parsed" \
  "accepted" "$(jq -s -r '[.[] | select(.comment_id == 101)][0].label' "$FENCED_OUT/comments.jsonl")"
eq "fenced classifier reply has no failures" \
  "0" "$(jq -r '.classifier_failed' "$FENCED_OUT/summary.json")"

PROSE_OUT="$TMP/prose"
MRA_TEST_CLASSIFIER_RESPONSE="$FIXTURE_DIR/prose-response.txt" \
  "$SCRIPT" --repo acme/legacy-api --bot-login review-bot --out "$PROSE_OUT" >/dev/null 2>&1
eq "prose around classifier array is stripped" \
  "rejected" "$(jq -s -r '[.[] | select(.comment_id == 102)][0].label' "$PROSE_OUT/comments.jsonl")"
eq "prose-wrapped classifier reply has no failures" \
  "0" "$(jq -r '.classifier_failed' "$PROSE_OUT/summary.json")"

cp "$DEFAULT_OUT/comments.jsonl" "$TMP/comments.before"
cp "$DEFAULT_OUT/summary.json" "$TMP/summary.before"
"$SCRIPT" --repo acme/legacy-api --bot-login review-bot --since 2026-09-01 >/dev/null 2>&1
if cmp -s "$TMP/comments.before" "$DEFAULT_OUT/comments.jsonl" \
  && cmp -s "$TMP/summary.before" "$DEFAULT_OUT/summary.json"; then
  ok "rerunning overwrites outputs deterministically"
else
  fail "rerunning overwrites outputs deterministically"
fi

NO_CLASSIFY_OUT="$TMP/no-classify"
: > "$MRA_TEST_CLASSIFIER_INVOCATIONS"
if output="$("$SCRIPT" --repo acme/legacy-api --bot-login review-bot --out "$NO_CLASSIFY_OUT" --no-classify 2>&1)"; then
  ok "--no-classify completes"
else
  fail "--no-classify completes — $output"
fi
[[ ! -s "$MRA_TEST_CLASSIFIER_INVOCATIONS" ]] && ok "--no-classify skips classifier" \
  || fail "--no-classify skips classifier"
eq "--no-classify labels answered comments other" \
  "other" "$(jq -s -r '[.[] | select(.comment_id == 101)][0].label' "$NO_CLASSIFY_OUT/comments.jsonl")"

MALFORMED_OUT="$TMP/malformed"
if output="$(MRA_TEST_CLASSIFIER_RESPONSE="$FIXTURE_DIR/malformed-response.txt" \
  "$SCRIPT" --repo acme/legacy-api --bot-login review-bot --out "$MALFORMED_OUT" 2>&1)"; then
  ok "malformed classifier output does not abort the run"
else
  fail "malformed classifier output does not abort the run — $output"
fi
eq "malformed classifier output falls back without aborting" \
  "8" "$(jq -s 'length' "$MALFORMED_OUT/comments.jsonl")"
eq "malformed classifier output marks answered items failed" \
  "classifier-failed" "$(jq -s -r '[.[] | select(.comment_id == 101)][0].label_reason' "$MALFORMED_OUT/comments.jsonl")"
eq "malformed classifier output keeps unanswered labels" \
  "unanswered" "$(jq -s -r '[.[] | select(.comment_id == 108)][0].label' "$MALFORMED_OUT/comments.jsonl")"
if cmp -s "$FIXTURE_DIR/malformed-response.txt" \
  "$MALFORMED_OUT/classifier-failures/batch-1.out.txt"; then
  ok "failed classifier stdout is saved"
else
  fail "failed classifier stdout is saved"
fi
if grep -Fq 'classifier diagnostic from stub' \
  "$MALFORMED_OUT/classifier-failures/batch-1.err.txt"; then
  ok "failed classifier stderr is saved"
else
  fail "failed classifier stderr is saved"
fi
eq "classifier failure count is recorded" \
  "6" "$(jq -r '.classifier_failed' "$MALFORMED_OUT/summary.json")"
if grep -Fq 'Classifier failed: 6' "$MALFORMED_OUT/summary.md" \
  && grep -Fq 'classified: 0, classifier-failed: 6' <<<"$output" \
  && grep -Fq 'Warning: classifier batch 1' <<<"$output"; then
  ok "classifier failures are prominent and reported"
else
  fail "classifier failures are prominent and reported"
fi

UNANSWERED_OUT="$TMP/unanswered"
: > "$MRA_TEST_CLASSIFIER_INVOCATIONS"
if output="$(MRA_TEST_GH_MODE=unanswered "$SCRIPT" --repo acme/legacy-api --bot-login review-bot --out "$UNANSWERED_OUT" 2>&1)"; then
  ok "all-unanswered run completes"
else
  fail "all-unanswered run completes — $output"
fi
[[ ! -s "$MRA_TEST_CLASSIFIER_INVOCATIONS" ]] && ok "all-unanswered run makes no model call" \
  || fail "all-unanswered run makes no model call"
eq "all-unanswered comments get unanswered label" \
  "unanswered" "$(jq -s -r '.[0].label' "$UNANSWERED_OUT/comments.jsonl")"

if output="$("$SCRIPT" --repo acme/legacy-api 2>&1)"; then
  fail "missing bot login is rejected"
else
  case "$output" in *"--bot-login is required"*) ok "missing bot login is rejected clearly" ;; *) fail "missing bot login is rejected clearly — $output" ;; esac
fi
if output="$(MRA_TEST_GH_UNAUTHENTICATED=1 "$SCRIPT" --repo acme/legacy-api --bot-login review-bot 2>&1)"; then
  fail "unauthenticated gh is rejected"
else
  case "$output" in *"gh is not authenticated"*) ok "unauthenticated gh is rejected clearly" ;; *) fail "unauthenticated gh is rejected clearly — $output" ;; esac
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit "$((errors > 0 ? 1 : 0))"
