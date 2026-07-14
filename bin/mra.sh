#!/usr/bin/env bash
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source all libs
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"
source "$MRA_DIR/lib/review-verdict.sh"
source "$MRA_DIR/lib/args.sh"
source "$MRA_DIR/lib/security-log.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/url-policy.sh"
source "$MRA_DIR/lib/validate.sh"
source "$MRA_DIR/lib/config.sh"
source "$MRA_DIR/lib/project-memory.sh"
source "$MRA_DIR/lib/preflight.sh"
source "$MRA_DIR/lib/detect-type.sh"
source "$MRA_DIR/lib/sync.sh"
source "$MRA_DIR/lib/branch.sh"
source "$MRA_DIR/lib/branch-ops.sh"
source "$MRA_DIR/lib/review-select.sh"
source "$MRA_DIR/lib/pr-ops.sh"
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
source "$MRA_DIR/lib/lint.sh"
source "$MRA_DIR/lib/review-diff.sh"
source "$MRA_DIR/lib/review-prompt.sh"
source "$MRA_DIR/lib/review-context.sh"
source "$MRA_DIR/lib/review-provider.sh"
source "$MRA_DIR/lib/review-json.sh"
source "$MRA_DIR/lib/review-strategy.sh"
source "$MRA_DIR/lib/review-pr-discussion.sh"
source "$MRA_DIR/lib/review-post.sh"
source "$MRA_DIR/lib/review.sh"
source "$MRA_DIR/lib/review-protocol.sh"
source "$MRA_DIR/lib/review-debate.sh"
source "$MRA_DIR/lib/review-debate-agents.sh"
source "$MRA_DIR/lib/personas.sh"
source "$MRA_DIR/lib/review-personas.sh"
source "$MRA_DIR/lib/plan-council.sh"
source "$MRA_DIR/lib/model-provider.sh"
source "$MRA_DIR/lib/test-audit.sh"
source "$MRA_DIR/lib/pkb.sh"
source "$MRA_DIR/lib/pkb-cache.sh"
source "$MRA_DIR/lib/pkb-query.sh"
source "$MRA_DIR/lib/pkb-prompts.sh"
source "$MRA_DIR/lib/eval.sh"
source "$MRA_DIR/lib/dev-agent.sh"
source "$MRA_DIR/lib/dev.sh"
source "$MRA_DIR/lib/prd.sh"
source "$MRA_DIR/lib/prd-issues.sh"
source "$MRA_DIR/lib/prd-scaffold.sh"

