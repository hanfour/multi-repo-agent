#!/usr/bin/env bash
# mra ask: query a project's codebase using Claude
#
# Two modes:
#   Non-interactive (default): claude -p with --setting-sources "project"
#     to bypass user plugins that break -p output
#   Interactive (--interactive): launches a full Claude session
#
# Usage:
#   mra ask <project> "<question>"
#   mra ask <project> --with-deps "<question>"
#   mra ask --all "<question>"
#   mra ask <project> --interactive "<question>"

ask_project() {
  local workspace="$1"
  shift
  local projects=() question="" with_deps=false interactive=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-deps) with_deps=true; shift ;;
      --interactive|-i) interactive=true; shift ;;
      --all)
        local graph_file
        graph_file=$(get_dep_graph_path "$workspace")
        while IFS= read -r p; do
          [[ -n "$p" ]] && projects+=("$p")
        done < <(list_all_projects "$graph_file")
        shift
        ;;
      -*)
        log_error "unknown option: $1" "ask"
        return 1
        ;;
      *)
        if [[ ${#projects[@]} -eq 0 && -d "$workspace/$1" ]]; then
          projects+=("$1")
        else
          question="$*"
          break
        fi
        shift
        ;;
    esac
  done

  if [[ ${#projects[@]} -eq 0 ]]; then
    log_error "usage: mra ask <project> \"<question>\"" "ask"
    return 1
  fi

  if [[ -z "$question" ]]; then
    log_error "no question provided" "ask"
    return 1
  fi

  # Resolve deps if requested
  if [[ "$with_deps" == "true" ]]; then
    local graph_file
    graph_file=$(get_dep_graph_path "$workspace")
    local resolved
    resolved=$(
      for p in "${projects[@]}"; do
        resolve_with_deps "$p" 1 "$graph_file"
      done | sort -u
    )
    projects=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && projects+=("$p")
    done <<< "$resolved"
  fi

  # Build --add-dir args
  local claude_args=()
  for project in "${projects[@]}"; do
    local project_dir="$workspace/$project"
    if [[ -d "$project_dir" ]]; then
      claude_args+=(--add-dir "$project_dir")
    fi
  done

  # Build context
  local context=""
  local graph_file
  graph_file=$(get_dep_graph_path "$workspace")
  if [[ -f "$graph_file" ]]; then
    local deps_info
    deps_info=$(jq -r '
      .projects | to_entries[] |
      select(.value.deps != {} or .value.consumedBy != []) |
      "\(.key): deps=\(.value.deps | tostring), consumedBy=\(.value.consumedBy | tostring)"
    ' "$graph_file" 2>/dev/null)
    if [[ -n "$deps_info" ]]; then
      context="Workspace dependency graph:\n$deps_info\n\n"
    fi
  fi

  local project_list
  project_list=$(printf '%s, ' "${projects[@]}")
  project_list="${project_list%, }"

  local system_prompt="You are a technical consultant analyzing the codebase of: ${project_list}. ${context}Answer questions by reading actual source code. Cite file paths and line numbers. Use 繁體中文台灣用語."

  log_progress "querying: $project_list" "ask"

  if [[ "$interactive" == "true" ]]; then
    # Interactive mode: full Claude session with follow-up capability
    claude "${claude_args[@]}" \
      --append-system-prompt "$system_prompt" \
      "$question"
  else
    # Non-interactive mode: claude -p with --setting-sources "project"
    # Uses "project" setting source to bypass user plugins that break -p output
    local result
    result=$(claude -p "$question" \
      "${claude_args[@]}" \
      --append-system-prompt "$system_prompt" \
      --setting-sources "project" \
      < /dev/null 2>/dev/null)

    if [[ -n "$result" ]]; then
      echo "$result"
    else
      # Fallback: try JSON output and extract result
      local json_result
      json_result=$(claude -p "$question" \
        "${claude_args[@]}" \
        --append-system-prompt "$system_prompt" \
        --setting-sources "project" \
        --output-format json \
        < /dev/null 2>/dev/null)

      local extracted
      extracted=$(echo "$json_result" | jq -r '.result // ""' 2>/dev/null)
      if [[ -n "$extracted" ]]; then
        echo "$extracted"
      else
        log_error "claude returned empty result" "ask"
        log_info "try: mra ask $project_list --interactive \"$question\"" "ask"
        return 1
      fi
    fi
  fi
}
