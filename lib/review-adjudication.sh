#!/usr/bin/env bash
# The adjudication gate: a finding refuted on the PR cannot come back unanswered.
#
# The prompt asks the model to adjudicate each rebutted prior finding. Asking is
# not enough — the same reasoning that produced a wrong finding will happily
# produce it again and say nothing about the reply. So the contract is checked
# rather than trusted, in the house style of the review sentinel: a claim only
# counts when it is present in a form we can verify.
#
# The check is deliberately narrow. It touches ONLY findings re-reported at a
# location that carries an unanswered reply. Everything else passes through
# byte-for-byte, including the verdict — this gate removes an unsupported
# finding, it does not decide reviews.

# _review_adjudicated_in_summary <summary> <loc>
# True when the summary carries an ADJUDICATION line for this location. Matched
# on whitespace-normalised text with a literal compare, so a path full of `.`
# and `/` needs no regex escaping.
_review_adjudicated_in_summary() {
  local summary="$1" loc="$2" norm
  norm=$(printf '%s' "$summary" | tr '\n\r\t' '   ' | tr -s ' ')
  printf '%s' "$norm" | grep -qF "ADJUDICATION $loc UPHELD" && return 0
  printf '%s' "$norm" | grep -qF "ADJUDICATION $loc WITHDRAWN" && return 0
  return 1
}

# _review_enforce_adjudication <review-json> <rebutted-locations>
# Locations are newline-separated "path:line". Emits the review JSON, with any
# finding re-reported at an unadjudicated rebutted location removed.
#
# Never destructive on inputs it does not understand: unparseable JSON, or no
# rebutted locations, is echoed back unchanged. A gate that eats a result it
# failed to read would be a worse failure than the one it guards against.
_review_enforce_adjudication() {
  local review_json="$1" rebutted="$2"

  [[ -n "${rebutted//[[:space:]]/}" ]] || { printf '%s' "$review_json"; return 0; }
  printf '%s' "$review_json" | jq -e . >/dev/null 2>&1 || { printf '%s' "$review_json"; return 0; }

  local summary unanswered=() loc
  summary=$(printf '%s' "$review_json" | jq -r '.summary // ""' 2>/dev/null) || summary=""

  while IFS= read -r loc; do
    [[ -n "$loc" ]] || continue
    if ! _review_adjudicated_in_summary "$summary" "$loc"; then
      unanswered+=("$loc")
    fi
  done <<< "$rebutted"

  if [[ ${#unanswered[@]} -eq 0 ]]; then
    printf '%s' "$review_json"
    return 0
  fi

  local locs_json filtered before after
  locs_json=$(printf '%s\n' "${unanswered[@]}" | jq -R . | jq -sc .) || { printf '%s' "$review_json"; return 0; }
  before=$(printf '%s' "$review_json" | jq '[.comments[]?] | length' 2>/dev/null) || before=0
  filtered=$(printf '%s' "$review_json" | jq -c --argjson drop "$locs_json" '
    .comments = [ (.comments[]? | select((("\(.path // ""):\(.line // 0)")) as $k | ($drop | index($k)) | not)) ]
  ' 2>/dev/null) || { printf '%s' "$review_json"; return 0; }
  after=$(printf '%s' "$filtered" | jq '[.comments[]?] | length' 2>/dev/null) || after=0

  if declare -F log_warn >/dev/null 2>&1 && [[ "$before" -gt "$after" ]]; then
    log_warn "dropped $((before - after)) finding(s) re-reported at a location whose rebuttal went unanswered: ${unanswered[*]}" "review" >&2
  fi
  printf '%s' "$filtered"
}
