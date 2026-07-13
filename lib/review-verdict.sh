#!/usr/bin/env bash
# Shared review verdict-sentinel contract, used by BOTH the debate path
# (lib/review-debate.sh) and the single-pass path (lib/review.sh). Kept in one
# place so a review can never be judged complete by two different rules.

# The sentinel a completed review ends its output with:
#   ===MRA-REVIEW-COMPLETE: APPROVED===
#   ===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
# Absence == the review did not finish (cutoff/failure), never an approval.
MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"

# Extract a declared verdict from arbitrary review text: APPROVED |
# CHANGES_REQUESTED | NONE. CHANGES_REQUESTED wins if both appear.
review_verdict_of() {
  if printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*CHANGES_REQUESTED"; then
    printf 'CHANGES_REQUESTED'
  elif printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*APPROVED"; then
    printf 'APPROVED'
  else
    printf 'NONE'
  fi
}

# The canonical neutral "review did not complete" verdict as ONE JSON object.
# $1 = optional full reason clause (already past "⚠️ REVIEW_INCOMPLETE — ").
# status COMMENT + empty comments => the approve gate passes it through, never
# APPROVE. jq -n builds it so the reason is safely escaped.
review_incomplete_json() {
  local reason="${1:-the single-pass review did not emit a completion sentinel (likely a max-turns cutoff or a failed call). This is NOT an approval; re-run or review manually.}"
  jq -cn --arg s "⚠️ REVIEW_INCOMPLETE — ${reason}" \
    '{status:"COMMENT", summary:$s, comments:[]}'
}
