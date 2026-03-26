#!/usr/bin/env bash
# Multi-workspace federation: publish/subscribe API contracts

get_contracts_dir() {
  local workspace="$1"
  echo "$workspace/.collab/contracts"
}

# Publish: extract API contract from a project
publish_contract() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local contracts_dir; contracts_dir=$(get_contracts_dir "$workspace")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "federation"; return 1; }
  mkdir -p "$contracts_dir/published"

  local project_type="unknown"
  [[ -f "$graph_file" ]] && project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")

  log_progress "$project: extracting API contract" "federation"

  local endpoints="[]"
  case "$project_type" in
    rails-api)
      # Extract routes
      if [[ -f "$project_dir/config/routes.rb" ]]; then
        endpoints=$(grep -nE '^\s*(get|post|put|patch|delete|resources|resource)\s' "$project_dir/config/routes.rb" 2>/dev/null | \
          while IFS=: read -r line_num content; do
            content=$(echo "$content" | sed 's/^[[:space:]]*//')
            jq -n --argjson ln "$line_num" --arg def "$content" '{"line":$ln,"definition":$def}'
          done | jq -s '.' 2>/dev/null || echo "[]")
      fi
      ;;
    node-backend|nextjs)
      # Extract route files
      endpoints=$(find "$project_dir/src" -name "*.ts" -path "*/route*" 2>/dev/null | \
        while read -r f; do
          local rel="${f#$project_dir/}"
          grep -nE '(get|post|put|patch|delete|router\.)' "$f" 2>/dev/null | \
            while IFS=: read -r line_num content; do
              content=$(echo "$content" | sed 's/^[[:space:]]*//')
              jq -n --arg file "$rel" --argjson ln "$line_num" --arg def "$content" \
                '{"file":$file,"line":$ln,"definition":$def}'
            done
        done | jq -s '.' 2>/dev/null || echo "[]")
      ;;
  esac

  # Build contract
  local contract
  contract=$(jq -n \
    --arg name "$project" \
    --arg type "$project_type" \
    --arg version "$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")" \
    --arg workspace "$(jq -r '.workspace // "unknown"' "$graph_file" 2>/dev/null)" \
    --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson endpoints "$endpoints" \
    '{
      schema: "mra-contract-v1",
      name: $name,
      type: $type,
      version: $version,
      workspace: $workspace,
      published: $published,
      endpointCount: ($endpoints | length),
      endpoints: $endpoints
    }')

  local contract_file="$contracts_dir/published/$project.json"
  echo "$contract" | jq '.' > "$contract_file"

  local ep_count; ep_count=$(echo "$contract" | jq '.endpointCount')
  log_success "$project: contract published ($ep_count endpoints) -> $contract_file" "federation"
}

# Subscribe: add a remote contract source
subscribe_contract() {
  local workspace="$1" source_url="$2"
  local contracts_dir; contracts_dir=$(get_contracts_dir "$workspace")
  mkdir -p "$contracts_dir/subscribed"

  local subs_file="$contracts_dir/subscriptions.json"

  # Initialize if not exists
  [[ ! -f "$subs_file" ]] && echo '[]' > "$subs_file"

  # Check if already subscribed
  if jq -e --arg u "$source_url" '.[] | select(.url == $u)' "$subs_file" &>/dev/null; then
    log_warn "already subscribed to: $source_url" "federation"
    return 0
  fi

  # Add subscription
  local tmp; tmp=$(mktemp)
  jq --arg u "$source_url" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{"url": $u, "subscribedAt": $ts, "lastFetched": null}]' \
    "$subs_file" > "$tmp" && mv "$tmp" "$subs_file"

  log_success "subscribed to: $source_url" "federation"

  # Try to fetch immediately
  fetch_subscription "$workspace" "$source_url"
}

