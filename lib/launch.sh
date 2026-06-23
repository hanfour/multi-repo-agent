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

  # Restrict settings to user+project scope so the orchestrator keeps the
  # operator's global settings.json but never loads each --add-dir repo's
  # gitignored CLAUDE.local.md (local scope) when project-memory is on.
  claude_args+=(--setting-sources user,project)

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

  # Collect system-prompt fragments, then emit a SINGLE --append-system-prompt.
  # The claude CLI rejects mixing --append-system-prompt with
  # --append-system-prompt-file, so we read the orchestrator file inline and
  # join every fragment into one flag value.
  local sys_prompt_parts=()

  # Orchestrator system prompt if available
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$mra_dir/agents/orchestrator.md" ]]; then
    sys_prompt_parts+=("$(cat "$mra_dir/agents/orchestrator.md")")
  fi

  # Inject output language from config
  local output_lang
  output_lang=$(config_get "outputLanguage" 2>/dev/null)
  if [[ -n "$output_lang" && "$output_lang" != "null" ]]; then
    sys_prompt_parts+=("Output Language: $output_lang. All agents (orchestrator, sub-agents, reviewers, PM) must use this language for descriptive output. Pass this language directive when dispatching any sub-agent.")
  fi

  # Inject PKB context if available for any loaded project
  local pkb_injected=false
  for project in "${projects[@]}"; do
    local project_dir="$workspace/$project"
    if pkb_exists "$project_dir" 2>/dev/null; then
      local pkb_ctx
      # Launch uses "full" tier — orchestrator needs complete project understanding
      pkb_ctx=$(pkb_build_context "$project_dir" "" "full")
      if [[ -n "$pkb_ctx" ]]; then
        sys_prompt_parts+=("$pkb_ctx")
        log_info "PKB loaded for $project" "load"
        pkb_injected=true
      fi
    fi
  done
  if [[ "$pkb_injected" == "false" ]]; then
    log_info "no PKB found — run 'mra analyze <project>' for faster context" "load"
  fi

  # Join fragments (blank-line separated) into one system-prompt flag
  if (( ${#sys_prompt_parts[@]} > 0 )); then
    local combined_prompt="" part
    for part in "${sys_prompt_parts[@]}"; do
      if [[ -n "$combined_prompt" ]]; then
        combined_prompt+=$'\n\n'
      fi
      combined_prompt+="$part"
    done
    claude_args+=(--append-system-prompt "$combined_prompt")
  fi

  # Launch claude (array preserves spaces in paths)
  claude "${claude_args[@]}"
}
