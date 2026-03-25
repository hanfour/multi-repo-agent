#!/usr/bin/env bash
# Environment verification: tools, databases, projects
#
# Data-returning functions (doctor_basic, doctor_databases, doctor_projects)
# send all human-readable log output to stderr and write only "pass fail [warn]"
# counts to stdout so callers can capture them cleanly.

# ---------------------------------------------------------------------------
# Level 1: Basic checks (preflight + docker daemon)
# ---------------------------------------------------------------------------

doctor_basic() {
  local pass=0 fail=0

  log_info "=== Basic Checks ===" "doctor" >&2

  local tools=("git" "docker" "jq" "gh")
  for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      log_success "$tool: ok" "check" >&2
      ((pass++))
    else
      log_error "$tool: not found" "check" >&2
      ((fail++))
    fi
  done

  # yq (optional — warn but don't count as failure)
  if command -v yq &>/dev/null; then
    log_success "yq: ok" "check" >&2
    ((pass++))
  else
    log_warn "yq: not found (brew install yq)" "check" >&2
  fi

  # Docker daemon
  if docker info &>/dev/null 2>&1; then
    log_success "docker daemon: running" "check" >&2
    ((pass++))
  else
    log_error "docker daemon: not running" "check" >&2
    ((fail++))
  fi

  echo "$pass $fail"
}

# ---------------------------------------------------------------------------
# Level 2: Database checks
# ---------------------------------------------------------------------------

