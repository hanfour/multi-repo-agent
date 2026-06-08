#!/usr/bin/env bash
# Branch-aware introspection and the pure sync decision engine.
# All functions are read-only: they never modify a working tree or branch.

# Pure decision engine. First matching rule wins (see spec §4.2).
# Args: ahead behind dirty upstream  -> prints one action string.
branch_sync_action() {
  local ahead="$1" behind="$2" dirty="$3" upstream="$4"
  if [[ "$upstream" == "(none)" ]]; then echo "no-upstream"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then echo "up-to-date"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then echo "ahead-only"; return; fi
  if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then echo "diverged"; return; fi
  # Remaining: behind>0 and ahead==0
  if [[ "$dirty" -gt 0 ]]; then echo "dirty-skip"; return; fi
  echo "fast-forward"
}

# Pure push decision engine, sibling to branch_sync_action. First matching rule wins.
# Args: ahead behind upstream branch  -> prints one action string.
# Does NOT consider dirty (uncommitted files don't affect pushing committed refs).
# `branch` distinguishes a real unpublished branch from a detached HEAD (both have upstream=(none)).
branch_push_action() {
  local ahead="$1" behind="$2" upstream="$3" branch="$4"
  if [[ "$branch" == "(detached)" ]]; then echo "skip-detached"; return; fi
  if [[ "$upstream" == "(none)" ]]; then echo "push-new"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then echo "up-to-date"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then echo "push"; return; fi
  if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then echo "skip-diverged"; return; fi
  echo "skip-behind"   # ahead==0 && behind>0
}

# Read one KEY=VALUE field out of a state block.
# Args: state_block key
branch_state_get() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# Compute a read-only BranchState snapshot for a repo.
# Does NOT fetch — reads local refs only (callers fetch when they want fresh counts).
# Prints flat KEY=VALUE lines (see spec §4.1).
get_branch_state() {
  local repo_dir="$1"
  local repo branch upstream ahead behind dirty action counts
  repo=$(basename "$repo_dir")
  branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "(none)")
  if [[ "$upstream" == "(none)" ]]; then
    ahead=0; behind=0
  else
    counts=$(git -C "$repo_dir" rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || printf '0\t0')
    behind=$(printf '%s' "$counts" | cut -f1)
    ahead=$(printf '%s' "$counts" | cut -f2)
    [[ -z "$behind" ]] && behind=0
    [[ -z "$ahead" ]] && ahead=0
  fi
  # dirty = tracked staged + unstaged (untracked excluded; out of scope, spec §4.3)
  dirty=$(git -C "$repo_dir" status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true)
  action=$(branch_sync_action "$ahead" "$behind" "$dirty" "$upstream")
  printf 'repo=%s\nbranch=%s\nupstream=%s\nahead=%s\nbehind=%s\ndirty=%s\nsync_action=%s\n' \
    "$repo" "$branch" "$upstream" "$ahead" "$behind" "$dirty" "$action"
}

# True (exit 0) if a repo's row should show by default in `branch status`.
# Args: ahead behind dirty on_default("true"/"false")
branch_row_needs_attention() {
  local ahead="$1" behind="$2" dirty="$3" on_default="$4"
  [[ "$ahead" -gt 0 || "$behind" -gt 0 || "$dirty" -gt 0 || "$on_default" != "true" ]]
}

# Format one BranchState block as a single aligned table row (no trailing newline).
# Args: state_block
branch_format_row() {
  local s="$1" repo branch upstream ahead behind dirty action
  repo=$(branch_state_get "$s" repo)
  branch=$(branch_state_get "$s" branch)
  upstream=$(branch_state_get "$s" upstream)
  ahead=$(branch_state_get "$s" ahead)
  behind=$(branch_state_get "$s" behind)
  dirty=$(branch_state_get "$s" dirty)
  action=$(branch_state_get "$s" sync_action)
  printf '%-20s %-24s +%-3s -%-3s ~%-3s %s' \
    "$repo" "$branch" "$ahead" "$behind" "$dirty" "$action"
}

# Emit one BranchState block as a JSON object (jq-built; injection-safe).
# The JSON sibling of branch_format_row.
# Args: state_block on_default needs_attention
#   - state_block MUST be a block produced by get_branch_state (guarantees the
#     numeric ahead/behind/dirty fields are present and numeric).
#   - on_default / needs_attention MUST be the strings "true" or "false"
#     (passed via --argjson to become JSON booleans).
branch_state_json() {
  local s="$1" on_default="$2" needs_attention="$3"
  [[ "$on_default" == "true" || "$on_default" == "false" ]] \
    || { echo "branch_state_json: on_default must be 'true' or 'false', got: '$on_default'" >&2; return 1; }
  [[ "$needs_attention" == "true" || "$needs_attention" == "false" ]] \
    || { echo "branch_state_json: needs_attention must be 'true' or 'false', got: '$needs_attention'" >&2; return 1; }
  jq -n \
    --arg repo "$(branch_state_get "$s" repo)" \
    --arg branch "$(branch_state_get "$s" branch)" \
    --arg upstream "$(branch_state_get "$s" upstream)" \
    --argjson ahead "$(branch_state_get "$s" ahead)" \
    --argjson behind "$(branch_state_get "$s" behind)" \
    --argjson dirty "$(branch_state_get "$s" dirty)" \
    --arg sync_action "$(branch_state_get "$s" sync_action)" \
    --argjson on_default "$on_default" \
    --argjson needs_attention "$needs_attention" \
    '{repo:$repo, branch:$branch, upstream:$upstream, ahead:$ahead, behind:$behind, dirty:$dirty, sync_action:$sync_action, on_default:$on_default, needs_attention:$needs_attention}'
}
