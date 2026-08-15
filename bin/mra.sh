#!/usr/bin/env bash
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Libraries, in load order. Order is significant — lib/review-verdict.sh mints
# the run's sentinel token at source time, and later files read it — so this
# stays an explicit ordered list rather than a glob over lib/*.sh.
#
# Kept as data rather than 78 hand-written `source` lines, which were most of
# what pushed this file over the project's 800-line ceiling (#39).
# tests/test_lib_loader.sh fails if a lib/*.sh exists that this list omits.
MRA_LIBS=(
  colors claude-invoke review-verdict args security-log
  project-path url-policy validate config project-memory
  preflight detect-type sync branch branch-ops
  review-select pr-ops deps repos init
  launch workflow alias cleanup db
  doctor structural scan ask export
  docker-exec test-runner change-detector integration-test status
  log-viewer diff-summary open-ide watch setup-project
  graph cost template ci snapshot
  dashboard federation notify lint review-diff
  review-prompt review-context review-provider review-json review-strategy
  review-pr-discussion review-pr-threads review-adjudication review-premise review-refute review-post review review-protocol review-debate
  review-debate-agents personas review-personas plan-council model-provider
  corpus-targets
  test-audit pkb pkb-cache pkb-query pkb-prompts
  eval eval-probe eval-ablation dev-agent dev
  prd prd-issues prd-scaffold
  cmd-workspace cmd-repo cmd-review cmd-prd cmd-launch
)

for _mra_lib in "${MRA_LIBS[@]}"; do
  # Path is built from the list above, not from input.
  # shellcheck source=/dev/null
  source "$MRA_DIR/lib/${_mra_lib}.sh"
done
unset _mra_lib


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
  eval-probe [--out <file>]            Deterministic PKB probe (no LLM): fixed cases, SHA-stamped report
  eval-ablation <project> [--base R] [--pr N] [--model M]  Run 2x2 PKB/structural ablation arms
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

# Commands dispatch by convention: `mra <name>` runs mra_cmd_<name>, with dashes
# in the name turned into underscores. Anything with no handler is treated as
# project names — what the old catch-all branch did. Adding a command means
# adding mra_cmd_<name> to a lib/cmd-*.sh; nothing here changes (#39).
#
# The `declare -F` gate means only a defined function is ever invoked, so a
# crafted argument cannot reach anything else. (A function exported into the
# environment could add or shadow a command, but whoever controls that
# environment can already run anything as this user.)
_mra_handler_for() {
  case "$1" in
    --all) printf 'mra_cmd_all' ;;
    *)     printf 'mra_cmd_%s' "${1//-/_}" ;;
  esac
}

main() {
  local command="${1:-}"

  apply_project_memory_env

  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi

  local handler
  handler=$(_mra_handler_for "$command")
  if declare -F "$handler" >/dev/null 2>&1; then
    "$handler" "$@"
  else
    mra_cmd_launch_projects "$@"
  fi
}

main "$@"
