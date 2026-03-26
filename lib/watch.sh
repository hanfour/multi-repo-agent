#!/usr/bin/env bash
watch_project() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "watch"; return 1; }
  if ! command -v fswatch &>/dev/null; then
    log_error "fswatch not found (install: brew install fswatch)" "watch"
    return 1
  fi
  log_info "watching $project for changes (Ctrl+C to stop)" "watch"
  fswatch -r -e "node_modules" -e ".git" -e "tmp" -e "log" -e "vendor" \
    --event Created --event Updated --event Removed \
    "$project_dir" | while read -r changed_file; do
    local relative="${changed_file#$project_dir/}"
    log_progress "changed: $relative" "watch"
    log_progress "running tests for $project" "watch"
    run_project_tests "$workspace" "$project" 2>&1 || true
    log_info "watching $project for changes (Ctrl+C to stop)" "watch"
  done
}

watch_all() {
  local workspace="$1"
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")
  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "watch"; return 1; }
  if ! command -v fswatch &>/dev/null; then
    log_error "fswatch not found (install: brew install fswatch)" "watch"
    return 1
  fi
  local dirs=()
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    [[ -d "$workspace/$project" ]] && dirs+=("$workspace/$project")
  done < <(jq -r '.projects | keys[]' "$graph_file")
  log_info "watching ${#dirs[@]} projects for changes (Ctrl+C to stop)" "watch"
  fswatch -r -e "node_modules" -e ".git" -e "tmp" -e "log" -e "vendor" \
    --event Created --event Updated --event Removed \
    "${dirs[@]}" | while read -r changed_file; do
    # Determine which project the file belongs to
    for dir in "${dirs[@]}"; do
      if [[ "$changed_file" == "$dir"/* ]]; then
        local project; project=$(basename "$dir")
        local relative="${changed_file#$dir/}"
        log_progress "[$project] changed: $relative" "watch"
        run_project_tests "$workspace" "$project" 2>&1 || true
        break
      fi
    done
    log_info "watching for changes (Ctrl+C to stop)" "watch"
  done
}
