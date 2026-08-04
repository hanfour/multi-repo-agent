#!/usr/bin/env bash
# Review, analysis and planning commands.
#
# Dispatched by convention from bin/mra.sh: `mra <name>` runs
# mra_cmd_<name> with dashes replaced by underscores. Adding a command means
# adding a function here — the dispatch itself is not edited (#39).
#
# Each still receives the full argv with the command name at $1, exactly as
# the case branch it replaced did, so the `shift` each body opens with means
# the same thing.

mra_cmd_review() {
  shift
  local review_args=() personas_flag=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --personas) personas_flag=true; shift ;;
      *) review_args+=("$1"); shift ;;
    esac
  done
  # Check if user supplied a project name (first non-flag arg that isn't a value for --pr/--base/--model/--strategy)
  local has_project=false
  local skip_next=false
  for a in "${review_args[@]}"; do
    if [[ "$skip_next" == "true" ]]; then skip_next=false; continue; fi
    case "$a" in
      --pr|--base|--model|--strategy|--range|--head|--provider) skip_next=true ;;
      --no-debate|--working) ;;
      -*) ;;
      *) has_project=true; break ;;
    esac
  done
  if [[ "$has_project" == "false" ]]; then
    log_error "usage: mra review <project> [--pr <N>] [--base <ref>] [--working] [--personas] [--strategy S] [--no-debate]" "review"
    exit 1
  fi
  local workspace; workspace=$(resolve_workspace)
  MRA_REVIEW_PERSONAS="$personas_flag" review_project "$workspace" "${review_args[@]}"
}

mra_cmd_analyze() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local project="" model="sonnet"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        if [[ $# -lt 2 ]]; then log_error "--model requires a value" "analyze"; exit 1; fi
        model="$2"; shift 2 ;;
      -*) log_error "unknown option: $1" "analyze"; exit 1 ;;
      *) project="$1"; shift ;;
    esac
  done
  if [[ -z "$project" ]]; then
    log_error "usage: mra analyze <project> [--model <model>]" "analyze"; exit 1
  fi
  local project_dir
  project_dir=$(resolve_project_dir "$workspace" "$project") || exit 1
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""
  structural_analyze_hint "$project" "$project_dir"
  pkb_generate "$project" "$project_dir" "$model" "$output_language"
}

mra_cmd_plan() {
  shift
  local plan_project="" plan_task="" plan_model="sonnet" plan_dual=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        [[ $# -lt 2 ]] && { log_error "--model requires a value" "plan"; exit 1; }
        plan_model="$2"; shift 2 ;;
      --dual) plan_dual=true; shift ;;
      -*) log_error "unknown option: $1" "plan"; exit 1 ;;
      *)
        if [[ -z "$plan_project" ]]; then
          plan_project="$1"
        else
          plan_task+="${plan_task:+ }$1"
        fi
        shift ;;
    esac
  done
  if [[ -z "$plan_project" || -z "$plan_task" ]]; then
    log_error "usage: mra plan <project> \"<task>\" [--model <model>] [--dual]" "plan"; exit 1
  fi
  local workspace; workspace=$(resolve_workspace)
  local project_dir
  project_dir=$(resolve_project_dir "$workspace" "$plan_project") || exit 1

  if [[ "$plan_dual" == "true" ]] && ! ensure_codex_available; then
    log_error "mra plan --dual requires the codex CLI (not found on PATH)" "plan"; exit 1
  fi

  local lang=""
  lang=$(config_get "outputLanguage" 2>/dev/null); [[ "$lang" == "null" ]] && lang=""
  local lang_directive=""; [[ -n "$lang" ]] && lang_directive="Use ${lang} for all output."
  local pkb_context=""
  pkb_context=$(pkb_build_context "$project_dir" "" "standard" 2>/dev/null || echo "")

  local add_dirs
  add_dirs=$(build_add_dir_string "$project_dir")
  run_plan_council "$plan_project" "$project_dir" "$plan_task" \
    "$(default_plan_personas)" "$plan_model" "$add_dirs" "$pkb_context" "$lang_directive" "$plan_dual"
}

mra_cmd_lint() {
  shift
  local workspace; workspace=$(resolve_workspace)
  if [[ "${1:-}" == "--all" ]]; then
    lint_all_projects "$workspace" || exit $?
  elif [[ -n "${1:-}" ]]; then
    lint_project "$workspace" "$1" || exit $?
  else
    log_error "usage: mra lint <project|--all>" "lint"; exit 1
  fi
}

mra_cmd_dev() {
  shift
  _dev_parse_args "$@" || exit 1
  local workspace; workspace=$(resolve_workspace)
  validate_project_name "$DEV_PROJECT" || exit 1
  [[ "$DEV_NO_PR" == true ]] || check_gh_auth || exit 1
  dev_project "$workspace" "$DEV_PROJECT" "$DEV_TASK"
}

mra_cmd_eval_review() {
  shift
  local workspace; workspace=$(resolve_workspace)
  eval_review "$workspace" "$@"
}

mra_cmd_eval_probe() {
  shift
  eval_pkb_probe "$@"
}

mra_cmd_eval_ablation() {
  shift
  local workspace; workspace=$(resolve_workspace)
  eval_pkb_ablation "$workspace" "$@"
}

mra_cmd_test_audit() {
  cmd_test_audit "$@"
}
