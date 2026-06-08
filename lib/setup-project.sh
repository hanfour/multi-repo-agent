#!/usr/bin/env bash
setup_project() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local graph_file="$workspace/.collab/dep-graph.json"
  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "setup"; return 1; }
  local project_type="unknown"
  [[ -f "$graph_file" ]] && project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")
  log_progress "$project ($project_type): setting up" "setup"
  case "$project_type" in
    rails-api)
      log_progress "$project: bundle install" "setup"
      run_in_docker "$workspace" "$project" "bundle install" 2>&1 || log_warn "$project: bundle install failed" "setup"
      log_progress "$project: copying config examples" "setup"
      run_in_docker "$workspace" "$project" 'for f in config/*.example.yml config/*.yml.example; do [ -f "$f" ] && cp -n "$f" "${f/.example/}" 2>/dev/null; done; [ -f env.example ] && cp -n env.example .env 2>/dev/null; true' 2>&1 || true
      log_progress "$project: db:create + db:migrate" "setup"
      run_in_docker "$workspace" "$project" "bundle exec rake db:create db:migrate 2>/dev/null || true" 2>&1 || true
      ;;
    node-frontend|node-backend|nextjs)
      log_progress "$project: installing dependencies" "setup"
      if [[ -f "$project_dir/pnpm-lock.yaml" ]]; then
        run_in_docker "$workspace" "$project" "corepack enable && pnpm install" 2>&1 || log_warn "$project: pnpm install failed" "setup"
      elif [[ -f "$project_dir/package-lock.json" ]]; then
        run_in_docker "$workspace" "$project" "npm install" 2>&1 || log_warn "$project: npm install failed" "setup"
      elif [[ -f "$project_dir/yarn.lock" ]]; then
        run_in_docker "$workspace" "$project" "yarn install" 2>&1 || log_warn "$project: yarn install failed" "setup"
      fi
      [[ -f "$project_dir/.env.example" ]] && { cp -n "$project_dir/.env.example" "$project_dir/.env" 2>/dev/null || true; }
      [[ -f "$project_dir/env.example" ]] && { cp -n "$project_dir/env.example" "$project_dir/.env" 2>/dev/null || true; }
      ;;
    go-service)
      log_progress "$project: go mod download" "setup"
      run_in_docker "$workspace" "$project" "go mod download" 2>&1 || log_warn "$project: go mod download failed" "setup"
      ;;
    python-service)
      log_progress "$project: pip install" "setup"
      run_in_docker "$workspace" "$project" "pip install -r requirements.txt 2>/dev/null || pip install -e . 2>/dev/null || true" 2>&1 || true
      ;;
    *)
      log_info "$project: unknown type, skipping setup" "setup"
      return 0
      ;;
  esac
  log_success "$project: setup complete" "setup"
}

setup_all_projects() {
  local workspace="$1"
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")
  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "setup"; return 1; }
  local count=0
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    [[ ! -d "$workspace/$project" ]] && continue
    setup_project "$workspace" "$project"
    count=$((count + 1))
  done < <(jq -r '.projects | keys[]' "$graph_file")
  log_success "setup complete for $count projects" "setup"
}
