#!/usr/bin/env bash
# mra eval-review: evaluate review quality against human baseline
#
# Compares MRA's code review output against a known human review to measure:
#   - Precision: what % of MRA findings are real issues?
#   - Recall: what % of human findings did MRA catch?
#   - False Positive Rate: what % of MRA findings are noise?
#
# Usage:
#   mra eval-review <project> --pr <N> --base <ref>
#   mra eval-review <project> --pr <N> --baseline <file.json>
#
# If no --baseline, fetches existing human review from GitHub PR.
# Outputs a structured eval report.

eval_review() {
  local workspace="$1"
  shift
  local project="" pr_number="" base_ref="" baseline_file="" model="sonnet" strategy=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)
        if [[ $# -lt 2 ]]; then log_error "--pr requires a PR number" "eval"; return 1; fi
        pr_number="$2"; shift 2 ;;
      --base)
        if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "eval"; return 1; fi
        base_ref="$2"; shift 2 ;;
      --baseline)
        if [[ $# -lt 2 ]]; then log_error "--baseline requires a JSON file" "eval"; return 1; fi
        baseline_file="$2"; shift 2 ;;
      --model)
        if [[ $# -lt 2 ]]; then log_error "--model requires a value" "eval"; return 1; fi
        model="$2"; shift 2 ;;
      --strategy)
        if [[ $# -lt 2 ]]; then log_error "--strategy requires light|standard|debate" "eval"; return 1; fi
        strategy="$2"; shift 2 ;;
      -*)
        log_error "unknown option: $1" "eval"; return 1 ;;
      *)
        project="$1"; shift ;;
    esac
  done

  if [[ -z "$project" || -z "$pr_number" ]]; then
    log_error "usage: mra eval-review <project> --pr <N> [--baseline <file>] [--strategy <s>]" "eval"
    return 1
  fi

  local project_dir
  project_dir=$(resolve_project_dir "$workspace" "$project") || return 1

  # --- Step 1: Get human baseline ---
  log_progress "collecting baseline review..." "eval"
  local baseline_json
  if [[ -n "$baseline_file" && -f "$baseline_file" ]]; then
    baseline_json=$(cat "$baseline_file")
  else
    baseline_json=$(_eval_fetch_human_review "$project_dir" "$pr_number")
  fi

  if [[ -z "$baseline_json" || "$baseline_json" == "[]" || "$baseline_json" == "null" ]]; then
    log_error "no human review baseline found for PR #$pr_number" "eval"
    log_info "provide one with --baseline <file.json> or ensure human reviews exist on the PR" "eval"
    return 1
  fi

  local baseline_count
  baseline_count=$(echo "$baseline_json" | jq 'length')
  log_info "baseline: $baseline_count human findings" "eval"

  # --- Step 2: Run MRA review ---
  log_progress "running MRA review for comparison..." "eval"
  local review_args=("$workspace" "$project" "--pr" "$pr_number" "--model" "$model")
  [[ -n "$base_ref" ]] && review_args+=("--base" "$base_ref")
  [[ -n "$strategy" ]] && review_args+=("--strategy" "$strategy")

  # Capture the review JSON before it's posted
  # We'll run the review in capture mode by intercepting post_inline_review
  local mra_review_json
  mra_review_json=$(_eval_run_review "$workspace" "$project" "$pr_number" "$base_ref" "$model" "$strategy")

  if [[ -z "$mra_review_json" ]] || ! echo "$mra_review_json" | jq . &>/dev/null; then
    log_error "MRA review did not produce valid JSON" "eval"
    return 1
  fi

  local mra_count
  mra_count=$(echo "$mra_review_json" | jq '.comments | length')
  log_info "MRA review: $mra_count findings" "eval"

  # --- Step 3: Compare ---
  log_progress "comparing MRA vs baseline..." "eval"

  local eval_result
  eval_result=$(_eval_compare "$baseline_json" "$mra_review_json" "$model")

  # --- Step 4: Output report ---
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  MRA Review Evaluation Report"
  echo "  Project: $project | PR: #$pr_number"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "$eval_result"
  echo ""
  echo "═══════════════════════════════════════════════════════════"

  # Save report
  local report_dir="$workspace/.collab/eval"
  mkdir -p "$report_dir"
  local report_file="$report_dir/${project}_pr${pr_number}_$(date +%Y%m%d_%H%M%S).json"

  jq -n \
    --arg project "$project" \
    --argjson pr "$pr_number" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson baseline_count "$baseline_count" \
    --argjson mra_count "$mra_count" \
    --arg model "$model" \
    --arg strategy "${strategy:-auto}" \
    --arg report "$eval_result" \
    '{project: $project, pr: $pr, date: $date, model: $model, strategy: $strategy,
      baseline_findings: $baseline_count, mra_findings: $mra_count, report: $report}' \
    > "$report_file"

  log_success "report saved: $report_file" "eval"
}

