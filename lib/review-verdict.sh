#!/usr/bin/env bash
# Shared review verdict-sentinel contract, used by BOTH the debate path
# (lib/review-debate.sh) and the single-pass path (lib/review.sh). Kept in one
# place so a review can never be judged complete by two different rules.

# The sentinel a completed review ends its output with:
#   ===MRA-REVIEW-COMPLETE-<nonce>: APPROVED===
#   ===MRA-REVIEW-COMPLETE-<nonce>: CHANGES_REQUESTED===
# Absence == the review did not finish (cutoff/failure), never an approval.
#
# The token carries a nonce minted once per process. A constant token is fully
# predictable from this (public) source, so a diff could simply contain a line
# spelling a valid sentinel and rely on the reviewing model quoting it back —
# turning content under review into a forged verdict (GHSA-5gjm-rqvq-f877).
# The nonce is generated after the diff was authored and never leaves this
# process except inside the prompt, so diff content cannot spell it.
#
# Anchoring alone (GHSA-vj6f-5fw7-p56f) is not enough: once the sentinel must
# occupy a whole line, injected content can still supply a whole line. Only an
# unpredictable token removes the forgery primitive.
_mra_review_mint_nonce() {
  local n=""
  if command -v openssl >/dev/null 2>&1; then
    n=$(openssl rand -hex 8 2>/dev/null)
  fi
  if [[ ! "$n" =~ ^[0-9a-f]{16}$ && -r /dev/urandom ]]; then
    n=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -dc '0-9a-f')
  fi
  if [[ ! "$n" =~ ^[0-9a-f]{16}$ ]]; then
    # Last resort: bash's own PRNG. Weaker than urandom, but it still delivers
    # the one property required here — unpredictability from diff content.
    n=$(printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
  fi
  printf '%s' "$n"
}

# Deliberately overridable: tests pin it to spell sentinels literally, and an
# operator debugging a transcript can do the same. It is NOT exported, so a
# nested `mra` process mints its own.
MRA_REVIEW_SENTINEL_TOKEN="${MRA_REVIEW_SENTINEL_TOKEN:-MRA-REVIEW-COMPLETE-$(_mra_review_mint_nonce)}"

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
