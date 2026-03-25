#!/usr/bin/env bash
# Scan orchestrator: runs all scanners and merges results into dep-graph.json

run_all_scanners() {
  local workspace="$1"
  local results_file
  results_file=$(mktemp)

  # Run each scanner, collect JSONL output
  # Note: log_progress writes to stderr so it doesn't pollute the return value
  for scanner in "$MRA_DIR"/scanners/*.sh; do
    [[ ! -f "$scanner" ]] && continue
    local scanner_name
    scanner_name=$(basename "$scanner" .sh)
    log_progress "running scanner: $scanner_name" "scan" >&2
    bash "$scanner" "$workspace" >> "$results_file" 2>/dev/null || true
  done

  echo "$results_file"
}

merge_scan_results() {
  local workspace="$1" results_file="$2"
  local graph_file="$workspace/.collab/dep-graph.json"
  local manual_deps="$workspace/.collab/manual-deps.json"

  if [[ ! -f "$graph_file" ]]; then
    log_error "dep-graph.json not found, run mra init first" "scan"
    return 1
  fi

  # Read current dep-graph
  local updated_graph
  updated_graph=$(cat "$graph_file")

  # Process each scanner result line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local source target dep_type confidence
    source=$(echo "$line" | jq -r '.source')
    target=$(echo "$line" | jq -r '.target')
    dep_type=$(echo "$line" | jq -r '.type')
    confidence=$(echo "$line" | jq -r '.confidence')

    # Skip low confidence unless manually confirmed
    if [[ "$confidence" == "low" ]]; then
      if [[ -f "$manual_deps" ]] && jq -e --arg s "$source" --arg t "$target" \
        '.[] | select(.source == $s and .target == $t)' "$manual_deps" &>/dev/null; then
        confidence="high"  # manually confirmed
      else
        continue  # skip low confidence
      fi
    fi

    # Update dep-graph: add target to source's deps
    if echo "$updated_graph" | jq -e --arg s "$source" '.projects[$s]' &>/dev/null; then
      updated_graph=$(echo "$updated_graph" | jq \
        --arg s "$source" --arg t "$target" --arg type "$dep_type" --arg conf "$confidence" \
        '.projects[$s].deps[$type] = ((.projects[$s].deps[$type] // []) + [$t] | unique) |
         .projects[$s].confidence[$t] = $conf')
    fi

    # Update consumedBy on target
    if echo "$updated_graph" | jq -e --arg t "$target" '.projects[$t]' &>/dev/null; then
      updated_graph=$(echo "$updated_graph" | jq \
        --arg s "$source" --arg t "$target" \
        '.projects[$t].consumedBy = ((.projects[$t].consumedBy // []) + [$s] | unique)')
    fi
  done < "$results_file"

  # Update lastScan timestamp
  updated_graph=$(echo "$updated_graph" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastScan = $ts')

  # Write updated graph
  echo "$updated_graph" | jq '.' > "$graph_file"
  log_success "dep-graph.json updated" "scan"
}

# Diff scan: only re-scan projects with changed git hash
diff_scan() {
  local workspace="$1"
  local graph_file="$workspace/.collab/dep-graph.json"

  if [[ ! -f "$graph_file" ]]; then
    log_warn "no existing dep-graph, running full scan" "scan"
    return 1  # caller should do full scan
  fi

  local changed=0
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local proj_dir="$workspace/$project"
    [[ ! -d "$proj_dir/.git" ]] && continue

    local stored_hash current_hash
    stored_hash=$(jq -r --arg p "$project" '.projects[$p].lastCommit // ""' "$graph_file")
    current_hash=$(git -C "$proj_dir" rev-parse --short HEAD 2>/dev/null || echo "")

    if [[ "$stored_hash" != "$current_hash" ]]; then
      ((changed++)) || true
      log_info "$project: changed ($stored_hash -> $current_hash)" "scan"
    fi
  done < <(jq -r '.projects | keys[]' "$graph_file")

  if [[ $changed -eq 0 ]]; then
    log_success "no changes detected, skipping scan" "scan"
    return 0
  fi

  log_progress "$changed project(s) changed, running scan" "scan"
  return 1  # signal to run full scan
}

handle_scan() {
  local workspace="$1"

  # Try diff scan first
  if diff_scan "$workspace"; then
    return 0
  fi

  # Full scan
  local results_file
  results_file=$(run_all_scanners "$workspace")

  local result_count
  result_count=$(wc -l < "$results_file" | tr -d ' ')
  log_info "scanners found $result_count relationship(s)" "scan"

  merge_scan_results "$workspace" "$results_file"

  # Update commit hashes
  local graph_file="$workspace/.collab/dep-graph.json"
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local proj_dir="$workspace/$project"
    [[ ! -d "$proj_dir/.git" ]] && continue
    local current_hash
    current_hash=$(git -C "$proj_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local tmp
    tmp=$(mktemp)
    jq --arg p "$project" --arg h "$current_hash" '.projects[$p].lastCommit = $h' "$graph_file" > "$tmp" && mv "$tmp" "$graph_file"
  done < <(jq -r '.projects | keys[]' "$graph_file")

  rm -f "$results_file"
  log_success "scan complete" "scan"
}
