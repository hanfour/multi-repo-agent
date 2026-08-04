#!/usr/bin/env bash
# The default path: arguments that are not a command are project names.
#
# Dispatched by convention from bin/mra.sh: `mra <name>` runs
# mra_cmd_<name> with dashes replaced by underscores. Adding a command means
# adding a function here — the dispatch itself is not edited (#39).
#
# Each still receives the full argv with the command name at $1, exactly as
# the case branch it replaced did, so the `shift` each body opens with means
# the same thing.

mra_cmd_launch_projects() {
  # Treat as project names
  local projects=() with_deps=false depth="" no_sync=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-deps) with_deps=true; shift ;;
      --depth)
        if [[ $# -lt 2 ]]; then log_error "--depth requires a value" "mra"; exit 1; fi
        depth="$2"; shift 2 ;;
      --no-sync) no_sync=true; shift ;;
      -*) log_error "unknown option: $1" "mra"; exit 1 ;;
      *) projects+=("$1"); shift ;;
    esac
  done

  # User-typed project names are joined onto the workspace path
  # downstream (launch, sync, deps); reject traversal here (TM-001).
  if (( ${#projects[@]} > 0 )); then
    local p
    for p in "${projects[@]}"; do
      validate_project_name "$p" || exit 1
    done
  fi

  local workspace
  workspace=$(resolve_workspace)
  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")

  run_preflight || true

  # Auto-scan
  if [[ "$(config_get autoScan)" == "true" ]]; then
    log_progress "auto-scanning for changes" "scan"
  fi

  # Sync
  if [[ "$no_sync" == "false" ]]; then
    local git_org
    git_org=$(jq -r '.gitOrg' "$graph_file")
    sync_from_repos_json "$workspace" "$git_org"
  fi

  # Resolve deps
  if [[ "$with_deps" == "true" ]]; then
    local resolved_depth="${depth:-$(config_get depthDefault)}"
    local resolved_projects
    resolved_projects=$(
      for p in "${projects[@]}"; do
        resolve_with_deps "$p" "$resolved_depth" "$graph_file"
      done | sort -u
    )
    projects=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && projects+=("$p")
    done <<< "$resolved_projects"
  fi

  launch_claude "$workspace" "$graph_file" "${projects[@]}"
}
