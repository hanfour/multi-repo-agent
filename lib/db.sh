#!/usr/bin/env bash
# Database management: db.json read/write, import dumps, verify connections

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

get_db_json_path() {
  local workspace="$1"
  echo "$workspace/.collab/db.json"
}

db_json_exists() {
  local workspace="$1"
  [[ -f "$(get_db_json_path "$workspace")" ]]
}

# ---------------------------------------------------------------------------
# Decompress dump file
# Supports: .sql, .sql.gz, .sql.bz2, .sql.xz, .sql.zst, .dump
# Returns the path to a decompressed .sql file (caller is responsible for
# removing the temp file if the returned path differs from the input path).
# ---------------------------------------------------------------------------

decompress_dump() {
  local source="$1"

  if [[ ! -f "$source" ]]; then
    log_error "dump file not found: $source" "db"
    return 1
  fi

  case "$source" in
    *.sql)
      echo "$source"
      ;;
    *.sql.gz)
      local tmp
      tmp=$(mktemp /tmp/mra_dump_XXXXXX.sql)
      gunzip -c "$source" > "$tmp"
      echo "$tmp"
      ;;
    *.sql.bz2)
      local tmp
      tmp=$(mktemp /tmp/mra_dump_XXXXXX.sql)
      bunzip2 -c "$source" > "$tmp"
      echo "$tmp"
      ;;
    *.sql.xz)
      local tmp
      tmp=$(mktemp /tmp/mra_dump_XXXXXX.sql)
      xz -d -c "$source" > "$tmp"
      echo "$tmp"
      ;;
    *.sql.zst)
      local tmp
      tmp=$(mktemp /tmp/mra_dump_XXXXXX.sql)
      zstd -d -c "$source" > "$tmp"
      echo "$tmp"
      ;;
    *.dump)
      # pg_restore output — return as-is for pg_restore pipeline use
      echo "$source"
      ;;
    *)
      log_error "unsupported dump extension: $source" "db"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Import a dump into a running DB container
# ---------------------------------------------------------------------------

import_dump() {
  local engine="$1"
  local container_name="$2"
  local db_name="$3"
  local dump_path="$4"
  local password="${5:-mra_password}"

  log_progress "importing dump into $container_name ($engine)…" "db"

  case "$engine" in
    mysql)
      docker exec -i "$container_name" \
        mysql -uroot -p"$password" "$db_name" < "$dump_path"
      ;;
    postgres|postgresql)
      if [[ "$dump_path" == *.dump ]]; then
        docker exec -i "$container_name" \
          pg_restore -U postgres -d "$db_name" < "$dump_path"
      else
        docker exec -i "$container_name" \
          psql -U postgres "$db_name" < "$dump_path"
      fi
      ;;
    *)
      log_error "unsupported engine: $engine" "db"
      return 1
      ;;
  esac

  log_success "dump imported into $db_name" "db"
}

# ---------------------------------------------------------------------------
# Start a DB container via docker run
# ---------------------------------------------------------------------------

start_db_container() {
  local db_name="$1"
  local engine="$2"
  local version="$3"
  local port="$4"
  local password="${5:-mra_password}"

  local container_name="mra-db-$db_name"

  # If the container is already running, do nothing
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    log_info "container $container_name already running" "db"
    return 0
  fi

  # Remove stopped container with the same name if present
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    log_progress "removing stopped container $container_name" "db"
    docker rm "$container_name" >/dev/null
  fi

  log_progress "starting $engine:$version container for $db_name on port $port" "db"

  case "$engine" in
    mysql)
      docker run -d \
        --name "$container_name" \
        -e MYSQL_ROOT_PASSWORD="$password" \
        -e MYSQL_DATABASE="$db_name" \
        -p "${port}:3306" \
        "mysql:${version}" >/dev/null
      ;;
    postgres|postgresql)
      docker run -d \
        --name "$container_name" \
        -e POSTGRES_PASSWORD="$password" \
        -e POSTGRES_DB="$db_name" \
        -p "${port}:5432" \
        "postgres:${version}" >/dev/null
      ;;
    *)
      log_error "unsupported engine: $engine" "db"
      return 1
      ;;
  esac

  log_success "container $container_name started" "db"
}

