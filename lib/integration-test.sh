#!/usr/bin/env bash
# Cross-repo integration testing
# Starts provider container, runs consumer tests against it

MRA_NETWORK="mra-test-net"

ensure_test_network() {
  if ! docker network inspect "$MRA_NETWORK" &>/dev/null; then
    docker network create "$MRA_NETWORK" &>/dev/null
    log_success "created test network: $MRA_NETWORK" "test"
  fi
}

# Run integration test: start provider, test consumer against it
run_integration_test() {
  local workspace="$1" provider="$2" consumer="$3"
  local graph_file="$workspace/.collab/dep-graph.json"

  log_progress "integration test: $consumer -> $provider" "test"

  ensure_test_network

  # Get provider's port from dep-graph
  local provider_port
  provider_port=$(jq -r --arg p "$provider" '.projects[$p].port // 4000' "$graph_file")

  # Start provider with modified code
  log_progress "starting $provider service" "test"
  local config
  config=$(resolve_compose_config "$workspace" "$provider")
  local compose_file="${config%%|*}"
  local service_name="${config##*|}"

  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    log_error "$provider: no docker-compose file, skipping integration test" "test"
    return 1
  fi

  # Start provider via compose (it mounts the local code)
  docker compose -f "$compose_file" up -d "$service_name" 2>&1
  local provider_container
  provider_container=$(docker compose -f "$compose_file" ps -q "$service_name" 2>/dev/null)

  if [[ -z "$provider_container" ]]; then
    log_error "$provider: failed to start" "test"
    return 1
  fi

  # Connect provider to test network
  docker network connect "$MRA_NETWORK" "$provider_container" 2>/dev/null || true

  # Wait for provider to be ready
  log_progress "waiting for $provider to be ready" "test"
  local elapsed=0
  while [[ $elapsed -lt 30 ]]; do
    if docker exec "$provider_container" curl -sf "http://localhost:$provider_port" &>/dev/null 2>&1; then
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  # Get provider's IP on the test network
  local provider_ip
  provider_ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{if eq .NetworkID \"$(docker network inspect $MRA_NETWORK -f '{{.Id}}')\"}}{{.IPAddress}}{{end}}{{end}}" "$provider_container" 2>/dev/null)

  if [[ -z "$provider_ip" ]]; then
    # Fallback to container name
    provider_ip="$service_name"
  fi

  local api_url="http://${provider_ip}:${provider_port}"
  log_info "$consumer will connect to $provider at $api_url" "test"

  # Run consumer tests with provider URL override
  local consumer_config
  consumer_config=$(resolve_compose_config "$workspace" "$consumer")
  local consumer_compose="${consumer_config%%|*}"
  local consumer_service="${consumer_config##*|}"

  if [[ -z "$consumer_compose" || ! -f "$consumer_compose" ]]; then
    log_warn "$consumer: no docker-compose file, running tests on host" "test"
    return 0
  fi

  local consumer_type
  consumer_type=$(jq -r --arg p "$consumer" '.projects[$p].type // "unknown"' "$graph_file")
  local test_cmd
  test_cmd=$(detect_test_command "$consumer_type")

  docker compose -f "$consumer_compose" run --rm \
    -e "API_URL=$api_url" \
    -e "ERP_HOST=$api_url" \
    -e "MASA_HOST=$api_url" \
    -e "API_GATEWAY_HOST=$api_url" \
    --network "$MRA_NETWORK" \
    "$consumer_service" \
    bash -c "$test_cmd" 2>&1

  local exit_code=$?

  # Cleanup: stop provider
  docker compose -f "$compose_file" stop "$service_name" 2>/dev/null

  if [[ $exit_code -eq 0 ]]; then
    log_success "integration test passed: $consumer -> $provider" "test"
  else
    log_error "integration test failed: $consumer -> $provider (exit $exit_code)" "test"
  fi

  return $exit_code
}

# Run the full cross-repo test strategy for a project
run_cross_repo_tests() {
  local workspace="$1" project="$2"
  local graph_file="$workspace/.collab/dep-graph.json"
  local project_dir="$workspace/$project"

  # Detect change level
  local project_type
  project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")

  local change_level
  change_level=$(is_api_change "$project_dir" "$project_type")
  local level="${change_level%%|*}"
  local reasons="${change_level#*|}"

  if [[ "$level" == "high" ]]; then
    log_warn "$project: API change detected ($reasons)" "test"
    log_info "triggering integration tests for consumers" "test"

    # Get consumers and run integration tests
    while IFS= read -r consumer; do
      [[ -z "$consumer" ]] && continue
      run_integration_test "$workspace" "$project" "$consumer"
    done < <(get_affected_consumers "$workspace" "$project")
  elif [[ "$level" == "none" ]]; then
    log_info "$project: no changes detected" "test"
  else
    log_info "$project: non-API changes, mock tests sufficient" "test"
  fi

  # Always run the project's own tests
  run_project_tests "$workspace" "$project"
}

# Cleanup test network
cleanup_test_network() {
  docker network rm "$MRA_NETWORK" 2>/dev/null && \
    log_success "removed test network: $MRA_NETWORK" "test" || true
}
