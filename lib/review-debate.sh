#!/usr/bin/env bash
# Adversarial multi-agent debate review system (optimized)
#
# Token optimization strategies applied:
# 1. Fast convergence: skip debate rounds when findings are few
# 2. Merged critique+refine: 2 agents per round instead of 4
# 3. Reduced max-turns: Agent A/B=8, critique-refine=5, synthesize=3
# 4. Model tiering: critique-refine uses haiku for cost savings
# 5. Focused context: non-search agents use --add-file instead of --add-dir
# 6. Leaner prompts: removed duplicated review criteria
#
# Usage: called from review.sh when strategy=debate

# Run the full debate review pipeline
# NOTE: All log_* calls use >&2 because this function runs inside $()
# and stdout must contain only the final JSON result
run_debate_review() {
  local project="$1"
  local project_dir="$2"
  # $3 (graph_file), $4 (base_ref), $7 (deps) are reserved slots in the
  # review-strategy call signature; this strategy does not use them.
  local _graph_file="$3"
  local _base_ref="$4"
  local project_type="$5"
  local consumers="$6"
  local _deps="$7"
  local has_api_change="$8"
  local output_language="$9"
  local model="${10:-sonnet}"
  local claude_add_dirs="${11:-}"
  local claude_focused_dirs="${12:-}"
  local pkb_context="${13:-}"
  local mode="${14:-range}"
  local range_expr="${15:-}"

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # --- Get diff (mode/range_expr resolved by review.sh) ---
  local diff
  diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")

  local lang_directive=""
  [[ -n "$output_language" ]] && lang_directive="Use ${output_language} for all output."

  # Model tiering: critique-refine uses haiku for cost savings
  local lite_model="haiku"

  # PKB tiering: critique-refine only needs minimal PKB (conventions)
  local pkb_context_lite=""
  if [[ -n "$pkb_context" ]]; then
    pkb_context_lite=$(pkb_build_context "$project_dir" "" "minimal")
  fi

  # Use focused context for non-search agents; fallback to full dirs
  local focused_ctx="$claude_focused_dirs"
  [[ -z "$focused_ctx" ]] && focused_ctx="$claude_add_dirs"

  # =====================================================================
  # ROUND 1: Independent Analysis (two agents in parallel)
  # =====================================================================
  log_progress >&2 "[round 1] independent analysis — 2 agents searching codebase..." "debate"

  local findings_a_file findings_b_file
  findings_a_file=$(mktemp)
  findings_b_file=$(mktemp)

  # Agent A: Impact Analyst — focuses on what's broken by the changes
  # With PKB: uses focused dirs + knowledge context (avoids full codebase scan)
  # Without PKB: uses full --add-dir (needs to search entire codebase)
  run_agent_a "$project" "$project_dir" "$diff" "$changed_files" \
    "$consumers" "$lang_directive" "$model" "$claude_add_dirs" \
    "$mra_dir" "$pkb_context" > "$findings_a_file" 2>/dev/null &
  local pid_a=$!

  # Agent B: Quality Auditor — focuses on code quality, security, patterns
  # With PKB: uses focused dirs + conventions/architecture knowledge
  # Without PKB: uses full --add-dir
  run_agent_b "$project" "$project_dir" "$diff" "$changed_files" \
    "$project_type" "$lang_directive" "$model" "$claude_add_dirs" \
    "$mra_dir" "$pkb_context" > "$findings_b_file" 2>/dev/null &
  local pid_b=$!

  wait $pid_a $pid_b
  local findings_a findings_b
  findings_a=$(cat "$findings_a_file")
  findings_b=$(cat "$findings_b_file")
  rm -f "$findings_a_file" "$findings_b_file"

  local count_a count_b
  count_a=$(echo "$findings_a" | grep -c '^\- \[' || true)
  count_b=$(echo "$findings_b" | grep -c '^\- \[' || true)
  count_a=${count_a//[^0-9]/}; [[ -z "$count_a" ]] && count_a=0
  count_b=${count_b//[^0-9]/}; [[ -z "$count_b" ]] && count_b=0
  log_info >&2 "[round 1] Agent A: $count_a findings, Agent B: $count_b findings" "debate"

  # =====================================================================
  # FAST CONVERGENCE: skip debate if findings are few or zero
  # =====================================================================
  local total_findings=$((count_a + count_b))

  if [[ "$total_findings" -eq 0 ]]; then
    log_success >&2 "[fast] no findings from either agent — APPROVED" "debate"
    echo '{"status":"APPROVED","summary":"No issues found by either agent","comments":[]}'
    return
  fi

  if [[ "$total_findings" -le 5 ]]; then
    log_info >&2 "[fast] few findings ($total_findings total), skipping debate — direct synthesis" "debate"
    run_synthesize "$project" "$project_dir" "$diff" "$changed_files" \
      "$findings_a" "$findings_b" "$consumers" "$has_api_change" \
      "$lang_directive" "$model" "$focused_ctx" "$mra_dir"
    return
  fi

  # =====================================================================
  # ROUND 2: Mailbox Voting — merge findings into shared pool, then vote
  #
  # Inspired by OpenHarness swarm mailbox pattern:
  # Instead of iterative critique→refine rounds, each agent independently
  # votes on a merged findings pool. Findings that survive voting (net
  # positive votes) proceed to synthesis.
  #
  # This is more token-efficient than iterative rounds because:
  # 1. Only 2 agents per voting round (not 4)
  # 2. Pool deduplicates findings upfront
  # 3. Single round typically sufficient for convergence
  # =====================================================================
  log_progress >&2 "[round 2] mailbox voting — merging findings into shared pool..." "debate"

  # Merge all findings into a numbered pool for voting
  local pool_file
  pool_file=$(mktemp)
  _build_findings_pool "$findings_a" "$findings_b" > "$pool_file"

  local pool
  pool=$(cat "$pool_file")
  rm -f "$pool_file"

  local pool_count
  pool_count=$(echo "$pool" | grep -c '^#[0-9]' || true)
  pool_count=${pool_count//[^0-9]/}; [[ -z "$pool_count" ]] && pool_count=0
  log_info >&2 "[round 2] merged pool: $pool_count unique findings" "debate"

  if [[ "$pool_count" -eq 0 ]]; then
    log_success >&2 "[round 2] empty pool after merge — APPROVED" "debate"
    echo '{"status":"APPROVED","summary":"No issues survived merging","comments":[]}'
    return
  fi

  # Two agents vote in parallel
  local vote_a_file vote_b_file
  vote_a_file=$(mktemp)
  vote_b_file=$(mktemp)

  run_vote "$project_dir" "$diff" "$pool" "Agent A (Impact Analyst)" \
    "$lang_directive" "$lite_model" "$focused_ctx" \
    "$mra_dir" "$pkb_context_lite" > "$vote_a_file" 2>/dev/null &
  local pid_va=$!

  run_vote "$project_dir" "$diff" "$pool" "Agent B (Quality Auditor)" \
    "$lang_directive" "$lite_model" "$focused_ctx" \
    "$mra_dir" "$pkb_context_lite" > "$vote_b_file" 2>/dev/null &
  local pid_vb=$!

  wait $pid_va $pid_vb
  local votes_a votes_b
  votes_a=$(cat "$vote_a_file")
  votes_b=$(cat "$vote_b_file")
  rm -f "$vote_a_file" "$vote_b_file"

  # Tally votes and filter surviving findings
  local surviving_findings
  surviving_findings=$(_tally_votes "$pool" "$votes_a" "$votes_b")

  local surviving_count
  surviving_count=$(echo "$surviving_findings" | grep -c '^\- \[' || true)
  surviving_count=${surviving_count//[^0-9]/}; [[ -z "$surviving_count" ]] && surviving_count=0
  log_info >&2 "[round 2] $surviving_count findings survived voting (from $pool_count)" "debate"

  # Use surviving findings for synthesis
  findings_a="$surviving_findings"
  findings_b=""

  # =====================================================================
  # FINAL: Synthesize into structured review
  # Uses focused context (not full codebase)
  # =====================================================================
  log_progress >&2 "[final] synthesizing review from debate results..." "debate"

  run_synthesize "$project" "$project_dir" "$diff" "$changed_files" \
    "$findings_a" "$findings_b" "$consumers" "$has_api_change" \
    "$lang_directive" "$model" "$focused_ctx" "$mra_dir"
}

# -----------------------------------------------------------------------
# Agent A: Impact Analyst
# Searches codebase for broken references, deleted API consumers, etc.
# Uses FULL --add-dir (needs codebase search)
# max-turns: 8 (down from 15)
# -----------------------------------------------------------------------
run_agent_a() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local consumers="$5" lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9" pkb_context="${10:-}"

  local consumer_note=""
  if [[ -n "$consumers" ]]; then
    consumer_note="Consumer projects that depend on this project's API: $consumers
Search their source code for references to any changed/deleted exports."
  fi

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="$pkb_context

Use the knowledge base above to understand the project structure and API surface.
Only read source files when you need exact file:line evidence for a finding.
"
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are Agent A (Impact Analyst). Find REAL, VERIFIED impact of this PR.
${pkb_section}
## Method
1. Read diff → identify added, modified, DELETED items.
2. For each deleted/renamed export: grep the project for remaining references. Report with file:line.
3. For modified signatures: search callers, verify compatibility.
4. Check for: duplicate definitions, duplicate imports, leftover debug artifacts, dead code.
5. Async safety: emit() vs emitAsync(), return type accuracy, await in try/catch.
${consumer_note}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output
- [CRITICAL] \`file:line\` — <verified issue with evidence>
- [HIGH] \`file:line\` — <verified issue with evidence>
- [MEDIUM] \`file:line\` — <potential issue>

If no references found for a deleted item: "Verified: <item> has no remaining references."

${lang_directive}

IMPORTANT: You MUST search the codebase using file reading/grep. Every finding must include exact file and line.
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 8 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Agent B: Quality Auditor
# Checks patterns, security, edge cases, best practices
# Uses FULL --add-dir (needs to read surrounding code & conventions)
# max-turns: 8 (down from 15)
# -----------------------------------------------------------------------
run_agent_b() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local project_type="$5" lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9" pkb_context="${10:-}"

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="$pkb_context

Use the knowledge base above for project conventions, architecture, and patterns.
Only read source files when you need to verify specific code around changed lines.
"
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are Agent B (Quality Auditor). Find code quality, security, and pattern issues.
${pkb_section}
## Method
1. Read diff + surrounding source files for context.
2. Read AGENTS.md / CLAUDE.md / .claude/rules/ for project conventions (skip if PKB conventions are provided above).
3. Check each category — report ONLY real issues found by reading code:
   - **Security**: XSS, injection, secrets, missing validation
   - **Error handling**: missing try/catch, unhandled rejections, missing error states
   - **State mgmt**: race conditions, stale closures, memory leaks; server data → TanStack Query not Zustand
   - **Type safety**: any usage, missing null checks, unsafe assertions
   - **Patterns**: violations of project conventions
   - **Performance**: static data inside components, missing useMemo for expensive ops
   - **Naming**: magic numbers, single-letter vars, missing validation messages
   - **Backend DDD**: bounded context isolation, transaction scope, OpenAPI accuracy
   - **Async safety**: emit vs emitAsync, Promise<T> accuracy, await in try/catch

## Project Type: ${project_type}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output
- [CRITICAL] \`file:line\` — <issue with evidence>
- [HIGH] \`file:line\` — <issue with evidence>
- [MEDIUM] \`file:line\` — <suggestion with rationale>

${lang_directive}

IMPORTANT: Read actual source files. Base findings on code, not assumptions.
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 8 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Merged Critique-and-Refine: one agent critiques the other AND updates
# its own findings in a single pass (replaces separate critique + refine)
# Uses FOCUSED context (changed files only) + haiku model
# max-turns: 5 (down from 10+10)
# -----------------------------------------------------------------------
run_critique_and_refine() {
  local project_dir="$1" diff="$2"
  local own_findings="$3" target_findings="$4" target_name="$5"
  local lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9" pkb_context="${10:-}"

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="$pkb_context
Use conventions above to judge whether findings align with project standards.
"
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are a critical reviewer. Review ${target_name}'s findings AND refine your own.
${pkb_section}

## Your Current Findings
${own_findings}

## ${target_name}'s Findings
${target_findings}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Tasks
1. For EACH of ${target_name}'s findings: verify by reading the source file.
   - WRONG → note why (file/line mismatch, flawed logic)
   - CORRECT but wrong severity → note upgrade/downgrade
   - MISSED something → add with file:line evidence
2. Update YOUR OWN findings:
   - Remove any you can no longer defend
   - Adjust severity based on valid challenges
   - Add new issues discovered during verification

## Output: Your REFINED findings list ONLY
- [CRITICAL] \`file:line\` — <issue with evidence>
- [HIGH] \`file:line\` — <issue with evidence>
- [MEDIUM] \`file:line\` — <issue>

${lang_directive}

Only include findings with evidence from actual source code.
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 5 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Mailbox: Build numbered findings pool from two agents' outputs
# Deduplicates by file:line, assigns unique IDs
# -----------------------------------------------------------------------
_build_findings_pool() {
  local findings_a="$1" findings_b="$2"

  # Extract finding lines from both agents
  local all_findings
  all_findings=$(
    echo "$findings_a" | grep '^\- \[' 2>/dev/null || true
    echo "$findings_b" | grep '^\- \[' 2>/dev/null || true
  )

  # Number each unique finding
  local i=1
  local -A seen=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract file:line as dedup key (macOS compatible, no -P flag)
    local key
    key=$(echo "$line" | sed -n 's/.*`\([^`]*\)`.*/\1/p' | head -1)
    [[ -z "$key" ]] && key="$line"
    if [[ -z "${seen[$key]+x}" ]]; then
      seen["$key"]=1
      echo "#${i}. ${line}"
      i=$((i + 1))
    fi
  done <<< "$all_findings"
}

# -----------------------------------------------------------------------
# Mailbox: Vote on findings pool
# Each agent independently votes KEEP/DROP on each finding
# Uses FOCUSED context + haiku model
# max-turns: 3
# -----------------------------------------------------------------------
run_vote() {
  local project_dir="$1" diff="$2" pool="$3" agent_name="$4"
  local lang_directive="$5" model="$6"
  local claude_add_dirs="$7" mra_dir="$8" pkb_context="${9:-}"

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="$pkb_context
"
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are ${agent_name}. Vote on each finding in the pool below.
${pkb_section}
## Findings Pool
${pool}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Your Task
For EACH numbered finding, verify by reading the actual source file, then vote:
- KEEP — the finding is valid and important
- DROP — the finding is wrong, irrelevant, or already handled

## Output Format (one line per finding)
#1. KEEP — <brief reason>
#2. DROP — <brief reason>
...

${lang_directive}

Be strict: only KEEP findings with real evidence. DROP anything speculative.
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 3 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Mailbox: Tally votes and return surviving findings
# A finding survives if at least one agent votes KEEP and neither
# votes DROP with strong evidence (net positive votes)
# -----------------------------------------------------------------------
_tally_votes() {
  local pool="$1" votes_a="$2" votes_b="$3"

  # Parse pool into associative array by ID
  local -A pool_items=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^#([0-9]+)\. ]]; then
      local id="${BASH_REMATCH[1]}"
      pool_items["$id"]="$line"
    fi
  done <<< "$pool"

  # Parse votes
  local -A score=()
  for votes in "$votes_a" "$votes_b"; do
    while IFS= read -r line; do
      if [[ "$line" =~ ^#([0-9]+)\..*KEEP ]]; then
        local id="${BASH_REMATCH[1]}"
        score["$id"]=$(( ${score[$id]:-0} + 1 ))
      elif [[ "$line" =~ ^#([0-9]+)\..*DROP ]]; then
        local id="${BASH_REMATCH[1]}"
        score["$id"]=$(( ${score[$id]:-0} - 1 ))
      fi
    done <<< "$votes"
  done

  # Output surviving findings (score >= 1, i.e., at least one KEEP and not unanimously DROP)
  for id in $(echo "${!pool_items[@]}" | tr ' ' '\n' | sort -n); do
    local s=${score[$id]:-0}
    if [[ $s -ge 1 ]]; then
      # Strip the #N. prefix and output as standard finding format
      echo "${pool_items[$id]}" | sed "s/^#[0-9]*\. //"
    fi
  done
}

# -----------------------------------------------------------------------
# Synthesize: merge debate results into final structured review
# Uses FOCUSED context (changed files only)
# max-turns: 3
# -----------------------------------------------------------------------
run_synthesize() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local findings_a="$5" findings_b="$6"
  local consumers="$7" has_api_change="$8"
  local lang_directive="$9" model="${10}" claude_add_dirs="${11}" mra_dir="${12}"

  local prompt
  prompt=$(cat <<'PROMPT_START'
You are the final synthesizer. Two agents have debated and refined their code review findings. Produce the FINAL review.

## Agent A (Impact Analyst) Final Findings
PROMPT_START
)

  prompt="${prompt}
${findings_a}

## Agent B (Quality Auditor) Final Findings
${findings_b}

## Changed Files
${changed_files}

## Rules
1. Deduplicate: if both agents found the same issue, merge into one.
2. Only include findings that survived the debate (were not disproven).
3. Prefer findings with specific file:line evidence over vague claims.
4. Status is APPROVED only if there are zero CRITICAL or HIGH issues.
${lang_directive}

## Output Format (STRICT JSON)

You MUST output ONLY valid JSON with no text before or after. No markdown fences.

{
  \"status\": \"APPROVED\" | \"CHANGES_REQUESTED\",
  \"summary\": \"<one-line summary of the review>\",
  \"comments\": [
    {
      \"path\": \"<file path relative to project root>\",
      \"line\": <line number in the NEW version of the file>,
      \"severity\": \"CRITICAL\" | \"HIGH\" | \"MEDIUM\",
      \"body\": \"<review comment — include evidence found by the agents>\"
    }
  ]
}

Rules for line numbers:
- Use line numbers from the NEW (right-side) version of the diff.
- Lines MUST be within a diff hunk. If the issue is on a deleted line, use the nearest remaining line in the same hunk."

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 3 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}