# ---------------------------------------------------------------------------
# Check if DB container is running and connectable
# ---------------------------------------------------------------------------

check_db_health() {
  local db_name="$1"
  local engine="$2"
  local port="$3"
  local password="${4:-mra_password}"

  local container_name="mra-db-$db_name"

  # Check container is running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    log_error "$db_name: container not running" "db"
    return 1
  fi

  # Attempt connection
  case "$engine" in
    mysql)
      if docker exec "$container_name" \
          mysql -uroot -p"$password" -e "SELECT 1" "$db_name" &>/dev/null; then
        log_success "$db_name: connectable" "db"
        return 0
      else
        log_error "$db_name: cannot connect" "db"
        return 1
      fi
      ;;
    postgres|postgresql)
      if docker exec "$container_name" \
          psql -U postgres -c "SELECT 1" "$db_name" &>/dev/null; then
        log_success "$db_name: connectable" "db"
        return 0
      else
        log_error "$db_name: cannot connect" "db"
        return 1
      fi
      ;;
    *)
      log_error "unsupported engine: $engine" "db"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Wait for DB to be ready (retry loop, max 30 seconds)
# ---------------------------------------------------------------------------

_wait_for_db() {
  local db_name="$1"
  local engine="$2"
  local port="$3"
  local password="${4:-mra_password}"

  log_progress "waiting for $db_name to be ready…" "db"
  local elapsed=0
  while [[ $elapsed -lt 30 ]]; do
    if check_db_health "$db_name" "$engine" "$port" "$password" &>/dev/null; then
      log_success "$db_name: ready" "db"
      return 0
    fi
    sleep 2
    ((elapsed += 2))
  done
  log_error "$db_name: did not become ready within 30 seconds" "db"
  return 1
}

# ---------------------------------------------------------------------------
# Resolve dump source: download if URL, resolve relative path
# ---------------------------------------------------------------------------

