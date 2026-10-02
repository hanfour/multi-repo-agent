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

_pkb_source_https_url() {
  local url="$1" path owner repo
  case "$url" in
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    https://github.com/*) printf '%s\n' "$url"; return 0 ;;
    *) return 0 ;;
  esac

  case "$path" in
    */*) ;;
    *) return 0 ;;
  esac
  owner="${path%%/*}"
  repo="${path#*/}"
  [[ -n "$owner" && -n "$repo" && "$repo" != */* && "$path" != *\?* && "$path" != *\#* ]] || return 0
  repo="${repo%.git}"
  [[ -n "$repo" ]] || return 0
  printf 'https://github.com/%s/%s.git\n' "$owner" "$repo"
}

_pkb_source_fetch() {
  local clone="$1" ref="$2" timeout_bin="" fetch_pid watchdog_pid rc git_ssh_command
  local token="${MRA_GIT_FETCH_TOKEN:-}" origin_url="" https_url="" auth_header=""
  local attempts=1 attempt fetch_mode fetch_url
  local -a fetch_args
  export -n MRA_GIT_FETCH_TOKEN
  git_ssh_command="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=$(command -v gtimeout)
  elif command -v timeout >/dev/null 2>&1; then
    timeout_bin=$(command -v timeout)
  fi

  source_fetch_via=none
  if [[ -n "$token" ]]; then
    origin_url=$(git -C "$clone" remote get-url origin 2>/dev/null || true)
    https_url=$(_pkb_source_https_url "$origin_url")
    if [[ -n "$https_url" ]]; then
      attempts=2
      auth_header="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    fi
  fi

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [[ -n "$https_url" && "$attempt" -eq 0 ]]; then
      fetch_url="$https_url"
      fetch_mode=https-token
    else
      fetch_url=origin
      fetch_mode=origin
    fi
    fetch_args=(-C "$clone" fetch --quiet "$fetch_url" -- "+refs/heads/$ref:refs/remotes/origin/$ref")

    if [[ -n "$timeout_bin" ]]; then
      if [[ "$fetch_mode" == https-token ]]; then
        if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
            GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
            GIT_CONFIG_VALUE_0="$auth_header" \
            "$timeout_bin" -k 1 59 git "${fetch_args[@]}"; then
          source_fetch_via=https-token
          return 0
        else
          rc=$?
        fi
      elif GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
          "$timeout_bin" -k 1 59 git "${fetch_args[@]}"; then
        source_fetch_via=origin
        return 0
      else
        rc=$?
      fi
      continue
    fi

    if [[ "$fetch_mode" == https-token ]]; then
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
        GIT_CONFIG_VALUE_0="$auth_header" \
        git "${fetch_args[@]}" &
    else
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_command" \
        git "${fetch_args[@]}" &
    fi
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
    if [[ "$rc" -eq 0 ]]; then
      source_fetch_via="$fetch_mode"
      return 0
    fi
  done
  return "$rc"
}

_pkb_source_record_meta() {
  local project_dir="$1" source_ref="$2" source_sha="$3" source_date="$4" fetched="$5"
  local source_fetch_via="$6" stale_docs="${7:-}"
  local meta_file="$project_dir/.mra/pkb/meta.json" tmp
  [[ -f "$meta_file" ]] || return 0
  tmp=$(mktemp "$meta_file.XXXXXX") || return 1
  if [[ -n "$stale_docs" ]]; then
    if jq --arg ref "$source_ref" --arg sha "$source_sha" --arg date "$source_date" \
        --argjson fetched "$fetched" --arg via "$source_fetch_via" --argjson stale "$stale_docs" \
        '.sourceRef = $ref | .sourceSha = $sha | .sourceCommitDate = $date | .sourceFetched = $fetched | .sourceFetchVia = $via | .sourceStaleDocs = $stale' \
        "$meta_file" > "$tmp"; then
      mv "$tmp" "$meta_file"
    else
      rm -f "$tmp"
      return 1
    fi
  elif jq --arg ref "$source_ref" --arg sha "$source_sha" --arg date "$source_date" \
      --argjson fetched "$fetched" --arg via "$source_fetch_via" \
      '.sourceRef = $ref | .sourceSha = $sha | .sourceCommitDate = $date | .sourceFetched = $fetched | .sourceFetchVia = $via' \
      "$meta_file" > "$tmp"; then
    mv "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_pkb_source_doc_checksum() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cksum "$file" | awk '{ print $1 ":" $2 }'
  else
    printf 'missing\n'
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
  export -n MRA_GIT_FETCH_TOKEN
  local workspace="$1" project="$2" clone="$3" model="$4" output_language="$5"
  local explicit_ref_set="$6" explicit_ref="$7"
  local source_ref="" source_sha="" source_date="" fetched=false source_fetch_via=none ref_commit=""
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
    _pkb_source_record_meta "$clone" "$source_ref" "$source_sha" "$source_date" false "$source_fetch_via" || {
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

  local core_docs=(sitemap.md architecture.md conventions.md api-surface.md)
  local -a prior_core_checksums=()
  local -A prior_module_checksums=()
  local core_doc core_index=0 module_doc module_name
  for core_doc in "${core_docs[@]}"; do
    prior_core_checksums[$core_index]=$(_pkb_source_doc_checksum "$worktree/.mra/pkb/$core_doc")
    core_index=$((core_index + 1))
  done
  if [[ -d "$worktree/.mra/pkb/modules" ]]; then
    while IFS= read -r module_doc; do
      [[ -f "$module_doc" ]] || continue
      module_name=${module_doc#"$worktree/.mra/pkb/"}
      prior_module_checksums["$module_name"]=$(_pkb_source_doc_checksum "$module_doc")
    done < <(find "$worktree/.mra/pkb/modules" -type f -name '*.md' -print)
  fi

  if ! pkb_generate "$project" "$worktree" "$model" "$output_language"; then
    log_error "PKB generation failed for origin/$source_ref" "analyze"
    return 1
  fi
  if [[ ! -d "$worktree/.mra/pkb" ]]; then
    log_error "PKB generation did not create a PKB for $project" "analyze"
    return 1
  fi

  local regenerated_core_count=0 stale_docs_json='[]' current_checksum
  core_index=0
  for core_doc in "${core_docs[@]}"; do
    current_checksum=$(_pkb_source_doc_checksum "$worktree/.mra/pkb/$core_doc")
    if [[ "$current_checksum" != "missing" && \
        ( "${prior_core_checksums[$core_index]}" == "missing" || \
          "$current_checksum" != "${prior_core_checksums[$core_index]}" ) ]]; then
      regenerated_core_count=$((regenerated_core_count + 1))
    elif [[ "$current_checksum" != "missing" && \
        "$current_checksum" == "${prior_core_checksums[$core_index]}" ]]; then
      stale_docs_json=$(jq -c --arg doc "$core_doc" '. + [$doc]' <<<"$stale_docs_json")
    fi
    core_index=$((core_index + 1))
  done
  if [[ "$regenerated_core_count" -eq 0 ]]; then
    log_error "PKB generation from origin/$source_ref failed: nothing was regenerated" "analyze"
    return 1
  fi

  if [[ -d "$worktree/.mra/pkb/modules" ]]; then
    while IFS= read -r module_doc; do
      [[ -f "$module_doc" ]] || continue
      module_name=${module_doc#"$worktree/.mra/pkb/"}
      if [[ -n "${prior_module_checksums[$module_name]+x}" && \
          "$(_pkb_source_doc_checksum "$module_doc")" == "${prior_module_checksums[$module_name]}" ]]; then
        stale_docs_json=$(jq -c --arg doc "$module_name" '. + [$doc]' <<<"$stale_docs_json")
      fi
    done < <(find "$worktree/.mra/pkb/modules" -type f -name '*.md' -print)
  fi

  _pkb_source_record_meta "$worktree" "origin/$source_ref" "$source_sha" "$source_date" "$fetched" "$source_fetch_via" "$stale_docs_json" || {
    log_error "could not record PKB source metadata for $project" "analyze"
    return 1
  }

  stage=$(mktemp -d "$clone/.mra/pkb.stage.XXXXXX") || {
    log_error "could not stage PKB replacement for $project" "analyze"
    return 1
  }
  cp -R "$worktree/.mra/pkb/." "$stage/" || return 1
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
  if [[ "$stale_docs_json" != '[]' ]]; then
    log_warn "PKB built from origin/$source_ref with kept docs: $(jq -r 'join(", ")' <<<"$stale_docs_json")" "analyze"
  fi
)
