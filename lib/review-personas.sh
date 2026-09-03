#!/usr/bin/env bash
# Persona-based review — N named personas run in parallel, findings concatenated,
# then handed off to run_synthesize from lib/review-debate.sh.

default_review_personas() {
  local base="security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect"
  if [[ "${MRA_REVIEW_ENABLE_CONVENTION_AUDITOR:-0}" == "1" ]]; then
    base="$base convention-auditor"
  fi
  if [[ "${MRA_REVIEW_ENABLE_UI_BEHAVIOR:-0}" == "1" ]]; then
    base="$base ui-behavior-inspector"
  fi
  echo "$base"
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

  local coverage_section=""
  if [[ "${MRA_REVIEW_ENABLE_COVERAGE_CHECKLIST:-0}" == "1" ]]; then
    coverage_section=$'## Coverage Checklist\nBefore finishing, account for every file in the Changed Files list above:\nmark it PASS (reviewed, no issue) or list your finding. Do not silently\nskip any file. If the Changed Files list is long, group entries by\ndirectory and give one PASS/finding line per group instead of per file —\ncall out individually only the files where you actually found something or\nthat you specifically inspected.\n\n'
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

%COVERAGE_SECTION%%LANG%

IMPORTANT: Every finding MUST include exact file:line evidence from the source.
TEMPLATE
)

  template="${template//%PERSONA_BODY%/$persona_body}"
  template="${template//%PKB_SECTION%/$pkb_section}"
  template="${template//%CONSUMER_SECTION%/$consumer_section}"
  template="${template//%DIFF%/$diff}"
  template="${template//%CHANGED_FILES%/$changed_files}"
  template="${template//%COVERAGE_SECTION%/$coverage_section}"
  template="${template//%LANG%/$lang_directive}"
  printf '%s\n' "$template"
}

run_persona_review() {
  local _project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local personas="$5" consumers="$6" lang_directive="$7" model="$8"
  local claude_add_dirs="$9" pkb_context="${10:-}"
  local provider="${11:-claude}"

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
      local prompt max_turns
      prompt=$(build_persona_prompt "$p" "$diff" "$changed_files" "$consumers" "$pkb_context" "$lang_directive")
      max_turns="${MRA_REVIEW_PERSONA_MAX_TURNS:-8}"
      if [[ "$p" == "convention-auditor" ]]; then
        max_turns="${MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS:-$max_turns}"
      fi
      review_call_model "review-persona" "$provider" "$prompt" "$model" \
        "$project_dir" "$claude_add_dirs" "$max_turns" ""
    ) > "$f" 2> "$err" &
    pids+=("$!")
  done

  # 失敗狀態要等所有子程序都 wait 完、輸出也清理完，才能交回呼叫端。
  # 否則全部失敗時，空的 findings 會被誤當成可以 synthesize 的輸入。
  local i pid rc failed_count=0 persona_count="${#pids[@]}"
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    # Capture the real exit code directly from `wait`, not from `!`
    # (negating before capturing $? always yields 0/1, never the real code —
    # that's why every "failed (rc=...)" log line used to read rc=0). Keep
    # `wait` as the if-condition itself (not `! wait`) so a nonzero exit
    # doesn't trip `set -e` (bin/mra.sh runs under `set -euo pipefail`) and
    # abort this loop before the remaining personas are waited on.
    if wait "$pid"; then
      rc=0
    else
      rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      failed_count=$((failed_count + 1))
      log_warn >&2 "[personas] ${persona_names[$i]} failed (rc=$rc) — stderr: ${err_files[$i]}" "review"
    fi
  done

  # Keep each persona's raw stdout/stderr when a dump dir is requested. What
  # normally survives a review is only the synthesized JSON, which cannot tell
  # "this persona never looked at the file" apart from "this persona flagged it
  # and synthesize dropped it" — both look identical downstream. Unset (the
  # default) writes nothing and leaves the flow untouched.
  local dump_dir="${MRA_REVIEW_PERSONA_DUMP_DIR:-}"
  if [[ -n "$dump_dir" ]] && ! mkdir -p "$dump_dir" 2>/dev/null; then
    log_warn >&2 "[personas] cannot create dump dir '$dump_dir' — raw outputs not kept" "review"
    dump_dir=""
  fi

  local all_findings=""
  local i f
  for i in "${!result_files[@]}"; do
    f="${result_files[$i]}"
    all_findings+="$(cat "$f")"$'\n'
    [[ -n "$dump_dir" ]] && cp "$f" "$dump_dir/${persona_names[$i]}.txt" 2>/dev/null
    rm -f "$f"
  done
  local e
  for i in "${!err_files[@]}"; do
    e="${err_files[$i]}"
    [[ -n "$dump_dir" ]] && cp "$e" "$dump_dir/${persona_names[$i]}.err" 2>/dev/null
    if [[ ! -s "$e" ]]; then
      rm -f "$e"
    fi
  done

  if [[ "$persona_count" -gt 0 && "$failed_count" -eq "$persona_count" ]]; then
    log_warn >&2 "[personas] PERSONAS_ALL_FAILED: ${persona_count} 個 persona 全部失敗，沒有東西可以 synthesize" "review"
    echo "$all_findings"
    return 1
  fi

  echo "$all_findings"
}
