#!/usr/bin/env bash
# Snapshot and rollback mechanism

get_snapshots_dir() {
  local workspace="$1"
  echo "$workspace/.collab/snapshots"
}

get_snapshots_file() {
  local workspace="$1"
  echo "$workspace/.collab/snapshots/snapshots.json"
}

# Create a snapshot of current state
create_snapshot() {
  local workspace="$1" name="${2:-}"
  local snapshots_dir; snapshots_dir=$(get_snapshots_dir "$workspace")
  local snapshots_file; snapshots_file=$(get_snapshots_file "$workspace")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  mkdir -p "$snapshots_dir"

  # Auto-generate name if not provided
  if [[ -z "$name" ]]; then
    name="snapshot-$(date +%Y%m%d-%H%M%S)"
  fi

  log_progress "creating snapshot: $name" "snapshot"

  # Collect git state for all projects
  local projects_state="{}"
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local project_dir="$workspace/$project"
    [[ ! -d "$project_dir/.git" ]] && continue

    local branch commit has_changes
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
    has_changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$has_changes" -gt 0 ]]; then
      log_warn "$project: has $has_changes uncommitted changes (snapshot captures committed state only)" "snapshot"
    fi

    projects_state=$(echo "$projects_state" | jq \
      --arg p "$project" --arg b "$branch" --arg c "$commit" --argjson ch "$has_changes" \
      '.[$p] = {"branch": $b, "commit": $c, "uncommittedChanges": $ch}')
  done < <(jq -r '.projects | keys[]' "$graph_file" 2>/dev/null)

  # Collect DB state (which containers are running)
  local db_state="{}"
  local db_json="$workspace/.collab/db.json"
  if [[ -f "$db_json" ]]; then
    while IFS= read -r db_name; do
      [[ -z "$db_name" ]] && continue
      local container_name="mra-db-$db_name"
      local running="false"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$" && running="true"
      db_state=$(echo "$db_state" | jq --arg n "$db_name" --argjson r "$running" '.[$n] = {"running": $r}')
    done < <(jq -r '.databases | keys[]' "$db_json")
  fi

  # Build snapshot entry
  local snapshot
  snapshot=$(jq -n \
    --arg name "$name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson projects "$projects_state" \
    --argjson databases "$db_state" \
    '{name: $name, timestamp: $ts, projects: $projects, databases: $databases}')

  # Append to snapshots file
  if [[ -f "$snapshots_file" ]]; then
    local tmp; tmp=$(mktemp)
    jq --argjson snap "$snapshot" '. + [$snap]' "$snapshots_file" > "$tmp" && mv "$tmp" "$snapshots_file"
  else
    echo "[$snapshot]" | jq '.' > "$snapshots_file"
  fi

  local project_count
  project_count=$(echo "$projects_state" | jq 'length')
  log_success "snapshot '$name' created ($project_count projects)" "snapshot"
}

# List snapshots
list_snapshots() {
  local workspace="$1"
  local snapshots_file; snapshots_file=$(get_snapshots_file "$workspace")

  if [[ ! -f "$snapshots_file" ]]; then
    log_info "no snapshots yet (run: mra snapshot)" "snapshot"
    return 0
  fi

  echo ""
  printf "%-30s %-25s %s\n" "NAME" "TIMESTAMP" "PROJECTS"
  printf "%s\n" "--------------------------------------------------------------------------------"

  jq -r '.[] | "\(.name)|\(.timestamp)|\(.projects | length)"' "$snapshots_file" | while IFS='|' read -r name ts count; do
    printf "%-30s %-25s %s\n" "$name" "$ts" "$count projects"
  done

  echo ""
}

# Rollback a project to its state in a snapshot
rollback_project() {
  local workspace="$1" project="$2" snapshot_name="${3:-}"
  local snapshots_file; snapshots_file=$(get_snapshots_file "$workspace")
  local project_dir="$workspace/$project"

  if [[ ! -f "$snapshots_file" ]]; then
    log_error "no snapshots found" "rollback"
    return 1
  fi

  # Use latest snapshot if name not specified
  local snapshot
  if [[ -z "$snapshot_name" ]]; then
    snapshot=$(jq '.[-1]' "$snapshots_file")
    snapshot_name=$(echo "$snapshot" | jq -r '.name')
  else
    snapshot=$(jq --arg n "$snapshot_name" '.[] | select(.name == $n)' "$snapshots_file")
  fi

  if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
    log_error "snapshot '$snapshot_name' not found" "rollback"
    return 1
  fi

  # Get project state from snapshot
  local target_branch target_commit
  target_branch=$(echo "$snapshot" | jq -r --arg p "$project" '.projects[$p].branch // ""')
  target_commit=$(echo "$snapshot" | jq -r --arg p "$project" '.projects[$p].commit // ""')

  if [[ -z "$target_branch" || "$target_branch" == "null" ]]; then
    log_error "$project: not found in snapshot '$snapshot_name'" "rollback"
    return 1
  fi

  if [[ ! -d "$project_dir/.git" ]]; then
    log_error "$project: not a git repo" "rollback"
    return 1
  fi

  # Check for uncommitted changes
  local changes
  changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$changes" -gt 0 ]]; then
    log_warn "$project: has $changes uncommitted changes" "rollback"
    log_warn "stashing changes before rollback" "rollback"
    git -C "$project_dir" stash push -m "mra-rollback-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  fi

  log_progress "$project: rolling back to $snapshot_name ($target_commit)" "rollback"

  # Checkout the branch and reset to the snapshot commit
  git -C "$project_dir" checkout "$target_branch" 2>/dev/null || {
    log_error "$project: failed to checkout $target_branch" "rollback"
    return 1
  }

  git -C "$project_dir" reset --hard "$target_commit" 2>/dev/null || {
    log_error "$project: failed to reset to $target_commit" "rollback"
    return 1
  }

  log_success "$project: rolled back to $target_commit (branch: $target_branch)" "rollback"
}

# Rollback all projects to a snapshot
rollback_all() {
  local workspace="$1" snapshot_name="${2:-}"
  local snapshots_file; snapshots_file=$(get_snapshots_file "$workspace")

  if [[ ! -f "$snapshots_file" ]]; then
    log_error "no snapshots found" "rollback"
    return 1
  fi

  local snapshot
  if [[ -z "$snapshot_name" ]]; then
    snapshot=$(jq '.[-1]' "$snapshots_file")
    snapshot_name=$(echo "$snapshot" | jq -r '.name')
  else
    snapshot=$(jq --arg n "$snapshot_name" '.[] | select(.name == $n)' "$snapshots_file")
  fi

  if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
    log_error "snapshot '$snapshot_name' not found" "rollback"
    return 1
  fi

  log_progress "rolling back all projects to '$snapshot_name'" "rollback"

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    rollback_project "$workspace" "$project" "$snapshot_name"
  done < <(echo "$snapshot" | jq -r '.projects | keys[]')

  log_success "rollback complete" "rollback"
}

# Delete a snapshot
delete_snapshot() {
  local workspace="$1" snapshot_name="$2"
  local snapshots_file; snapshots_file=$(get_snapshots_file "$workspace")

  if [[ ! -f "$snapshots_file" ]]; then
    log_error "no snapshots found" "snapshot"
    return 1
  fi

  local tmp; tmp=$(mktemp)
  jq --arg n "$snapshot_name" '[.[] | select(.name != $n)]' "$snapshots_file" > "$tmp" && mv "$tmp" "$snapshots_file"
  log_success "snapshot '$snapshot_name' deleted" "snapshot"
}
