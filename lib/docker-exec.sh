#!/usr/bin/env bash
# Docker execution helpers for running commands in project containers

# Resolve which docker-compose file and service name a project uses
# Scans workspace for docker-compose files that reference the project
resolve_compose_config() {
  local workspace="$1" project="$2"
  local compose_file="" service_name=""

  # Check dep-graph for dockerCompose hint
  local graph_file="$workspace/.collab/dep-graph.json"
  if [[ -f "$graph_file" ]]; then
    compose_file=$(jq -r --arg p "$project" '.projects[$p].dockerCompose // ""' "$graph_file")
    if [[ -n "$compose_file" && "$compose_file" != "null" ]]; then
      compose_file="$workspace/$compose_file"
    fi
  fi

  # Fallback: search for docker-compose files that mention the project
  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    while IFS= read -r f; do
      if grep -q "context:.*$project" "$f" 2>/dev/null || grep -q "/$project:" "$f" 2>/dev/null; then
        compose_file="$f"
        break
      fi
    done < <(find "$workspace" -maxdepth 3 -name "docker-compose*.yml" -o -name "docker-compose*.yaml" 2>/dev/null)
  fi

  # Fallback: check for docker-compose in the project itself
  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    for candidate in "$workspace/$project/docker-compose.yml" "$workspace/$project/docker-compose.yaml"; do
      if [[ -f "$candidate" ]]; then
        compose_file="$candidate"
        break
      fi
    done
  fi

  # Determine service name from compose file
  if [[ -f "$compose_file" ]]; then
    # Look for a service that builds from or mounts the project directory
    service_name=$(grep -B5 "context:.*$project\|/$project:" "$compose_file" 2>/dev/null | grep -E '^\s+\w+:$' | tail -1 | tr -d ' :')
    # Fallback: use project name as service name
    if [[ -z "$service_name" ]]; then
      service_name="$project"
    fi
  fi

  echo "$compose_file|$service_name"
}

# Run a command inside a project's Docker container
# Uses docker compose run (inherits env, network, depends_on)
run_in_docker() {
  local workspace="$1" project="$2" command="$3"
  local db_override="${4:-}"  # optional DB name override for test isolation

  local config
  config=$(resolve_compose_config "$workspace" "$project")
  local compose_file="${config%%|*}"
  local service_name="${config##*|}"

  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    log_error "$project: no docker-compose file found" "docker"
    return 1
  fi

  log_progress "$project: running in Docker ($service_name)" "docker"

  # Build extra env args
  local env_args=()
  if [[ -n "$db_override" ]]; then
    # Override DB name for test isolation
    env_args+=(-e "MYSQL_DATABASE=$db_override")
    env_args+=(-e "DATABASE_NAME=$db_override")
    env_args+=(-e "RAILS_ENV=test")
  fi

  # Read platform from db.json if available
  local db_json="$workspace/.collab/db.json"
  local platform=""
  if [[ -f "$db_json" ]]; then
    platform=$(jq -r '.databases | to_entries[0].value.platform // ""' "$db_json" 2>/dev/null)
  fi

  local platform_args=()
  # Note: platform for docker compose run is set in the compose file, not as a flag
  # We don't add --platform here

  # Run the command
  docker compose -f "$compose_file" run --rm \
    "${env_args[@]}" \
    "$service_name" \
    bash -c "$command" 2>&1

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    log_success "$project: command completed" "docker"
  else
    log_error "$project: command failed (exit $exit_code)" "docker"
  fi
  return $exit_code
}

# Build Docker image for a project
build_docker_image() {
  local workspace="$1" project="$2"

  local config
  config=$(resolve_compose_config "$workspace" "$project")
  local compose_file="${config%%|*}"
  local service_name="${config##*|}"

  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    log_error "$project: no docker-compose file found" "docker"
    return 1
  fi

  log_progress "$project: building Docker image" "docker"
  docker compose -f "$compose_file" build "$service_name" 2>&1

  if [[ $? -eq 0 ]]; then
    log_success "$project: image built" "docker"
  else
    log_error "$project: build failed" "docker"
    return 1
  fi
}

# Start a service container (for integration testing - keeps running)
# Returns container name
start_service_container() {
  local workspace="$1" project="$2"
  local container_name="mra-svc-$project"

  # Check if already running
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    log_info "$project: service already running ($container_name)" "docker"
    echo "$container_name"
    return 0
  fi

  local config
  config=$(resolve_compose_config "$workspace" "$project")
  local compose_file="${config%%|*}"
  local service_name="${config##*|}"

  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    log_error "$project: no docker-compose file found" "docker"
    return 1
  fi

  log_progress "$project: starting service container" "docker"

  # Use docker compose up -d for the service
  docker compose -f "$compose_file" up -d "$service_name" 2>&1

  if [[ $? -eq 0 ]]; then
    log_success "$project: service started" "docker"
    echo "$container_name"
  else
    log_error "$project: failed to start service" "docker"
    return 1
  fi
}

# Stop a service container
stop_service_container() {
  local workspace="$1" project="$2"

  local config
  config=$(resolve_compose_config "$workspace" "$project")
  local compose_file="${config%%|*}"
  local service_name="${config##*|}"

  if [[ -n "$compose_file" && -f "$compose_file" ]]; then
    docker compose -f "$compose_file" stop "$service_name" 2>/dev/null
    log_success "$project: service stopped" "docker"
  fi
}
