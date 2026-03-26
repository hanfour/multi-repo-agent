#!/usr/bin/env bash
# CI/CD helpers for multi-repo-agent
# Generates GitHub Actions workflows for projects

generate_ci_workflow() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local workflow_dir="$project_dir/.github/workflows"

  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "ci"; return 1; }

  mkdir -p "$workflow_dir"

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local template="$mra_dir/templates/github-workflow.yml"

  if [[ ! -f "$template" ]]; then
    log_error "workflow template not found: $template" "ci"
    return 1
  fi

  local target="$workflow_dir/mra-test.yml"
  if [[ -f "$target" ]]; then
    log_warn "$project: workflow already exists ($target)" "ci"
    return 0
  fi

  # Get git org from dep-graph
  local graph_file="$workspace/.collab/dep-graph.json"
  local git_org=""
  [[ -f "$graph_file" ]] && git_org=$(jq -r '.gitOrg // ""' "$graph_file")

  # Copy template and replace placeholders
  sed "s|YOUR_ORG|${git_org##*/}|g" "$template" > "$target"

  log_success "$project: workflow created at $target" "ci"
}
