#!/usr/bin/env bash
# Lint: profile-driven JS/TS BLOCKER rules.
#
# Rules live in templates/lint-profiles/<name>.json. Workspaces opt in via
# <workspace>/.collab/lint-profile.json:
#   {"profile": "ts-strict"}          -> templates/lint-profiles/ts-strict.json
#   {"rules": [...]}                 -> use rules inline (custom profile)
# When neither is provided, the default profile (no rules) is loaded and lint
# passes silently.
#
# Rule schema:
#   { "id", "severity": "blocker"|"warn", "pattern": <ERE-regex>,
#     "message", "line_excludes": [str], "file_excludes": [glob] }

# lint_load_profile <workspace>  -> prints rules JSON array on stdout.
lint_load_profile() {
  local workspace="$1"
  local profile_file="$workspace/.collab/lint-profile.json"
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ -f "$profile_file" ]]; then
    local inline_rules
    inline_rules=$(jq -c '.rules // empty' "$profile_file" 2>/dev/null)
    if [[ -n "$inline_rules" && "$inline_rules" != "null" ]]; then
      printf '%s' "$inline_rules"
      return
    fi
    local profile_name
    profile_name=$(jq -r '.profile // "default"' "$profile_file" 2>/dev/null)
    local bundled="$mra_dir/templates/lint-profiles/${profile_name}.json"
    if [[ -f "$bundled" ]]; then
      jq -c '.rules // []' "$bundled"
      return
    fi
    log_warn "lint-profile.json references unknown profile '$profile_name', using default" "lint" >&2
  fi

  local default_profile="$mra_dir/templates/lint-profiles/default.json"
  if [[ -f "$default_profile" ]]; then
    jq -c '.rules // []' "$default_profile"
  else
    printf '[]'
  fi
}

# _lint_run_rule <files-multiline> <project_dir> <rule-json> -> echoes violation count.
# file_excludes patterns use bash glob syntax; extglob is enabled locally so
# patterns like `*.@(test|spec).*` and `?(integration|e2e).*` are accepted.
_lint_run_rule() {
  shopt -s extglob 2>/dev/null || true

  local files="$1" project_dir="$2" rule="$3"

  local rule_id severity pattern message
  rule_id=$(echo "$rule" | jq -r '.id')
  severity=$(echo "$rule" | jq -r '.severity // "warn"')
  pattern=$(echo "$rule" | jq -r '.pattern')
  message=$(echo "$rule" | jq -r '.message')

  # Apply file_excludes via native bash glob matching to avoid regex pitfalls
  # (e.g. naive `*.d.ts -> .*.d.ts` would also drop `bad.ts`).
  local file_excludes
  file_excludes=$(echo "$rule" | jq -r '(.file_excludes // [])[]')
  if [[ -n "$file_excludes" ]]; then
    local filtered="" f glob skip
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      skip=0
      while IFS= read -r glob; do
        [[ -z "$glob" ]] && continue
        # shellcheck disable=SC2254
        case "$f" in
          $glob)   skip=1; break ;;
          */$glob) skip=1; break ;;
        esac
      done <<< "$file_excludes"
      if (( skip == 0 )); then
        filtered+="$f"$'\n'
      fi
    done <<< "$files"
    files="${filtered%$'\n'}"
  fi

  if [[ -z "$files" ]]; then
    echo 0
    return
  fi

  local raw
  raw=$(echo "$files" | xargs grep -Hn -E "$pattern" 2>/dev/null || true)

  if [[ -n "$raw" ]]; then
    local line_excludes
    line_excludes=$(echo "$rule" | jq -r '(.line_excludes // [])[]')
    if [[ -n "$line_excludes" ]]; then
      while IFS= read -r ex; do
        [[ -z "$ex" ]] && continue
        raw=$(echo "$raw" | grep -vF "$ex" || true)
      done <<< "$line_excludes"
    fi
  fi

  if [[ -z "$raw" ]]; then
    echo 0
    return
  fi

  local count
  count=$(echo "$raw" | wc -l | tr -d ' ')

  case "$severity" in
    blocker) log_error "$message ($count) [rule: $rule_id]" "lint" >&2 ;;
    *)       log_warn  "$message ($count) [rule: $rule_id]" "lint" >&2 ;;
  esac
  echo "$raw" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
    echo "    $line" >&2
  done
  [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more" >&2

  echo "$count"
}

lint_project() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local graph_file="$workspace/.collab/dep-graph.json"

  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "lint"; return 1; }

  local project_type="unknown"
  [[ -f "$graph_file" ]] && project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")

  case "$project_type" in
    node-frontend|node-backend|nextjs) ;;
    *)
      log_info "$project ($project_type): skipping lint (not a JS/TS project)" "lint"
      return 0
      ;;
  esac

  local rules
  rules=$(lint_load_profile "$workspace")
  local rule_count
  rule_count=$(echo "$rules" | jq 'length')
  if [[ "$rule_count" -eq 0 ]]; then
    log_info "$project: no lint rules in profile (configure .collab/lint-profile.json)" "lint"
    return 0
  fi

  log_progress "$project: checking $rule_count rule(s)" "lint"

  local total_violations=0 blocker_violations=0
  local src_dir="$project_dir/src"
  [[ ! -d "$src_dir" ]] && src_dir="$project_dir"

  local files
  files=$(find "$src_dir" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) \
    -not -path "*/node_modules/*" \
    -not -path "*/dist/*" \
    -not -path "*/.git/*" \
    -not -path "*/vendor/*" \
    -not -name "*.d.ts" \
    -not -name "*.test.*" \
    -not -name "*.spec.*" \
    2>/dev/null)

  [[ -z "$files" ]] && { log_info "$project: no TS/JS source files found" "lint"; return 0; }

  local file_count; file_count=$(echo "$files" | wc -l | tr -d ' ')
  log_info "$project: scanning $file_count file(s)" "lint"

  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    local count
    count=$(_lint_run_rule "$files" "$project_dir" "$rule")
    count=${count:-0}
    total_violations=$((total_violations + count))
    if [[ "$(echo "$rule" | jq -r '.severity // "warn"')" == "blocker" ]]; then
      blocker_violations=$((blocker_violations + count))
    fi
  done < <(echo "$rules" | jq -c '.[]')

  echo ""
  if [[ $total_violations -eq 0 ]]; then
    log_success "$project: no violations found" "lint"
  else
    log_error "$project: $total_violations violation(s) found ($blocker_violations blocker)" "lint"
  fi

  return $([[ $blocker_violations -eq 0 ]] && echo 0 || echo 1)
}

lint_all_projects() {
  local workspace="$1"
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")
  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "lint"; return 1; }

  local total=0 failed=0
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    [[ ! -d "$workspace/$project" ]] && continue
    local project_type
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")
    case "$project_type" in
      node-frontend|node-backend|nextjs)
        total=$((total + 1))
        lint_project "$workspace" "$project" || failed=$((failed + 1))
        ;;
    esac
  done < <(jq -r '.projects | keys[]' "$graph_file")

  echo ""
  if [[ $failed -eq 0 ]]; then
    log_success "lint complete: $total project(s) checked, all clean" "lint"
  else
    log_error "lint complete: $failed/$total project(s) have violations" "lint"
  fi
}
