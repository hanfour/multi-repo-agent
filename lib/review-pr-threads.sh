#!/usr/bin/env bash
# Prior MRA findings on a PR, and the replies that answer them.
#
# A reply to one of our own findings is not "discussion to avoid duplicating" —
# it is a demand to adjudicate a specific earlier claim. The generic discussion
# block gets the opposite instruction ("do NOT re-report issues already raised
# here"), which, applied to our own wrong finding, freezes it instead of
# reconsidering it. So these threads are lifted out and framed separately.
#
# Production case that motivated this: a [HIGH] finding rested on a false
# premise about DOM event propagation. A reviewer replied with an 838-character
# rebuttal naming the premise and listing three verifications. The review was
# dismissed by hand; a re-run would have reproduced the finding verbatim.
#
# Callers supply items shaped:
#   {id, inReplyToId, author, kind, path, line, body, createdAt, isPriorReview}
# `isPriorReview` is set by whoever fetched the discussion, because only they
# know which comments they posted. MRA must not guess: in the integration path
# it posts under the operator's own account, so author identity proves nothing.

# Per-item body budget. Deliberately far above the 240 chars the generic block
# uses: a rebuttal's value is its reasoning, and 240 chars reliably cuts a real
# one off at the point where the evidence starts.
_MRA_THREAD_BODY_MAX="${MRA_REVIEW_THREAD_BODY_MAX:-4000}"

# Location key for a finding: "path:line". Falls back to `loc` for callers still
# using the flat shape.
_MRA_THREAD_LOC_JQ='(if ((.path // "") != "") then "\(.path):\(.line // 0)" else (.loc // "") end)'

# _review_mark_prior_reviews <discussion-json> <our-login>
# Set `isPriorReview` on the items we posted.
#
# Identity alone is not evidence. In the integration path MRA posts with the
# operator's own token, so our comments carry a human's login and that human
# also talks on the PR normally. A content marker alone is not evidence either —
# a reviewer can write "[HIGH] ..." by hand. Both must match.
#
# An unknown login (the lookup failed) marks nothing: a review that cannot tell
# which comments are its own must behave exactly as it did before this existed,
# not guess and then invite the model to revise a human's comment.
_review_mark_prior_reviews() {
  local json="$1" self="$2"
  if [[ -z "$self" ]]; then
    printf '%s' "$json" | jq -c 'map(.isPriorReview = false)' 2>/dev/null || printf '%s' "$json"
    return 0
  fi
  printf '%s' "$json" | jq -c --arg self "$self" '
    map(.isPriorReview =
      (((.author // "") == $self)
       and (((.body // "") | test("^\\[(CRITICAL|HIGH|MEDIUM|LOW)\\]"))
            or ((.body // "") | test("MRA artifact:"))
            or ((.body // "") | test("## MRA Code Review Summary")))))
  ' 2>/dev/null || printf '%s' "$json"
}

# _review_rebutted_locations <discussion-json>
# One "path:line" per line, for every prior finding that somebody other than us
# answered. A finding nobody replied to is not rebutted, and our own follow-up
# to our own finding is not somebody rebutting it.
_review_rebutted_locations() {
  local json="$1"
  printf '%s' "$json" | jq -r --argjson _n 0 '
    (map(select(.isPriorReview == true)) // []) as $prior
    | (map(select((.isPriorReview != true) and (.inReplyToId != null))) // []) as $replies
    | $prior
    | map(. as $f | select($replies | any(.inReplyToId == $f.id)))
    | map('"$_MRA_THREAD_LOC_JQ"')
    | map(select(. != ""))
    | unique
    | .[]
  ' 2>/dev/null || true
}

# _review_format_prior_findings <discussion-json>
# The threaded section, or empty when there is nothing to adjudicate. Empty is
# the important default: a review with no prior findings must read exactly as it
# did before this existed.
_review_format_prior_findings() {
  local json="$1" answered unanswered
  answered=$(printf '%s' "$json" | jq -r --argjson max "$_MRA_THREAD_BODY_MAX" '
    def clip: if (. | length) > $max then .[0:$max] + "…(truncated)" else . end;
    (map(select(.isPriorReview == true)) // []) as $prior
    | (map(select((.isPriorReview != true) and (.inReplyToId != null))) // []) as $replies
    | $prior
    | map(. as $f
        | ($replies | map(select(.inReplyToId == $f.id))) as $answers
        | select(($answers | length) > 0)
        | "### Prior finding — " + '"$_MRA_THREAD_LOC_JQ"' + "\n\n"
          + (($f.body // "") | clip) + "\n\n"
          + ($answers
             | sort_by(.createdAt // "")
             | map("  ↳ @" + (.author // "?") + " replied:\n\n"
                   + ((.body // "") | clip | split("\n") | map("  " + .) | join("\n")))
             | join("\n\n")))
    | join("\n\n---\n\n")
  ' 2>/dev/null) || answered=""
  [[ "$answered" == "null" ]] && answered=""

  unanswered=$(printf '%s' "$json" | jq -r --argjson max "$_MRA_THREAD_BODY_MAX" '
    def clip: if (. | length) > $max then .[0:$max] + "…(truncated)" else . end;
    (map(select((.isPriorReview != true) and (.inReplyToId != null))) // []) as $replies
    | map(select(.isPriorReview == true))
    | map(. as $f | select($replies | any(.inReplyToId == $f.id) | not)
        | "### Prior output, no response — "
          + (if '"$_MRA_THREAD_LOC_JQ"' != "" then '"$_MRA_THREAD_LOC_JQ"' else "(review summary)" end)
          + "\n\n" + (($f.body // "") | clip))
    | join("\n\n---\n\n")
  ' 2>/dev/null) || unanswered=""
  [[ "$unanswered" == "null" ]] && unanswered=""

  [[ -n "$answered$unanswered" ]] || return 0

  # Everything of ours is framed here rather than in the generic discussion
  # block, whose instruction is "do NOT re-report issues already raised here".
  # That is right for other people's comments and wrong for our own: applied to
  # our own finding it makes round two silent about a problem round one found
  # and nobody fixed, and the caller reads that silence as the problem being
  # gone. It is the reason the dev loop had to run with PR context switched off.
  echo "## Your own prior output on this PR"
  echo
  if [[ -n "$answered" ]]; then
    cat <<'HDR'
Somebody answered the findings below. They are OPEN FOR REVISION — treat each
reply as an argument you must engage with, not as discussion to stay quiet about.

For EACH of them you MUST emit exactly one line in your summary:

    ADJUDICATION <path>:<line> UPHELD — <why the reply does not refute the finding>
    ADJUDICATION <path>:<line> WITHDRAWN — <what the finding got wrong>

Upholding is always available; it just has to be argued against what the reply
actually says. A finding you re-report at a location carrying an unanswered
reply WILL BE DROPPED — silence is not a way to keep it.

Withdraw whenever the reply is right. A withdrawal stated plainly is a correct
review outcome, not a failure.

HDR
    printf '%s\n' "$answered"
    [[ -n "$unanswered" ]] && echo
  fi
  if [[ -n "$unanswered" ]]; then
    cat <<'HDR'
Nobody responded to the output below. It is NOT "already raised, leave it
alone": judge it against the diff in front of you now. If the problem is still
there, report it again. If it has been fixed or the code has moved on, do not.

HDR
    printf '%s\n' "$unanswered"
  fi
}
