#!/usr/bin/env bash
# Deterministic implement -> review -> fix -> PR loop for `mra dev`.
# Verdict comes ONLY from $MRA_REVIEW_RESULT_FILE; exit code is never the gate.

_dev_read_status() {
  local rf="$1" st
  st=$(jq -r '.status // empty' "$rf" 2>/dev/null || true)
  [[ -n "$st" ]] && printf '%s' "$st" || printf 'REVIEW_INCOMPLETE'
}

_dev_fingerprint() {
  local rf="$1"
  jq -r '(.comments // [])[] | "\(.path):\(.line):\(.severity)"' "$rf" 2>/dev/null \
    | sort | tr '\n' ',' || true
}

# Run one debate review; emit verdict to RF; echo "STATUS|FINGERPRINT".
# mode=code (local base...HEAD) | pr (post to GitHub PR + verdict).
_dev_review_one() {
  local workspace="$1" project="$2" mode="$3" base="$4" pr_n="$5"
  : > "$MRA_REVIEW_RESULT_FILE"
  local -a rargs=(--strategy debate --base "$base")
  local pr_ctx="" allow=""
  if [[ "$mode" == pr ]]; then
    rargs+=(--pr "$pr_n"); pr_ctx=0
    [[ "${DEV_AUTO_APPROVE:-false}" == true ]] && allow=1
  fi
  # set -e firewall (§10-1): || true so review_project's documented return-1
  # (malformed-JSON path) can never abort the loop before we read the file.
  MRA_REVIEW_VERIFY_APPROVE=1 MRA_REVIEW_PR_CONTEXT="$pr_ctx" MRA_REVIEW_ALLOW_APPROVE="$allow" \
    review_project "$workspace" "$project" "${rargs[@]}" 1>&2 || true
  printf '%s|%s' "$(_dev_read_status "$MRA_REVIEW_RESULT_FILE")" "$(_dev_fingerprint "$MRA_REVIEW_RESULT_FILE")"
}
