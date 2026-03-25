#!/usr/bin/env bash
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source all libs
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/config.sh"
source "$MRA_DIR/lib/preflight.sh"
source "$MRA_DIR/lib/detect-type.sh"
source "$MRA_DIR/lib/sync.sh"
source "$MRA_DIR/lib/deps.sh"
source "$MRA_DIR/lib/repos.sh"
source "$MRA_DIR/lib/init.sh"
source "$MRA_DIR/lib/launch.sh"
source "$MRA_DIR/lib/workflow.sh"
source "$MRA_DIR/lib/alias.sh"
source "$MRA_DIR/lib/cleanup.sh"
source "$MRA_DIR/lib/db.sh"
source "$MRA_DIR/lib/doctor.sh"
source "$MRA_DIR/lib/scan.sh"
source "$MRA_DIR/lib/ask.sh"

usage() {
  cat <<'USAGE'
Usage: mra <command|project...> [options]

Commands:
  init <path> --git-org <url>   Initialize a workspace
  scan [path]                   Re-scan dependency graph
  deps [project]                Show dependency graph
  config <key> <value>          Set configuration
  alias <name> <path>           Create workspace alias
  clean [--logs-older-than Nd]  Clean orphan containers and old logs
  db [setup|status|import]      Manage databases
  doctor [project]              Verify environment health
  ask <project> "<question>"   Query codebase via Claude
  --all                         Load all projects
  <project...>                  Load specific projects

Options:
  --with-deps                   Include upstream/downstream dependencies
  --depth N                     Dependency traversal depth (default: 1)
  --no-sync                     Skip git sync
  --help                        Show this help
USAGE
}

resolve_workspace() {
  local workspace=""

  # Check if running from alias (set by wrapper function)
  if [[ -n "${MRA_WORKSPACE:-}" ]]; then
    workspace="$MRA_WORKSPACE"
  else
    # Try to detect workspace from current directory
    local current_dir
    current_dir=$(pwd)
    # Check if we're in a workspace or its subdirectory
    if [[ -f "$current_dir/.collab/dep-graph.json" ]]; then
      workspace="$current_dir"
    elif [[ -f "$(dirname "$current_dir")/.collab/dep-graph.json" ]]; then
      workspace="$(dirname "$current_dir")"
    fi
  fi

  if [[ -z "$workspace" ]]; then
    log_error "not in a workspace (run: mra init <path> --git-org <url>)" "mra"
    exit 1
  fi

  echo "$workspace"
}

main() {
  local command="${1:-}"

  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi

  case "$command" in
    init)
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
      ;;

    scan)
      shift
      local workspace
      workspace="${1:-$(resolve_workspace)}"
      handle_scan "$workspace"
      ;;

    deps)
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
      ;;

    config)
      shift
      config_handle "$@"
      ;;

    alias)
      shift
      handle_alias "$@"
      ;;

    clean)
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
      ;;

    --all)
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
      ;;

    db)
      shift
      local workspace
      workspace=$(resolve_workspace)
      local subcmd="${1:-status}"
      shift 2>/dev/null || true
      case "$subcmd" in
        setup)
          if db_json_exists "$workspace"; then
            setup_all_databases "$workspace"
          else
            interactive_db_setup "$workspace"
            if db_json_exists "$workspace"; then
              setup_all_databases "$workspace"
            fi
          fi
          ;;
        status)
          list_databases "$workspace"
          ;;
        import)
          local db_name="${1:-}"
          if [[ -z "$db_name" ]]; then
            log_error "usage: mra db import <db_name>" "db"
            exit 1
          fi
          reimport_database "$workspace" "$db_name"
          ;;
        *)
          log_error "unknown db command: $subcmd (use: setup, status, import)" "db"
          exit 1
          ;;
      esac
      ;;

    doctor)
      shift
      local workspace
      workspace=$(resolve_workspace)
      run_doctor "$workspace" "${1:-}"
      ;;

    ask)
      shift
      local workspace
      workspace=$(resolve_workspace)
      ask_project "$workspace" "$@"
      ;;

    *)
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
      ;;
  esac
}

main "$@"