# ---------------------------------------------------------------------------
# Fetch human review comments from GitHub PR
# Returns: JSON array of {path, line, body} objects
# ---------------------------------------------------------------------------
_eval_fetch_human_review() {
  local project_dir="$1" pr_number="$2"

  local remote_url
  remote_url=$(git -C "$project_dir" remote get-url origin 2>/dev/null)
  local repo_slug
  repo_slug=$(echo "$remote_url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')

  if [[ -z "$repo_slug" ]]; then
    echo "[]"
    return
  fi

  # Fetch all review comments (exclude bot/MRA comments)
  gh api "repos/$repo_slug/pulls/$pr_number/comments" --jq '
    [.[] |
      select(.user.type != "Bot") |
      select(.body | contains("MRA Code Review") | not) |
      select(.body | contains("Generated by") | not) |
      {
        path: .path,
        line: (.line // .original_line // 0),
        body: .body,
        author: .user.login
      }
    ]
  ' 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# Run MRA review and capture JSON output (without posting to GitHub)
# ---------------------------------------------------------------------------
_eval_run_review() {
  local workspace="$1" project="$2" pr_number="$3" base_ref="$4" model="$5" strategy="$6"

  local project_dir="$workspace/$project"
  local graph_file="$workspace/.collab/dep-graph.json"

  # Resolve base ref
  if [[ -z "$base_ref" ]]; then
    base_ref=$(resolve_pr_base "$project_dir" "$pr_number" 2>/dev/null || echo "main")
  fi

  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  # Get project metadata
  local project_type="unknown" consumers="" deps=""
  if [[ -f "$graph_file" ]]; then
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file" 2>/dev/null)
    consumers=$(jq -r --arg p "$project" '.projects[$p].consumedBy // [] | join(" ")' "$graph_file" 2>/dev/null)
    deps=$(jq -r --arg p "$project" '[.projects[$p].deps // {} | to_entries[].value[]] | unique | join(" ")' "$graph_file" 2>/dev/null)
  fi

  local has_api_change="false"
  if [[ -d "$project_dir/.git" ]]; then
    local change_result
    change_result=$(is_api_change "$project_dir" "$project_type" range "${resolved_base}...HEAD" 2>/dev/null || echo "low")
    [[ "${change_result%%|*}" == "high" ]] && has_api_change="true"
  fi

  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""

  # Build prompt for inline JSON output
  local prompt
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$resolved_base" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "inline" "range" "${resolved_base}...HEAD")

  # PKB context
  local pkb_ctx=""
  if pkb_exists "$project_dir"; then
    local changed_files
    changed_files=$(review_diff_files "$project_dir" range "${resolved_base}...HEAD")
    local relevant_modules
    relevant_modules=$(pkb_modules_from_files "$changed_files")
    pkb_ctx=$(pkb_build_context "$project_dir" "$relevant_modules" "standard")
  fi

  if [[ -n "$pkb_ctx" ]]; then
    prompt="${pkb_ctx}

${prompt}"
  fi

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local claude_args=("--add-dir" "$project_dir")
  claude_args+=(--append-system-prompt-file "$mra_dir/agents/code-reviewer.md")
  claude_args+=(--model "$model")
  claude_args+=(--max-turns 3)
  claude_args+=(--setting-sources "project")

  local raw_output
  raw_output=$(claude -p "$prompt" "${claude_args[@]}" 2>/dev/null)

  # Extract JSON
  extract_json "$raw_output"
}

# ---------------------------------------------------------------------------
# Compare baseline vs MRA using LLM-assisted matching
# ---------------------------------------------------------------------------
_eval_compare() {
  local baseline_json="$1" mra_review_json="$2" model="$3"

  local mra_comments
  mra_comments=$(echo "$mra_review_json" | jq -c '.comments // []')

  # Use Claude to do semantic matching between human and MRA findings
  local compare_prompt
  compare_prompt=$(cat <<PROMPT
You are an evaluation judge. Compare a human code review (baseline) against an automated review (MRA).

## Human Review Findings (Baseline — ground truth)
$baseline_json

## MRA Automated Review Findings
$mra_comments

## Your Task
1. For each MRA finding, determine if it matches a human finding (same file, similar issue).
   - TRUE POSITIVE: MRA found the same or equivalent issue as a human
   - FALSE POSITIVE: MRA flagged something the human didn't consider a problem
2. For each human finding, determine if MRA caught it.
   - CAUGHT: MRA has a matching finding
   - MISSED: Human found it but MRA did not
3. Calculate metrics:
   - Precision = true_positives / (true_positives + false_positives)
   - Recall = caught / (caught + missed)
   - F1 = 2 * precision * recall / (precision + recall)

## Output Format
### Matching Analysis

| MRA Finding | Match | Human Finding | Verdict |
|-------------|-------|---------------|---------|
| ... | TP/FP | ... or N/A | ... |

### Human Findings Coverage

| Human Finding | Status | MRA Match |
|---------------|--------|-----------|
| ... | CAUGHT/MISSED | ... or N/A |

### Metrics
- True Positives: N
- False Positives: N
- Missed: N
- Precision: N% (true_positives / total_mra_findings)
- Recall: N% (caught / total_human_findings)
- F1 Score: N%

### Assessment
<2-3 sentences on overall review quality and areas for improvement>

Use the output language from config if available.
PROMPT
)

  claude -p "$compare_prompt" --model "$model" --max-turns 1 --setting-sources "project" 2>/dev/null
}
