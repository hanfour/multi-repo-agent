#!/usr/bin/env bash
# Launch Claude Code orchestrator with --add-dir flags

build_add_dir_args() {
  local workspace="$1"
  shift
  local projects=("$@")

  for project in ${projects[@]+"${projects[@]}"}; do
    local project_dir="$workspace/$project"
    if [[ -d "$project_dir" ]]; then
      printf '%s\0' "--add-dir" "$project_dir"
    else
      log_warn "$project: directory not found, skipping" "load" >&2
    fi
  done
}

# _launch_interactive: shared assembly used by launch_claude and mra prd.
#
# Parameters:
#   $1  workspace      — root directory containing project sub-dirs
#   $2  graph_file     — path to dep-graph.json (may not exist)
#   $3  sys_prompt_file — base system-prompt file to read (e.g. agents/orchestrator.md)
#   $4  extra_fragments — optional additional text appended after lang directive (may be empty)
#   $5… projects        — one or more project names (relative to workspace)
#
# Changes vs original launch_claude body:
#   (a) reads base system prompt from $sys_prompt_file instead of hardcoding agents/orchestrator.md
#   (b) appends $extra_fragments as one more sys_prompt_parts entry when non-empty
#   (c) execs "${MRA_CLAUDE_BIN:-claude}" instead of bare claude (enables test shims)
_launch_interactive() {
  local workspace="$1" graph_file="$2" sys_prompt_file="$3" extra_fragments="$4"
  shift 4
  local projects=("$@")
  local claude_args=()

  # Build --add-dir args (null-delimited for space safety)
  while IFS= read -r -d '' arg; do
    claude_args+=("$arg")
  done < <(build_add_dir_args "$workspace" ${projects[@]+"${projects[@]}"})

  # Restrict settings to user+project scope so the orchestrator keeps the
  # operator's global settings.json but never loads each --add-dir repo's
  # gitignored CLAUDE.local.md (local scope) when project-memory is on.
  claude_args+=(--setting-sources user,project)

  # Display loaded projects
  local project_list
  project_list=$(printf '%s, ' ${projects[@]+"${projects[@]}"})
  project_list="${project_list%, }"
  log_success "loaded projects: $project_list" "load"

  # Display dependency info
  if [[ -f "$graph_file" ]]; then
    for project in ${projects[@]+"${projects[@]}"}; do
      display_deps "$project" "$graph_file" 2>/dev/null || true
    done
  fi

  log_success "launching Claude orchestrator" "ready"

  # Collect system-prompt fragments, then emit a SINGLE --append-system-prompt.
  # The claude CLI rejects mixing --append-system-prompt with
  # --append-system-prompt-file, so we read the prompt file inline and
  # join every fragment into one flag value.
  local sys_prompt_parts=()

  # (a) Base system prompt read from the caller-supplied file
  if [[ -f "$sys_prompt_file" ]]; then
    sys_prompt_parts+=("$(cat "$sys_prompt_file")")
  fi

  # Inject output language from config
  local output_lang
  output_lang=$(config_get "outputLanguage" 2>/dev/null)
  if [[ -n "$output_lang" && "$output_lang" != "null" ]]; then
    sys_prompt_parts+=("Output Language: $output_lang. All agents (orchestrator, sub-agents, reviewers, PM) must use this language for descriptive output. Pass this language directive when dispatching any sub-agent.")
  fi

  # (b) Append caller-supplied extra fragments when non-empty
  if [[ -n "$extra_fragments" ]]; then
    sys_prompt_parts+=("$extra_fragments")
  fi

  # Inject PKB context if available for any loaded project
  local pkb_injected=false
  for project in ${projects[@]+"${projects[@]}"}; do
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

  # (c) Launch via MRA_CLAUDE_BIN when set (enables test shims), fall back to claude
  "${MRA_CLAUDE_BIN:-claude}" "${claude_args[@]}"
}

launch_claude() {
  local workspace="$1" graph_file="$2"; shift 2
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  _launch_interactive "$workspace" "$graph_file" "$mra_dir/agents/orchestrator.md" "" "$@"
}
