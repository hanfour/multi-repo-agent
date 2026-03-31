#!/usr/bin/env bash
# Adversarial multi-agent debate review system
#
# Multiple specialized agents independently analyze code, then
# cross-critique each other's findings in iterative rounds until
# consensus is reached. Produces higher-quality reviews by:
# 1. Actually searching the codebase (agentic mode with tools)
# 2. Challenging each finding with counter-evidence
# 3. Eliminating false positives through adversarial debate
#
# Usage: called from review.sh when --debate flag is used

DEBATE_MAX_ROUNDS=3

# Run the full debate review pipeline
run_debate_review() {
  local project="$1"
  local project_dir="$2"
  local graph_file="$3"
  local base_ref="$4"
  local project_type="$5"
  local consumers="$6"
  local deps="$7"
  local has_api_change="$8"
  local output_language="$9"
  local model="${10:-sonnet}"
  local claude_add_dirs="${11:-}"

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # --- Resolve base ref ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  local diff
  diff=$(git -C "$project_dir" diff "${resolved_base}...HEAD" 2>/dev/null || \
         git -C "$project_dir" diff "${resolved_base}" HEAD 2>/dev/null || \
         echo "(diff unavailable)")

  local changed_files
  changed_files=$(git -C "$project_dir" diff --name-only "${resolved_base}...HEAD" 2>/dev/null || \
                  git -C "$project_dir" diff --name-only "${resolved_base}" HEAD 2>/dev/null || \
                  echo "")

  local lang_directive=""
  [[ -n "$output_language" ]] && lang_directive="Use ${output_language} for all output."

  # =====================================================================
  # ROUND 1: Independent Analysis (two agents in parallel)
  # =====================================================================
  log_progress "[round 1] independent analysis — 2 agents searching codebase..." "debate"

  local findings_a_file findings_b_file
  findings_a_file=$(mktemp)
  findings_b_file=$(mktemp)

  # Agent A: Impact Analyst — focuses on what's broken by the changes
  run_agent_a "$project" "$project_dir" "$diff" "$changed_files" \
    "$consumers" "$lang_directive" "$model" "$claude_add_dirs" \
    "$mra_dir" > "$findings_a_file" 2>/dev/null &
  local pid_a=$!

  # Agent B: Quality Auditor — focuses on code quality, security, patterns
  run_agent_b "$project" "$project_dir" "$diff" "$changed_files" \
    "$project_type" "$lang_directive" "$model" "$claude_add_dirs" \
    "$mra_dir" > "$findings_b_file" 2>/dev/null &
  local pid_b=$!

  wait $pid_a $pid_b
  local findings_a findings_b
  findings_a=$(cat "$findings_a_file")
  findings_b=$(cat "$findings_b_file")
  rm -f "$findings_a_file" "$findings_b_file"

  local count_a count_b
  count_a=$(echo "$findings_a" | grep -c '^\- \[' 2>/dev/null | tr -d '[:space:]' || echo "0")
  count_b=$(echo "$findings_b" | grep -c '^\- \[' 2>/dev/null | tr -d '[:space:]' || echo "0")
  [[ -z "$count_a" ]] && count_a=0
  [[ -z "$count_b" ]] && count_b=0
  log_info "[round 1] Agent A: $count_a findings, Agent B: $count_b findings" "debate"

  # =====================================================================
  # ROUND 2+: Adversarial Cross-Critique Loop
  # =====================================================================
  local round=2
  local prev_critique_a="" prev_critique_b=""

  while [[ $round -le $((DEBATE_MAX_ROUNDS + 1)) ]]; do
    log_progress "[round $round] cross-critique — agents challenging each other..." "debate"

    local critique_a_file critique_b_file
    critique_a_file=$(mktemp)
    critique_b_file=$(mktemp)

    # Agent A critiques Agent B's findings
    run_critique "$project_dir" "$diff" "$findings_b" "Agent B (Quality Auditor)" \
      "$findings_a" "$lang_directive" "$model" "$claude_add_dirs" \
      "$mra_dir" > "$critique_a_file" 2>/dev/null &
    local pid_ca=$!

    # Agent B critiques Agent A's findings
    run_critique "$project_dir" "$diff" "$findings_a" "Agent A (Impact Analyst)" \
      "$findings_b" "$lang_directive" "$model" "$claude_add_dirs" \
      "$mra_dir" > "$critique_b_file" 2>/dev/null &
    local pid_cb=$!

    wait $pid_ca $pid_cb
    local critique_a critique_b
    critique_a=$(cat "$critique_a_file")
    critique_b=$(cat "$critique_b_file")
    rm -f "$critique_a_file" "$critique_b_file"

    # Check convergence: if critiques are essentially "no issues found"
    local new_issues_a new_issues_b
    new_issues_a=$(echo "$critique_a" | grep -c "DISAGREE\|MISSING\|UPGRADE\|NEW" 2>/dev/null | tr -d '[:space:]' || echo "0")
    new_issues_b=$(echo "$critique_b" | grep -c "DISAGREE\|MISSING\|UPGRADE\|NEW" 2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$new_issues_a" ]] && new_issues_a=0
    [[ -z "$new_issues_b" ]] && new_issues_b=0

    log_info "[round $round] critique A: $new_issues_a challenges, critique B: $new_issues_b challenges" "debate"

    if [[ "$new_issues_a" -eq 0 && "$new_issues_b" -eq 0 ]]; then
      log_success "[round $round] consensus reached — no new challenges" "debate"
      break
    fi

    if [[ $round -gt $DEBATE_MAX_ROUNDS ]]; then
      log_warn "max rounds ($DEBATE_MAX_ROUNDS) reached, proceeding to synthesis" "debate"
      break
    fi

    # Refine findings based on critique
    log_progress "[round $round] agents refining based on critique..." "debate"

    local refined_a_file refined_b_file
    refined_a_file=$(mktemp)
    refined_b_file=$(mktemp)

    run_refine "$project_dir" "$diff" "$findings_a" "$critique_b" \
      "$lang_directive" "$model" "$claude_add_dirs" "$mra_dir" > "$refined_a_file" 2>/dev/null &
    local pid_ra=$!

    run_refine "$project_dir" "$diff" "$findings_b" "$critique_a" \
      "$lang_directive" "$model" "$claude_add_dirs" "$mra_dir" > "$refined_b_file" 2>/dev/null &
    local pid_rb=$!

    wait $pid_ra $pid_rb
    findings_a=$(cat "$refined_a_file")
    findings_b=$(cat "$refined_b_file")
    rm -f "$refined_a_file" "$refined_b_file"

    ((round++))
  done

  # =====================================================================
  # FINAL: Synthesize into structured review
  # =====================================================================
  log_progress "[final] synthesizing review from debate results..." "debate"

  run_synthesize "$project" "$project_dir" "$diff" "$changed_files" \
    "$findings_a" "$findings_b" "$consumers" "$has_api_change" \
    "$lang_directive" "$model" "$claude_add_dirs" "$mra_dir"
}

# -----------------------------------------------------------------------
# Agent A: Impact Analyst
# Searches codebase for broken references, deleted API consumers, etc.
# -----------------------------------------------------------------------
run_agent_a() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local consumers="$5" lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9"

  local consumer_note=""
  if [[ -n "$consumers" ]]; then
    consumer_note="Consumer projects that depend on this project's API: $consumers
Search their source code for references to any changed/deleted exports."
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are Agent A (Impact Analyst). Your job is to find REAL, VERIFIED impact of this PR on the codebase.

## Your Method
1. Read the diff to identify what was added, modified, or DELETED.
2. For each deleted/renamed export, function, type, or hook:
   - Use grep/read to search the ENTIRE project for files that import or reference it.
   - Report ONLY confirmed references with exact file paths and line numbers.
3. For each modified function signature or return type:
   - Search for all callers and verify they are compatible with the new signature.
4. Check for duplicate definitions:
   - Search if the same function/type/component name exists elsewhere in the project.
   - Flag if a new utility duplicates an existing one.
5. Check for duplicate imports:
   - Search if the same module (e.g., devtools, providers) is imported in multiple entry points.
6. Check for leftover test/debug artifacts:
   - Search for console.log, devtools references, temporary mocks, or test-only code in production files.
7. Dead code detection:
   - When a function/method is deleted or replaced, search for remaining references in port interfaces, adapters, test mocks, re-exports.
   - Report exact file:line of each orphaned reference.
8. Async safety:
   - If event emission is modified, verify emit() vs emitAsync() correctness.
   - If return types changed, verify all callers handle the new type.
   - If try/catch wraps async calls, verify the call is awaited.
${consumer_note}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output Format
List your findings as:
- [CRITICAL] \`file:line\` — <verified issue with evidence>
- [HIGH] \`file:line\` — <verified issue with evidence>
- [MEDIUM] \`file:line\` — <potential issue, explain uncertainty>

If you searched and found NO references to a deleted item, state: "Verified: <item> has no remaining references."

${lang_directive}

IMPORTANT: You MUST actually search the codebase using file reading. Do NOT guess or speculate. Every finding must include the exact file and line you found.
PROMPT
)

  # shellcheck disable=SC2086
  claude -p "$prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 15 \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Agent B: Quality Auditor
# Checks patterns, security, edge cases, best practices
# -----------------------------------------------------------------------
run_agent_b() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local project_type="$5" lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9"

  local prompt
  prompt=$(cat <<PROMPT
You are Agent B (Quality Auditor). Your job is to find code quality, security, and pattern issues in this PR.

## Your Method
1. Read the diff to understand the changes.
2. Read the surrounding source files to understand the existing patterns and conventions.
3. Read the project's AGENTS.md, CLAUDE.md, or .claude/rules/ files if they exist — these contain project-specific conventions.
4. Check for:
   - Security issues (XSS, injection, exposed secrets, missing validation)
   - Error handling gaps (missing try/catch, unhandled promise rejections, missing error states)
   - State management issues (race conditions, stale closures, memory leaks in effects)
   - Type safety (any usage, missing null checks, unsafe type assertions)
   - Pattern violations (does new code follow existing project conventions?)
   - Missing edge cases (empty arrays, null/undefined, loading/error states)
5. Architecture & state management:
   - Server data (API responses) should be in TanStack Query, NOT in client stores (Zustand/Pinia)
   - Store access should be wrapped in custom hooks, not called directly in components
   - API types should use Zod schema validation when the project uses Zod
6. Performance:
   - Static data (column definitions, config objects) should be hoisted outside components
   - Check if expensive computations need useMemo
7. Tailwind & styling:
   - Use cn() for conditional classes, not ternary string concatenation
   - No hardcoded color values (oklch, hex, rgb) — use theme tokens
   - No redundant width + max-width
8. Code readability:
   - Nested map/filter chains → suggest flatMap or reduce
   - Complex spread logic → suggest named intermediate variables
   - If project has es-toolkit/lodash, use their utilities instead of hand-rolling
9. Naming & magic values:
   - No single-letter variable names (r, e, x) outside tiny lambdas
   - No magic numbers — use named constants
   - Repeated string operations (e.g., date.substring(0,7)) → extract helper
   - Validation decorators (@Matches, @IsString) should have custom error messages
10. Backend architecture (NestJS/DDD):
   - Module A should not import module B's internal entities — use shared ports
   - Transaction scope: avoid cross-DB I/O inside transactions
   - OpenAPI: integer DB fields must use type 'integer' in @ApiProperty
   - Shared utilities should live outside specific modules
11. Async safety:
   - emit() vs emitAsync() — async handlers need emitAsync()
   - Return types must reflect async reality (Promise<T> not T)
   - try/catch must await async calls to catch errors

## Project Type: ${project_type}

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output Format
List your findings as:
- [CRITICAL] \`file:line\` — <issue with evidence from reading the code>
- [HIGH] \`file:line\` — <issue with evidence>
- [MEDIUM] \`file:line\` — <suggestion with rationale>

${lang_directive}

IMPORTANT: Read the actual source files around the changed code. Base your findings on what you see in the codebase, not assumptions.
PROMPT
)

  # shellcheck disable=SC2086
  claude -p "$prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 15 \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Cross-Critique: one agent reviews the other's findings
# -----------------------------------------------------------------------
run_critique() {
  local project_dir="$1" diff="$2" target_findings="$3" target_name="$4"
  local own_findings="$5" lang_directive="$6" model="$7"
  local claude_add_dirs="$8" mra_dir="$9"

  local prompt
  prompt=$(cat <<PROMPT
You are a critical reviewer. Another agent (${target_name}) produced the following code review findings. Your job is to CHALLENGE them.

## ${target_name}'s Findings
${target_findings}

## Your Own Findings (for context)
${own_findings}

## The Diff Being Reviewed
\`\`\`diff
${diff}
\`\`\`

## Your Task
For EACH finding by ${target_name}:
1. Verify the claim by reading the actual source file and line mentioned.
2. If the finding is WRONG (file doesn't exist, line doesn't match, logic is flawed):
   → Mark as: DISAGREE — <reason with evidence>
3. If the finding is CORRECT but severity is wrong:
   → Mark as: UPGRADE/DOWNGRADE — <reason>
4. If the finding is valid:
   → Mark as: AGREE
5. If ${target_name} MISSED something important that you found:
   → Mark as: MISSING — <what was missed, with file:line evidence>

## Output Format
For each of ${target_name}'s findings:
- [AGREE/DISAGREE/UPGRADE/DOWNGRADE] Finding: "<summary>" — <your evidence>

Additional findings they missed:
- [NEW] \`file:line\` — <issue with evidence>

${lang_directive}

IMPORTANT: Actually read the files to verify. Do not just agree or disagree based on reasoning alone.
PROMPT
)

  # shellcheck disable=SC2086
  claude -p "$prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 10 \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Refine: agent updates findings based on critique received
# -----------------------------------------------------------------------
run_refine() {
  local project_dir="$1" diff="$2" own_findings="$3" critique="$4"
  local lang_directive="$5" model="$6" claude_add_dirs="$7" mra_dir="$8"

  local prompt
  prompt=$(cat <<PROMPT
You previously produced these code review findings:

## Your Previous Findings
${own_findings}

## Critique You Received
${critique}

## The Diff
\`\`\`diff
${diff}
\`\`\`

## Your Task
1. For each DISAGREE critique: re-verify by reading the file. If they're right, remove or fix your finding. If you're still correct, keep it with stronger evidence.
2. For each UPGRADE/DOWNGRADE: adjust severity if the argument is valid.
3. For each MISSING/NEW item: verify it and add to your findings if confirmed.
4. Remove any finding you can no longer defend with evidence.

## Output Format
Your refined findings list:
- [CRITICAL] \`file:line\` — <issue with evidence>
- [HIGH] \`file:line\` — <issue with evidence>
- [MEDIUM] \`file:line\` — <issue>

${lang_directive}

Only include findings you can defend with evidence from the actual source code.
PROMPT
)

  # shellcheck disable=SC2086
  claude -p "$prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 10 \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Synthesize: merge debate results into final structured review
# -----------------------------------------------------------------------
run_synthesize() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local findings_a="$5" findings_b="$6"
  local consumers="$7" has_api_change="$8"
  local lang_directive="$9" model="${10}" claude_add_dirs="${11}" mra_dir="${12}"

  local prompt
  prompt=$(cat <<'PROMPT_START'
You are the final synthesizer. Two agents have debated and refined their code review findings through multiple rounds. Produce the FINAL review.

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

  # shellcheck disable=SC2086
  claude -p "$prompt" \
    $claude_add_dirs \
    --model "$model" \
    --max-turns 3 \
    --setting-sources "project" 2>/dev/null
}
