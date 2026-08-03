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
#
# The match is anchored to a WHOLE line that IS the sentinel (tolerating
# surrounding and internal whitespace) — the same rule _review_singlepass_body
# applies in lib/review-json.sh, which is the point of this file existing.
# A bare substring match treated any output that merely QUOTED the sentinel as
# a declared verdict, so an agent that echoed the sentinel out of the diff and
# was then cut off by max-turns — never stating a verdict of its own — was read
# as APPROVED. With both debate agents cut off that way, _debate_assess
# returned APPROVE: a false green in the mechanism built to prevent false
# greens (GHSA-vj6f-5fw7-p56f).
review_verdict_of() {
  printf '%s\n' "$1" | awk -v token="$MRA_REVIEW_SENTINEL_TOKEN" '
    $0 ~ "^[[:space:]]*===" token ":[[:space:]]*CHANGES_REQUESTED[[:space:]]*===[[:space:]]*$" { cr = 1 }
    $0 ~ "^[[:space:]]*===" token ":[[:space:]]*APPROVED[[:space:]]*===[[:space:]]*$"          { ap = 1 }
    END {
      if (cr)      print "CHANGES_REQUESTED"
      else if (ap) print "APPROVED"
      else         print "NONE"
    }
  '
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
