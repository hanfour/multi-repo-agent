#!/usr/bin/env bash
# Mutating cross-repo branch operations (create / switch).
# Read-only introspection lives in lib/branch.sh; this file is the write side.

# Validate a branch name. Returns 0 if valid, non-zero otherwise.
# Rejects: empty, leading dash (git option injection), and git-invalid ref names.
validate_branch_name() {
  local name="$1"
  [[ -z "$name" ]] && return 1
  case "$name" in -*) return 1 ;; esac
  git check-ref-format "refs/heads/$name" >/dev/null 2>&1 || return 1
  return 0
}

# Validate a repo NAME (a flat directory under the workspace). Returns non-zero if invalid.
# Rejects: empty, contains '/', equals '.' or '..', or begins with '-' (path traversal / option injection).
validate_repo_name() {
  local name="$1"
  [[ -z "$name" ]] && return 1
  case "$name" in
    -*) return 1 ;;
    .|..) return 1 ;;
    */*) return 1 ;;
  esac
  return 0
}

# Create+checkout a branch in one repo (base = current HEAD).
# If the branch already exists, switch to it and warn. Returns non-zero on failure.
create_branch_in_repo() {
  local repo_dir="$1" name="$2"
  local repo_name; repo_name=$(basename "$repo_dir")
  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$name"; then
    log_warn "$repo_name: branch '$name' already exists, switching" "branch"
    if git -C "$repo_dir" checkout "$name" >/dev/null 2>&1; then
      log_success "$repo_name: on '$name'" "branch"; return 0
    else
      log_error "$repo_name: cannot switch to '$name' (working tree?)" "branch"; return 1
    fi
  fi
  if git -C "$repo_dir" checkout -b "$name" >/dev/null 2>&1; then
    log_success "$repo_name: created '$name'" "branch"; return 0
  else
    log_error "$repo_name: failed to create '$name'" "branch"; return 1
  fi
}

# Create the branch across a repo set. Extra args = repo names; if none, all workspace git repos.
# Validates the name first (fail fast, no repo touched). Returns non-zero if any repo failed.
create_branch_workspace() {
  local workspace="$1" name="$2"; shift 2
  if ! validate_branch_name "$name"; then
    log_error "invalid branch name: '$name'" "branch"; return 1
  fi
  local failed=0
  local repos=("$@")
  if [[ ${#repos[@]} -eq 0 ]]; then
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      local b; b=$(basename "$dir")
      [[ "$b" == .* ]] && continue
      should_skip_dir "$dir" && continue
      if ! create_branch_in_repo "$dir" "$name"; then failed=$((failed+1)); fi
    done
  else
    for r in "${repos[@]}"; do
      if ! validate_repo_name "$r"; then
        log_error "invalid repo name: '$r'" "branch"; failed=$((failed+1)); continue
      fi
      local dir="$workspace/$r"
      if should_skip_dir "$dir"; then
        log_error "$r: not a git repo" "branch"; failed=$((failed+1)); continue
      fi
      if ! create_branch_in_repo "$dir" "$name"; then failed=$((failed+1)); fi
    done
  fi
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# Switch one repo to an EXISTING branch. Missing branch or a dirty/conflict
# checkout failure are non-fatal skips (warn, return 0) — never -f, never discard.
switch_branch_in_repo() {
  local repo_dir="$1" name="$2"
  local repo_name; repo_name=$(basename "$repo_dir")
  if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$name"; then
    log_warn "$repo_name: no branch '$name' — skipping" "branch"; return 0
  fi
  if git -C "$repo_dir" checkout "$name" >/dev/null 2>&1; then
    log_success "$repo_name: on '$name'" "branch"; return 0
  fi
  log_warn "$repo_name: cannot switch to '$name' (dirty/conflict) — skipping" "branch"; return 0
}

# Switch every workspace git repo that has the branch. Validates name first.
# Returns non-zero only on an invalid name (per-repo skips are expected, not failures).
switch_branch_workspace() {
  local workspace="$1" name="$2"
  if ! validate_branch_name "$name"; then
    log_error "invalid branch name: '$name'" "branch"; return 1
  fi
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local b; b=$(basename "$dir")
    [[ "$b" == .* ]] && continue
    should_skip_dir "$dir" && continue
    switch_branch_in_repo "$dir" "$name"
  done
  return 0
}