_resolve_source() {
  local source="$1"
  local workspace="$2"

  if [[ "$source" == http://* || "$source" == https://* ]]; then
    local filename
    filename=$(basename "$source")
    local tmp="/tmp/mra_download_${filename}"
    log_progress "downloading dump from $source" "db"
    curl -fsSL "$source" -o "$tmp"
    echo "$tmp"
  elif [[ "$source" != /* ]]; then
    # Relative path — resolve against workspace
    echo "$workspace/$source"
  else
    echo "$source"
  fi
}

# ---------------------------------------------------------------------------
# Interactive DB setup
# ---------------------------------------------------------------------------

interactive_db_setup() {
  local workspace="$1"
  local db_json_path
  db_json_path=$(get_db_json_path "$workspace")

  log_progress "scanning workspace for docker-compose files…" "db"

  local databases_json="{}"

  # Find docker-compose files
  local compose_files=()
  while IFS= read -r f; do
    compose_files+=("$f")
  done < <(find "$workspace" -maxdepth 3 -name "docker-compose*.yml" 2>/dev/null | sort)

  if [[ ${#compose_files[@]} -eq 0 ]]; then
    log_warn "no docker-compose files found in workspace" "db"
  fi

  for compose_file in "${compose_files[@]}"; do
    log_info "scanning: $compose_file" "db"

    # Extract mysql/postgres services using yq if available, else grep heuristic
    local services=()
    if command -v yq &>/dev/null; then
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local image
        image=$(yq e ".services.${svc}.image // \"\"" "$compose_file" 2>/dev/null || true)
        if [[ "$image" == mysql* || "$image" == postgres* || "$image" == mariadb* ]]; then
          services+=("$svc:$image")
        fi
      done < <(yq e '.services | keys | .[]' "$compose_file" 2>/dev/null || true)
    else
      # Fallback: grep for mysql/postgres image lines
      while IFS= read -r line; do
        [[ "$line" =~ image:\ *(mysql|postgres|mariadb) ]] || continue
        services+=("db:${BASH_REMATCH[1]}")
      done < "$compose_file"
    fi

    for svc_entry in "${services[@]}"; do
      local svc_name="${svc_entry%%:*}"
      local svc_image="${svc_entry#*:}"

      local engine="mysql"
      local default_port=3306
      if [[ "$svc_image" == postgres* ]]; then
        engine="postgres"
        default_port=5432
      fi

      local version="latest"
      if [[ "$svc_image" =~ :([0-9][^[:space:]]*) ]]; then
        version="${BASH_REMATCH[1]}"
      fi

      printf "\n[db] Found %s service '%s' (%s)\n" "$engine" "$svc_name" "$svc_image"
      printf "  Database name [%s]: " "$svc_name"
      read -r db_name_input < /dev/tty
      local db_name="${db_name_input:-$svc_name}"

      printf "  Port [%s]: " "$default_port"
      read -r port_input < /dev/tty
      local db_port="${port_input:-$default_port}"

      printf "  Dump source path or URL (leave blank to skip): "
      read -r dump_source < /dev/tty

      printf "  Used by (comma-separated project names, optional): "
      read -r used_by_input < /dev/tty

      local used_by_array="[]"
      if [[ -n "$used_by_input" ]]; then
        used_by_array=$(echo "$used_by_input" | tr ',' '\n' | jq -Rn '[inputs | select(length > 0) | ltrimstr(" ") | rtrimstr(" ")]')
      fi

      databases_json=$(echo "$databases_json" | jq \
        --arg name "$db_name" \
        --arg engine "$engine" \
        --arg version "$version" \
        --arg source "$dump_source" \
        --argjson port "$db_port" \
        --argjson usedBy "$used_by_array" \
        '.[$name] = {
          "engine": $engine,
          "version": $version,
          "source": $source,
          "port": $port,
          "usedBy": $usedBy
        }')
    done
  done

  if [[ "$databases_json" == "{}" ]]; then
    log_warn "no databases discovered — db.json will be empty" "db"
  fi

  mkdir -p "$(dirname "$db_json_path")"
  echo "{\"databases\": $databases_json}" | jq '.' > "$db_json_path"
  log_success "db.json written: $db_json_path" "db"
}

# ---------------------------------------------------------------------------
# Setup all databases from db.json
# ---------------------------------------------------------------------------

setup_all_databases() {
  local workspace="$1"
  local db_json_path
  db_json_path=$(get_db_json_path "$workspace")

  if [[ ! -f "$db_json_path" ]]; then
    log_error "db.json not found: $db_json_path" "db"
    return 1
  fi

  local db_names=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    db_names+=("$name")
  done < <(jq -r '.databases | keys[]' "$db_json_path")

  if [[ ${#db_names[@]} -eq 0 ]]; then
    log_warn "no databases defined in db.json" "db"
    return 0
  fi

  for db_name in "${db_names[@]}"; do
    local engine version port source
    engine=$(jq -r --arg n "$db_name" '.databases[$n].engine' "$db_json_path")
    version=$(jq -r --arg n "$db_name" '.databases[$n].version' "$db_json_path")
    port=$(jq -r --arg n "$db_name" '.databases[$n].port' "$db_json_path")
    source=$(jq -r --arg n "$db_name" '.databases[$n].source // ""' "$db_json_path")

    log_progress "setting up database: $db_name ($engine:$version)" "db"

    # Start container
    if ! start_db_container "$db_name" "$engine" "$version" "$port"; then
      log_error "failed to start container for $db_name" "db"
      continue
    fi

    # Wait for health
    if ! _wait_for_db "$db_name" "$engine" "$port"; then
      log_error "database $db_name did not become healthy" "db"
      continue
    fi

    # Import dump if source is set
    if [[ -n "$source" && "$source" != "null" ]]; then
      local resolved_source
      resolved_source=$(_resolve_source "$source" "$workspace")

      if [[ ! -f "$resolved_source" ]]; then
        log_warn "dump file not found: $resolved_source (skipping import)" "db"
        continue
      fi

      local decompressed
      decompressed=$(decompress_dump "$resolved_source") || continue

      local container_name="mra-db-$db_name"
      import_dump "$engine" "$container_name" "$db_name" "$decompressed" || true

      # Clean up temp file if different from resolved_source
      if [[ "$decompressed" != "$resolved_source" && -f "$decompressed" ]]; then
        rm -f "$decompressed"
      fi

      # Clean up downloaded file if it was a URL
      if [[ "$source" == http://* || "$source" == https://* && -f "$resolved_source" ]]; then
        rm -f "$resolved_source"
      fi
    fi

    log_success "database $db_name ready" "db"
  done
}

# ---------------------------------------------------------------------------
# Re-import a specific database
# ---------------------------------------------------------------------------

reimport_database() {
  local workspace="$1"
  local db_name="$2"
  local db_json_path
  db_json_path=$(get_db_json_path "$workspace")

  if [[ ! -f "$db_json_path" ]]; then
    log_error "db.json not found" "db"
    return 1
  fi

  local engine port source
  engine=$(jq -r --arg n "$db_name" '.databases[$n].engine // ""' "$db_json_path")
  port=$(jq -r --arg n "$db_name" '.databases[$n].port // ""' "$db_json_path")
  source=$(jq -r --arg n "$db_name" '.databases[$n].source // ""' "$db_json_path")

  if [[ -z "$engine" || "$engine" == "null" ]]; then
    log_error "database '$db_name' not found in db.json" "db"
    return 1
  fi

  if [[ -z "$source" || "$source" == "null" ]]; then
    log_error "no source defined for $db_name" "db"
    return 1
  fi

  local resolved_source
  resolved_source=$(_resolve_source "$source" "$workspace")

  if [[ ! -f "$resolved_source" ]]; then
    log_error "dump file not found: $resolved_source" "db"
    return 1
  fi

  local decompressed
  decompressed=$(decompress_dump "$resolved_source") || return 1

  local container_name="mra-db-$db_name"
  import_dump "$engine" "$container_name" "$db_name" "$decompressed"

  if [[ "$decompressed" != "$resolved_source" && -f "$decompressed" ]]; then
    rm -f "$decompressed"
  fi
}

# ---------------------------------------------------------------------------
# List databases from db.json
# ---------------------------------------------------------------------------

list_databases() {
  local workspace="$1"
  local db_json_path
  db_json_path=$(get_db_json_path "$workspace")

  if [[ ! -f "$db_json_path" ]]; then
    log_warn "db.json not found — run: mra db setup" "db"
    return 0
  fi

  local db_names=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    db_names+=("$name")
  done < <(jq -r '.databases | keys[]' "$db_json_path")

  if [[ ${#db_names[@]} -eq 0 ]]; then
    log_warn "no databases defined in db.json" "db"
    return 0
  fi

  printf "\n%-20s %-12s %-8s %-8s %s\n" "NAME" "ENGINE" "VERSION" "PORT" "STATUS"
  printf "%s\n" "--------------------------------------------------------------------------------"

  for db_name in "${db_names[@]}"; do
    local engine version port container_name status
    engine=$(jq -r --arg n "$db_name" '.databases[$n].engine' "$db_json_path")
    version=$(jq -r --arg n "$db_name" '.databases[$n].version' "$db_json_path")
    port=$(jq -r --arg n "$db_name" '.databases[$n].port' "$db_json_path")
    container_name="mra-db-$db_name"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
      status="running"
    else
      status="stopped"
    fi

    printf "%-20s %-12s %-8s %-8s %s\n" "$db_name" "$engine" "$version" "$port" "$status"
  done

  printf "\n"
}
