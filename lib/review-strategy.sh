#!/usr/bin/env bash
# Review strategy selection (light/standard/debate), turn budgets, and focused context.

## Strategy selection based on diff size, file count, and API change
## Returns: light | standard | debate
select_review_strategy() {
  local diff="$1" changed_count="$2" has_api_change="$3"

  local diff_lines
  diff_lines=$(printf '%s' "$diff" | wc -l | tr -d '[:space:]')
  diff_lines=$((diff_lines + 0))
  changed_count=$((changed_count + 0))

  if [[ "$diff_lines" -lt 50 && "$changed_count" -le 3 && "$has_api_change" == "false" ]]; then
    echo "light"
  elif [[ "$diff_lines" -lt 300 && "$has_api_change" == "false" ]]; then
    echo "standard"
  else
    echo "debate"
  fi
}

## Turn budget for a single-pass strategy. Tunable via env; too low a value cuts
## the agent off mid-analysis and yields an empty/garbled response (an incomplete
## review, not a clean one). standard default raised 3 -> 6.
##   light    -> MRA_REVIEW_LIGHT_MAX_TURNS    (default 2)
##   standard -> MRA_REVIEW_STANDARD_MAX_TURNS (default 6)
_review_strategy_turns() {
  case "$1" in
    light) echo "${MRA_REVIEW_LIGHT_MAX_TURNS:-2}" ;;
    *)     echo "${MRA_REVIEW_STANDARD_MAX_TURNS:-6}" ;;
  esac
}

# Build focused context: unique directories of changed files
# Used by lightweight agents (critique, refine, synthesize) to reduce token usage
# Uses --add-dir on changed-file directories instead of full project root
build_focused_context() {
  local project_dir="$1" changed_files="$2"
  local -A seen_dirs=()
  local context_args=""

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local dir
    dir=$(dirname "$project_dir/$file")
    [[ -d "$dir" ]] || continue
    if [[ -z "${seen_dirs[$dir]+x}" ]]; then
      seen_dirs["$dir"]=1
      append_add_dir_string context_args "$dir"
    fi
  done <<< "$changed_files"

  # Always include project root for config files (package.json, tsconfig, etc.)
  if [[ -z "${seen_dirs[$project_dir]+x}" ]]; then
    append_add_dir_string context_args "$project_dir"
  fi

  printf '%s' "$context_args"
}
