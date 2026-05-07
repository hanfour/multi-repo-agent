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

  # Custom scanners from workspace
  local custom_dir="$workspace/.collab/scanners"
  if [[ -d "$custom_dir" ]]; then
    for scanner in "$custom_dir"/*.sh; do
      [[ ! -f "$scanner" ]] && continue
      local scanner_name="custom/$(basename "$scanner" .sh)"
      log_progress "running scanner: $scanner_name" "scan"
      bash "$scanner" "$workspace" >> "$results_file" 2>/dev/null || true
    done
  fi

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

  # Scanner-owned edges: rebuild deps/consumedBy/confidence from scratch each
  # scan so removed dependencies don't linger as stale graph edges.
  # Project-level metadata (type/port/lastCommit/etc.) is preserved.
  local updated_graph
  updated_graph=$(jq '
    .projects |= map_values(
      .deps = {}
      | .consumedBy = []
      | .confidence = {}
    )
  ' "$graph_file")

  # First pass: apply scanner records (skip low confidence unless manually confirmed).
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local source target dep_type confidence
    source=$(echo "$line" | jq -r '.source')
    target=$(echo "$line" | jq -r '.target')
    dep_type=$(echo "$line" | jq -r '.type')
    confidence=$(echo "$line" | jq -r '.confidence')

    if [[ "$confidence" == "low" ]]; then
      if [[ -f "$manual_deps" ]] && jq -e --arg s "$source" --arg t "$target" \
        '.[] | select(.source == $s and .target == $t)' "$manual_deps" &>/dev/null; then
        confidence="high"
      else
        continue
      fi
    fi

    updated_graph=$(echo "$updated_graph" | jq \
      --arg s "$source" --arg t "$target" --arg type "$dep_type" --arg conf "$confidence" '
        (if .projects[$s] then
          .projects[$s].deps[$type] = ((.projects[$s].deps[$type] // []) + [$t] | unique)
          | .projects[$s].confidence[$t] = $conf
        else . end)
        | (if .projects[$t] then
            .projects[$t].consumedBy = ((.projects[$t].consumedBy // []) + [$s] | unique)
          else . end)
      ')
  done < "$results_file"

  # Second pass: manual overrides act like high-confidence scanner edges, even
  # if the scanner missed them this run. Honors --include-manual semantics
  # without forcing a specific scanner to emit them.
  if [[ -f "$manual_deps" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local source target dep_type
      source=$(echo "$entry" | jq -r '.source')
      target=$(echo "$entry" | jq -r '.target')
      dep_type=$(echo "$entry" | jq -r '.type // "api"')

      updated_graph=$(echo "$updated_graph" | jq \
        --arg s "$source" --arg t "$target" --arg type "$dep_type" '
          (if .projects[$s] then
            .projects[$s].deps[$type] = ((.projects[$s].deps[$type] // []) + [$t] | unique)
            | .projects[$s].confidence[$t] = "high"
          else . end)
          | (if .projects[$t] then
              .projects[$t].consumedBy = ((.projects[$t].consumedBy // []) + [$s] | unique)
            else . end)
        ')
    done < <(jq -c '.[]' "$manual_deps" 2>/dev/null || true)
  fi

  updated_graph=$(echo "$updated_graph" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastScan = $ts')

  echo "$updated_graph" | jq '.' > "$graph_file"
  log_success "dep-graph.json rebuilt from scanners" "scan"
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
