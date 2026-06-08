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

# Compute a SHA-256 hash over the canonical JSON form of the
# rollback-relevant fields of a snapshot (projects + databases).
# Excluding the `.integrity` field itself keeps the hash stable across
# its own writes (TM-009).
_snapshot_integrity_hash() {
  local snap_json="$1"
  local canonical
  canonical=$(echo "$snap_json" | jq -cS 'del(.integrity) | {projects: .projects, databases: .databases}')
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
  fi
}

# Verify the stored .integrity matches a fresh recomputation. Returns 0
# when the snapshot is intact, 1 when it has been tampered with or has
# no hash at all (snapshots written by older versions). Callers can opt
# out via MRA_ROLLBACK_IGNORE_INTEGRITY=1 when they intentionally edited
# the snapshot file by hand.
_verify_snapshot_integrity() {
  local snap_json="$1"
  local stored expected
  stored=$(echo "$snap_json" | jq -r '.integrity // ""')
  if [[ -z "$stored" ]]; then
    log_error "snapshot has no integrity hash (likely written by an older mra version); set MRA_ROLLBACK_IGNORE_INTEGRITY=1 to proceed" "rollback"
    return 1
  fi
  expected=$(_snapshot_integrity_hash "$snap_json")
  if [[ "$stored" != "$expected" ]]; then
    log_error "snapshot integrity check failed (stored=$stored, computed=$expected); the snapshots file may have been edited" "rollback"
    log_error "set MRA_ROLLBACK_IGNORE_INTEGRITY=1 to proceed if the edit was intentional" "rollback"
    return 1
  fi
  return 0
}

# Confirm a destructive rollback. The destructive step (`git reset
# --hard`) cannot be undone without external state, so we require either
# an interactive yes/no from the operator or an explicit
# MRA_ROLLBACK_FORCE=1 env var. Stdin not being a tty AND no force flag
# means we fail closed (TM-009).
_confirm_rollback() {
  local summary="$1"
  if [[ "${MRA_ROLLBACK_FORCE:-}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "rollback requires confirmation, but stdin is not a terminal; set MRA_ROLLBACK_FORCE=1 to proceed non-interactively" "rollback"
    return 1
  fi
  echo "$summary" >&2
  local reply=""
  read -r -p "Proceed with rollback? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) log_error "rollback aborted by user" "rollback"; return 1 ;;
  esac
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

  # Build snapshot entry, then compute and attach the integrity hash
  # (TM-009). The hash is over the projects+databases shape so it
  # detects after-the-fact edits to commits/branches.
  local snapshot
  snapshot=$(jq -n \
    --arg name "$name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson projects "$projects_state" \
    --argjson databases "$db_state" \
    '{name: $name, timestamp: $ts, projects: $projects, databases: $databases}')
  local integrity
  integrity=$(_snapshot_integrity_hash "$snapshot")
  snapshot=$(echo "$snapshot" | jq --arg h "$integrity" '. + {integrity: $h}')

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

  # Integrity check (TM-009). Operators who hand-edited the snapshot
  # file can opt out with MRA_ROLLBACK_IGNORE_INTEGRITY=1.
  if [[ "${MRA_ROLLBACK_IGNORE_INTEGRITY:-}" != "1" ]]; then
    if ! _verify_snapshot_integrity "$snapshot"; then
      declare -F log_security_event >/dev/null && \
        log_security_event "rollback" "integrity-fail" \
          "project=$project" "snapshot=$snapshot_name"
      return 1
    fi
  fi

  # Confirmation gate (TM-009). git reset --hard is destructive, so we
  # require explicit consent before touching the working tree.
  local current_commit current_branch changes
  current_commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
  current_branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  local summary
  summary=$(cat <<EOM
About to roll back '$project' to snapshot '$snapshot_name':
  branch: $current_branch -> $target_branch
  commit: $current_commit -> $target_commit
  uncommitted changes: $changes (will be stashed)
This runs 'git reset --hard'; uncommitted unstashed work cannot be recovered.
EOM
)
  if ! _confirm_rollback "$summary"; then
    declare -F log_security_event >/dev/null && \
      log_security_event "rollback" "refuse" \
        "project=$project" "snapshot=$snapshot_name" \
        "from_commit=$current_commit" "target_commit=$target_commit"
    return 1
  fi
  declare -F log_security_event >/dev/null && \
    log_security_event "rollback" "grant" \
      "project=$project" "snapshot=$snapshot_name" \
      "from_commit=$current_commit" "target_commit=$target_commit" \
      "from_branch=$current_branch" "target_branch=$target_branch" \
      "uncommitted=$changes"

  # Check for uncommitted changes
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

  # Integrity + confirm once for the whole batch. Each rollback_project
  # call below will see MRA_ROLLBACK_FORCE=1 and skip its own prompt.
  if [[ "${MRA_ROLLBACK_IGNORE_INTEGRITY:-}" != "1" ]]; then
    if ! _verify_snapshot_integrity "$snapshot"; then
      return 1
    fi
  fi
  local project_count
  project_count=$(echo "$snapshot" | jq -r '.projects | length')
  local summary
  summary=$(cat <<EOM
About to roll back $project_count projects to snapshot '$snapshot_name'.
This runs 'git reset --hard' in each project; uncommitted unstashed work cannot be recovered.
EOM
)
  if ! _confirm_rollback "$summary"; then
    return 1
  fi

  log_progress "rolling back all projects to '$snapshot_name'" "rollback"

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    MRA_ROLLBACK_FORCE=1 rollback_project "$workspace" "$project" "$snapshot_name"
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
