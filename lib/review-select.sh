#!/usr/bin/env bash
# Pure selection of repos to auto-review after a sync.
# review_targets(workspace, changed...) = {changed} ∪ {repos with ahead>0 OR not on default branch}.
# Read-only; relies on get_branch_state / branch_state_get / is_on_default_branch / should_skip_dir.

review_targets() {
  local workspace="$1"; shift
  local seen=" " out=()
  # 1) repos sync changed this run (passed as args)
  local r
  for r in "$@"; do
    [[ -z "$r" ]] && continue
    if [[ "$seen" != *" $r "* ]]; then out+=("$r"); seen="$seen$r "; fi
  done
  # 2) repos with local work: ahead>0 or off-default
  local dir name state ahead on_default
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    state=$(get_branch_state "$dir")
    ahead=$(branch_state_get "$state" ahead)
    if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
    if [[ "$ahead" -gt 0 || "$on_default" != "true" ]]; then
      if [[ "$seen" != *" $name "* ]]; then out+=("$name"); seen="$seen$name "; fi
    fi
  done
  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
  return 0
}
