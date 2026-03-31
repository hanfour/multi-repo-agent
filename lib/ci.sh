#!/usr/bin/env bash
# CI/CD helpers for multi-repo-agent
# Generates GitHub Actions workflows for projects

generate_ci_workflow() {
  local workspace="$1" project="$2"
  shift 2
  local with_review=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-review) with_review=true; shift ;;
      *) shift ;;
    esac
  done

  local project_dir="$workspace/$project"
  local workflow_dir="$project_dir/.github/workflows"

  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "ci"; return 1; }

  mkdir -p "$workflow_dir"

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Get git org from dep-graph
  local graph_file="$workspace/.collab/dep-graph.json"
  local git_org="" org_name=""
  if [[ -f "$graph_file" ]]; then
    git_org=$(jq -r '.gitOrg // ""' "$graph_file")
    org_name="${git_org##*/}"
  fi

  # Get output language from config
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ "$output_language" == "null" ]] && output_language=""

  # --- Generate test workflow ---
  local test_template="$mra_dir/templates/github-workflow.yml"
  local test_target="$workflow_dir/mra-test.yml"

  if [[ -f "$test_template" ]]; then
    if [[ -f "$test_target" ]]; then
      log_warn "$project: test workflow already exists ($test_target)" "ci"
    else
      sed "s|YOUR_ORG|${org_name}|g" "$test_template" > "$test_target"
      log_success "$project: test workflow created at $test_target" "ci"
    fi
  fi

  # --- Generate code review workflow ---
  if [[ "$with_review" == "true" ]]; then
    local review_template="$mra_dir/templates/code-review-workflow.yml"
    local review_target="$workflow_dir/mra-code-review.yml"

    if [[ ! -f "$review_template" ]]; then
      log_error "code review template not found: $review_template" "ci"
      return 1
    fi

    local git_org_url="$git_org"
    [[ -z "$git_org_url" ]] && git_org_url="git@github.com:YOUR_ORG"

    sed -e "s|YOUR_ORG|${org_name}|g" \
        -e "s|YOUR_PROJECT|${project}|g" \
        -e "s|YOUR_GIT_ORG|${git_org_url}|g" \
        -e "s|YOUR_OUTPUT_LANGUAGE|${output_language}|g" \
        "$review_template" > "$review_target"

    if [[ -f "$review_target" ]]; then
      log_success "$project: code review workflow created at $review_target" "ci"
      log_info "Required secret: ANTHROPIC_API_KEY (add in repo Settings > Secrets)" "ci"
    fi
  fi
}