# Fetch a subscribed contract
fetch_subscription() {
  local workspace="$1" source_url="$2"
  local contracts_dir; contracts_dir=$(get_contracts_dir "$workspace")

  log_progress "fetching contract: $source_url" "federation"

  local contract_content=""
  if [[ "$source_url" == http://* || "$source_url" == https://* ]]; then
    contract_content=$(curl -sf "$source_url" 2>/dev/null) || {
      log_error "failed to fetch: $source_url" "federation"
      return 1
    }
  elif [[ -f "$source_url" ]]; then
    contract_content=$(cat "$source_url")
  else
    log_error "source not found: $source_url" "federation"
    return 1
  fi

  # Validate it's a valid contract
  local name; name=$(echo "$contract_content" | jq -r '.name // ""' 2>/dev/null)
  if [[ -z "$name" || "$name" == "null" ]]; then
    log_error "invalid contract format" "federation"
    return 1
  fi

  local sub_file="$contracts_dir/subscribed/$name.json"
  echo "$contract_content" | jq '.' > "$sub_file"

  # Update lastFetched
  local subs_file="$contracts_dir/subscriptions.json"
  if [[ -f "$subs_file" ]]; then
    local tmp; tmp=$(mktemp)
    jq --arg u "$source_url" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '[.[] | if .url == $u then .lastFetched = $ts else . end]' \
      "$subs_file" > "$tmp" && mv "$tmp" "$subs_file"
  fi

  log_success "fetched contract: $name ($sub_file)" "federation"
}

# Verify: check if local code satisfies subscribed contracts
verify_contracts() {
  local workspace="$1"
  local contracts_dir; contracts_dir=$(get_contracts_dir "$workspace")
  local sub_dir="$contracts_dir/subscribed"

  if [[ ! -d "$sub_dir" ]]; then
    log_info "no subscribed contracts" "federation"
    return 0
  fi

  local total=0 passed=0 failed=0

  for contract_file in "$sub_dir"/*.json; do
    [[ ! -f "$contract_file" ]] && continue
    local name; name=$(jq -r '.name' "$contract_file")
    local ep_count; ep_count=$(jq '.endpointCount' "$contract_file")
    total=$((total + 1))

    log_progress "verifying contract: $name ($ep_count endpoints)" "federation"

    # Check if we have a local project that depends on this
    local local_dir="$workspace/$name"
    if [[ -d "$local_dir" ]]; then
      # Compare published contract with current state
      local pub_file="$contracts_dir/published/$name.json"
      if [[ -f "$pub_file" ]]; then
        local pub_count; pub_count=$(jq '.endpointCount' "$pub_file")
        local sub_count; sub_count=$(jq '.endpointCount' "$contract_file")
        local pub_version; pub_version=$(jq -r '.version' "$pub_file")
        local sub_version; sub_version=$(jq -r '.version' "$contract_file")

        if [[ "$pub_version" == "$sub_version" ]]; then
          log_success "$name: contract matches (v$pub_version, $pub_count endpoints)" "federation"
          passed=$((passed + 1))
        else
          log_warn "$name: version mismatch (local: $pub_version, contract: $sub_version)" "federation"
          # Check endpoint count change
          if [[ "$pub_count" -lt "$sub_count" ]]; then
            log_error "$name: endpoints reduced ($sub_count -> $pub_count) — possible breaking change" "federation"
            failed=$((failed + 1))
          else
            log_info "$name: endpoints changed ($sub_count -> $pub_count) — re-publish recommended" "federation"
            passed=$((passed + 1))
          fi
        fi
      else
        log_info "$name: local project exists but no published contract (run: mra federation publish $name)" "federation"
        passed=$((passed + 1))
      fi
    else
      # External dependency — just report status
      log_info "$name: external contract ($ep_count endpoints, v$(jq -r '.version' "$contract_file"))" "federation"
      passed=$((passed + 1))
    fi
  done

  echo ""
  if [[ $failed -gt 0 ]]; then
    log_error "contract verification: $passed passed, $failed failed (out of $total)" "federation"
    return 1
  else
    log_success "contract verification: $passed passed, $failed failed (out of $total)" "federation"
  fi
}

# List published and subscribed contracts
list_contracts() {
  local workspace="$1"
  local contracts_dir; contracts_dir=$(get_contracts_dir "$workspace")

  echo ""
  log_info "Published Contracts:" "federation"
  if [[ -d "$contracts_dir/published" ]]; then
    local found_published=false
    for f in "$contracts_dir/published"/*.json; do
      [[ ! -f "$f" ]] && continue
      found_published=true
      local name ep_count version
      name=$(jq -r '.name' "$f")
      ep_count=$(jq '.endpointCount' "$f")
      version=$(jq -r '.version' "$f")
      printf "  %-20s v%-10s %s endpoints\n" "$name" "$version" "$ep_count"
    done
    [[ "$found_published" == "false" ]] && echo "  (none)"
  else
    echo "  (none)"
  fi

  echo ""
  log_info "Subscribed Contracts:" "federation"
  if [[ -d "$contracts_dir/subscribed" ]]; then
    local found_subscribed=false
    for f in "$contracts_dir/subscribed"/*.json; do
      [[ ! -f "$f" ]] && continue
      found_subscribed=true
      local name ep_count version ws
      name=$(jq -r '.name' "$f")
      ep_count=$(jq '.endpointCount' "$f")
      version=$(jq -r '.version' "$f")
      ws=$(jq -r '.workspace' "$f")
      printf "  %-20s v%-10s %s endpoints (from: %s)\n" "$name" "$version" "$ep_count" "$ws"
    done
    [[ "$found_subscribed" == "false" ]] && echo "  (none)"
  else
    echo "  (none)"
  fi
  echo ""
}
