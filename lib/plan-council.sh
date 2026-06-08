#!/usr/bin/env bash
# Council Plan: N personas independently propose strategies for a task,
# then a synthesizer merges them into one unified plan.

default_plan_personas() {
  echo "security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect"
}

build_plan_prompt() {
  local persona="$1" task="$2" pkb_context="${3:-}" lang_directive="${4:-}"

  local persona_body
  persona_body="$(load_persona "$persona")" || return 1

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="${pkb_context}"$'\n\nUse the knowledge base above to ground every suggestion in the real code.\n'
  fi

  local template
  template=$(cat <<'TEMPLATE'
%PERSONA_BODY%

%PKB_SECTION%

## Task
%TASK%

## Your Role in Council Plan
You are ONE of several domain experts. Think independently. Do not defer to what another expert might say — your value is your unique lens.

Propose a concrete implementation strategy from YOUR domain's perspective:
1. What concerns MUST be addressed that others might miss?
2. Which files / modules will need to change?
3. What risks do you see? Rank them CRITICAL / HIGH / MEDIUM.
4. What tests must exist before merging?

## Output Format

### Perspective: <ROLE>

**Key concerns**
- <bullet list>

**Files to touch**
- `path/to/file` — <why>

**Risks**
- [CRITICAL] <risk + mitigation>
- [HIGH] <risk + mitigation>

**Required tests**
- <test description>

%LANG%
TEMPLATE
)

  # Safe substitution via bash parameter expansion (no command evaluation)
  template="${template//%PERSONA_BODY%/$persona_body}"
  template="${template//%PKB_SECTION%/$pkb_section}"
  template="${template//%TASK%/$task}"
  template="${template//%LANG%/$lang_directive}"
  printf '%s\n' "$template"
}

run_plan_council() {
  local project="$1" project_dir="$2" task="$3" personas="$4" model="$5"
  local claude_add_dirs="$6" pkb_context="${7:-}" lang_directive="${8:-}" dual="${9:-false}"

  local providers=("claude")
  [[ "$dual" == "true" ]] && providers=("claude" "codex")

  local expert_count; expert_count=$(echo "$personas" | wc -w | tr -d ' ')
  log_progress >&2 "[plan] convening council of $expert_count experts$([[ "$dual" == "true" ]] && echo ' ×2 models')..." "plan"

  local pids=() result_files=() err_files=() persona_names=() provider_names=()
  local p prov
  for p in $personas; do
    for prov in "${providers[@]}"; do
      local f err
      f=$(mktemp); err=$(mktemp)
      result_files+=("$f"); err_files+=("$err")
      persona_names+=("$p"); provider_names+=("$prov")
      (
        local prompt
        prompt=$(build_plan_prompt "$p" "$task" "$pkb_context" "$lang_directive")
        call_model "$prov" "$prompt" "$model" "$project_dir" "$claude_add_dirs" 6
      ) > "$f" 2> "$err" &
      pids+=("$!")
    done
  done

  local i pid rc
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    rc=0
    wait "$pid" || rc=$?
    if [[ $rc -ne 0 ]]; then
      log_warn >&2 "[plan] ${persona_names[$i]} [${provider_names[$i]}] failed (rc=$rc) — stderr: ${err_files[$i]}" "plan"
    fi
  done

  local all=""
  for i in "${!result_files[@]}"; do
    local tag content
    if [[ "$dual" == "true" ]]; then
      tag="### ${persona_names[$i]} [${provider_names[$i]}]"
    else
      tag="### ${persona_names[$i]}"
    fi
    content="$(cat "${result_files[$i]}")"
    if [[ "$dual" == "true" && -z "${content//[[:space:]]/}" ]]; then
      content="(no response — ${provider_names[$i]} call failed or returned empty)"
    fi
    all+="$tag"$'\n\n'"$content"$'\n\n---\n\n'
    rm -f "${result_files[$i]}"
  done
  local e
  for e in "${err_files[@]}"; do
    [[ -s "$e" ]] || rm -f "$e"
  done

  log_progress >&2 "[plan] synthesizing unified plan..." "plan"
  local synth_template
  if [[ "$dual" == "true" ]]; then
    synth_template=$(cat <<'TEMPLATE'
You are the council synthesizer. Below are independent plans for the same task, each from a domain expert as seen by TWO models (claude and codex). Blocks are tagged "### <persona> [claude]" / "### <persona> [codex]". A block reading "(no response — ...)" means that model did not return for that persona.

## Task
%TASK%

## Expert Perspectives (per persona × model)
%EXPERTS%

## Your Job
For each persona, COMPARE the claude and codex perspectives:
1. Where BOTH models agree → list under "High-confidence (both models agree)".
2. Where they DISAGREE, only one model raised it, or one is "(no response)" → list under "Model Disagreements" showing both sides. DO NOT pick a winner — leave it for a human to decide.
3. Then produce the consolidated plan, keeping every CRITICAL concern from either model with attribution.

%LANG%

## Output Format

# Unified Plan: <task>

## High-confidence (both models agree)
- [persona] <concern>

## ⚠ Model Disagreements (human decides)
- [persona] claude: <position> │ codex: <position>

## Consolidated Files
- `path` — <why, which expert/model raised it>

## Risks (sorted)
- [CRITICAL] [persona/model] <risk + mitigation>
- [HIGH] [persona/model] <risk + mitigation>

## Required Tests
- <test>

## Execution Steps
1. <step>
2. <step>
TEMPLATE
)
  else
    synth_template=$(cat <<'TEMPLATE'
You are the council synthesizer. Below are independent plans from N domain experts for the same task.

## Task
%TASK%

## Expert Perspectives
%EXPERTS%

## Your Job
Produce ONE unified implementation plan that:
1. Keeps every CRITICAL concern raised by any expert.
2. Merges overlapping files-to-touch into one consolidated list.
3. Orders risks by severity, keeping expert attribution (e.g. "[security-auditor] ...").
4. Lists required tests deduped across experts.
5. Ends with a numbered step-by-step TODO list ready for execution.

%LANG%

## Output Format

# Unified Plan: <task>

## Consolidated Files
- `path` — <why, which expert raised it>

## Risks (sorted)
- [CRITICAL] [expert] <risk>
- [HIGH] [expert] <risk>

## Required Tests
- <test>

## Execution Steps
1. <step>
2. <step>
TEMPLATE
)
  fi

  # Safe substitution via bash parameter expansion (no command evaluation)
  local synth_prompt="$synth_template"
  synth_prompt="${synth_prompt//%TASK%/$task}"
  synth_prompt="${synth_prompt//%EXPERTS%/$all}"
  synth_prompt="${synth_prompt//%LANG%/$lang_directive}"

  local synth_out; synth_out=$(mktemp)
  local synth_err; synth_err=$(mktemp)
  rc=0
  call_model claude "$synth_prompt" "$model" "$project_dir" "$claude_add_dirs" 4 \
    >"$synth_out" 2>"$synth_err" || rc=$?

  if [[ $rc -ne 0 ]]; then
    log_warn >&2 "[plan] synthesizer failed (rc=$rc) — stderr: $synth_err" "plan"
    rm -f "$synth_out"
    return $rc
  fi

  if [[ ! -s "$synth_out" ]]; then
    log_warn >&2 "[plan] synthesizer returned empty output — see stderr: $synth_err" "plan"
    rm -f "$synth_out"
    return 1
  fi

  cat "$synth_out"
  rm -f "$synth_out"
  [[ -s "$synth_err" ]] || rm -f "$synth_err"
}
