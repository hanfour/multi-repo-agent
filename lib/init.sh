#!/usr/bin/env bash
# Workspace initialization

init_workspace() {
  local workspace="$1" git_org="$2"
  local workspace_name
  workspace_name=$(basename "$workspace")

  # Resolve to absolute path
  workspace=$(cd "$workspace" && pwd)

  log_progress "initializing workspace: $workspace" "init"

  # Create .collab directory
  mkdir -p "$workspace/.collab/logs"

  # Create .gitignore for .collab
  cat > "$workspace/.collab/.gitignore" <<'GITIGNORE'
dep-graph.json
manual-deps.json
logs/
GITIGNORE

  # repos.json flow: existing file → use it, otherwise → interactive setup
  if repos_json_exists "$workspace"; then
    log_success "repos.json found, using existing configuration" "init"
    # Clone/pull repos based on repos.json
    sync_from_repos_json "$workspace" "$git_org"
  else
    # Try interactive setup via gh CLI
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
      if interactive_repo_setup "$workspace" "$git_org"; then
        # Clone repos based on newly created repos.json
        sync_from_repos_json "$workspace" "$git_org"
      else
        log_warn "repo discovery failed, continuing with local repos only" "init"
      fi
    else
      log_warn "gh CLI not available, skipping repo discovery" "init"
      log_info "you can manually create .collab/repos.json or run mra init again after: gh auth login" "init"
    fi
  fi

  # DB setup: existing db.json → use it, otherwise → interactive
  if db_json_exists "$workspace"; then
    log_success "db.json found, setting up databases" "init"
    setup_all_databases "$workspace"
  else
    if command -v docker &>/dev/null; then
      interactive_db_setup "$workspace"
      if db_json_exists "$workspace"; then
        setup_all_databases "$workspace"
      fi
    else
      log_warn "docker not available, skipping database setup" "init"
    fi
  fi

  # Scan git repos and build dep-graph
  build_dep_graph "$workspace" "$workspace_name" "$git_org"

  # Create default alias
  config_set_alias "$workspace_name" "$workspace" "$git_org"
  log_success "alias '$workspace_name' created" "init"

  log_success "workspace initialized: $workspace" "init"
}

build_dep_graph() {
  local workspace="$1" workspace_name="$2" git_org="$3"

  local projects_json="{}"
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    [[ ! -d "$dir/.git" ]] && continue

    local project_type last_commit
    project_type=$(detect_project_type "$dir")
    last_commit=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    projects_json=$(echo "$projects_json" | jq \
      --arg name "$name" \
      --arg type "$project_type" \
      --arg commit "$last_commit" \
      '.[$name] = {"type": $type, "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": $commit, "deps": {}, "consumedBy": [], "confidence": {}}')

    log_success "$name ($project_type)" "found"
  done

  # Write dep-graph.json
  jq -n \
    --argjson version 1 \
    --arg workspace "$workspace_name" \
    --arg gitOrg "$git_org" \
    --arg lastScan "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson projects "$projects_json" \
    '{version: $version, workspace: $workspace, gitOrg: $gitOrg, lastScan: $lastScan, projects: $projects}' \
    > "$workspace/.collab/dep-graph.json"

  log_success "dep-graph.json created with $(echo "$projects_json" | jq 'length') projects" "init"
}
