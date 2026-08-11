#!/usr/bin/env bash
# One refutation pass over the findings — and only when there are findings.
#
# The debate strategy already carries this stage. Running the whole multi-agent
# path in production to reach it would be paying for a fleet to get one
# question asked, on reviews that mostly have nothing to ask it about: measured
# over 80 reviewed pull requests, 95 reviews produced 31 findings and 80 of the
# reviews produced none at all. The refutation's value comes entirely from
# there being something to refute, so it runs only then and costs nothing
# otherwise.
#
# What it is for: every one of the five reviews a human dismissed rested on a
# premise nobody had checked, and three of the five were the same invented
# decorator. lib/review-premise.sh catches the mechanically checkable half —
# a named symbol that is nowhere in the tree. This catches the rest: a claim
# that is coherent, cites nothing absent, and still is not supported by the
# diff in front of it.
#
# Two properties matter more than the filtering:
#   - it may REMOVE a finding, never ADD one. A refuter that introduces
#     findings is running a second review that nothing then checks.
#   - a broken pass keeps every original finding. Emptying a review because a
#     stage failed would be a worse failure than the noise it removes.

_review_refute_prompt() {
  local findings="$1"
  cat <<HDR
## Adversarial verification

A prior reviewer reported the findings below on this diff. For EACH one, try
hard to REFUTE it: is it wrong, out of scope for this change, or not
substantiated by the actual diff and the code you can read?

Check the claims rather than judging them plausible. A finding that asserts an
existing convention, an API's behaviour, or what other code does is only
substantiated if you can find that in the repository.

Keep ONLY the findings you can substantiate. Drop the rest. Do NOT introduce
issues of your own — anything you add here has been reviewed by nobody.

Reply with JSON only:
{"comments":[<the surviving findings, copied verbatim>]}

### Findings under refutation

$findings
HDR
}

# _review_refute_findings <review-json> <project-dir> <provider> <model> <add-dirs> <turns> <system-prompt-file>
_review_refute_findings() {
  local review_json="$1" project_dir="$2" provider="${3:-claude}" model="${4:-}"
  local add_dirs="${5:-}" turns="${6:-6}" sys="${7:-}"

  [[ "${MRA_REVIEW_REFUTE:-1}" != "0" ]] || { printf '%s' "$review_json"; return 0; }
  printf '%s' "$review_json" | jq -e . >/dev/null 2>&1 || { printf '%s' "$review_json"; return 0; }

  local n
  n=$(printf '%s' "$review_json" | jq '[.comments[]?] | length' 2>/dev/null) || n=0
  [[ "$n" -gt 0 ]] || { printf '%s' "$review_json"; return 0; }

  local findings prompt raw kept
  findings=$(printf '%s' "$review_json" | jq -r '
    [.comments[]? | "- [\(.severity // "?")] \(.path // "?"):\(.line // 0) — \(.body // "")"] | join("\n\n")
  ' 2>/dev/null) || { printf '%s' "$review_json"; return 0; }
  prompt=$(_review_refute_prompt "$findings")

  raw=$(review_call_model refute "$provider" "$prompt" "$model" "$project_dir" "$add_dirs" "$turns" "$sys" 2>/dev/null) || raw=""

  # Anything we cannot read leaves the review exactly as it was. The `comments`
  # key must be PRESENT: `{"comments":[]}` is an answer meaning none survived,
  # while a reply that simply lacks the key answered nothing — and treating the
  # second as the first would empty a review on a malformed response.
  kept=$(printf '%s' "$raw" | sed -n '/{/,$p' \
    | jq -c 'if has("comments") then [.comments[]? | {path, line}] else empty end' 2>/dev/null) || kept=""
  [[ -n "$kept" && "$kept" != "null" ]] || {
    if declare -F log_warn >/dev/null 2>&1; then
      log_warn "refutation pass returned nothing usable — keeping all $n finding(s)" "review" >&2
    fi
    printf '%s' "$review_json"; return 0
  }

  # Intersect: the refuter chooses which of the ORIGINAL findings survive. A
  # location it invented is not one of them.
  local filtered after
  filtered=$(printf '%s' "$review_json" | jq -c --argjson keep "$kept" '
    .comments = [ .comments[]? | . as $c
                  | select($keep | any((.path == $c.path) and ((.line // 0) == ($c.line // 0)))) ]
  ' 2>/dev/null) || { printf '%s' "$review_json"; return 0; }
  after=$(printf '%s' "$filtered" | jq '[.comments[]?] | length' 2>/dev/null) || after="$n"

  if [[ "$after" -lt "$n" ]] && declare -F log_warn >/dev/null 2>&1; then
    log_warn "refutation dropped $((n - after)) of $n finding(s) it could not substantiate against the diff" "review" >&2
  fi
  printf '%s' "$filtered"
}
