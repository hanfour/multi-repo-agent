#!/usr/bin/env bash
# The dev loop must hear a human who replies to one of its findings.
#
# It used to force MRA_REVIEW_PR_CONTEXT=0 on every loop-internal re-review
# (design D7), for a real reason: the generic discussion block is introduced
# with "do NOT re-report issues already raised here", and the loop's own
# round-1 findings came back through it. Round 2 would read its own finding as
# already-raised, say nothing, and the loop would take that silence for the
# problem having been fixed — a cross-round false green.
#
# The cost was that a reviewer replying "不改，因為…" was equally unheard: the
# loop could not see any PR discussion at all, including the human's.
#
# What changed is the framing, not the discipline. Our own prior output is no
# longer in the do-not-re-report block; it is presented as ours, to be judged
# against the current diff and re-reported if it still holds. With that, the
# reason to blind the loop is gone.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-pr-discussion.sh"
source "$MRA_DIR/lib/review-pr-threads.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export MRA_REVIEW_RESULT_FILE="$TMP/rf"

# Pull in just the function under test — dev.sh at large drags in the whole
# loop, and this is about one decision inside it.
eval "$(sed -n '/^_dev_review_one()/,/^}/p' "$MRA_DIR/lib/dev.sh")"

SEEN="$TMP/seen"
review_project() { printf 'PR_CONTEXT=[%s]\nARGS=[%s]\n' "${MRA_REVIEW_PR_CONTEXT:-unset}" "$*" > "$SEEN"; }
_dev_read_status() { echo APPROVED; }
_dev_fingerprint() { echo fp; }

# --- the PR path must not blind itself --------------------------------------
_dev_review_one /ws proj pr main 7 >/dev/null 2>&1
ctx=$(sed -n 's/^PR_CONTEXT=\[\(.*\)\]$/\1/p' "$SEEN")
[[ "$ctx" != "0" ]] \
  && ok "a PR re-review is no longer blind to the discussion (PR_CONTEXT=[$ctx])" \
  || fail "the loop still discards PR discussion, so a reviewer's rebuttal is unheard"
grep -q -- '--pr 7' "$SEEN" && ok "the review is still pinned to the PR" || fail "--pr lost"

# --- the local path is unchanged: there is no PR to read -------------------
_dev_review_one /ws proj code main "" >/dev/null 2>&1
grep -q -- '--pr' "$SEEN" && fail "a local review must not carry --pr" \
                          || ok "a local review is unaffected"

# --- and the false green D7 guarded against must be structurally gone -------
# If this regresses, turning PR context back on is unsafe, so it is asserted
# here too rather than only where the renderer is tested.
OWN=$(jq -cn '[{id:1, inReplyToId:null, author:"bot", kind:"inline", path:"a.ts", line:3,
                body:"[HIGH] round-one finding", createdAt:"1", isPriorReview:true}]')
printf '%s' "$(_review_format_pr_discussion "$OWN")" | grep -qF "round-one finding" \
  && fail "the loop's own finding is back under do-not-re-report — round 2 would go silent" \
  || ok "the loop's own finding is never presented as already-raised"
printf '%s' "$(_review_format_prior_findings "$OWN")" | grep -qF "round-one finding" \
  && ok "it is carried as our own output, to be re-judged against the diff" \
  || fail "the loop's own finding vanished instead of being re-judged"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
