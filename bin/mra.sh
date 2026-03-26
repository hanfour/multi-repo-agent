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
source "$MRA_DIR/lib/export.sh"
source "$MRA_DIR/lib/docker-exec.sh"
source "$MRA_DIR/lib/test-runner.sh"
source "$MRA_DIR/lib/change-detector.sh"
source "$MRA_DIR/lib/integration-test.sh"
source "$MRA_DIR/lib/status.sh"
source "$MRA_DIR/lib/log-viewer.sh"
source "$MRA_DIR/lib/diff-summary.sh"
source "$MRA_DIR/lib/open-ide.sh"
source "$MRA_DIR/lib/watch.sh"
source "$MRA_DIR/lib/setup-project.sh"
source "$MRA_DIR/lib/graph.sh"
source "$MRA_DIR/lib/cost.sh"
source "$MRA_DIR/lib/template.sh"
source "$MRA_DIR/lib/ci.sh"
source "$MRA_DIR/lib/snapshot.sh"
source "$MRA_DIR/lib/dashboard.sh"
source "$MRA_DIR/lib/federation.sh"
source "$MRA_DIR/lib/notify.sh"

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
  export [project]              Export project context files
  test <project> [--integration|--mock]  Run tests in Docker
  status                        Show workspace status overview
  log [project]                 View operation history
  diff                          Show cross-repo diff summary
  open <project> [--with-deps]  Open project in IDE
  watch <project|--all>         Watch files and auto-test on change
  setup <project|--all>         Auto-install dependencies
  graph [--mermaid|--dot]       Visualize dependency graph
  cost [--reset]                Show Claude API usage
  template [repos|db|deps|all]  Generate config templates
  ci <project>                 Generate GitHub Actions workflow
  snapshot [name]               Create a state snapshot
  snapshots                     List all snapshots
  rollback <project> [name]    Rollback project to snapshot
  rollback --all [name]        Rollback all projects
  dashboard                    Interactive terminal dashboard
  federation <subcommand>       Multi-workspace contract management
  notify [setup|status|test]    Manage notifications
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

    export)
      shift
      local workspace
      workspace=$(resolve_workspace)
      if [[ -n "${1:-}" ]]; then
        export_project "$workspace" "$1"
      else
        export_all_projects "$workspace"
      fi
      ;;

    test)
      shift
      local workspace project test_mode="auto"
      workspace=$(resolve_workspace)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --integration) test_mode="integration"; shift ;;
          --mock) test_mode="mock"; shift ;;
          -*) log_error "unknown option: $1" "test"; exit 1 ;;
          *) project="$1"; shift ;;
        esac
      done
      if [[ -z "${project:-}" ]]; then
        log_error "usage: mra test <project> [--integration|--mock]" "test"
        exit 1
      fi
      case "$test_mode" in
        integration) run_cross_repo_tests "$workspace" "$project" ;;
        mock) run_project_tests "$workspace" "$project" ;;
        auto) run_cross_repo_tests "$workspace" "$project" ;;
      esac
      ;;

    status)
      shift
      local workspace
      workspace=$(resolve_workspace)
      show_status "$workspace"
      ;;

    log)
      shift
      local workspace
      workspace=$(resolve_workspace)
      show_logs "$workspace" "${1:-}"
      ;;

    diff)
      shift
      local workspace
      workspace=$(resolve_workspace)
      show_diff_summary "$workspace"
      ;;

    open)
      shift
      local workspace
      workspace=$(resolve_workspace)
      open_project "$workspace" "$@"
      ;;

    watch)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ "${1:-}" == "--all" ]]; then
        watch_all "$workspace"
      elif [[ -n "${1:-}" ]]; then
        watch_project "$workspace" "$1"
      else
        log_error "usage: mra watch <project|--all>" "watch"; exit 1
      fi
      ;;

    setup)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ "${1:-}" == "--all" ]]; then
        setup_all_projects "$workspace"
      elif [[ -n "${1:-}" ]]; then
        setup_project "$workspace" "$1"
      else
        log_error "usage: mra setup <project|--all>" "setup"; exit 1
      fi
      ;;

    graph)
      shift
      local workspace format="terminal"
      workspace=$(resolve_workspace)
      case "${1:-}" in
        --mermaid) format="mermaid" ;;
        --dot) format="dot" ;;
      esac
      generate_graph "$workspace" "$format"
      ;;

    cost)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ "${1:-}" == "--reset" ]]; then
        reset_cost "$workspace"
      else
        show_cost "$workspace"
      fi
      ;;

    template)
      shift
      local workspace; workspace=$(resolve_workspace)
      generate_template "$workspace" "${1:-all}"
      ;;

    ci)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ -z "${1:-}" ]]; then
        log_error "usage: mra ci <project>" "ci"; exit 1
      fi
      generate_ci_workflow "$workspace" "$1"
      ;;

    snapshot)
      shift
      local workspace; workspace=$(resolve_workspace)
      create_snapshot "$workspace" "${1:-}"
      ;;

    snapshots)
      shift
      local workspace; workspace=$(resolve_workspace)
      list_snapshots "$workspace"
      ;;

    rollback)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ "${1:-}" == "--all" ]]; then
        shift
        rollback_all "$workspace" "${1:-}"
      elif [[ -n "${1:-}" ]]; then
        local project="$1"; shift
        rollback_project "$workspace" "$project" "${1:-}"
      else
        log_error "usage: mra rollback <project|--all> [snapshot-name]" "rollback"
        exit 1
      fi
      ;;

    dashboard)
      shift
      local workspace; workspace=$(resolve_workspace)
      run_dashboard "$workspace"
      ;;

    federation)
      shift
      local workspace; workspace=$(resolve_workspace)
      local subcmd="${1:-list}"; shift 2>/dev/null || true
      case "$subcmd" in
        publish)
          [[ -z "${1:-}" ]] && { log_error "usage: mra federation publish <project>" "federation"; exit 1; }
          publish_contract "$workspace" "$1"
          ;;
        subscribe)
          [[ -z "${1:-}" ]] && { log_error "usage: mra federation subscribe <url-or-path>" "federation"; exit 1; }
          subscribe_contract "$workspace" "$1"
          ;;
        verify)
          verify_contracts "$workspace"
          ;;
        list)
          list_contracts "$workspace"
          ;;
        fetch)
          # Re-fetch all subscriptions
          local subs_file; subs_file="$(get_contracts_dir "$workspace")/subscriptions.json"
          if [[ -f "$subs_file" ]]; then
            while IFS= read -r url; do
              [[ -z "$url" ]] && continue
              fetch_subscription "$workspace" "$url"
            done < <(jq -r '.[].url' "$subs_file")
          else
            log_info "no subscriptions" "federation"
          fi
          ;;
        *)
          log_error "unknown federation command: $subcmd (use: publish, subscribe, verify, list, fetch)" "federation"
          exit 1
          ;;
      esac
      ;;

    notify)
      shift
      local workspace; workspace=$(resolve_workspace)
      local subcmd="${1:-status}"; shift 2>/dev/null || true
      case "$subcmd" in
        setup) setup_notifications "$workspace" ;;
        status) show_notify_status "$workspace" ;;
        test) test_notification "$workspace" ;;
        *) log_error "usage: mra notify [setup|status|test]" "notify"; exit 1 ;;
      esac
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
