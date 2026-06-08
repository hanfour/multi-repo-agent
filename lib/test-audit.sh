#!/usr/bin/env bash
# mra test-audit: audits project tests against Kent Beck 11 principles
# via the test-architect persona.

# find_test_files <dir>: list test files (macOS/Linux compatible)
find_test_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" \
    \( -path '*/node_modules' -o -path '*/.git' -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' \) -prune \
    -o -type f \( \
      -name '*.test.*' -o -name '*_test.*' -o -name '*.spec.*' \
    \) -print 2>/dev/null
}

# build_audit_prompt <file_path> <file_contents> [lang_directive]
# Uses safe placeholder substitution (no command eval on content)
build_audit_prompt() {
  local file_path="$1" file_contents="$2" lang_directive="${3:-}"

  local persona_body
  persona_body="$(load_persona "test-architect")" || return 1

  local template
  template=$(cat <<'TEMPLATE'
%PERSONA_BODY%

## File under audit: %FILE_PATH%

```
%FILE_CONTENTS%
```

## Your Task
Audit this test file against the 11 PRINCIPLES listed in your role.
For each violation, produce a finding with file:line and the principle number.

%LANG%
TEMPLATE
)

  template="${template//%PERSONA_BODY%/$persona_body}"
  template="${template//%FILE_PATH%/$file_path}"
  template="${template//%FILE_CONTENTS%/$file_contents}"
  template="${template//%LANG%/$lang_directive}"
  printf '%s\n' "$template"
}

# run_test_audit <project> <project_dir> <model> <add_dirs> [lang_directive]
# Audits each discovered test file in parallel (bounded by MRA_AUDIT_PARALLEL, default 5)
run_test_audit() {
  local project="$1" project_dir="$2" model="$3" claude_add_dirs="$4" lang_directive="${5:-}"

  log_progress >&2 "[test-audit] discovering tests in $project..." "test-audit"

  local files
  files=$(find_test_files "$project_dir")
  if [[ -z "$files" ]]; then
    log_warn >&2 "no test files found" "test-audit"
    echo '{"status":"NO_TESTS","findings":[]}'
    return
  fi

  local count; count=$(echo "$files" | wc -l | tr -d ' ')
  log_info >&2 "[test-audit] auditing $count test files..." "test-audit"

  local max_parallel="${MRA_AUDIT_PARALLEL:-5}"
  local pids=() results=() err_files=() file_list=()
  local active=0

  # wait -n requires bash 4.3+; detect once.
  local _wait_n_supported=false
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    _wait_n_supported=true
  fi

  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    # Bound parallelism: wait for a slot to open before dispatching another.
    if (( active >= max_parallel )); then
      if [[ "$_wait_n_supported" == "true" ]]; then
        wait -n 2>/dev/null || true
      else
        # Bash <4.3: block on the oldest pid.
        wait "${pids[0]}" 2>/dev/null || true
      fi
      active=$((active - 1))
    fi

    local out err
    out=$(mktemp); err=$(mktemp)
    results+=("$out")
    err_files+=("$err")
    file_list+=("$f")
    (
      local raw_size body trunc_note=""
      raw_size=$(wc -c < "$f" 2>/dev/null || echo 0)
      body=$(head -c 50000 "$f" 2>/dev/null || echo "")
      if (( raw_size > 50000 )); then
        trunc_note=$'\n\n[TRUNCATED at 50000 bytes; original size: '"$raw_size"$' bytes]'
      fi
      local prompt
      prompt=$(build_audit_prompt "$f" "${body}${trunc_note}" "$lang_directive")
      local _ad_arr=()
      expand_add_dir_string _ad_arr "$claude_add_dirs"
      claude -p "$prompt" \
        "${_ad_arr[@]}" \
        --model "$model" \
        --max-turns 3 \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project"
    ) > "$out" 2> "$err" &
    pids+=("$!")
    active=$((active + 1))
  done <<< "$files"

  # Drain remaining pids by index, warning on failures with correct file paths.
  local i pid rc
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    if ! wait "$pid" 2>/dev/null; then
      rc=$?
      # rc may be 127 if already reaped by `wait -n` — only warn when there's real stderr
      if [[ -s "${err_files[$i]}" ]]; then
        log_warn >&2 "[test-audit] ${file_list[$i]} failed (rc=$rc) — stderr: ${err_files[$i]}" "test-audit"
      fi
    fi
  done

  # Concatenate findings with file attribution; clean up.
  local all=""
  for i in "${!results[@]}"; do
    local content
    content="$(cat "${results[$i]}")"
    if [[ -n "$content" ]]; then
      all+="## ${file_list[$i]}"$'\n\n'
      all+="$content"$'\n\n'
    fi
    rm -f "${results[$i]}"
  done

  # Keep stderr logs only when non-empty (operator evidence for failures)
  local e
  for e in "${err_files[@]}"; do
    [[ -s "$e" ]] || rm -f "$e"
  done

  echo "$all"
}
