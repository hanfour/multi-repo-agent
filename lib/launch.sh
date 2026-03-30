#!/usr/bin/env bash
# Launch Claude Code orchestrator with --add-dir flags

build_add_dir_args() {
  local workspace="$1"
  shift
  local projects=("$@")

  for project in "${projects[@]}"; do
    local project_dir="$workspace/$project"
    if [[ -d "$project_dir" ]]; then
      printf '%s\0' "--add-dir" "$project_dir"
    else
      log_warn "$project: directory not found, skipping" "load" >&2
    fi
  done
}

launch_claude() {
  local workspace="$1" graph_file="$2"
  shift 2
  local projects=("$@")
  local claude_args=()

  # Build --add-dir args (null-delimited for space safety)
  while IFS= read -r -d '' arg; do
    claude_args+=("$arg")
  done < <(build_add_dir_args "$workspace" "${projects[@]}")

  # Display loaded projects
  local project_list
  project_list=$(printf '%s, ' "${projects[@]}")
  project_list="${project_list%, }"
  log_success "loaded projects: $project_list" "load"

  # Display dependency info
  if [[ -f "$graph_file" ]]; then
    for project in "${projects[@]}"; do
      display_deps "$project" "$graph_file" 2>/dev/null || true
    done
  fi

  log_success "launching Claude orchestrator" "ready"

  # Add orchestrator system prompt if available
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$mra_dir/agents/orchestrator.md" ]]; then
    claude_args+=(--append-system-prompt-file "$mra_dir/agents/orchestrator.md")
  fi

  # Inject output language from config
  local output_lang
  output_lang=$(config_get "outputLanguage" 2>/dev/null)
  if [[ -n "$output_lang" && "$output_lang" != "null" ]]; then
    claude_args+=(--append-system-prompt "Output Language: $output_lang. All agents (orchestrator, sub-agents, reviewers, PM) must use this language for descriptive output. Pass this language directive when dispatching any sub-agent.")
  fi

  # Launch claude (array preserves spaces in paths)
  claude "${claude_args[@]}"
}
