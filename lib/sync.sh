#!/usr/bin/env bash
# Git sync: pull existing repos, clone missing ones

get_default_branch() {
  local repo_dir="$1"
  # Try remote HEAD first
  local remote_head
  remote_head=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -n "$remote_head" ]]; then
    echo "$remote_head"
    return
  fi
  # Fall back to checking common default branch names
  for branch in main master trunk develop; do
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      echo "$branch"
      return
    fi
  done
  echo "main"
}

get_current_branch() {
  local repo_dir="$1"
  git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null
}

is_on_default_branch() {
  local repo_dir="$1"
  local default_branch current_branch
  default_branch=$(get_default_branch "$repo_dir")
  current_branch=$(get_current_branch "$repo_dir")
  [[ "$current_branch" == "$default_branch" ]]
}

should_skip_dir() {
  local dir="$1"
  [[ ! -d "$dir/.git" ]]
}

sync_repo() {
  local repo_dir="$1" git_org="$2"
  local repo_name
  repo_name=$(basename "$repo_dir")

  if [[ ! -d "$repo_dir" ]]; then
    # Clone
    local clone_url="${git_org}/${repo_name}.git"
    log_progress "$repo_name: git clone" "sync"
    if git clone "$clone_url" "$repo_dir" &>/dev/null 2>&1; then
      log_success "$repo_name: cloned" "sync"
      _sync_record "$repo_name" cloned true
      return 0
    else
      log_error "$repo_name: clone failed ($clone_url)" "sync"
      _sync_record "$repo_name" clone-failed false
      return 1
    fi
  fi

  if should_skip_dir "$repo_dir"; then
    return 0
  fi

  if ! is_on_default_branch "$repo_dir"; then
    local branch
    branch=$(get_current_branch "$repo_dir")
    log_warn "$repo_name: on branch '$branch', skipping sync" "sync"
    _sync_record "$repo_name" skipped-branch true
    return 0
  fi

  log_progress "$repo_name: git pull" "sync"
  if git -C "$repo_dir" fetch --quiet 2>/dev/null && git -C "$repo_dir" pull --quiet 2>/dev/null; then
    log_success "$repo_name: ok" "sync"
    _sync_record "$repo_name" pulled true
    return 0
  else
    log_error "$repo_name: sync failed" "sync"
    _sync_record "$repo_name" sync-failed false
    return 1
  fi
}

sync_workspace() {
  local workspace="$1" git_org="$2"

  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name
    name=$(basename "$dir")
    # Skip hidden dirs and non-git dirs
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    sync_repo "$dir" "$git_org"
  done
}

# Branch-aware safe sync for one repo: fetch, then fast-forward ONLY when safe.
# Never merges/rebases, never touches a dirty or diverged tree. Returns non-zero on pull failure.
safe_sync_repo() {
  local repo_dir="$1"
  local repo_name; repo_name=$(basename "$repo_dir")

  if should_skip_dir "$repo_dir"; then
    return 0
  fi

  if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
    log_error "$repo_name: fetch failed" "sync"
    _sync_record "$repo_name" fetch-failed false
    return 1
  fi

  local state action
  state=$(get_branch_state "$repo_dir")
  action=$(branch_state_get "$state" sync_action)

  case "$action" in
    fast-forward)
      log_progress "$repo_name: fast-forward" "sync"
      if git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null; then
        log_success "$repo_name: ok" "sync"; _sync_record "$repo_name" pulled true; return 0
      else
        log_error "$repo_name: ff-only pull failed" "sync"; _sync_record "$repo_name" ff-failed false; return 1
      fi
      ;;
    up-to-date|ahead-only)
      log_success "$repo_name: $action (no pull needed)" "sync"; _sync_record "$repo_name" "$action" true; return 0 ;;
    diverged)
      log_warn "$repo_name: diverged (ahead & behind) — skipping, resolve manually" "sync"; _sync_record "$repo_name" diverged true; return 0 ;;
    dirty-skip)
      log_warn "$repo_name: behind but working tree dirty — skipping" "sync"; _sync_record "$repo_name" dirty-skip true; return 0 ;;
    no-upstream)
      log_warn "$repo_name: no upstream branch set — skipping" "sync"; _sync_record "$repo_name" no-upstream true; return 0 ;;
    *)
      log_warn "$repo_name: unknown state '$action' — skipping" "sync"; _sync_record "$repo_name" unknown true; return 0 ;;
  esac
}

