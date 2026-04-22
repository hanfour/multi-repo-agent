#!/usr/bin/env bash
# Persona-based review — N named personas run in parallel, findings concatenated,
# then handed off to run_synthesize from lib/review-debate.sh.

default_review_personas() {
  echo "security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect"
}

build_persona_prompt() {
  local persona="$1" diff="$2" changed_files="$3"
  local consumers="${4:-}" pkb_context="${5:-}" lang_directive="${6:-}"

  local persona_body
  persona_body="$(load_persona "$persona")" || return 1

  local pkb_section=""
  [[ -n "$pkb_context" ]] && pkb_section="$pkb_context

Use the knowledge base above. Only read source files to verify findings.
"

  local consumer_section=""
  [[ -n "$consumers" ]] && consumer_section="
Consumer projects: $consumers
Grep them for references to any changed/removed identifiers.
"

  cat <<PROMPT
${persona_body}

${pkb_section}${consumer_section}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

${lang_directive}

IMPORTANT: Every finding MUST include exact file:line evidence from the source.
PROMPT
}

run_persona_review() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local personas="$5" consumers="$6" lang_directive="$7" model="$8"
  local claude_add_dirs="$9" pkb_context="${10:-}"

  log_progress >&2 "[personas] running $(echo "$personas" | wc -w | tr -d ' ') personas in parallel..." "review"

  local pids=() result_files=()
  local p
  for p in $personas; do
    local f; f=$(mktemp)
    result_files+=("$f")
    (
      local prompt
      prompt=$(build_persona_prompt "$p" "$diff" "$changed_files" "$consumers" "$pkb_context" "$lang_directive")
      # shellcheck disable=SC2086
      claude -p "$prompt" \
        $claude_add_dirs \
        --model "$model" \
        --max-turns 8 \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project" 2>/dev/null
    ) > "$f" 2>/dev/null &
    pids+=("$!")
  done

  local pid
  for pid in "${pids[@]}"; do wait "$pid"; done

  local all_findings=""
  local f
  for f in "${result_files[@]}"; do
    all_findings+="$(cat "$f")"$'\n'
    rm -f "$f"
  done

  echo "$all_findings"
}
