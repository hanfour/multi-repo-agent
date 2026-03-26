#!/usr/bin/env bash
# Lint: check OneAD frontend JS/TS BLOCKER rules

lint_project() {
  local workspace="$1" project="$2"
  local project_dir="$workspace/$project"
  local graph_file="$workspace/.collab/dep-graph.json"

  [[ ! -d "$project_dir" ]] && { log_error "$project: not found" "lint"; return 1; }

  # Determine project type
  local project_type="unknown"
  [[ -f "$graph_file" ]] && project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file")

  # Only lint frontend/TS projects
  case "$project_type" in
    node-frontend|node-backend|nextjs) ;;
    *)
      log_info "$project ($project_type): skipping lint (not a JS/TS project)" "lint"
      return 0
      ;;
  esac

  log_progress "$project: checking BLOCKER rules" "lint"

  local total_violations=0
  local src_dir="$project_dir/src"
  [[ ! -d "$src_dir" ]] && src_dir="$project_dir"

  # Find all TS/JS files (exclude node_modules, dist, .git)
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

  # BLOCKER 1: interface keyword (should use type)
  local violations
  violations=$(echo "$files" | xargs grep -Hn '^\s*\(export\s\+\)\?interface\s\+\w\+' 2>/dev/null | grep -v "// eslint-disable" | head -20)
  if [[ -n "$violations" ]]; then
    local count; count=$(echo "$violations" | wc -l | tr -d ' ')
    total_violations=$((total_violations + count))
    log_error "BLOCKER: 'interface' found ($count) — use 'type' instead" "lint"
    echo "$violations" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
      echo "    $line"
    done
    [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more"
  fi

  # BLOCKER 2: enum keyword
  violations=$(echo "$files" | xargs grep -Hn '^\s*\(export\s\+\)\?enum\s\+\w\+' 2>/dev/null | grep -v "// eslint-disable" | head -20)
  if [[ -n "$violations" ]]; then
    local count; count=$(echo "$violations" | wc -l | tr -d ' ')
    total_violations=$((total_violations + count))
    log_error "BLOCKER: 'enum' found ($count) — use 'as const' object instead" "lint"
    echo "$violations" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
      echo "    $line"
    done
    [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more"
  fi

  # BLOCKER 3: any type annotation
  violations=$(echo "$files" | xargs grep -Hn ':\s*any\b' 2>/dev/null | grep -v "// eslint-disable\|// @ts-\|\.d\.ts" | head -20)
  if [[ -n "$violations" ]]; then
    local count; count=$(echo "$violations" | wc -l | tr -d ' ')
    total_violations=$((total_violations + count))
    log_error "BLOCKER: 'any' type found ($count) — use 'unknown' with type guards" "lint"
    echo "$violations" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
      echo "    $line"
    done
    [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more"
  fi

  # BLOCKER 4: non-null assertion !. (excluding tests)
  violations=$(echo "$files" | xargs grep -Hn '\w\+!\.' 2>/dev/null | grep -v "// eslint-disable\|\.test\.\|\.spec\." | head -20)
  if [[ -n "$violations" ]]; then
    local count; count=$(echo "$violations" | wc -l | tr -d ' ')
    total_violations=$((total_violations + count))
    log_warn "WARN: non-null assertion '!' found ($count) — prefer type guards" "lint"
    echo "$violations" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
      echo "    $line"
    done
    [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more"
  fi

  # BLOCKER 5: var keyword
  violations=$(echo "$files" | xargs grep -Hn '^\s*var\s\+' 2>/dev/null | head -20)
  if [[ -n "$violations" ]]; then
    local count; count=$(echo "$violations" | wc -l | tr -d ' ')
    total_violations=$((total_violations + count))
    log_warn "WARN: 'var' found ($count) — use 'const' or 'let'" "lint"
    echo "$violations" | head -5 | sed "s|$project_dir/||g" | while read -r line; do
      echo "    $line"
    done
    [[ $count -gt 5 ]] && echo "    ... and $((count - 5)) more"
  fi

  echo ""
  if [[ $total_violations -eq 0 ]]; then
    log_success "$project: no violations found" "lint"
  else
    log_error "$project: $total_violations violation(s) found" "lint"
  fi

  return $([[ $total_violations -eq 0 ]] && echo 0 || echo 1)
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
