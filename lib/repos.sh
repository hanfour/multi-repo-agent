#!/usr/bin/env bash
# Repo list management: fetch from GitHub org, interactive setup, repos.json read/write

get_repos_json_path() {
  local workspace="$1"
  echo "$workspace/.collab/repos.json"
}

repos_json_exists() {
  local workspace="$1"
  [[ -f "$(get_repos_json_path "$workspace")" ]]
}

# Fetch repo list from GitHub org using gh CLI
fetch_org_repos() {
  local git_org="$1"
  # Extract org name from git@github.com:orgname or https://github.com/orgname
  local org_name
  org_name=$(echo "$git_org" | sed -E 's#.*github\.com[:/]([^/]+).*#\1#')

  if [[ -z "$org_name" ]]; then
    log_error "cannot extract org name from: $git_org" "repos"
    return 1
  fi

  log_progress "fetching repo list from github.com/$org_name" "repos"
  gh repo list "$org_name" --limit 200 --json name,description,isArchived --no-limit 2>/dev/null \
    || { log_error "failed to fetch repos (check: gh auth status)" "repos"; return 1; }
}

# Interactive: ask user about each repo
interactive_repo_setup() {
  local workspace="$1" git_org="$2"
  local repos_file
  repos_file=$(get_repos_json_path "$workspace")

  local org_repos
  org_repos=$(fetch_org_repos "$git_org")
  if [[ $? -ne 0 || -z "$org_repos" ]]; then
    return 1
  fi

  local total
  total=$(echo "$org_repos" | jq 'length')
  log_info "found $total repos in org" "repos"

  local repos_array="[]"
  local index=0

  while IFS= read -r repo_json; do
    local name description is_archived
    name=$(echo "$repo_json" | jq -r '.name')
    description=$(echo "$repo_json" | jq -r '.description // ""')
    is_archived=$(echo "$repo_json" | jq -r '.isArchived')

    ((index++))

    # Skip archived repos by default
    if [[ "$is_archived" == "true" ]]; then
      log_info "  [$index/$total] $name (archived, skipping)" "repos"
      repos_array=$(echo "$repos_array" | jq --arg name "$name" --arg desc "$description" \
        '. + [{"name": $name, "clone": false, "branch": "main", "description": $desc, "archived": true}]')
      continue
    fi

    # Check if already exists locally
    local exists="false"
    if [[ -d "$workspace/$name/.git" ]]; then
      exists="true"
    fi

    # Ask user
    local prompt_text
    if [[ "$exists" == "true" ]]; then
      prompt_text="  [$index/$total] $name (exists locally)"
    else
      prompt_text="  [$index/$total] $name"
    fi
    if [[ -n "$description" ]]; then
      prompt_text="$prompt_text - $description"
    fi

    printf "%s\n" "$prompt_text"
    printf "  Clone this repo? [Y/n]: "
    read -r answer < /dev/tty

    local should_clone="true"
    if [[ "$answer" =~ ^[Nn] ]]; then
      should_clone="false"
    fi

    repos_array=$(echo "$repos_array" | jq \
      --arg name "$name" \
      --arg desc "$description" \
      --argjson clone "$should_clone" \
      '. + [{"name": $name, "clone": $clone, "branch": "main", "description": $desc, "archived": false}]')

  done < <(echo "$org_repos" | jq -c '.[] | sort_by(.name)' 2>/dev/null || echo "$org_repos" | jq -c '.[]')

  # Write repos.json
  echo "$repos_array" | jq '{repos: .}' > "$repos_file"
  log_success "repos.json created with $total repos" "repos"
}

# Read repos.json and return list of repos to clone
get_clone_repos() {
  local workspace="$1"
  local repos_file
  repos_file=$(get_repos_json_path "$workspace")

  if [[ ! -f "$repos_file" ]]; then
    return 1
  fi

  jq -r '.repos[] | select(.clone == true) | .name' "$repos_file"
}

# Sync workspace based on repos.json
sync_from_repos_json() {
  local workspace="$1" git_org="$2"

  local repos_file
  repos_file=$(get_repos_json_path "$workspace")

  if [[ ! -f "$repos_file" ]]; then
    log_warn "repos.json not found, syncing existing repos only" "sync"
    sync_workspace "$workspace" "$git_org"
    return
  fi

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    sync_repo "$workspace/$repo_name" "$git_org"
  done < <(get_clone_repos "$workspace")
}
