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
      return 0
    else
      log_error "$repo_name: clone failed ($clone_url)" "sync"
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
    return 0
  fi

  log_progress "$repo_name: git pull" "sync"
  if git -C "$repo_dir" fetch --quiet 2>/dev/null && git -C "$repo_dir" pull --quiet 2>/dev/null; then
    log_success "$repo_name: ok" "sync"
    return 0
  else
    log_error "$repo_name: sync failed" "sync"
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
