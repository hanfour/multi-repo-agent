#!/usr/bin/env bash
# Findings get one refutation pass — and only when there are findings.
#
# Measured over 80 reviewed pull requests: 95 reviews produced 31 inline
# findings, and 80 of the reviews produced none at all. Every one of the five
# reviews a human dismissed rested on a premise nobody had checked; three of the
# five were the same invented decorator.
#
# The debate strategy already has a stage for exactly this — "For EACH finding:
# try hard to REFUTE it — is it wrong, out-of-scope, or not substantiated by the
# actual diff?" — but running the whole multi-agent path on the 84% of reviews
# that find nothing buys nothing. The refutation's value comes entirely from
# there being something to refute, so it runs only then.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-refute.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CALLS="$TMP/calls"; : > "$CALLS"
REPLY='{"comments":[]}'
PROMPT="$TMP/prompt"

# The refuter is just another model call; record it and answer as configured.
review_call_model() { echo x >> "$CALLS"; printf '%s' "$3" > "$PROMPT"; printf '%s' "$REPLY"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

TWO='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"a.ts","line":1,"severity":"HIGH","body":"real: divides by zero"},
  {"path":"b.ts","line":2,"severity":"HIGH","body":"invented: violates the `Nonexistent` convention"}]}'
NONE='{"status":"APPROVED","summary":"nothing found","comments":[]}'

run() { _review_refute_findings "$1" "$TMP" claude "" "" 6 ""; }

# --- 1. no findings, no call — this is the whole point of the choice --------
: > "$CALLS"
out=$(run "$NONE")
[[ "$(calls)" == "0" ]] \
  && ok "a review with no findings costs no extra model call" \
  || fail "the refutation ran with nothing to refute ($(calls) call(s))"
[[ "$(jq -r '.status' <<<"$out")" == "APPROVED" ]] \
  && ok "a finding-free review passes through untouched" || fail "a finding-free review was altered"

# --- 2. findings → exactly one pass -----------------------------------------
: > "$CALLS"; REPLY='{"comments":[{"path":"a.ts","line":1,"severity":"HIGH","body":"real: divides by zero"}]}'
out=$(run "$TWO")
[[ "$(calls)" == "1" ]] && ok "findings trigger exactly one refutation pass" \
                        || fail "expected 1 pass, got $(calls)"
[[ "$(jq -r '[.comments[]|select(.path=="b.ts")]|length' <<<"$out")" == "0" ]] \
  && ok "a finding the refuter could not substantiate is dropped" \
  || fail "the unsubstantiated finding survived"
[[ "$(jq -r '[.comments[]|select(.path=="a.ts")]|length' <<<"$out")" == "1" ]] \
  && ok "a finding it upheld survives" || fail "the refuter's pass dropped a substantiated finding"

# --- 3. it may refute, never introduce --------------------------------------
# A refuter that adds findings is doing a second review, unverified by anything.
: > "$CALLS"; REPLY='{"comments":[
  {"path":"a.ts","line":1,"severity":"HIGH","body":"real: divides by zero"},
  {"path":"z.ts","line":9,"severity":"CRITICAL","body":"brand new issue nobody reviewed"}]}'
out=$(run "$TWO")
[[ "$(jq -r '[.comments[]|select(.path=="z.ts")]|length' <<<"$out")" == "0" ]] \
  && ok "the refuter cannot introduce a finding of its own" \
  || fail "a new, unreviewed finding entered through the refutation stage"

# --- 4. a broken pass must never empty the findings -------------------------
# Silently dropping everything because a stage failed is a worse failure than
# the noise it was meant to remove.
for bad in 'not json' '' '{"unexpected":true}'; do
  : > "$CALLS"; REPLY="$bad"
  out=$(run "$TWO")
  n=$(jq -r '[.comments[]]|length' <<<"$out" 2>/dev/null)
  [[ "$n" == "2" ]] && ok "a broken refutation keeps the original findings ([${bad:0:12}])" \
                    || fail "findings were lost to a broken refutation ([${bad:0:12}], left $n)"
done

# --- 5. the verdict is not the refuter's to change --------------------------
: > "$CALLS"; REPLY='{"comments":[]}'
out=$(run "$TWO")
[[ "$(jq -r '.status' <<<"$out")" == "CHANGES_REQUESTED" ]] \
  && ok "the refutation does not rewrite the verdict" || fail "the verdict changed"
[[ "$(jq -r '.summary' <<<"$out")" == "s" ]] && ok "the summary is preserved" || fail "summary lost"

# --- 6. what the refuter is asked -------------------------------------------
: > "$CALLS"; REPLY='{"comments":[]}'
run "$TWO" >/dev/null
for probe in REFUTE substantiate; do
  grep -qi "$probe" "$PROMPT" && ok "the prompt asks it to $probe" \
                              || fail "the refutation prompt does not mention $probe"
done
grep -qF 'invented: violates' "$PROMPT" \
  && ok "the findings under refutation are in the prompt" || fail "the refuter was not shown the findings"

# --- 7. opt-out, for a caller that has its own refutation -------------------
# Debate already refutes internally; running this on top would pay twice.
: > "$CALLS"
out=$(MRA_REVIEW_REFUTE=0 run "$TWO")
[[ "$(calls)" == "0" ]] && ok "MRA_REVIEW_REFUTE=0 skips the pass" || fail "the opt-out was ignored"
[[ "$(jq -r '[.comments[]]|length' <<<"$out")" == "2" ]] \
  && ok "skipping leaves the findings alone" || fail "the opt-out path altered findings"

# --- 8. never destroys input it cannot read ---------------------------------
[[ "$(run 'not json')" == "not json" ]] && ok "unparseable input passes through" \
                                        || fail "the stage ate a result it could not parse"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
