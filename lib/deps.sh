#!/usr/bin/env bash
# Dependency graph reader and display

get_dep_graph_path() {
  local workspace="$1"
  echo "$workspace/.collab/dep-graph.json"
}

dep_graph_exists() {
  local workspace="$1"
  [[ -f "$(get_dep_graph_path "$workspace")" ]]
}

list_all_projects() {
  local graph_file="$1"
  jq -r '.projects | keys[]' "$graph_file"
}

get_project_deps() {
  local project="$1" graph_file="$2"
  jq -r --arg p "$project" '
    .projects[$p].deps // {} |
    to_entries[] |
    select(.key != "infra") |
    .value[]
  ' "$graph_file" 2>/dev/null
}

get_project_consumers() {
  local project="$1" graph_file="$2"
  jq -r ".projects.\"$project\".consumedBy // [] | .[]" "$graph_file" 2>/dev/null
}

resolve_with_deps() {
  local project="$1" depth="${2:-1}" graph_file="$3"
  local projects=("$project")
  local current_depth=0
  local visited="$project"

  while [[ $current_depth -lt $depth ]]; do
    local new_projects=()
    for p in "${projects[@]}"; do
      # Add deps
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if [[ ! " $visited " =~ " $dep " ]]; then
          new_projects+=("$dep")
          visited="$visited $dep"
        fi
      done < <(get_project_deps "$p" "$graph_file")

      # Add consumers
      while IFS= read -r consumer; do
        [[ -z "$consumer" ]] && continue
        if [[ ! " $visited " =~ " $consumer " ]]; then
          new_projects+=("$consumer")
          visited="$visited $consumer"
        fi
      done < <(get_project_consumers "$p" "$graph_file")
    done

    if [[ ${#new_projects[@]} -eq 0 ]]; then
      break
    fi
    projects+=("${new_projects[@]}")
    ((current_depth++))
  done

  echo "$visited" | tr ' ' '\n' | sort -u
}

display_deps() {
  local project="$1" graph_file="$2"

  log_info "" "deps"

  local consumers deps_infra deps_api
  consumers=$(get_project_consumers "$project" "$graph_file" | paste -sd, -)
  deps_infra=$(jq -r ".projects.\"$project\".deps.infra // [] | join(\", \")" "$graph_file")
  deps_api=$(jq -r ".projects.\"$project\".deps.api // [] | join(\", \")" "$graph_file")

  [[ -n "$consumers" ]] && log_info "  $project <- $consumers (API)" ""
  [[ -n "$deps_api" && "$deps_api" != "" ]] && log_info "  $project <- $deps_api (route)" ""
  [[ -n "$deps_infra" && "$deps_infra" != "" ]] && log_info "  $project -> $deps_infra (infra)" ""
}

display_all_deps() {
  local graph_file="$1"

  log_info "" "deps"
  while IFS= read -r project; do
    display_deps "$project" "$graph_file"
  done < <(list_all_projects "$graph_file")
}