usage() {
  cat <<'USAGE'
Usage: mra <command|project...> [options]

Commands:
  init <path> --git-org <url>   Initialize a workspace
  scan [path]                   Re-scan dependency graph
  deps [project]                Show dependency graph
  config <key> <value>          Set configuration
  config project-memory on|off  Load each project's CLAUDE.md/AGENTS.md/.claude/rules (default on)
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
  ci <project> [--with-review] Generate GitHub Actions workflow
  snapshot [name]               Create a state snapshot
  snapshots                     List all snapshots
  rollback <project> [name] [--force] [--ignore-integrity]
                                Rollback project to snapshot (asks before destroying)
  rollback --all [name] [--force] [--ignore-integrity]
                                Rollback all projects (single confirmation for the batch)
  trust <project>               Grant Docker trust for project (records in .collab/trusted-projects.json)
  dashboard                    Interactive terminal dashboard
  federation <subcommand>       Multi-workspace contract management
  notify [setup|status|test]    Manage notifications
  lint <project|--all>          Check JS/TS BLOCKER rules
  sync [--safe] [--push] [--dry-run] [--review] [--json]  Clone/pull; --safe ff-only; --push pushes; --review auto-reviews; --json per-repo {repo,action,ok} array (not with --review)
  branch status [--all] [--fetch] [--json]  Cross-repo branch overview (default: repos needing attention; --json: machine-readable array of all repos)
  branch new <name> [repos...]  Create+checkout a branch across repos
  branch switch <name>          Switch repos that have <name> to it
  branch pr [--base <ref>] [--dry-run] [repos...]  Push feature branches and open PRs across repos (deps first; repos... = subset)
  branch merge [--strategy S] [--dry-run] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [repos...]  Merge open PRs across repos (deps first; mergeable+CI gated; --wait-ci polls CI; repos... = subset)
  review <project> [--pr N] [--provider claude|codex|fallback|dual] [--working] [--range A..B] [--head <ref>] [--no-debate]  Code review
  integration describe|doctor|review  Versioned machine integration protocol
  plan <project> "<task>" [--model M] [--dual]  Multi-expert plan; --dual = claude+codex council
  prd [projects…] [--no-sync]      Interactive cross-repo PRD/spec planner (writes .collab/, opens no issues)
  prd-issues --req <ID> [--confirm] [--dry-run]   Apply: open the planned issues (operator-run, TTY-gated)
  prd-scaffold --req <ID> [--confirm] [--dry-run]   Apply: create the greenfield-planned repos (operator-run, TTY-gated)
  prd-render <path>                 Render a .collab markdown file to .html
  dev <project> "<task>" [--base R] [--max-rounds N] [--no-pr] [--auto-approve] [--resume] [--dry-run]
                                Autonomous implement->review->fix->PR loop (headless)
  test-audit <project> [--model M]     Audit tests vs Kent Beck 11 principles
  analyze <project> [--model M]        Generate/update project knowledge base (PKB)
  eval-review <project> --pr <N> [--baseline <file>] [--strategy S]  Score AI review against a human baseline
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

  apply_project_memory_env

  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi

  case "$command" in
    integration)
      shift
      local subcommand="${1:-}"; [[ -n "$subcommand" ]] && shift
      case "$subcommand" in
        describe)
          [[ "${1:-}" == "--json" || $# -eq 0 ]] || { log_error "usage: mra integration describe --json" "integration"; exit 2; }
          review_protocol_describe
          ;;
        doctor)
          local request_file=""
          while [[ $# -gt 0 ]]; do
            case "$1" in --request) request_file="${2:-}"; shift 2 ;; --json) shift ;; *) log_error "unknown integration doctor option: $1" "integration"; exit 2 ;; esac
          done
          [[ -n "$request_file" ]] || { log_error "usage: mra integration doctor --request FILE --json" "integration"; exit 2; }
          review_protocol_doctor "$request_file"
          ;;
        review)
          local request_file="" result_file="" events_file=""
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --request) request_file="${2:-}"; shift 2 ;;
              --result) result_file="${2:-}"; shift 2 ;;
              --events) events_file="${2:-}"; shift 2 ;;
              *) log_error "unknown integration review option: $1" "integration"; exit 2 ;;
            esac
          done
          [[ -n "$request_file" && -n "$result_file" ]] || { log_error "usage: mra integration review --request FILE --result FILE [--events FILE]" "integration"; exit 2; }
          review_protocol_review "$request_file" "$result_file" "$events_file"
          ;;
        *) log_error "usage: mra integration describe|doctor|review" "integration"; exit 2 ;;
      esac
      ;;

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
      local ci_project="" ci_opts=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --with-review) ci_opts+=("--with-review"); shift ;;
          -*) log_error "unknown option: $1" "ci"; exit 1 ;;
          *) ci_project="$1"; shift ;;
        esac
      done
      if [[ -z "$ci_project" ]]; then
        log_error "usage: mra ci <project> [--with-review]" "ci"; exit 1
      fi
      generate_ci_workflow "$workspace" "$ci_project" "${ci_opts[@]}"
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
      local rb_force=0 rb_ignore_integrity=0
      local rb_args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) rb_force=1; shift ;;
          --ignore-integrity) rb_ignore_integrity=1; shift ;;
          *) rb_args+=("$1"); shift ;;
        esac
      done
      [[ "$rb_force" == "1" ]] && export MRA_ROLLBACK_FORCE=1
      [[ "$rb_ignore_integrity" == "1" ]] && export MRA_ROLLBACK_IGNORE_INTEGRITY=1
      if [[ "${rb_args[0]:-}" == "--all" ]]; then
        rollback_all "$workspace" "${rb_args[1]:-}"
      elif [[ -n "${rb_args[0]:-}" ]]; then
        rollback_project "$workspace" "${rb_args[0]}" "${rb_args[1]:-}"
      else
        log_error "usage: mra rollback <project|--all> [snapshot-name] [--force] [--ignore-integrity]" "rollback"
        exit 1
      fi
      ;;

    trust)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ -z "${1:-}" ]]; then
        log_error "usage: mra trust <project>" "trust"
        exit 1
      fi
      local trust_project="$1"
      if ! validate_project_name "$trust_project"; then
        exit 1
      fi
      MRA_DOCKER_TRUST_FORCE=1 _docker_trust_check "$workspace" "$trust_project" ""
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

    lint)
      shift
      local workspace; workspace=$(resolve_workspace)
      if [[ "${1:-}" == "--all" ]]; then
        lint_all_projects "$workspace" || exit $?
      elif [[ -n "${1:-}" ]]; then
        lint_project "$workspace" "$1" || exit $?
      else
        log_error "usage: mra lint <project|--all>" "lint"; exit 1
      fi
      ;;

    sync)
      shift
      local safe=false push=false dry_run=false review=false json=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --safe) safe=true; shift ;;
          --push) push=true; shift ;;
          --dry-run) dry_run=true; shift ;;
          --review) review=true; shift ;;
          --json) json=true; shift ;;
          *) log_error "unknown option: $1" "sync"; exit 1 ;;
        esac
      done
      # mode flags are mutually exclusive
      local mode_count=0
      [[ "$safe" == "true" ]] && mode_count=$((mode_count+1))
      [[ "$push" == "true" ]] && mode_count=$((mode_count+1))
      [[ "$review" == "true" ]] && mode_count=$((mode_count+1))
      if [[ "$mode_count" -gt 1 ]]; then
        log_error "sync: choose only one of --safe / --push / --review" "sync"; exit 1
      fi
      if [[ "$dry_run" == "true" && "$push" != "true" ]]; then
        log_error "sync: --dry-run only applies to --push" "sync"; exit 1
      fi
      if [[ "$json" == "true" && "$review" == "true" ]]; then
        log_error "sync: --review does not support --json" "sync"; exit 1
      fi
      local workspace; workspace=$(resolve_workspace)
      if [[ "$json" == "true" ]]; then
        local rf; rf=$(mktemp)
        export SYNC_RESULT_FILE="$rf"
        local jrc=0
        if [[ "$push" == "true" ]]; then
          push_workspace "$workspace" "$dry_run" 1>&2 || jrc=$?
        elif [[ "$safe" == "true" ]]; then
          safe_sync_workspace "$workspace" 1>&2 || jrc=$?
        else
          local graph_file git_org
          graph_file=$(get_dep_graph_path "$workspace")
          git_org=$(jq -r '.gitOrg' "$graph_file")
          sync_from_repos_json "$workspace" "$git_org" 1>&2 || jrc=$?
        fi
        unset SYNC_RESULT_FILE
        local json_objs=() repo action okv obj
        while IFS=$'\t' read -r repo action okv; do
          [[ -z "$repo" ]] && continue
          if obj=$(sync_result_json "$repo" "$action" "$okv"); then
            json_objs+=("$obj")
          else
            log_error "sync: skipping malformed result record: $repo $action $okv" "sync" >&2
          fi
        done < "$rf"
        rm -f "$rf"
        if [[ ${#json_objs[@]} -eq 0 ]]; then
          printf '[]\n'
        else
          printf '%s\n' "${json_objs[@]}" | jq -s '.'
        fi
        exit "$jrc"
      fi
      if [[ "$review" == "true" ]]; then
        sync_review_workspace "$workspace"
        exit $?
      elif [[ "$push" == "true" ]]; then
        push_workspace "$workspace" "$dry_run"
        exit $?
      elif [[ "$safe" == "true" ]]; then
        safe_sync_workspace "$workspace"
        exit $?
      else
        # Default: reproduce existing helper behavior as a public command.
        local graph_file git_org
        graph_file=$(get_dep_graph_path "$workspace")
        git_org=$(jq -r '.gitOrg' "$graph_file")
        sync_from_repos_json "$workspace" "$git_org"
        exit $?
      fi
      ;;

    branch)
      shift
      local sub="${1:-}"; shift || true
      case "$sub" in
        status)
          local show_all=false do_fetch=false json=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --all) show_all=true; shift ;;
              --fetch) do_fetch=true; shift ;;
              --json) json=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          local shown=0 failed=0
          local json_objs=()
          [[ "$json" == "false" ]] && printf '%-20s %-24s %-5s%-5s%-5s %s\n' "REPO" "BRANCH" "AHEAD" "BEHIND" "DIRTY" "ACTION"
          for dir in "$workspace"/*/; do
            [[ ! -d "$dir" ]] && continue
            local name; name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            should_skip_dir "$dir" && continue
            if [[ "$do_fetch" == "true" ]]; then
              if ! git -C "$dir" fetch --quiet 2>/dev/null; then
                if [[ "$json" == "true" ]]; then
                  log_error "$name: fetch failed" "branch" >&2
                else
                  log_error "$name: fetch failed" "branch"
                fi
                failed=$((failed+1))
              fi
            fi
            local state on_default ahead behind dirty needs_attention
            state=$(get_branch_state "$dir")
            ahead=$(branch_state_get "$state" ahead)
            behind=$(branch_state_get "$state" behind)
            dirty=$(branch_state_get "$state" dirty)
            if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
            if branch_row_needs_attention "$ahead" "$behind" "$dirty" "$on_default"; then needs_attention=true; else needs_attention=false; fi
            if [[ "$json" == "true" ]]; then
              json_objs+=("$(branch_state_json "$state" "$on_default" "$needs_attention")")
            elif [[ "$show_all" == "true" || "$needs_attention" == "true" ]]; then
              branch_format_row "$state"; printf '\n'; shown=$((shown+1))
            fi
          done
          if [[ "$json" == "true" ]]; then
            if [[ ${#json_objs[@]} -eq 0 ]]; then
              printf '[]\n'
            else
              printf '%s\n' "${json_objs[@]}" | jq -s '.'
            fi
            [[ "$failed" -gt 0 ]] && exit 1
            exit 0
          fi
          if [[ "$shown" -eq 0 && "$show_all" == "false" ]]; then
            log_success "all repos clean and up to date" "branch"
          fi
          [[ "$failed" -gt 0 ]] && exit 1
          exit 0
          ;;
        new)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch new <name> [repos...]" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          create_branch_workspace "$workspace" "$bname" "$@"
          exit $?
          ;;
        switch)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch switch <name>" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          switch_branch_workspace "$workspace" "$bname"
          exit $?
          ;;
        pr)
          local base="" dry_run=false repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --base) if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "branch"; exit 1; fi; base="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch pr requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          pr_workspace "$workspace" "$base" "$dry_run" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
        merge)
          local strategy="merge" dry_run=false delete_branch=false wait_ci=false ci_timeout="" repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              --delete-branch) delete_branch=true; shift ;;
              --wait-ci) wait_ci=true; shift ;;
              --ci-timeout) if [[ $# -lt 2 ]]; then log_error "--ci-timeout requires a positive integer (seconds)" "branch"; exit 1; fi; ci_timeout="$2"; shift 2 ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          case "$strategy" in
            merge|squash|rebase) ;;
            *) log_error "branch merge: --strategy must be merge|squash|rebase" "branch"; exit 1 ;;
          esac
          # Validate CI flags post-parse (order-independent), before any side effect.
          if [[ -n "$ci_timeout" && "$wait_ci" != "true" ]]; then
            log_error "--ci-timeout requires --wait-ci" "branch"; exit 1
          fi
          if [[ -n "$ci_timeout" && ! "$ci_timeout" =~ ^[1-9][0-9]*$ ]]; then
            log_error "--ci-timeout must be a positive integer (seconds): '$ci_timeout'" "branch"; exit 1
          fi
          local ci_wait_timeout=""
          if [[ "$wait_ci" == "true" ]]; then ci_wait_timeout="${ci_timeout:-1800}"; fi
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch merge requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          merge_workspace "$workspace" "$strategy" "$dry_run" "$delete_branch" "$ci_wait_timeout" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
        *)
          log_error "usage: mra branch status|new|switch|pr|merge ..." "branch"; exit 1 ;;
      esac
      ;;

    review)
      shift
      local review_args=() personas_flag=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --personas) personas_flag=true; shift ;;
          *) review_args+=("$1"); shift ;;
        esac
      done
      # Check if user supplied a project name (first non-flag arg that isn't a value for --pr/--base/--model/--strategy)
      local has_project=false
      local skip_next=false
      for a in "${review_args[@]}"; do
        if [[ "$skip_next" == "true" ]]; then skip_next=false; continue; fi
        case "$a" in
          --pr|--base|--model|--strategy|--range|--head|--provider) skip_next=true ;;
          --no-debate|--working) ;;
          -*) ;;
          *) has_project=true; break ;;
        esac
      done
      if [[ "$has_project" == "false" ]]; then
        log_error "usage: mra review <project> [--pr <N>] [--base <ref>] [--working] [--personas] [--strategy S] [--no-debate]" "review"
        exit 1
      fi
      local workspace; workspace=$(resolve_workspace)
      MRA_REVIEW_PERSONAS="$personas_flag" review_project "$workspace" "${review_args[@]}"
      ;;

    analyze)
      shift
      local workspace; workspace=$(resolve_workspace)
      local project="" model="sonnet"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model)
            if [[ $# -lt 2 ]]; then log_error "--model requires a value" "analyze"; exit 1; fi
            model="$2"; shift 2 ;;
          -*) log_error "unknown option: $1" "analyze"; exit 1 ;;
          *) project="$1"; shift ;;
        esac
      done
      if [[ -z "$project" ]]; then
        log_error "usage: mra analyze <project> [--model <model>]" "analyze"; exit 1
      fi
      local project_dir
      project_dir=$(resolve_project_dir "$workspace" "$project") || exit 1
      local output_language=""
      output_language=$(config_get "outputLanguage" 2>/dev/null)
      [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""
      pkb_generate "$project" "$project_dir" "$model" "$output_language"
      ;;

    plan)
      shift
      local plan_project="" plan_task="" plan_model="sonnet" plan_dual=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model)
            [[ $# -lt 2 ]] && { log_error "--model requires a value" "plan"; exit 1; }
            plan_model="$2"; shift 2 ;;
          --dual) plan_dual=true; shift ;;
          -*) log_error "unknown option: $1" "plan"; exit 1 ;;
          *)
            if [[ -z "$plan_project" ]]; then
              plan_project="$1"
            else
              plan_task+="${plan_task:+ }$1"
            fi
            shift ;;
        esac
      done
      if [[ -z "$plan_project" || -z "$plan_task" ]]; then
        log_error "usage: mra plan <project> \"<task>\" [--model <model>] [--dual]" "plan"; exit 1
      fi
      local workspace; workspace=$(resolve_workspace)
      local project_dir
      project_dir=$(resolve_project_dir "$workspace" "$plan_project") || exit 1

      if [[ "$plan_dual" == "true" ]] && ! ensure_codex_available; then
        log_error "mra plan --dual requires the codex CLI (not found on PATH)" "plan"; exit 1
      fi

      local lang=""
      lang=$(config_get "outputLanguage" 2>/dev/null); [[ "$lang" == "null" ]] && lang=""
      local lang_directive=""; [[ -n "$lang" ]] && lang_directive="Use ${lang} for all output."
      local pkb_context=""
      pkb_context=$(pkb_build_context "$project_dir" "" "standard" 2>/dev/null || echo "")

      local add_dirs
      add_dirs=$(build_add_dir_string "$project_dir")
      run_plan_council "$plan_project" "$project_dir" "$plan_task" \
        "$(default_plan_personas)" "$plan_model" "$add_dirs" "$pkb_context" "$lang_directive" "$plan_dual"
      ;;

    prd)
      shift
      local workspace; workspace=$(resolve_workspace)
      local graph_file="$workspace/.collab/dep-graph.json"
      local prd_projects=() new_name=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --new)
            [[ -n "${2:-}" && "$2" != -* ]] || { log_error "usage: mra prd --new <name>" "prd"; exit 1; }
            new_name="$2"; shift 2 ;;
          --no-sync) shift ;;  # accepted no-op: the interactive planner never auto-syncs
          -*) log_error "unknown option: $1" "prd"; exit 1 ;;
          *) prd_projects+=("$1"); shift ;;
        esac
      done
      if [[ -n "$new_name" ]]; then
        [[ "${#prd_projects[@]}" -eq 0 ]] || { log_error "prd --new takes no positional projects" "prd"; exit 1; }
        validate_repo_name "$new_name" || { log_error "invalid project name: $new_name" "prd"; exit 1; }
        [[ "$new_name" =~ $_MRA_ID_REGEX ]] || { log_error "name must match $_MRA_ID_REGEX" "prd"; exit 1; }
        prd_launch_new "$workspace" "$graph_file" "$new_name"
      else
        if [[ "${#prd_projects[@]}" -eq 0 ]]; then
          while IFS= read -r p; do prd_projects+=("$p"); done < <(list_all_projects "$graph_file")
        else
          validate_repo_subset "$workspace" "${prd_projects[@]}" || exit 1
        fi
        # No auto-sync: a full-workspace network sync blocks (and can hang) the interactive
        # planner before it even starts, and planning reads the repos + PKB as-is.
        # Run `mra sync` beforehand if you want fresh repos.
        prd_launch "$workspace" "$graph_file" "${prd_projects[@]}"
      fi
      ;;

    prd-issues)
      shift
      local workspace; workspace=$(resolve_workspace)
      local req="" extra=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --req) req="$2"; shift 2 ;;
          *) extra+=("$1"); shift ;;
        esac
      done
      [[ -n "$req" ]] || { log_error "usage: mra prd-issues --req <REQ-ID> [--confirm] [--dry-run]" "prd"; exit 1; }
      local tasks="$workspace/.collab/requirements/$req-tasks.json"
      local prd_html="$workspace/.collab/requirements/$req.html"
      local scope_file="$workspace/.collab/requirements/$req-scope"
      [[ -f "$scope_file" ]] || { log_error "no scope record for $req — was it created by 'mra prd'?" "prd"; exit 1; }
      MRA_PRD_PROJECTS="$(cat "$scope_file")"; export MRA_PRD_PROJECTS
      mra_prd_open_issues --tasks "$tasks" --req "$req" --prd-url "$prd_html" "${extra[@]}"
      ;;

    prd-scaffold)
      shift
      local workspace; workspace=$(resolve_workspace)
      local req="" extra=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --req) req="$2"; shift 2 ;;
          *) extra+=("$1"); shift ;;
        esac
      done
      [[ -n "$req" ]] || { log_error "usage: mra prd-scaffold --req <REQ-ID> [--confirm] [--dry-run]" "prd"; exit 1; }
      local scaffold="$workspace/.collab/requirements/$req-scaffold.json"
      local tasks="$workspace/.collab/requirements/$req-tasks.json"
      [[ -f "$scaffold" ]] || { log_error "not a greenfield REQ (no scaffold plan) — was it created by 'mra prd --new'?" "prd"; exit 1; }
      mra_prd_scaffold --scaffold "$scaffold" --tasks "$tasks" --req "$req" "${extra[@]}"
      ;;

    prd-render)
      shift
      [[ -n "${1:-}" ]] || { log_error "usage: mra prd-render <.collab .md path>" "prd"; exit 1; }
      prd_render_html "$1"
      ;;

    dev)
      shift
      _dev_parse_args "$@" || exit 1
      local workspace; workspace=$(resolve_workspace)
      validate_project_name "$DEV_PROJECT" || exit 1
      [[ "$DEV_NO_PR" == true ]] || check_gh_auth || exit 1
      dev_project "$workspace" "$DEV_PROJECT" "$DEV_TASK"
      ;;

    eval-review)
      shift
      local workspace; workspace=$(resolve_workspace)
      eval_review "$workspace" "$@"
      ;;

    test-audit)
      shift
      local audit_project="" audit_model="sonnet"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model)
            [[ $# -lt 2 ]] && { log_error "--model requires a value" "test-audit"; exit 1; }
            audit_model="$2"; shift 2 ;;
          -*) log_error "unknown option: $1" "test-audit"; exit 1 ;;
          *) audit_project="$1"; shift ;;
        esac
      done
      if [[ -z "$audit_project" ]]; then
        log_error "usage: mra test-audit <project> [--model M]" "test-audit"; exit 1
      fi
      local workspace; workspace=$(resolve_workspace)
      local project_dir
      project_dir=$(resolve_project_dir "$workspace" "$audit_project") || exit 1

      local lang=""
      lang=$(config_get "outputLanguage" 2>/dev/null); [[ "$lang" == "null" ]] && lang=""
      local lang_directive=""; [[ -n "$lang" ]] && lang_directive="Use ${lang} for all output."

      local add_dirs
      add_dirs=$(build_add_dir_string "$project_dir")
      run_test_audit "$audit_project" "$project_dir" "$audit_model" "$add_dirs" "$lang_directive"
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
      ;;
  esac
}

main "$@"
