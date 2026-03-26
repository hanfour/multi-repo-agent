#!/usr/bin/env bash
generate_graph() {
  local workspace="$1" format="${2:-terminal}"
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")
  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "graph"; return 1; }

  case "$format" in
    terminal)
      _graph_terminal "$graph_file"
      ;;
    mermaid)
      _graph_mermaid "$graph_file" "$workspace"
      ;;
    dot)
      _graph_dot "$graph_file" "$workspace"
      ;;
    *)
      log_error "unknown format: $format (use: terminal, mermaid, dot)" "graph"
      return 1
      ;;
  esac
}

_graph_terminal() {
  local graph_file="$1"
  echo ""
  echo "Dependency Graph"
  echo "================"
  echo ""
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local deps consumedBy
    deps=$(jq -r --arg p "$project" '(.projects[$p].deps // {}) | to_entries[] | "\(.key): \(.value | join(", "))"' "$graph_file" 2>/dev/null)
    consumedBy=$(jq -r --arg p "$project" '(.projects[$p].consumedBy // []) | join(", ")' "$graph_file" 2>/dev/null)
    local type; type=$(jq -r --arg p "$project" '.projects[$p].type // "?"' "$graph_file")
    echo "  $project ($type)"
    [[ -n "$deps" ]] && echo "$deps" | while IFS= read -r d; do echo "    -> $d"; done
    [[ -n "$consumedBy" && "$consumedBy" != "" ]] && echo "    <- $consumedBy"
    echo ""
  done < <(jq -r '.projects | keys[]' "$graph_file")
}

_graph_mermaid() {
  local graph_file="$1" workspace="$2"
  local output_file="$workspace/.collab/dep-graph.mmd"
  {
    echo "graph LR"
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      local type; type=$(jq -r --arg p "$project" '.projects[$p].type // "?"' "$graph_file")
      echo "  $project[\"$project<br/>$type\"]"
      # deps (non-infra)
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        echo "  $project --> $dep"
      done < <(jq -r --arg p "$project" '(.projects[$p].deps // {}) | to_entries[] | select(.key != "infra") | .value[]' "$graph_file" 2>/dev/null)
      # infra deps (dashed)
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        echo "  $project -.-> $dep"
      done < <(jq -r --arg p "$project" '(.projects[$p].deps.infra // []) | .[]' "$graph_file" 2>/dev/null)
    done < <(jq -r '.projects | keys[]' "$graph_file")
  } > "$output_file"
  log_success "mermaid graph written to $output_file" "graph"
  cat "$output_file"
}

_graph_dot() {
  local graph_file="$1" workspace="$2"
  local output_file="$workspace/.collab/dep-graph.dot"
  {
    echo "digraph workspace {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, style=rounded];"
    echo ""
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      local type; type=$(jq -r --arg p "$project" '.projects[$p].type // "?"' "$graph_file")
      echo "  \"$project\" [label=\"$project\\n($type)\"];"
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        echo "  \"$project\" -> \"$dep\";"
      done < <(jq -r --arg p "$project" '(.projects[$p].deps // {}) | to_entries[] | select(.key != "infra") | .value[]' "$graph_file" 2>/dev/null)
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        echo "  \"$project\" -> \"$dep\" [style=dashed];"
      done < <(jq -r --arg p "$project" '(.projects[$p].deps.infra // []) | .[]' "$graph_file" 2>/dev/null)
    done < <(jq -r '.projects | keys[]' "$graph_file")
    echo "}"
  } > "$output_file"
  log_success "DOT graph written to $output_file" "graph"
  cat "$output_file"
}
