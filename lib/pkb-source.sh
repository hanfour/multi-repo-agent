#!/usr/bin/env bash
# PKB source selection and isolated generation from a repository ref.

_pkb_source_ref_from_config() {
  local workspace="$1" project="$2"
  local repos_file="$workspace/.collab/repos.json"
  [[ -f "$repos_file" ]] || return 0
  jq -r --arg project "$project" '
    [.repos[]? | select(.name == $project) | .pkbRef | select(type == "string")][0] // ""
  ' "$repos_file" 2>/dev/null || true
}

_pkb_source_origin_head() {
  local clone="$1" head
  head=$(git -C "$clone" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
  case "$head" in
    origin/*) printf '%s\n' "${head#origin/}" ;;
  esac
}

_pkb_source_fetch() {
  local clone="$1" ref="$2" timeout_bin="" fetch_pid watchdog_pid rc git_ssh_command
  git_ssh_command="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=$(command -v gtimeout)
  elif command -v timeout >/dev/null 2>&1; then
    timeout_bin=$(command -v timeout)
  fi

  if [[ -n "$timeout_bin" ]]; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
      "$timeout_bin" -k 1 59 git -C "$clone" fetch --quiet origin -- \
      "+refs/heads/$ref:refs/remotes/origin/$ref"
    return $?
  fi

  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
    git -C "$clone" fetch --quiet origin -- \
    "+refs/heads/$ref:refs/remotes/origin/$ref" &
  fetch_pid=$!
  (
    local sleep_pid=""
    trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
    sleep 59 & sleep_pid=$!
    wait "$sleep_pid" || exit 0
    pkill -TERM -P "$fetch_pid" 2>/dev/null || true
    pkill -KILL -P "$fetch_pid" 2>/dev/null || true
    kill -TERM "$fetch_pid" 2>/dev/null || exit 0
    kill -KILL "$fetch_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  if wait "$fetch_pid"; then rc=0; else rc=$?; fi
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$rc"
}

_pkb_source_record_meta() {
  local project_dir="$1" source_ref="$2" source_sha="$3" source_date="$4" fetched="$5"
  local meta_file="$project_dir/.mra/pkb/meta.json" tmp
  [[ -f "$meta_file" ]] || return 0
  tmp=$(mktemp "$meta_file.XXXXXX") || return 1
  if jq --arg ref "$source_ref" --arg sha "$source_sha" --arg date "$source_date" \
      --argjson fetched "$fetched" \
      '.sourceRef = $ref | .sourceSha = $sha | .sourceCommitDate = $date | .sourceFetched = $fetched' \
      "$meta_file" > "$tmp"; then
    mv "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_pkb_source_recover_backup() {
  local clone="$1" candidate owner_pid
  [[ ! -e "$clone/.mra/pkb" ]] || return 0
  for candidate in "$clone/.mra"/pkb.backup.*; do
    [[ -d "$candidate" ]] || continue
    owner_pid="${candidate##*.}"
    [[ "$owner_pid" =~ ^[0-9]+$ ]] || continue
    if ! kill -0 "$owner_pid" 2>/dev/null && [[ ! -e "$clone/.mra/pkb" ]] && \
        mv "$candidate" "$clone/.mra/pkb"; then
      log_warn "restored PKB backup from dead pid $owner_pid" "analyze"
      return 0
    fi
  done
}

_pkb_source_cleanup() {
  local clone="$1" worktree="$2" temp_root="$3" stage="$4" backup="$5" lock="$6"
  trap '' INT TERM HUP
  trap - EXIT
  if [[ -n "$worktree" ]]; then
    git -C "$clone" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  if [[ -n "$temp_root" ]]; then rm -rf "$temp_root"; fi
  if [[ -n "$worktree" ]]; then
    git -C "$clone" worktree prune >/dev/null 2>&1 || true
  fi
  if [[ -n "$stage" ]]; then rm -rf "$stage"; fi
  if [[ -n "$backup" && -d "$backup" && ! -e "$clone/.mra/pkb" ]]; then
    if mv "$backup" "$clone/.mra/pkb"; then backup=""; fi
  fi
  if [[ -n "$backup" && -e "$clone/.mra/pkb" ]]; then rm -rf "$backup"; fi
  if [[ -n "$lock" ]]; then _pkb_lock_release "$lock"; fi
  return 0
}

# Args: workspace project clone model output_language explicit_ref_set explicit_ref
pkb_generate_from_source() (
  local workspace="$1" project="$2" clone="$3" model="$4" output_language="$5"
  local explicit_ref_set="$6" explicit_ref="$7"
  local source_ref="" source_sha="" source_date="" fetched=false ref_commit=""
  local branch="" short_sha="" lock="$clone/.mra/pkb.lock" temp_root="" worktree="" stage="" backup=""

  if [[ "$explicit_ref_set" == "true" ]]; then
    source_ref="$explicit_ref"
  else
    source_ref=$(_pkb_source_ref_from_config "$workspace" "$project")
    [[ -n "$source_ref" ]] || source_ref=$(_pkb_source_origin_head "$clone")
  fi

  if [[ "$explicit_ref_set" == "true" && -z "$source_ref" ]] || \
      { [[ -n "$source_ref" ]] && ! git check-ref-format --branch "$source_ref" >/dev/null 2>&1; }; then
    log_error "invalid PKB source ref: '$source_ref'" "analyze"
    return 1
  fi

  mkdir -p "$clone/.mra" || {
    log_error "could not create PKB directory for $project" "analyze"
    return 1
  }
  if ! _pkb_lock_acquire "$lock"; then
    log_error "PKB analysis already running for $project (lock: $lock)" "analyze"
    return 1
  fi
  trap '_pkb_source_cleanup "$clone" "$worktree" "$temp_root" "$stage" "$backup" "$lock"' EXIT
  trap '_pkb_source_cleanup "$clone" "$worktree" "$temp_root" "$stage" "$backup" "$lock"; exit 130' INT
  trap '_pkb_source_cleanup "$clone" "$worktree" "$temp_root" "$stage" "$backup" "$lock"; exit 143' TERM
  trap '_pkb_source_cleanup "$clone" "$worktree" "$temp_root" "$stage" "$backup" "$lock"; exit 129' HUP
  _pkb_source_recover_backup "$clone"
  pkb_ensure_gitignore "$clone"

  if [[ -n "$source_ref" ]]; then
    if _pkb_source_fetch "$clone" "$source_ref"; then
      fetched=true
    else
      log_warn "fetch of origin/$source_ref failed; checking the cached remote ref" "analyze"
    fi
    ref_commit=$(git -C "$clone" rev-parse --verify "refs/remotes/origin/$source_ref^{commit}" 2>/dev/null || true)
    if [[ -n "$ref_commit" ]]; then
      source_sha="$ref_commit"
      source_date=$(git -C "$clone" show -s --format=%cI "$ref_commit" 2>/dev/null || echo "")
      if [[ "$fetched" == "false" ]]; then
        log_warn "using cached origin/$source_ref at $source_date" "analyze"
      fi
    else
      log_warn "origin/$source_ref is unavailable; building from the current checkout" "analyze"
      source_ref=""
    fi
  fi

  if [[ -z "$source_ref" ]]; then
    branch=$(git -C "$clone" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")
    short_sha=$(git -C "$clone" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
    source_sha=$(git -C "$clone" rev-parse HEAD 2>/dev/null || echo "")
    source_date=$(git -C "$clone" show -s --format=%cI HEAD 2>/dev/null || echo "")
    source_ref="checkout:$branch"
    log_warn "no PKB source ref resolved; building from the current checkout ${branch}@${short_sha}" "analyze"
    if ! pkb_generate "$project" "$clone" "$model" "$output_language"; then
      return 1
    fi
    _pkb_source_record_meta "$clone" "$source_ref" "$source_sha" "$source_date" false || {
      log_error "could not record PKB source metadata for $project" "analyze"
      return 1
    }
    return 0
  fi

  temp_root=$(mktemp -d "${TMPDIR:-/tmp}/mra-pkb-source.XXXXXX") || {
    log_error "could not create temporary PKB source directory" "analyze"
    return 1
  }
  worktree="$temp_root/source"
  if ! git -C "$clone" worktree add --detach "$worktree" "$ref_commit"; then
    log_error "could not create temporary worktree for origin/$source_ref" "analyze"
    return 1
  fi

  mkdir -p "$worktree/.mra" || return 1
  if [[ -d "$clone/.mra/pkb" ]]; then
    cp -R "$clone/.mra/pkb" "$worktree/.mra/pkb" || return 1
  fi
  if ! pkb_generate "$project" "$worktree" "$model" "$output_language"; then
    log_error "PKB generation failed for origin/$source_ref" "analyze"
    return 1
  fi
  if [[ ! -d "$worktree/.mra/pkb" ]]; then
    log_error "PKB generation did not create a PKB for $project" "analyze"
    return 1
  fi
  _pkb_source_record_meta "$worktree" "origin/$source_ref" "$source_sha" "$source_date" "$fetched" || {
    log_error "could not record PKB source metadata for $project" "analyze"
    return 1
  }

  stage=$(mktemp -d "$clone/.mra/pkb.stage.XXXXXX") || {
    log_error "could not stage PKB replacement for $project" "analyze"
    return 1
  }
  cp -R "$worktree/.mra/pkb/." "$stage/" || return 1
  local core_doc
  for core_doc in sitemap.md architecture.md conventions.md api-surface.md; do
    if [[ ! -f "$stage/$core_doc" ]]; then
      log_error "PKB generation did not produce $core_doc for $project" "analyze"
      return 1
    fi
  done
  if [[ -e "$clone/.mra/pkb" ]]; then
    backup="$clone/.mra/pkb.backup.$$"
    if [[ -e "$backup" ]] || ! mv "$clone/.mra/pkb" "$backup"; then
      log_error "could not prepare PKB replacement for $project" "analyze"
      return 1
    fi
  fi
  if [[ -e "$clone/.mra/pkb" || -L "$clone/.mra/pkb" ]]; then
    log_error "PKB appeared during generation for $project; keeping the existing PKB" "analyze"
    return 1
  fi
  if ! mv "$stage" "$clone/.mra/pkb"; then
    log_error "could not install generated PKB for $project" "analyze"
    return 1
  fi
  stage=""
  if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
  backup=""
)
