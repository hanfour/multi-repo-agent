#!/usr/bin/env bash
detect_project_type() {
  local project_dir="$1"
  if [[ -f "$project_dir/Gemfile" && -f "$project_dir/config/routes.rb" ]]; then echo "rails-api"
  elif [[ -f "$project_dir/package.json" ]] && ls "$project_dir"/vite.config.* &>/dev/null 2>&1; then echo "node-frontend"
  elif [[ -f "$project_dir/package.json" ]] && ls "$project_dir"/next.config.* &>/dev/null 2>&1; then echo "nextjs"
  elif [[ -f "$project_dir/package.json" && -f "$project_dir/tsconfig.json" ]]; then echo "node-backend"
  elif [[ -f "$project_dir/go.mod" ]]; then echo "go-service"
  elif [[ -f "$project_dir/requirements.txt" || -f "$project_dir/pyproject.toml" ]]; then echo "python-service"
  else echo "unknown"; fi
}
