#!/usr/bin/env bash
# Export project context files for external tools (reqbot-slack, etc.)

export_project() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local export_dir="$workspace/.collab/exports"
  local export_file="$export_dir/$project-context.md"
  local graph_file="$workspace/.collab/dep-graph.json"

  if [[ ! -d "$project_dir" ]]; then
    log_error "$project: directory not found" "export"
    return 1
  fi

  mkdir -p "$export_dir"

  local project_type="unknown"
  if [[ -f "$graph_file" ]]; then
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")
  fi

  # Build the context file
  {
    echo "# $project Context"
    echo ""
    echo "Type: $project_type"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # Dependencies from dep-graph
    if [[ -f "$graph_file" ]]; then
      echo "## Dependencies"
      echo ""
      local deps consumedBy
      deps=$(jq -r --arg p "$project" '.projects[$p].deps // {} | to_entries[] | "\(.key): \(.value | join(", "))"' "$graph_file" 2>/dev/null)
      consumedBy=$(jq -r --arg p "$project" '.projects[$p].consumedBy // [] | join(", ")' "$graph_file" 2>/dev/null)
      if [[ -n "$deps" ]]; then echo "$deps"; fi
      if [[ -n "$consumedBy" ]]; then echo "consumedBy: $consumedBy"; fi
      echo ""
    fi

    # Routes/Endpoints
    echo "## API Endpoints"
    echo ""
    case "$project_type" in
      rails-api)
        if [[ -f "$project_dir/config/routes.rb" ]]; then
          echo '```ruby'
          # Extract route definitions (grep for HTTP verbs and resources)
          grep -E '^\s*(get|post|put|patch|delete|resources|resource|namespace|scope|mount)\s' \
            "$project_dir/config/routes.rb" 2>/dev/null | head -100 || echo "# no routes found"
          echo '```'
        else
          echo "(no routes.rb found)"
        fi
        ;;
      node-frontend|node-backend|nextjs)
        # Look for route files
        local route_files
        route_files=$(find "$project_dir/src" -name "*.ts" -path "*/route*" -o -name "*.js" -path "*/route*" 2>/dev/null | head -20)
        if [[ -n "$route_files" ]]; then
          echo "Route files:"
          echo "$route_files" | sed "s|$project_dir/||g"
        else
          echo "(no route files found)"
        fi
        ;;
      *)
        echo "(no endpoint extraction for type: $project_type)"
        ;;
    esac
    echo ""

    # Database schema
    echo "## Database Schema"
    echo ""
    case "$project_type" in
      rails-api)
        if [[ -f "$project_dir/db/schema.rb" ]]; then
          echo '```ruby'
          # Extract table definitions (create_table lines and column lines)
          grep -E '^\s*(create_table|t\.\w+)' "$project_dir/db/schema.rb" 2>/dev/null | head -200 || echo "# no schema found"
          echo '```'
        else
          echo "(no schema.rb found)"
        fi
        ;;
      *)
        echo "(no schema extraction for type: $project_type)"
        ;;
    esac
    echo ""

    # Environment variables
    echo "## Environment Variables"
    echo ""
    local env_file=""
    for candidate in "$project_dir/.env.example" "$project_dir/env.example" "$project_dir/.env.sample"; do
      if [[ -f "$candidate" ]]; then
        env_file="$candidate"
        break
      fi
    done
    if [[ -n "$env_file" ]]; then
      echo '```bash'
      # Strip actual values, show only keys and comments
      sed 's/=.*/=/' "$env_file" | head -50
      echo '```'
    else
      echo "(no .env.example found)"
    fi
    echo ""

    # File structure (top 2 levels)
    echo "## File Structure"
    echo ""
    echo '```'
    # List top-level directories, skip node_modules, vendor, .git
    find "$project_dir" -maxdepth 2 -type d \
      -not -path "*/.git/*" \
      -not -path "*/node_modules/*" \
      -not -path "*/vendor/*" \
      -not -path "*/.git" \
      -not -path "*/node_modules" \
      -not -path "*/vendor" \
      -not -path "*/tmp/*" \
      -not -path "*/log/*" \
      2>/dev/null | sed "s|$project_dir/||g" | sed "s|$project_dir||" | sort | head -50
    echo '```'

  } > "$export_file"

  log_success "$project -> $export_file" "export"
}

export_all_projects() {
  local workspace="$1"
  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")

  if [[ ! -f "$graph_file" ]]; then
    log_error "dep-graph.json not found, run mra init first" "export"
    return 1
  fi

  local count=0
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local project_dir="$workspace/$project"
    [[ ! -d "$project_dir" ]] && continue
    export_project "$workspace" "$project"
    count=$((count + 1))
  done < <(jq -r '.projects | keys[]' "$graph_file")

  log_success "exported $count projects to .collab/exports/" "export"
}
