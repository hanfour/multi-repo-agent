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
  if [[ -n "$pkb_context" ]]; then
    pkb_section="${pkb_context}"$'\n\nUse the knowledge base above. Only read source files to verify findings.\n'
  fi

  local consumer_section=""
  if [[ -n "$consumers" ]]; then
    consumer_section=$'\nConsumer projects: '"${consumers}"$'\nGrep them for references to any changed/removed identifiers.\n'
  fi

  local template
  template=$(cat <<'TEMPLATE'
%PERSONA_BODY%

%PKB_SECTION%%CONSUMER_SECTION%

## Diff
```diff
%DIFF%
```

## Changed Files
%CHANGED_FILES%

%LANG%

IMPORTANT: Every finding MUST include exact file:line evidence from the source.
TEMPLATE
)

  template="${template//%PERSONA_BODY%/$persona_body}"
  template="${template//%PKB_SECTION%/$pkb_section}"
  template="${template//%CONSUMER_SECTION%/$consumer_section}"
  template="${template//%DIFF%/$diff}"
  template="${template//%CHANGED_FILES%/$changed_files}"
  template="${template//%LANG%/$lang_directive}"
  printf '%s\n' "$template"
}

run_persona_review() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local personas="$5" consumers="$6" lang_directive="$7" model="$8"
  local claude_add_dirs="$9" pkb_context="${10:-}"

  log_progress >&2 "[personas] running $(echo "$personas" | wc -w | tr -d ' ') personas in parallel..." "review"

  local pids=() result_files=() err_files=() persona_names=()
  local p
  for p in $personas; do
    local f err
    f=$(mktemp)
    err=$(mktemp)
    result_files+=("$f")
    err_files+=("$err")
    persona_names+=("$p")
    (
      local prompt
      prompt=$(build_persona_prompt "$p" "$diff" "$changed_files" "$consumers" "$pkb_context" "$lang_directive")
      local _ad_arr=()
      expand_add_dir_string _ad_arr "$claude_add_dirs"
      claude -p "$prompt" \
        "${_ad_arr[@]}" \
        --model "$model" \
        --max-turns 8 \
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
      log_warn >&2 "[personas] ${persona_names[$i]} failed (rc=$rc) — stderr: ${err_files[$i]}" "review"
    fi
  done

  local all_findings=""
  local f
  for f in "${result_files[@]}"; do
    all_findings+="$(cat "$f")"$'\n'
    rm -f "$f"
  done
  local e
  for e in "${err_files[@]}"; do
    if [[ ! -s "$e" ]]; then
      rm -f "$e"
    fi
  done

  echo "$all_findings"
}
