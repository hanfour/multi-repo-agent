#!/usr/bin/env bash
# Cross-repo PR operations (writes / gh). Pure ordering + per-repo PR + workspace driver.

# Order the given repos dependency-first (Kahn best-effort) within the set.
# Args: graph_file repo...  -> prints ordered repo names, one per line.
order_repos_by_deps() {
  local graph_file="$1"; shift
  local allset=" $* "
  local remaining=("$@") ordered=() ordered_str=" "
  while [[ ${#remaining[@]} -gt 0 ]]; do
    local ready=() notready=() r dep blocked
    for r in "${remaining[@]}"; do
      blocked=false
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        # blocked if an in-set dependency is not yet ordered
        if [[ "$allset" == *" $dep "* && "$ordered_str" != *" $dep "* ]]; then
          blocked=true; break
        fi
      done < <(get_project_deps "$r" "$graph_file")
      if [[ "$blocked" == "true" ]]; then notready+=("$r"); else ready+=("$r"); fi
    done
    if [[ ${#ready[@]} -eq 0 ]]; then
      log_warn "branch pr: cannot fully order by deps (cycle?), using given order for: ${remaining[*]}" "branch"
      for r in "${remaining[@]}"; do ordered+=("$r"); done
      break
    fi
    for r in $(printf '%s\n' "${ready[@]}" | sort); do
      ordered+=("$r"); ordered_str="$ordered_str$r "
    done
    remaining=(${notready[@]+"${notready[@]}"})
  done
  [[ ${#ordered[@]} -gt 0 ]] && printf '%s\n' "${ordered[@]}"
  return 0
}

# Validate an explicit repo subset against the workspace: each name must pass
# validate_repo_name and resolve to a non-skipped git repo. Reports ALL failures,
# returns non-zero if any. Side-effect-free (no gh, no writes) so the dispatch can
# call it before the gh-auth preflight.
validate_repo_subset() {
  local workspace="$1"; shift
  local failed=0 r dir
  for r in "$@"; do
    if ! validate_repo_name "$r"; then
      log_error "invalid repo name: '$r'" "branch"; failed=$((failed+1)); continue
    fi
    dir="$workspace/$r"
    if should_skip_dir "$dir"; then
      log_error "$r: not a git repo" "branch"; failed=$((failed+1)); continue
    fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# Advisory warning: for each repo in the subset, if it depends (per the dep graph)
# on a repo that is itself on a feature branch but NOT in the subset, warn (the
# PR/merge order may be incomplete). Pure logging — never changes control flow.
# Signature: warn_excluded_feature_deps workspace graph_file subset...
# Called by pr_workspace / merge_workspace in subset mode (Phase 9 Tasks 3–4).
warn_excluded_feature_deps() {
  local workspace="$1" graph_file="$2"; shift 2
  local subset=("$@")
  local subset_str=" ${subset[*]} "
  local r dep ddir dbr ddef
  for r in ${subset[@]+"${subset[@]}"}; do
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      [[ "$subset_str" == *" $dep "* ]] && continue   # dep is in the subset — fine
      ddir="$workspace/$dep"
      [[ -d "$ddir" ]] || continue
      should_skip_dir "$ddir" && continue
      dbr=$(git -C "$ddir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
      ddef=$(get_default_branch "$ddir")
      if [[ "$dbr" != "(detached)" && "$dbr" != "$ddef" ]]; then
        log_warn "$r: depends on '$dep' (on feature branch '$dbr', not in selected subset) — PR/merge order may be incomplete" "branch"
      fi
    done < <(get_project_deps "$r" "$graph_file")
  done
}

# Open a PR for one repo. base="" -> repo's default branch. dry_run="true" -> preview only.
# Skips detached/on-base/no-commits-vs-base. Pushes via push_repo (never force), then
# verifies the branch is fully published before opening. Existing PR -> report URL (not a failure).
pr_repo() {
  local repo_dir="$1" base="$2" dry_run="${3:-false}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0

  local branch; branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  local base_ref="$base"
  if [[ -z "$base_ref" ]]; then base_ref=$(get_default_branch "$repo_dir"); fi

  if [[ "$branch" == "(detached)" ]]; then
    log_warn "$repo_name: detached HEAD — skipping" "branch"; return 0
  fi
  if [[ "$branch" == "$base_ref" ]]; then
    log_warn "$repo_name: on base branch '$base_ref' — skipping" "branch"; return 0
  fi

  if ! git -C "$repo_dir" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 \
     && ! git -C "$repo_dir" rev-parse --verify --quiet "origin/$base_ref" >/dev/null 2>&1; then
    log_warn "$repo_name: base '$base_ref' not found — skipping" "branch"; return 0
  fi

  local count
  count=$(git -C "$repo_dir" rev-list --count "${base_ref}..${branch}" 2>/dev/null || echo 0)
  if [[ "${count:-0}" -eq 0 ]]; then
    log_info "$repo_name: no commits vs $base_ref — nothing to PR, skipping" "branch"; return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "$repo_name: would open PR: $branch → $base_ref" "branch"; return 0
  fi

  if ! push_repo "$repo_dir" false; then
    log_error "$repo_name: push failed — not opening PR" "branch"; return 1
  fi
  # verify branch fully published (guards against behind/diverged push-skip)
  local lref rref
  lref=$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || echo "L")
  rref=$(git -C "$repo_dir" rev-parse "origin/$branch" 2>/dev/null || echo "R")
  if [[ "$lref" != "$rref" ]]; then
    log_warn "$repo_name: branch not fully published (behind/diverged) — skipping PR" "branch"; return 0
  fi

  local existing
  existing=$(cd "$repo_dir" && gh pr view "$branch" --json url --jq '.url' 2>/dev/null || echo "")
  if [[ -n "$existing" ]]; then
    log_success "$repo_name: PR already exists: $existing" "branch"; return 0
  fi
  local url
  if url=$(cd "$repo_dir" && gh pr create --base "$base_ref" --head "$branch" --fill 2>/dev/null); then
    log_success "$repo_name: opened PR: $url" "branch"; return 0
  fi
  log_error "$repo_name: gh pr create failed" "branch"; return 1
}

# Merge one repo's open PR (for its current feature branch), gated on mergeable + CI.
# strategy: merge|squash|rebase. dry_run="true" previews only.
# ci_wait_timeout: empty (default) -> one-shot gh pr checks gate; non-empty -> poll via wait_for_pr_checks.
# Returns 0 on success/skip; non-zero when a PR exists but cannot merge or the merge fails (stop signal).
merge_repo() {
  local repo_dir="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}" ci_wait_timeout="${5:-}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0

  local branch; branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  if [[ "$branch" == "(detached)" ]]; then
    log_warn "$repo_name: detached HEAD — skipping" "branch"; return 0
  fi
  local def; def=$(get_default_branch "$repo_dir")
  if [[ "$branch" == "$def" ]]; then
    log_warn "$repo_name: on default branch '$def' — skipping" "branch"; return 0
  fi

  local pr_json
  pr_json=$(cd "$repo_dir" && gh pr view "$branch" --json number,state,mergeable 2>/dev/null || echo "")
  if [[ -z "$pr_json" ]]; then
    log_info "$repo_name: no open PR for '$branch' — skipping" "branch"; return 0
  fi
  local state number mergeable
  state=$(printf '%s' "$pr_json" | jq -r '.state' 2>/dev/null)
  number=$(printf '%s' "$pr_json" | jq -r '.number' 2>/dev/null)
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable' 2>/dev/null)

  if [[ "$state" != "OPEN" ]]; then
    log_info "$repo_name: PR #$number not open ($state) — skipping" "branch"; return 0
  fi
  if [[ "$mergeable" != "MERGEABLE" ]]; then
    log_error "$repo_name: PR #$number not mergeable ($mergeable) — stopping" "branch"; return 1
  fi

  # CI gate: poll when ci_wait_timeout is set (and not dry-run), else the one-shot
  # check (unchanged). Dry-run with a wait skips polling — it is previewed below.
  if [[ -n "$ci_wait_timeout" ]]; then
    if [[ "$dry_run" != "true" ]]; then
      local crc=0
      wait_for_pr_checks "$repo_dir" "$branch" "$ci_wait_timeout" || crc=$?
      if [[ "$crc" -eq 2 ]]; then
        log_error "$repo_name: PR #$number CI did not finish within ${ci_wait_timeout}s — stopping" "branch"; return 1
      elif [[ "$crc" -ne 0 ]]; then
        log_error "$repo_name: PR #$number CI not green — stopping" "branch"; return 1
      fi
    fi
  else
    if ! (cd "$repo_dir" && gh pr checks "$branch" >/dev/null 2>&1); then
      log_error "$repo_name: PR #$number CI not green — stopping" "branch"; return 1
    fi
  fi

  local del_note=""
  local merge_args=(--"$strategy")
  if [[ "$delete_branch" == "true" ]]; then del_note=" (+delete-branch)"; merge_args+=(--delete-branch); fi

  if [[ "$dry_run" == "true" ]]; then
    if [[ -n "$ci_wait_timeout" ]]; then
      log_info "$repo_name: would wait for CI (timeout ${ci_wait_timeout}s) then merge PR #$number ($strategy)$del_note" "branch"
    else
      log_info "$repo_name: would merge PR #$number ($strategy)$del_note" "branch"
    fi
    return 0
  fi
  if (cd "$repo_dir" && gh pr merge "$branch" "${merge_args[@]}" >/dev/null 2>&1); then
    log_success "$repo_name: merged PR #$number ($strategy)$del_note" "branch"; return 0
  fi
  log_error "$repo_name: gh pr merge failed for PR #$number" "branch"; return 1
}

# Merge open PRs across feature-branch repos in dependency order (deps first).
# Optional trailing repo names restrict to that subset (default-branch repos in
# the subset are skipped with info; excluded feature-branch deps trigger a warning).
# No subset args = full-workspace scan (unchanged). Stop-on-first-failure.
# A non-empty ci_wait_timeout (5th arg) is threaded to merge_repo to poll CI.
merge_workspace() {
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}" ci_wait_timeout="${5:-}"
  local subset=("${@:6}")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  # Names to consider: explicit subset, or every workspace git repo.
  local consider=() dir name
  if [[ ${#subset[@]} -gt 0 ]]; then
    consider=("${subset[@]}")
  else
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      should_skip_dir "$dir" && continue
      consider+=("$name")
    done
  fi

  # Keep only feature-branch repos; in subset mode, info/warn-skip the rest.
  local candidates=() br def
  for name in ${consider[@]+"${consider[@]}"}; do
    dir="$workspace/$name"
    should_skip_dir "$dir" && continue   # in subset mode, guards a named dir that isn't a git repo
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    def=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$def" ]]; then
      candidates+=("$name")
    elif [[ ${#subset[@]} -gt 0 ]]; then
      if [[ "$br" == "(detached)" ]]; then
        log_warn "$name: detached HEAD — nothing to merge, skipping" "branch"
      else
        log_info "$name: on default branch '$def' — nothing to merge, skipping" "branch"
      fi
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "no feature-branch repos to merge" "branch"; return 0
  fi

  if [[ ${#subset[@]} -gt 0 ]]; then
    warn_excluded_feature_deps "$workspace" "$graph_file" "${candidates[@]}"
  fi

  local ordered=() r
  while IFS= read -r r; do
    [[ -n "$r" ]] && ordered+=("$r")
  done < <(order_repos_by_deps "$graph_file" "${candidates[@]}")
  for r in "${ordered[@]}"; do
    merge_repo "$workspace/$r" "$strategy" "$dry_run" "$delete_branch" "$ci_wait_timeout" || return 1
  done
  return 0
}

# Open PRs across feature-branch repos in dependency order. Optional trailing
# repo names restrict the operation to that subset (default-branch repos in the
# subset are skipped with info; excluded feature-branch deps trigger a warning).
# No subset args = full-workspace scan (unchanged). Returns non-zero if any failed.
pr_workspace() {
  local workspace="$1" base="$2" dry_run="${3:-false}"
  local subset=("${@:4}")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  # Names to consider: explicit subset, or every workspace git repo.
  local consider=() dir name
  if [[ ${#subset[@]} -gt 0 ]]; then
    consider=("${subset[@]}")
  else
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      should_skip_dir "$dir" && continue
      consider+=("$name")
    done
  fi

  # Keep only feature-branch repos; in subset mode, info-skip default-branch ones.
  local candidates=() br base_ref
  for name in ${consider[@]+"${consider[@]}"}; do
    dir="$workspace/$name"
    should_skip_dir "$dir" && continue   # in subset mode, guards a named dir that isn't a git repo
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    base_ref="$base"
    [[ -z "$base_ref" ]] && base_ref=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$base_ref" ]]; then
      candidates+=("$name")
    elif [[ ${#subset[@]} -gt 0 ]]; then
      if [[ "$br" == "(detached)" ]]; then
        log_warn "$name: detached HEAD — nothing to PR, skipping" "branch"
      else
        log_info "$name: on base branch '$base_ref' — nothing to PR, skipping" "branch"
      fi
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "no feature-branch repos to PR" "branch"; return 0
  fi

  if [[ ${#subset[@]} -gt 0 ]]; then
    warn_excluded_feature_deps "$workspace" "$graph_file" "${candidates[@]}"
  fi

  local ordered=() failed=0 r
  while IFS= read -r r; do
    [[ -n "$r" ]] && ordered+=("$r")
  done < <(order_repos_by_deps "$graph_file" "${candidates[@]}")
  for r in "${ordered[@]}"; do
    if ! pr_repo "$workspace/$r" "$base" "$dry_run"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
