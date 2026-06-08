#!/usr/bin/env bash
# Docker execution helpers for running commands in project containers

# --- TM-005: Docker first-time trust gate -----------------------------------
#
# `mra test` and `mra setup` invoke `docker compose run ... bash -c`
# using whatever docker-compose.yml the workspace points at for the
# project. A maliciously-crafted compose file in a checked-out repo
# can mount the developer's home directory, talk to the docker socket,
# or run arbitrary build steps under the local docker daemon. We
# cannot prevent that fully without sandboxing, but we can require the
# operator to acknowledge the risk the first time MRA touches a
# project's Docker config.
#
# Trust state lives in .collab/trusted-projects.json:
#     { "trusted": ["alpha", "beta"] }
#
# Gate behaviour:
#   - If the project is already in the trusted list, pass silently.
#   - Otherwise: interactive shells get a y/N prompt; non-interactive
#     shells refuse unless MRA_DOCKER_TRUST_FORCE=1 is set (e.g. CI
#     after the operator vetted the workspace).
#   - In either path, a compose file resolved to somewhere outside
#     `$workspace/$project/` produces a warning even when the project
#     is trusted — that is a red flag that the trust grant pre-dated
#     the current compose location.

_get_trusted_projects_path() {
  echo "$1/.collab/trusted-projects.json"
}

_is_project_trusted() {
  local workspace="$1" project="$2"
  local trust_file
  trust_file=$(_get_trusted_projects_path "$workspace")
  [[ -f "$trust_file" ]] || return 1
  jq -e --arg p "$project" '.trusted // [] | index($p) | type == "number"' \
    "$trust_file" >/dev/null 2>&1
}

_record_project_trust() {
  local workspace="$1" project="$2"
  local trust_file
  trust_file=$(_get_trusted_projects_path "$workspace")
  mkdir -p "$(dirname "$trust_file")"
  if [[ ! -f "$trust_file" ]]; then
    echo '{"trusted":[]}' > "$trust_file"
  fi
  local tmp
  tmp=$(mktemp)
  jq --arg p "$project" '.trusted = ((.trusted // []) + [$p] | unique)' \
    "$trust_file" > "$tmp" && mv "$tmp" "$trust_file"
}

# _docker_trust_check <workspace> <project> <compose_file>
# Returns 0 if the operator has authorized Docker execution for this
# project, 1 otherwise. Caller should bail out on non-zero.
_docker_trust_check() {
  local workspace="$1" project="$2" compose_file="${3:-}"

  # Warn (but don't yet fail) when the compose file lives outside the
  # project's own directory. An out-of-tree compose path — including
  # the workspace root — is a likely indicator that the file was
  # planted or that an earlier trust decision no longer applies. The
  # operator can still proceed; this is a visibility signal, not a
  # hard gate.
  if [[ -n "$compose_file" ]]; then
    local project_dir_real compose_real
    project_dir_real=$(cd "$workspace/$project" 2>/dev/null && pwd -P || echo "$workspace/$project")
    compose_real=$(cd "$(dirname "$compose_file")" 2>/dev/null && pwd -P || echo "")
    if [[ -n "$compose_real" && "$compose_real" != "$project_dir_real" && "$compose_real" != "$project_dir_real"/* ]]; then
      log_warn "compose file '$compose_file' is outside '$project_dir_real'; verify it is trusted" "docker-trust" >&2
    fi
  fi

  if _is_project_trusted "$workspace" "$project"; then
    return 0
  fi

  if [[ "${MRA_DOCKER_TRUST_FORCE:-}" == "1" ]]; then
    _record_project_trust "$workspace" "$project"
    log_warn "MRA_DOCKER_TRUST_FORCE=1 granted Docker trust to '$project'" "docker-trust" >&2
    declare -F log_security_event >/dev/null && \
      MRA_WORKSPACE="$workspace" log_security_event "trust" "grant" \
        "project=$project" "via=force_flag" "compose=${compose_file:-unresolved}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_error "Docker execution requires trust grant for '$project', but stdin is not a terminal. Set MRA_DOCKER_TRUST_FORCE=1 to authorize non-interactively." "docker-trust" >&2
    declare -F log_security_event >/dev/null && \
      MRA_WORKSPACE="$workspace" log_security_event "trust" "refuse" \
        "project=$project" "reason=non_interactive" "compose=${compose_file:-unresolved}"
    return 1
  fi

  echo "" >&2
  echo "About to run Docker against '$project' for the first time." >&2
  echo "Compose file: ${compose_file:-(unresolved)}" >&2
  echo "Docker can run arbitrary build steps and mount workspace paths." >&2
  local reply=""
  read -r -p "Trust this project for Docker execution? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      _record_project_trust "$workspace" "$project"
      log_success "recorded trust for '$project' in .collab/trusted-projects.json" "docker-trust" >&2
      declare -F log_security_event >/dev/null && \
        MRA_WORKSPACE="$workspace" log_security_event "trust" "grant" \
          "project=$project" "via=interactive" "compose=${compose_file:-unresolved}"
      return 0
      ;;
    *)
      log_error "Docker execution aborted; '$project' not trusted" "docker-trust" >&2
      declare -F log_security_event >/dev/null && \
        MRA_WORKSPACE="$workspace" log_security_event "trust" "refuse" \
          "project=$project" "reason=user_declined" "compose=${compose_file:-unresolved}"
      return 1
      ;;
  esac
}

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

  # TM-005: require operator trust before executing arbitrary
  # docker compose from the workspace.
  if ! _docker_trust_check "$workspace" "$project" "$compose_file"; then
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

  # TM-005: same trust gate for image builds.
  if ! _docker_trust_check "$workspace" "$project" "$compose_file"; then
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

  # TM-005: gate `compose up -d` the same way `compose run` is gated.
  if ! _docker_trust_check "$workspace" "$project" "$compose_file"; then
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
