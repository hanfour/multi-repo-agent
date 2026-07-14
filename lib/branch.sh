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

# branch command handler (extracted from bin/mra.sh dispatch, #16)
cmd_branch() {
      shift
      local sub="${1:-}"; shift || true
      case "$sub" in
        status)
          local show_all=false do_fetch=false json=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --all) show_all=true; shift ;;
              --fetch) do_fetch=true; shift ;;
              --json) json=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          local shown=0 failed=0
          local json_objs=()
          [[ "$json" == "false" ]] && printf '%-20s %-24s %-5s%-5s%-5s %s\n' "REPO" "BRANCH" "AHEAD" "BEHIND" "DIRTY" "ACTION"
          for dir in "$workspace"/*/; do
            [[ ! -d "$dir" ]] && continue
            local name; name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            should_skip_dir "$dir" && continue
            if [[ "$do_fetch" == "true" ]]; then
              if ! git -C "$dir" fetch --quiet 2>/dev/null; then
                if [[ "$json" == "true" ]]; then
                  log_error "$name: fetch failed" "branch" >&2
                else
                  log_error "$name: fetch failed" "branch"
                fi
                failed=$((failed+1))
              fi
            fi
            local state on_default ahead behind dirty needs_attention
            state=$(get_branch_state "$dir")
            ahead=$(branch_state_get "$state" ahead)
            behind=$(branch_state_get "$state" behind)
            dirty=$(branch_state_get "$state" dirty)
            if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
            if branch_row_needs_attention "$ahead" "$behind" "$dirty" "$on_default"; then needs_attention=true; else needs_attention=false; fi
            if [[ "$json" == "true" ]]; then
              json_objs+=("$(branch_state_json "$state" "$on_default" "$needs_attention")")
            elif [[ "$show_all" == "true" || "$needs_attention" == "true" ]]; then
              branch_format_row "$state"; printf '\n'; shown=$((shown+1))
            fi
          done
          if [[ "$json" == "true" ]]; then
            if [[ ${#json_objs[@]} -eq 0 ]]; then
              printf '[]\n'
            else
              printf '%s\n' "${json_objs[@]}" | jq -s '.'
            fi
            [[ "$failed" -gt 0 ]] && exit 1
            exit 0
          fi
          if [[ "$shown" -eq 0 && "$show_all" == "false" ]]; then
            log_success "all repos clean and up to date" "branch"
          fi
          [[ "$failed" -gt 0 ]] && exit 1
          exit 0
          ;;
        new)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch new <name> [repos...]" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          create_branch_workspace "$workspace" "$bname" "$@"
          exit $?
          ;;
        switch)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch switch <name>" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          switch_branch_workspace "$workspace" "$bname"
          exit $?
          ;;
        pr)
          local base="" dry_run=false repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --base) if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "branch"; exit 1; fi; base="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch pr requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          pr_workspace "$workspace" "$base" "$dry_run" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
        merge)
          local strategy="merge" dry_run=false delete_branch=false wait_ci=false ci_timeout="" repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              --delete-branch) delete_branch=true; shift ;;
              --wait-ci) wait_ci=true; shift ;;
              --ci-timeout) if [[ $# -lt 2 ]]; then log_error "--ci-timeout requires a positive integer (seconds)" "branch"; exit 1; fi; ci_timeout="$2"; shift 2 ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          case "$strategy" in
            merge|squash|rebase) ;;
            *) log_error "branch merge: --strategy must be merge|squash|rebase" "branch"; exit 1 ;;
          esac
          # Validate CI flags post-parse (order-independent), before any side effect.
          if [[ -n "$ci_timeout" && "$wait_ci" != "true" ]]; then
            log_error "--ci-timeout requires --wait-ci" "branch"; exit 1
          fi
          if [[ -n "$ci_timeout" && ! "$ci_timeout" =~ ^[1-9][0-9]*$ ]]; then
            log_error "--ci-timeout must be a positive integer (seconds): '$ci_timeout'" "branch"; exit 1
          fi
          local ci_wait_timeout=""
          if [[ "$wait_ci" == "true" ]]; then ci_wait_timeout="${ci_timeout:-1800}"; fi
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch merge requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          merge_workspace "$workspace" "$strategy" "$dry_run" "$delete_branch" "$ci_wait_timeout" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
        *)
          log_error "usage: mra branch status|new|switch|pr|merge ..." "branch"; exit 1 ;;
      esac
}
