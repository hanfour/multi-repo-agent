#!/usr/bin/env bash
# Workspace and inspection commands.
#
# Dispatched by convention from bin/mra.sh: `mra <name>` runs
# mra_cmd_<name> with dashes replaced by underscores. Adding a command means
# adding a function here — the dispatch itself is not edited (#39).
#
# Each still receives the full argv with the command name at $1, exactly as
# the case branch it replaced did, so the `shift` each body opens with means
# the same thing.

mra_cmd_init() {
  shift
  local path="" git_org=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --git-org)
        if [[ $# -lt 2 ]]; then log_error "--git-org requires a value" "mra"; exit 1; fi
        git_org="$2"; shift 2 ;;
      *) path="$1"; shift ;;
    esac
  done
  if [[ -z "$path" || -z "$git_org" ]]; then
    log_error "usage: mra init <path> --git-org <url>" "mra"
    exit 1
  fi
  run_preflight || true
  init_workspace "$path" "$git_org"
}

mra_cmd_scan() {
  shift
  local workspace
  workspace="${1:-$(resolve_workspace)}"
  handle_scan "$workspace"
}

mra_cmd_deps() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")
  if [[ -n "${1:-}" ]]; then
    display_deps "$1" "$graph_file"
  else
    display_all_deps "$graph_file"
  fi
}

mra_cmd_config() {
  shift
  config_handle "$@"
}

mra_cmd_alias() {
  shift
  handle_alias "$@"
}

mra_cmd_clean() {
  shift
  local workspace logs_age="7"
  workspace=$(resolve_workspace)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --logs-older-than)
        if [[ $# -lt 2 ]]; then log_error "--logs-older-than requires a value" "mra"; exit 1; fi
        logs_age="${2%d}"  # strip trailing 'd'
        shift 2
        ;;
      *) shift ;;
    esac
  done
  handle_clean "$workspace" "$logs_age"
}

mra_cmd_all() {
  shift
  local workspace no_sync=false
  workspace=$(resolve_workspace)
  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-sync) no_sync=true; shift ;;
      *) shift ;;
    esac
  done

  run_preflight || true

  # Auto-scan if enabled
  if [[ "$(config_get autoScan)" == "true" ]]; then
    log_progress "auto-scanning for changes" "scan"
  fi

  # Sync
  if [[ "$no_sync" == "false" ]]; then
    local git_org
    git_org=$(jq -r '.gitOrg' "$graph_file")
    sync_from_repos_json "$workspace" "$git_org"
  fi

  # Get all projects
  local projects=()
  while IFS= read -r p; do
    projects+=("$p")
  done < <(list_all_projects "$graph_file")

  launch_claude "$workspace" "$graph_file" "${projects[@]}"
}

mra_cmd_doctor() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  run_doctor "$workspace" "${1:-}"
}

mra_cmd_status() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  show_status "$workspace"
}

mra_cmd_log() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  show_logs "$workspace" "${1:-}"
}

mra_cmd_diff() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  show_diff_summary "$workspace"
}

mra_cmd_open() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  open_project "$workspace" "$@"
}

mra_cmd_watch() {
  shift
  local workspace; workspace=$(resolve_workspace)
  if [[ "${1:-}" == "--all" ]]; then
    watch_all "$workspace"
  elif [[ -n "${1:-}" ]]; then
    watch_project "$workspace" "$1"
  else
    log_error "usage: mra watch <project|--all>" "watch"; exit 1
  fi
}

mra_cmd_setup() {
  shift
  local workspace; workspace=$(resolve_workspace)
  if [[ "${1:-}" == "--all" ]]; then
    setup_all_projects "$workspace"
  elif [[ -n "${1:-}" ]]; then
    setup_project "$workspace" "$1"
  else
    log_error "usage: mra setup <project|--all>" "setup"; exit 1
  fi
}

mra_cmd_graph() {
  shift
  local workspace format="terminal"
  workspace=$(resolve_workspace)
  case "${1:-}" in
    --mermaid) format="mermaid" ;;
    --dot) format="dot" ;;
  esac
  generate_graph "$workspace" "$format"
}

mra_cmd_cost() {
  shift
  local workspace; workspace=$(resolve_workspace)
  if [[ "${1:-}" == "--reset" ]]; then
    reset_cost "$workspace"
  else
    show_cost "$workspace"
  fi
}

mra_cmd_template() {
  shift
  local workspace; workspace=$(resolve_workspace)
  generate_template "$workspace" "${1:-all}"
}

mra_cmd_export() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  if [[ -n "${1:-}" ]]; then
    export_project "$workspace" "$1"
  else
    export_all_projects "$workspace"
  fi
}

mra_cmd_ask() {
  shift
  local workspace
  workspace=$(resolve_workspace)
  ask_project "$workspace" "$@"
}
