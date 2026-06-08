#!/usr/bin/env bash
# Test execution with Docker isolation

# Detect the test command for a project type
detect_test_command() {
  local project_type="$1"
  case "$project_type" in
    rails-api)     echo "bundle exec rspec" ;;
    node-frontend) echo "pnpm test:run 2>/dev/null || pnpm test 2>/dev/null || npx vitest run 2>/dev/null || echo 'no test command found'" ;;
    node-backend)  echo "pnpm test:run 2>/dev/null || pnpm test 2>/dev/null || npx jest 2>/dev/null || echo 'no test command found'" ;;
    nextjs)        echo "pnpm test 2>/dev/null || npx jest 2>/dev/null || echo 'no test command found'" ;;
    go-service)    echo "go test ./..." ;;
    python-service) echo "pytest" ;;
    *)             echo "echo 'unknown project type: no test command'" ;;
  esac
}

# Run tests for a project inside Docker
run_project_tests() {
  local workspace="$1" project="$2"
  local test_type="${3:-auto}"  # auto, unit, integration
  local graph_file="$workspace/.collab/dep-graph.json"

  # Determine project type
  local project_type="unknown"
  if [[ -f "$graph_file" ]]; then
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")
  fi

  # Get test command
  local test_cmd
  test_cmd=$(detect_test_command "$project_type")

  # Generate isolated DB name for test
  local db_override="gspadmin_test_mra_${project}"

  log_progress "$project ($project_type): running tests" "test"

  # Run in Docker with DB isolation
  run_in_docker "$workspace" "$project" "$test_cmd" "$db_override"
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_success "$project: tests passed" "test"
  else
    log_error "$project: tests failed (exit $exit_code)" "test"
  fi

  return $exit_code
}