# Safe-sync every git repo in a workspace. Returns non-zero if any repo failed.
safe_sync_workspace() {
  local workspace="$1"
  local failed=0
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    if ! safe_sync_repo "$dir"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# Push one repo per the push decision engine. dry_run="true" previews only.
# Never force-pushes. Returns non-zero on push failure.
push_repo() {
  local repo_dir="$1" dry_run="${2:-false}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0
  git -C "$repo_dir" fetch --quiet 2>/dev/null || true

  local state branch upstream ahead behind dirty action
  state=$(get_branch_state "$repo_dir")
  branch=$(branch_state_get "$state" branch)
  upstream=$(branch_state_get "$state" upstream)
  ahead=$(branch_state_get "$state" ahead)
  behind=$(branch_state_get "$state" behind)
  dirty=$(branch_state_get "$state" dirty)
  action=$(branch_push_action "$ahead" "$behind" "$upstream" "$branch")

  local dirty_note=""
  [[ "$dirty" -gt 0 ]] && dirty_note=" ($dirty uncommitted files remain local)"

  case "$action" in
    push-new)
      if [[ "$dry_run" == "true" ]]; then
        log_info "$repo_name: would push -u origin $branch (new branch)$dirty_note" "sync"; _sync_record "$repo_name" would-push-new true; return 0
      fi
      if git -C "$repo_dir" push -u origin "$branch" >/dev/null 2>&1; then
        log_success "$repo_name: pushed new branch '$branch'$dirty_note" "sync"; _sync_record "$repo_name" pushed-new true; return 0
      else
        log_error "$repo_name: push -u failed" "sync"; _sync_record "$repo_name" push-new-failed false; return 1
      fi
      ;;
    push)
      if [[ "$dry_run" == "true" ]]; then
        log_info "$repo_name: would push $branch ($ahead ahead)$dirty_note" "sync"; _sync_record "$repo_name" would-push true; return 0
      fi
      if git -C "$repo_dir" push >/dev/null 2>&1; then
        log_success "$repo_name: pushed$dirty_note" "sync"; _sync_record "$repo_name" pushed true; return 0
      else
        log_error "$repo_name: push failed" "sync"; _sync_record "$repo_name" push-failed false; return 1
      fi
      ;;
    up-to-date)
      log_success "$repo_name: up-to-date (nothing to push)" "sync"; _sync_record "$repo_name" up-to-date true; return 0 ;;
    skip-detached)
      log_warn "$repo_name: detached HEAD — skipping (check out a branch first)" "sync"; _sync_record "$repo_name" skip-detached true; return 0 ;;
    skip-diverged)
      log_warn "$repo_name: diverged — skipping (pull/reconcile first, never force)" "sync"; _sync_record "$repo_name" skip-diverged true; return 0 ;;
    skip-behind)
      log_warn "$repo_name: behind upstream — skipping (pull first)" "sync"; _sync_record "$repo_name" skip-behind true; return 0 ;;
    *)
      log_warn "$repo_name: unknown push state '$action' — skipping" "sync"; _sync_record "$repo_name" unknown true; return 0 ;;
  esac
}

# Push every git repo in a workspace. Returns non-zero if any push failed.
push_workspace() {
  local workspace="$1" dry_run="${2:-false}"
  local failed=0
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    if ! push_repo "$dir" "$dry_run"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# Run a safe-sync across the workspace, then auto-review the changed repos.
# "changed" = repos whose HEAD moved during sync; review targets also include
# repos with local work (ahead>0 / off-default), via review_targets.
# Reviews run via review_project in terminal mode. Returns non-zero if any review failed.
sync_review_workspace() {
  local workspace="$1"
  local changed=() failed=0
  local dir name before after
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    before=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    safe_sync_repo "$dir" || true
    after=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    [[ -n "$before" && "$before" != "$after" ]] && changed+=("$name")
  done

  local targets=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && targets+=("$t")
  done < <(review_targets "$workspace" ${changed[@]+"${changed[@]}"})

  if [[ ${#targets[@]} -eq 0 ]]; then
    log_info "no repos to review" "sync"; return 0
  fi
  local repo
  for repo in "${targets[@]}"; do
    log_progress "reviewing $repo" "sync"
    if ! review_project "$workspace" "$repo"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# Emit one per-repo sync result as a JSON object (jq-built; injection-safe).
# Sibling of branch_state_json. Args: repo action ok
#   - ok MUST be the string "true" or "false" (passed via --argjson to become a JSON boolean).
sync_result_json() {
  local repo="$1" action="$2" ok="$3"
  [[ "$ok" == "true" || "$ok" == "false" ]] \
    || { echo "sync_result_json: ok must be 'true' or 'false', got: '$ok'" >&2; return 1; }
  jq -n --arg repo "$repo" --arg action "$action" --argjson ok "$ok" \
    '{repo:$repo, action:$action, ok:$ok}'
}

# Record one per-repo sync outcome to the SYNC_RESULT_FILE sink, when set.
# No-op (and side-effect-free) when SYNC_RESULT_FILE is unset — keeps text mode unchanged.
# A file sink (not a shell var) is used so records survive subshell boundaries.
# Callers must ensure SYNC_RESULT_FILE is writable; a write failure propagates
# as a non-zero exit (consistent with set -euo pipefail).
# Args: repo action ok
_sync_record() {
  [[ -n "${SYNC_RESULT_FILE:-}" ]] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SYNC_RESULT_FILE"
}
