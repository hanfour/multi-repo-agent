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
  local claude_add_dirs="$6" pkb_context="${7:-}" lang_directive="${8:-}"

  log_progress >&2 "[plan] convening council of $(echo "$personas" | wc -w | tr -d ' ') experts..." "plan"

  local pids=() result_files=() err_files=() persona_names=()
  local p
  for p in $personas; do
    local f err
    f=$(mktemp); err=$(mktemp)
    result_files+=("$f")
    err_files+=("$err")
    persona_names+=("$p")
    (
      local prompt
      prompt=$(build_plan_prompt "$p" "$task" "$pkb_context" "$lang_directive")
      # shellcheck disable=SC2086
      claude -p "$prompt" \
        $claude_add_dirs \
        --model "$model" \
        --max-turns 6 \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project"
    ) > "$f" 2> "$err" &
    pids+=("$!")
  done

  local i pid rc
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    if ! wait "$pid"; then
      rc=$?
      log_warn >&2 "[plan] ${persona_names[$i]} failed (rc=$rc) — stderr: ${err_files[$i]}" "plan"
    fi
  done

  local all=""
  for i in "${!result_files[@]}"; do
    all+="### ${persona_names[$i]}"$'\n\n'
    all+="$(cat "${result_files[$i]}")"$'\n\n---\n\n'
    rm -f "${result_files[$i]}"
  done
  local e
  for e in "${err_files[@]}"; do
    [[ -s "$e" ]] || rm -f "$e"
  done

  log_progress >&2 "[plan] synthesizing unified plan..." "plan"
  local synth_template
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

  # Safe substitution via bash parameter expansion (no command evaluation)
  local synth_prompt="$synth_template"
  synth_prompt="${synth_prompt//%TASK%/$task}"
  synth_prompt="${synth_prompt//%EXPERTS%/$all}"
  synth_prompt="${synth_prompt//%LANG%/$lang_directive}"

  local synth_out; synth_out=$(mktemp)
  local synth_err; synth_err=$(mktemp)
  local rc=0
  # shellcheck disable=SC2086
  claude -p "$synth_prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 4 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" >"$synth_out" 2>"$synth_err" || rc=$?

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