doctor_databases() {
  local workspace="$1"
  local pass=0 fail=0 warn=0

  log_info "=== Database Checks ===" "doctor" >&2

  local db_json_path
  db_json_path=$(get_db_json_path "$workspace")

  if [[ ! -f "$db_json_path" ]]; then
    log_warn "db.json not found — run: mra db setup" "doctor" >&2
    echo "$pass $fail $warn"
    return 0
  fi

  local db_names=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    db_names+=("$name")
  done < <(jq -r '.databases | keys[]' "$db_json_path")

  if [[ ${#db_names[@]} -eq 0 ]]; then
    log_warn "no databases defined in db.json" "doctor" >&2
    echo "$pass $fail $warn"
    return 0
  fi

  for db_name in "${db_names[@]}"; do
    local engine version port password container_name
    engine=$(jq -r --arg n "$db_name" '.databases[$n].engine' "$db_json_path")
    version=$(jq -r --arg n "$db_name" '.databases[$n].version // "latest"' "$db_json_path")
    port=$(jq -r --arg n "$db_name" '.databases[$n].port' "$db_json_path")
    password=$(jq -r --arg n "$db_name" '.databases[$n].password // "mra_password"' "$db_json_path")
    container_name="mra-db-$db_name"

    # --- Container running? ---
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
      log_success "$db_name ($engine:$version): running" "check" >&2
      ((pass++))
    else
      log_error "$db_name ($engine:$version): not running" "check" >&2
      ((fail++))
      printf "  Offer: run 'mra db setup' to start container\n" >&2
      continue
    fi

    # --- Connectable? (test connection only, no specific DB) ---
    local connectable=false
    case "$engine" in
      mysql)
        if docker exec "$container_name" \
            mysql -uroot -p"$password" -e "SELECT 1" &>/dev/null; then
          connectable=true
        fi
        ;;
      postgres|postgresql)
        if docker exec "$container_name" \
            psql -U postgres -c "SELECT 1" &>/dev/null; then
          connectable=true
        fi
        ;;
    esac

    if $connectable; then
      log_success "$db_name: connectable" "check" >&2
      ((pass++))
    else
      log_error "$db_name: cannot connect" "check" >&2
      ((fail++))
      continue
    fi

    # --- Determine if instance uses multi-schema format ---
    local has_schemas
    has_schemas=$(jq -r --arg n "$db_name" '.databases[$n].schemas // empty | length' "$db_json_path" 2>/dev/null || echo "0")

    if [[ -n "$has_schemas" && "$has_schemas" != "0" ]]; then
      # Multi-schema format: iterate each schema
      local schema_names=()
      while IFS= read -r schema; do
        [[ -z "$schema" ]] && continue
        schema_names+=("$schema")
      done < <(jq -r --arg n "$db_name" '.databases[$n].schemas | keys[]' "$db_json_path")

      for schema_name in "${schema_names[@]}"; do
        local schema_source
        schema_source=$(jq -r --arg n "$db_name" --arg s "$schema_name" \
          '.databases[$n].schemas[$s].source // ""' "$db_json_path")

        # --- Tables exist in this schema? ---
        local table_count=0
        case "$engine" in
          mysql)
            table_count=$(docker exec "$container_name" \
              mysql -uroot -p"$password" -N -B -e "SHOW TABLES;" "$schema_name" 2>/dev/null \
              | wc -l | tr -d ' ' || echo "0")
            ;;
          postgres|postgresql)
            table_count=$(docker exec "$container_name" \
              psql -U postgres -t -c "\dt" "$schema_name" 2>/dev/null \
              | grep -c '|' || echo "0")
            ;;
        esac

        if [[ "$table_count" -gt 0 ]]; then
          log_success "$db_name/$schema_name: $table_count tables" "check" >&2
          ((pass++))
        else
          log_warn "$db_name/$schema_name: 0 tables (dump not imported?)" "check" >&2
          ((warn++))
        fi

        # --- Dump file exists for this schema? ---
        if [[ -n "$schema_source" && "$schema_source" != "null" ]]; then
          if [[ "$schema_source" == http://* || "$schema_source" == https://* ]]; then
            log_info "$db_name/$schema_name: source is a URL ($schema_source)" "check" >&2
            ((pass++))
          else
            local resolved_source
            if [[ "$schema_source" != /* ]]; then
              resolved_source="$workspace/$schema_source"
            else
              resolved_source="$schema_source"
            fi

            if [[ -f "$resolved_source" ]]; then
              log_success "$db_name/$schema_name: dump file exists" "check" >&2
              ((pass++))
            else
              log_warn "$db_name/$schema_name: dump file not found ($resolved_source)" "check" >&2
              ((warn++))
            fi
          fi
        fi
      done
    else
      # Backward-compatible single-DB format: check instance as single DB
      local source
      source=$(jq -r --arg n "$db_name" '.databases[$n].source // ""' "$db_json_path")

      # --- Tables exist? ---
      local table_count=0
      case "$engine" in
        mysql)
          table_count=$(docker exec "$container_name" \
            mysql -uroot -p"$password" -N -B -e "SHOW TABLES;" "$db_name" 2>/dev/null \
            | wc -l | tr -d ' ' || echo "0")
          ;;
        postgres|postgresql)
          table_count=$(docker exec "$container_name" \
            psql -U postgres -t -c "\dt" "$db_name" 2>/dev/null \
            | grep -c '|' || echo "0")
          ;;
      esac

      if [[ "$table_count" -gt 0 ]]; then
        log_success "$db_name: $table_count tables" "check" >&2
        ((pass++))
      else
        log_warn "$db_name: 0 tables (dump not imported?)" "check" >&2
        ((warn++))
      fi

      # --- Dump file exists? ---
      if [[ -n "$source" && "$source" != "null" ]]; then
        if [[ "$source" == http://* || "$source" == https://* ]]; then
          log_info "$db_name: source is a URL ($source)" "check" >&2
          ((pass++))
        else
          local resolved_source
          if [[ "$source" != /* ]]; then
            resolved_source="$workspace/$source"
          else
            resolved_source="$source"
          fi

          if [[ -f "$resolved_source" ]]; then
            log_success "$db_name: dump file exists" "check" >&2
            ((pass++))
          else
            log_warn "$db_name: dump file not found ($resolved_source)" "check" >&2
            ((warn++))
          fi
        fi
      fi
    fi
  done

  echo "$pass $fail $warn"
}

# ---------------------------------------------------------------------------
# Level 3: Project checks
# ---------------------------------------------------------------------------

doctor_projects() {
  local workspace="$1"
  local filter_project="${2:-}"
  local pass=0 fail=0 warn=0

  log_info "=== Project Checks ===" "doctor" >&2

  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")

  if [[ ! -f "$graph_file" ]]; then
    log_warn "dep-graph.json not found — run: mra init" "doctor" >&2
    echo "$pass $fail $warn"
    return 0
  fi

  # Build project list from repos.json (clone=true) or dep-graph fallback
  local repos_json_path
  repos_json_path=$(get_repos_json_path "$workspace")

  local projects=()
  if [[ -f "$repos_json_path" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      [[ -n "$filter_project" && "$name" != "$filter_project" ]] && continue
      projects+=("$name")
    done < <(jq -r '.repos[] | select(.clone == true) | .name' "$repos_json_path")
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      [[ -n "$filter_project" && "$name" != "$filter_project" ]] && continue
      projects+=("$name")
    done < <(jq -r '.projects | keys[]' "$graph_file")
  fi

  if [[ ${#projects[@]} -eq 0 ]]; then
    log_warn "no projects to check" "doctor" >&2
    echo "$pass $fail $warn"
    return 0
  fi

  for proj in "${projects[@]}"; do
    local proj_dir="$workspace/$proj"

    # --- Directory exists? ---
    if [[ -d "$proj_dir" ]]; then
      log_success "$proj: directory exists" "check" >&2
      ((pass++))
    else
      log_error "$proj: directory not found ($proj_dir)" "check" >&2
      ((fail++))
      continue
    fi

    # Determine project type
    local proj_type
    proj_type=$(jq -r --arg p "$proj" '.projects[$p].type // "unknown"' "$graph_file" 2>/dev/null || echo "unknown")
    if [[ -z "$proj_type" || "$proj_type" == "null" ]]; then
      proj_type=$(detect_project_type "$proj_dir")
    fi

    # Type-specific checks (report only, do not fix)
    case "$proj_type" in
      rails-api)
        if docker compose -f "$proj_dir/docker-compose.yml" run --rm \
            "$(basename "$proj_dir")" bundle check &>/dev/null 2>&1; then
          log_success "$proj: bundle check ok" "check" >&2
          ((pass++))
        else
          log_warn "$proj: bundle check failed (gems may need installing)" "check" >&2
          ((warn++))
        fi

        if docker compose -f "$proj_dir/docker-compose.yml" run --rm \
            "$(basename "$proj_dir")" rake db:migrate:status &>/dev/null 2>&1; then
          log_success "$proj: db:migrate:status ok" "check" >&2
          ((pass++))
        else
          log_warn "$proj: db:migrate:status failed (pending migrations?)" "check" >&2
          ((warn++))
        fi
        ;;

      node-frontend|node-backend|nextjs)
        if [[ -d "$proj_dir/node_modules" ]]; then
          log_success "$proj: node_modules exists" "check" >&2
          ((pass++))
        else
          log_warn "$proj: node_modules missing (run npm/pnpm install)" "check" >&2
          ((warn++))
        fi
        ;;

      go-service)
        if (cd "$proj_dir" && go build ./... &>/dev/null 2>&1); then
          log_success "$proj: go build ok" "check" >&2
          ((pass++))
        else
          log_warn "$proj: go build failed" "check" >&2
          ((warn++))
        fi
        ;;

      python-service)
        if (cd "$proj_dir" && pip check &>/dev/null 2>&1); then
          log_success "$proj: pip check ok" "check" >&2
          ((pass++))
        else
          log_warn "$proj: pip check failed (dependencies missing?)" "check" >&2
          ((warn++))
        fi
        ;;

      *)
        log_info "$proj: type '$proj_type' — no specific checks" "check" >&2
        ;;
    esac
  done

  echo "$pass $fail $warn"
}

# ---------------------------------------------------------------------------
# Main entry: run all 3 levels
# ---------------------------------------------------------------------------

run_doctor() {
  local workspace="$1"
  local filter_project="${2:-}"

  local total_pass=0 total_fail=0 total_warn=0

  # Level 1: Basic
  local basic_result
  basic_result=$(doctor_basic)
  local basic_pass basic_fail
  basic_pass=$(echo "$basic_result" | awk '{print $1}')
  basic_fail=$(echo "$basic_result" | awk '{print $2}')
  ((total_pass += basic_pass)) || true
  ((total_fail += basic_fail)) || true

  # Level 2: Databases
  local db_result
  db_result=$(doctor_databases "$workspace")
  local db_pass db_fail db_warn
  db_pass=$(echo "$db_result" | awk '{print $1}')
  db_fail=$(echo "$db_result" | awk '{print $2}')
  db_warn=$(echo "$db_result" | awk '{print $3}')
  ((total_pass += db_pass)) || true
  ((total_fail += db_fail)) || true
  ((total_warn += db_warn)) || true

  # Level 3: Projects
  local proj_result
  proj_result=$(doctor_projects "$workspace" "$filter_project")
  local proj_pass proj_fail proj_warn
  proj_pass=$(echo "$proj_result" | awk '{print $1}')
  proj_fail=$(echo "$proj_result" | awk '{print $2}')
  proj_warn=$(echo "$proj_result" | awk '{print $3}')
  ((total_pass += proj_pass)) || true
  ((total_fail += proj_fail)) || true
  ((total_warn += proj_warn)) || true

  # Summary
  log_info "=== Summary ===" "doctor"
  if [[ $total_fail -eq 0 && $total_warn -eq 0 ]]; then
    log_success "$total_pass passed, $total_warn warnings, $total_fail errors" "doctor"
  elif [[ $total_fail -gt 0 ]]; then
    log_error "$total_pass passed, $total_warn warnings, $total_fail errors" "doctor"
  else
    log_warn "$total_pass passed, $total_warn warnings, $total_fail errors" "doctor"
  fi
}
