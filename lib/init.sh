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

  # Scan git repos and build initial dep-graph
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

  # Create default alias
  config_set_alias "$workspace_name" "$workspace" "$git_org"
  log_success "alias '$workspace_name' created" "init"

  log_success "workspace initialized: $workspace" "init"
}
