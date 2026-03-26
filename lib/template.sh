#!/usr/bin/env bash
generate_template() {
  local workspace="$1" template_type="${2:-all}"
  local collab_dir="$workspace/.collab"
  mkdir -p "$collab_dir"

  case "$template_type" in
    repos|all)
      if [[ ! -f "$collab_dir/repos.json" ]]; then
        cat > "$collab_dir/repos.json.template" <<'TMPL'
{
  "repos": [
    { "name": "example-api", "clone": true, "branch": "main", "description": "Backend API", "archived": false },
    { "name": "example-ui", "clone": true, "branch": "main", "description": "Frontend app", "archived": false },
    { "name": "example-old", "clone": false, "branch": "main", "description": "Deprecated", "archived": true }
  ]
}
TMPL
        log_success "repos.json.template created" "template"
      else
        log_info "repos.json already exists, skipping" "template"
      fi
      ;;&
    db|all)
      if [[ ! -f "$collab_dir/db.json" ]]; then
        cat > "$collab_dir/db.json.template" <<'TMPL'
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "8.0",
      "platform": "",
      "port": 3306,
      "password": "dev_password",
      "schemas": {
        "myapp": {
          "source": "./dumps/myapp.sql.gz",
          "usedBy": ["example-api"]
        }
      }
    }
  }
}
TMPL
        log_success "db.json.template created" "template"
      else
        log_info "db.json already exists, skipping" "template"
      fi
      ;;&
    deps|all)
      if [[ ! -f "$collab_dir/manual-deps.json" ]]; then
        cat > "$collab_dir/manual-deps.json.template" <<'TMPL'
[
  { "source": "example-ui", "target": "example-api", "type": "api" }
]
TMPL
        log_success "manual-deps.json.template created" "template"
      else
        log_info "manual-deps.json already exists, skipping" "template"
      fi
      ;;&
    all) ;;
    *)
      log_error "unknown template: $template_type (use: repos, db, deps, all)" "template"
      return 1
      ;;
  esac

  log_success "templates generated in $collab_dir" "template"
}
