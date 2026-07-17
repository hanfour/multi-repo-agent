#!/usr/bin/env bash
# mra review: context-aware code review
#
# Usage:
#   mra review <project>              Terminal output (current branch vs main)
#   mra review <project> --pr <N>     Inline review on GitHub PR
#   mra review <project> --base <ref> Compare against specific branch
#   mra review <project> --no-debate  Skip debate, single-pass review

# review.sh is also sourced directly by focused unit tests. Production loads
# review-provider.sh first, but keep the credential boundary available when it
# is not present in the caller's source order.
if ! declare -F _review_without_github_credentials >/dev/null 2>&1; then
  _review_without_github_credentials() {
    (
      unset GH_TOKEN GITHUB_TOKEN
      "$@"
    )
  }
fi
if ! declare -F _review_file_owner_uid >/dev/null 2>&1; then
  _review_file_owner_uid() {
    local uid
    uid=$(stat -c '%u' "$1" 2>/dev/null || true)
    if [[ "$uid" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$uid"
      return 0
    fi
    uid=$(stat -f '%u' "$1" 2>/dev/null || true)
    if [[ "$uid" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$uid"
      return 0
    fi
    return 1
  }
fi

review_project() {
  local workspace="$1"
  shift
  local project="" pr_number="" base_ref="" model="" model_arg_provided=false
  local debate=true force_strategy="" working=false range_arg="" head_arg="" provider_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)
        if [[ $# -lt 2 ]]; then log_error "--pr requires a PR number" "review"; return 1; fi
        pr_number="$2"; shift 2 ;;
      --base)
        if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "review"; return 1; fi
        base_ref="$2"; shift 2 ;;
      --model)
        if [[ $# -lt 2 ]]; then log_error "--model requires a value" "review"; return 1; fi
        model="$2"; model_arg_provided=true; shift 2 ;;
      --provider)
        if [[ $# -lt 2 ]]; then log_error "--provider requires claude|codex|fallback|dual" "review"; return 1; fi
        provider_arg="$2"; shift 2 ;;
      --no-debate)
        debate=false; shift ;;
      --strategy)
        if [[ $# -lt 2 ]]; then log_error "--strategy requires light|standard|debate" "review"; return 1; fi
        force_strategy="$2"; shift 2 ;;
      --working)
        working=true; shift ;;
      --range)
        if [[ $# -lt 2 ]]; then log_error "--range requires a range (e.g. A..B)" "review"; return 1; fi
        range_arg="$2"; shift 2 ;;
      --head)
        if [[ $# -lt 2 ]]; then log_error "--head requires a ref" "review"; return 1; fi
        head_arg="$2"; shift 2 ;;
      -*)
        log_error "unknown option: $1" "review"; return 1 ;;
      *)
        project="$1"; shift ;;
    esac
  done

  if [[ -z "$project" ]]; then
    log_error "usage: mra review <project> [--pr <N>] [--base <ref>] [--provider claude|codex|fallback|dual]" "review"
    return 1
  fi

  if [[ "$working" == "true" ]]; then
    if [[ "${MRA_REVIEW_PERSONAS:-false}" == "true" ]]; then
      log_error "--working cannot be combined with --personas (Phase 0: single-pass only)" "review"
      return 1
    fi
    if [[ "$force_strategy" == "debate" ]]; then
      log_error "--working cannot be combined with --strategy debate (Phase 0: single-pass only)" "review"
      return 1
    fi
    if [[ -n "$pr_number" ]]; then
      log_error "review: --working cannot be combined with --pr (working-tree changes have no PR line mapping)" "review"
      return 1
    fi
    debate=false   # force light/standard single-pass
  fi

  if [[ -n "$range_arg" && -n "$head_arg" ]]; then
    log_error "review: --range and --head are mutually exclusive" "review"; return 1
  fi
  if [[ ( -n "$range_arg" || -n "$head_arg" ) && -n "$pr_number" ]]; then
    log_error "review: --range/--head cannot be combined with --pr" "review"; return 1
  fi
  if [[ ( -n "$range_arg" || -n "$head_arg" ) && "$working" == "true" ]]; then
    log_error "review: --range/--head cannot be combined with --working" "review"; return 1
  fi

  local review_personas_flag="${MRA_REVIEW_PERSONAS:-false}"

  local review_provider
  review_provider=$(review_provider_effective "$provider_arg") || return 1

  local project_dir
  project_dir=$(resolve_project_dir "$workspace" "$project") || return 1

  model=$(review_provider_effective_model "$review_provider" "$model" "$model_arg_provided")

  local graph_file="$workspace/.collab/dep-graph.json"

  # --- Resolve base ref ---
  if [[ -z "$base_ref" ]]; then
    if [[ -n "$pr_number" ]]; then
      base_ref=$(resolve_pr_base "$project_dir" "$pr_number")
    else
      base_ref=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    fi
  fi

  # --- Get project metadata from dep-graph ---
  local project_type="unknown" consumers="" deps=""
  if [[ -f "$graph_file" ]]; then
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file" 2>/dev/null)
    consumers=$(jq -r --arg p "$project" '.projects[$p].consumedBy // [] | join(" ")' "$graph_file" 2>/dev/null)
    deps=$(jq -r --arg p "$project" '[.projects[$p].deps // {} | to_entries[].value[]] | unique | join(" ")' "$graph_file" 2>/dev/null)
  fi
  [[ "$project_type" == "null" ]] && project_type="unknown"

  # --- Resolve base ref for git operations ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  # --- Resolve diff mode + range expression (single decision point) ---
  local mode="range" range_expr="${resolved_base}...HEAD" explicit_range=false
  if [[ "$working" == "true" ]]; then
    mode="working"; range_expr=""
  elif [[ -n "$range_arg" ]]; then
    mode="range"; range_expr="$range_arg"; explicit_range=true
  elif [[ -n "$head_arg" ]]; then
    mode="range"; range_expr="${resolved_base}...${head_arg}"; explicit_range=true
  fi
  # An explicit --range/--head must resolve; a typo fails loud (never a silent empty review).
  if [[ "$explicit_range" == "true" ]]; then
    if ! git -C "$project_dir" rev-list "$range_expr" -- >/dev/null 2>&1; then
      log_error "review: invalid range/ref '$range_expr'" "review"; return 1
    fi
  fi

  # --- Detect API change (mode-aware) ---
  local has_api_change="false"
  if [[ -d "$project_dir/.git" ]]; then
    local change_result
    change_result=$(is_api_change "$project_dir" "$project_type" "$mode" "$range_expr" 2>/dev/null || echo "low")
    [[ "${change_result%%|*}" == "high" ]] && has_api_change="true"
  fi

  # --- Output language ---
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""

  # --- Determine output mode ---
  local output_mode="terminal"
  [[ -n "$pr_number" || "${MRA_REVIEW_OUTPUT_MODE:-}" == "inline" ]] && output_mode="inline"

  # --- Auto-select strategy based on diff size ---
  local diff_for_strategy changed_files_for_strategy
  diff_for_strategy=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  changed_files_for_strategy=$(review_diff_files "$project_dir" "$mode" "$range_expr")
  local changed_count
  changed_count=$(printf '%s\n' "$changed_files_for_strategy" | { grep -c '[^[:space:]]' 2>/dev/null || true; } | tr -d '[:space:]')
  [[ -z "$changed_count" ]] && changed_count=0

  if [[ "$working" == "true" && "$changed_count" -eq 0 ]]; then
    log_info "no uncommitted changes to review" "review"
    return 0
  fi

  if [[ "$explicit_range" == "true" && "$changed_count" -eq 0 ]]; then
    log_info "review: no changes in '$range_expr' — nothing to review" "review"
    return 0
  fi

  local strategy=""
  if [[ -n "$force_strategy" ]]; then
    strategy="$force_strategy"
  elif [[ "$debate" == "false" ]]; then
    strategy="standard"
  else
    strategy=$(select_review_strategy "$diff_for_strategy" "$changed_count" "$has_api_change")
  fi

  # --- Log context ---
  log_progress "reviewing $project (type: $project_type, base: $base_ref, strategy: $strategy, provider: $(review_provider_label "$review_provider" "$model"))" "review"
  [[ "$has_api_change" == "true" ]] && log_warn "API change detected — loading consumer context" "review"
  [[ -n "$consumers" ]] && log_info "consumers: $consumers" "review"

  # --- PKB: Use knowledge base if available ---
  local pkb_context="" use_pkb=false
  if pkb_exists "$project_dir"; then
    local relevant_modules
    relevant_modules=$(pkb_modules_from_files "$changed_files_for_strategy" "$project_dir")
    # Review uses "standard" tier: sitemap + conventions + architecture + api-surface
    # Module summaries loaded only by debate Agent B (full tier) when needed
    pkb_context=$(pkb_build_context "$project_dir" "$relevant_modules" "standard")
    use_pkb=true
    log_info "PKB available — using knowledge base (modules: ${relevant_modules:-all})" "review"
  fi
  # --- Structural context (issue #25): symbol-level blast radius + affected
  # tests from an existing codegraph index. Best-effort and capped — with no
  # codegraph this adds nothing and the prompt stays byte-identical. ---
  local structural_context=""
  structural_context=$(structural_review_context "$project_dir" "$changed_files_for_strategy" 2>/dev/null) || structural_context=""
  if [[ -n "$structural_context" ]]; then
    if [[ -n "$pkb_context" ]]; then
      pkb_context="${pkb_context}

${structural_context}"
    else
      pkb_context="$structural_context"
    fi
    log_info "structural context loaded (codegraph)" "review"
  fi

  local review_instruction_context=""
  review_instruction_context=$(review_context_build "$project_dir")
  if [[ -n "$review_instruction_context" ]]; then
    if [[ -n "$pkb_context" ]]; then
      pkb_context="${review_instruction_context}

${pkb_context}"
    else
      pkb_context="$review_instruction_context"
    fi
    log_info "untrusted repository review guidance loaded" "review"
  fi

  # --- PR discussion context: let the review see the PR's existing comments /
  # reviews so it doesn't re-report already-raised issues or fight the author's
  # clarifications. Only on the --pr path; best-effort + gated (MRA_REVIEW_PR_CONTEXT=0
  # disables). Exported so the dispatched agents (run_agent_*/synthesis) read it. ---
  export MRA_REVIEW_PR_DISCUSSION=""
  if [[ -n "${MRA_REVIEW_SUPPLIED_CONTEXT:-}" ]]; then
    MRA_REVIEW_PR_DISCUSSION="$MRA_REVIEW_SUPPLIED_CONTEXT"
    log_info "loaded supplied untrusted PR scope into review context" "review"
  elif [[ -n "$pr_number" && "${MRA_REVIEW_PR_CONTEXT:-1}" != "0" ]]; then
    MRA_REVIEW_PR_DISCUSSION=$(_review_fetch_pr_discussion "$project_dir" "$pr_number")
    [[ -n "$MRA_REVIEW_PR_DISCUSSION" ]] && log_info "loaded existing PR discussion into review context" "review"
  fi

  # --- Build --add-dir args as a string shared by Claude and Codex providers ---
  local claude_add_dirs_str=""

  if [[ "$use_pkb" == "true" ]]; then
    # With PKB: only load changed-file directories (not full project)
    local focused_dirs
    focused_dirs=$(build_focused_context "$project_dir" "$changed_files_for_strategy")
    claude_add_dirs_str="$focused_dirs"
  else
    # Without PKB: load full project (original behavior)
    claude_add_dirs_str=$(build_add_dir_string "$project_dir")
  fi

  # Always add consumer/dep repos if API change
  for repo in $consumers $deps; do
    local repo_dir="$workspace/$repo"
    if [[ -d "$repo_dir" && "$repo" != "$project" ]]; then
      append_add_dir_string claude_add_dirs_str "$repo_dir"
    fi
  done

  # --- Build focused context (changed files only) for lightweight agents ---
  local claude_focused_dirs_str=""
  claude_focused_dirs_str=$(build_focused_context "$project_dir" "$changed_files_for_strategy")

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # ---- Persona-based review path (opt-in via --personas) ----
  # Reuses the debate path's post-synthesis rendering via the _render_review_json helper.
  if [[ "$review_personas_flag" == "true" && -n "$force_strategy" ]]; then
    log_warn "--strategy '$force_strategy' is ignored when --personas is set (persona path overrides strategy selection)" "review"
  fi
  if [[ "$review_personas_flag" == "true" ]]; then
    # diff via review-diff.sh (mode/range_expr resolved above)
    local persona_diff persona_changed
    persona_diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
    [[ -z "$persona_diff" ]] && persona_diff="(diff unavailable)"
    persona_changed=$(review_diff_files "$project_dir" "$mode" "$range_expr")
    local persona_lang=""
    [[ -n "$output_language" ]] && persona_lang="Use ${output_language} for all output."
    local persona_focused="$claude_focused_dirs_str"
    [[ -z "$persona_focused" ]] && persona_focused="$claude_add_dirs_str"

    local persona_findings
    persona_findings="$(run_persona_review \
      "$project" "$project_dir" "$persona_diff" "$persona_changed" \
      "$(default_review_personas)" "$consumers" "$persona_lang" "$model" \
      "$claude_add_dirs_str" "$pkb_context" "$review_provider")"

    local review_json
    review_json=$(run_synthesize \
      "$project" "$project_dir" "$persona_diff" "$persona_changed" \
      "$persona_findings" "" "$consumers" "$has_api_change" \
      "$persona_lang" "$model" "$persona_focused" "$mra_dir")

    _render_review_json "$review_json" "$output_mode" "$project_dir" "$pr_number" "personas" || return 1
    _review_notify_complete "$workspace" "$project" "$(_review_status_for_notify "$review_json")"
    _review_pkb_auto_update "$project" "$project_dir" "$persona_changed" "$output_language" "$review_json" "$review_provider" &
    return
  fi

  # ===================================================================
  # DEBATE MODE: multi-agent adversarial review
  # ===================================================================
  if [[ "$strategy" == "debate" ]]; then
    local review_json
    review_json=$(run_debate_review \
      "$project" "$project_dir" "$graph_file" "$base_ref" \
      "$project_type" "$consumers" "$deps" "$has_api_change" \
      "$output_language" "$model" "$claude_add_dirs_str" "$claude_focused_dirs_str" \
      "$pkb_context" "$mode" "$range_expr" "$review_provider")

    _review_emit_verdict "$review_json" "$project_dir"
    _render_review_json "$review_json" "$output_mode" "$project_dir" "$pr_number" "debate" || return 1
    _review_notify_complete "$workspace" "$project" "$(_review_status_for_notify "$review_json")"

    # Auto-update PKB after debate review (background, non-blocking)
    _review_pkb_auto_update "$project" "$project_dir" "$changed_files_for_strategy" "$output_language" "$review_json" "$review_provider" &
    return
  fi

  # ===================================================================
  # SINGLE-PASS MODE: light or standard review
  # ===================================================================

  # --- Build prompt ---
  local prompt
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$base_ref" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "$output_mode" "$mode" "$range_expr")
  prompt=$(_review_prompt_with_pr_discussion "$prompt")

  # Inject PKB context into prompt if available
  if [[ -n "$pkb_context" ]]; then
    prompt="${pkb_context}

${prompt}"
  fi

  # Turn budget per strategy (see _review_strategy_turns — tunable via env).
  local strategy_turns
  strategy_turns=$(_review_strategy_turns "$strategy")
  if [[ "$strategy" == "light" ]]; then
    log_info "light strategy: max-turns=$strategy_turns, focused context" "review"
  else
    log_info "standard strategy: max-turns=$strategy_turns" "review"
  fi

  # --- Run provider ---
  local system_prompt_file="$mra_dir/agents/code-reviewer.md"
  log_progress "running $(review_provider_label "$review_provider" "$model")..." "review"

  if [[ "$output_mode" == "terminal" ]]; then
    # Terminal mode: Claude streams live; Codex prints its final response.
    local terminal_rc=0
    review_call_model --stream review "$review_provider" "$prompt" "$model" "$project_dir" "$claude_add_dirs_str" "$strategy_turns" "$system_prompt_file" || terminal_rc=$?
    if [[ "$terminal_rc" -eq 0 ]]; then
      _review_notify_complete "$workspace" "$project" "COMPLETED"
    else
      log_warn "terminal review provider failed with rc=$terminal_rc; notifying REVIEW_INCOMPLETE" "review"
      _review_notify_complete "$workspace" "$project" "REVIEW_INCOMPLETE"
      return "$terminal_rc"
    fi
  else
    # Inline mode: get JSON, gate on the completion sentinel, post to GitHub.
    # `|| true` keeps a total provider failure from aborting under `set -e`.
    local review_json raw_review
    raw_review=$(review_call_model review "$review_provider" "$prompt" "$model" "$project_dir" "$claude_add_dirs_str" "$strategy_turns" "$system_prompt_file") || true
    # Missing sentinel / empty / unparseable => neutral REVIEW_INCOMPLETE (#8),
    # never a false APPROVE. _review_singlepass_body always yields valid JSON.
    review_json=$(_review_singlepass_body "$raw_review")
    _review_emit_verdict "$review_json" "$project_dir"
    # The inline schema only permits APPROVED/CHANGES_REQUESTED, so a COMMENT
    # status can ONLY be the neutral REVIEW_INCOMPLETE verdict — log it.
    if [[ "$(printf '%s' "$review_json" | jq -r .status)" == "COMMENT" ]]; then
      log_warn "single-pass review incomplete (no completion sentinel / empty / unparseable) — posting REVIEW_INCOMPLETE" "review"
    fi
    if [[ "${MRA_REVIEW_POST_MODE:-github}" != "none" ]]; then
      post_inline_review "$project_dir" "$pr_number" "$review_json" || return 1
    fi
    _review_notify_complete "$workspace" "$project" "$(_review_status_for_notify "$review_json")"
  fi

  # Auto-update PKB after single-pass review (background, non-blocking)
  _review_pkb_auto_update "$project" "$project_dir" "$changed_files_for_strategy" "$output_language" "${review_json:-}" "$review_provider" &
}

# Background PKB update after review — only runs if PKB exists
# Also captures decisions from review findings into conventions.md
_review_pkb_auto_update() {
  local project="$1" project_dir="$2" changed_files="$3" output_language="$4" review_json="${5:-}" provider="${6:-claude}"
  [[ "$provider" == "claude" ]] || return 0
  unset GH_TOKEN GITHUB_TOKEN
  if pkb_exists "$project_dir"; then
    pkb_incremental_update "$project" "$project_dir" "$changed_files" "haiku" "$output_language" 2>/dev/null
    # Capture decisions from review findings (mempalace-inspired conversation hook)
    if [[ -n "$review_json" ]] && echo "$review_json" | jq . &>/dev/null 2>&1; then
      pkb_capture_decisions "$project_dir" "$review_json" 2>/dev/null
    fi
  fi
}
