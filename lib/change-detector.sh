#!/usr/bin/env bash
# API change detection matrix
# Determines if changes require integration testing or mock testing

# High confidence file patterns that trigger integration tests
is_api_change() {
  local project_dir="$1"
  local project_type="$2"
  local mode="${3:-range}"
  local range_expr="${4:-}"

  local default_branch
  default_branch=$(get_default_branch "$project_dir" 2>/dev/null || echo "main")
  # Back-compat: no explicit range in range mode → default to "<default_branch>...HEAD".
  if [[ "$mode" != "working" && -z "$range_expr" ]]; then
    range_expr="${default_branch}...HEAD"
  fi
  # Revision arg for content (pathspec) diffs: HEAD for working, else the range expression.
  local diff_rev="$range_expr"
  [[ "$mode" == "working" ]] && diff_rev="HEAD"

  # Get list of changed files (mode-aware, via the single diff source of truth)
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")

  if [[ -z "$changed_files" ]]; then
    echo "none"
    return 0
  fi

  local high_confidence=false
  local reasons=()

  case "$project_type" in
    rails-api)
      if echo "$changed_files" | grep -q "^config/routes.rb$"; then
        high_confidence=true; reasons+=("routes.rb changed")
      fi
      if echo "$changed_files" | grep -E "^app/controllers/" | grep -qvE "concerns/"; then
        local ctrl_diff
        ctrl_diff=$(git -C "$project_dir" diff "$diff_rev" -- "app/controllers/" 2>/dev/null)
        if echo "$ctrl_diff" | grep -qE "^\+.*def (index|show|create|update|destroy|search)"; then
          high_confidence=true; reasons+=("controller public method changed")
        elif echo "$ctrl_diff" | grep -qE "^\+.*(get|post|put|patch|delete) "; then
          high_confidence=true; reasons+=("route definition in controller")
        fi
      fi
      if echo "$changed_files" | grep -qE "^app/serializers/"; then
        high_confidence=true; reasons+=("serializer changed")
      fi
      if echo "$changed_files" | grep -q "^db/schema.rb$"; then
        local schema_diff
        schema_diff=$(git -C "$project_dir" diff "$diff_rev" -- "db/schema.rb" 2>/dev/null)
        if echo "$schema_diff" | grep -qE "^\+.*t\.(string|integer|text|boolean|datetime|decimal|float|json|jsonb|references)"; then
          high_confidence=true; reasons+=("schema column added/changed")
        fi
      fi
      ;;

    node-backend|node-frontend|nextjs)
      if echo "$changed_files" | grep -qE "^src/routes/"; then
        high_confidence=true; reasons+=("route files changed")
      fi
      if echo "$changed_files" | grep -q "openapi.yaml\|openapi.json"; then
        high_confidence=true; reasons+=("OpenAPI spec changed")
      fi
      if echo "$changed_files" | grep -qE "^src/(types|interfaces)/"; then
        high_confidence=true; reasons+=("type/interface definitions changed")
      fi
      if echo "$changed_files" | grep -qE "^src/validation/"; then
        high_confidence=true; reasons+=("validation rules changed")
      fi
      ;;
  esac

  # Common triggers (any project type)
  if echo "$changed_files" | grep -q "^\.env\.example$\|^env\.example$"; then
    local env_diff
    env_diff=$(git -C "$project_dir" diff "$diff_rev" -- ".env.example" "env.example" 2>/dev/null)
    if echo "$env_diff" | grep -qE "^\+.*(KEY|TOKEN|SECRET|HEADER|AUTH)"; then
      high_confidence=true; reasons+=("new required env var (auth/key)")
    fi
  fi
  if echo "$changed_files" | grep -qE "docker-compose.*\.(yml|yaml)$"; then
    high_confidence=true; reasons+=("docker-compose changed")
  fi

  if [[ "$high_confidence" == "true" ]]; then
    echo "high|${reasons[*]}"
  else
    echo "low"
  fi
}

# Determine which downstream projects need integration testing
get_affected_consumers() {
  local workspace="$1" project="$2"
  local graph_file="$workspace/.collab/dep-graph.json"

  if [[ ! -f "$graph_file" ]]; then
    return
  fi

  jq -r --arg p "$project" '.projects[$p].consumedBy // [] | .[]' "$graph_file" 2>/dev/null
}
