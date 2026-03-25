#!/usr/bin/env bash
# mra ask: query a project's codebase using Claude non-interactive mode
#
# Usage:
#   mra ask <project> "<question>"
#   mra ask <project> --with-deps "<question>"
#   mra ask --all "<question>"

ask_project() {
  local workspace="$1"
  shift
  local projects=() question="" with_deps=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-deps) with_deps=true; shift ;;
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
        # First non-option arg without quotes is project name, rest is question
        if [[ ${#projects[@]} -eq 0 && -d "$workspace/$1" ]]; then
          projects+=("$1")
        else
          # Everything remaining is the question
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
    log_info "usage: mra ask <project> \"<question>\"" "ask"
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

  # Build context about the workspace
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

  # Build the prompt
  local project_list
  project_list=$(printf '%s, ' "${projects[@]}")
  project_list="${project_list%, }"

  local full_prompt
  full_prompt=$(cat <<PROMPT
You are a technical consultant analyzing the codebase of these projects: ${project_list}.

${context}Answer the following question by reading the actual source code. Be specific — cite file paths and line numbers. Use 繁體中文台灣用語 for explanations.

Question: ${question}
PROMPT
  )

  log_progress "querying: $project_list" "ask"

  # Run claude in non-interactive mode with JSON output for reliable capture
  local raw_output
  raw_output=$(claude -p "$full_prompt" "${claude_args[@]}" --output-format json < /dev/null 2>/dev/null) || {
    log_error "claude query failed" "ask"
    return 1
  }

  # Extract result from JSON, fallback to raw output
  if echo "$raw_output" | jq -e '.result' &>/dev/null; then
    local result
    result=$(echo "$raw_output" | jq -r '.result')
    if [[ -n "$result" && "$result" != "null" ]]; then
      echo "$result"
    else
      # result is empty but tokens were generated — try cost info
      local tokens
      tokens=$(echo "$raw_output" | jq -r '.usage.output_tokens // 0')
      if [[ "$tokens" -gt 0 ]]; then
        log_warn "claude generated $tokens tokens but result was empty" "ask"
        log_info "try running interactively: claude --add-dir $workspace/${projects[0]}" "ask"
      fi
    fi
  else
    # Not JSON, print as-is
    echo "$raw_output"
  fi
}
