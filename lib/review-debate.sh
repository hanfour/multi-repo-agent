#!/usr/bin/env bash
# Adversarial multi-agent debate review system (optimized)
#
# Token optimization strategies applied:
# 1. Fast convergence: skip debate rounds when findings are few
# 2. Merged critique+refine: 2 agents per round instead of 4
# 3. Tunable max-turns: Agent A/B=MRA_REVIEW_AGENT_MAX_TURNS (default 20),
#    critique-refine=5, synthesize=3
# 4. Model tiering: critique-refine uses haiku for cost savings
# 5. Focused context: non-search agents use --add-file instead of --add-dir
# 6. Leaner prompts: removed duplicated review criteria
#
# Usage: called from review.sh when strategy=debate

# The review agents end their output with a verdict line that BOTH confirms the
# review finished AND states the verdict explicitly:
#   ===MRA-REVIEW-COMPLETE: APPROVED===
#   ===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
# Deciding from this explicit signal — never by regex-counting the agents'
# free-text findings (bullet / bold "- **[MED]**" / "### [HIGH]" heading / prose
# all occur live) — is what keeps a failed/garbled/cut-off review from
# masquerading as a clean approval. Absence of the line = the agent did not finish.
MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"

# Extract one agent's declared verdict: APPROVED | CHANGES_REQUESTED | NONE.
_debate_verdict_of() {
  if printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*CHANGES_REQUESTED"; then
    printf 'CHANGES_REQUESTED'
  elif printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*APPROVED"; then
    printf 'APPROVED'
  else
    printf 'NONE'
  fi
}

# Decide from the two agents' EXPLICIT verdicts. Prints one of:
#   PROCEED — at least one agent reports CHANGES_REQUESTED; go to synthesis.
#   APPROVE — BOTH agents completed and reported APPROVED.
#   ERROR   — at least one agent did not complete (no verdict): failure / cutoff /
#             garbled. Never report as approved.
_debate_assess() {
  local va vb
  va=$(_debate_verdict_of "$1")
  vb=$(_debate_verdict_of "$2")
  if [[ "$va" == "CHANGES_REQUESTED" || "$vb" == "CHANGES_REQUESTED" ]]; then
    printf 'PROCEED\n'
  elif [[ "$va" == "APPROVED" && "$vb" == "APPROVED" ]]; then
    printf 'APPROVE\n'
  else
    printf 'ERROR\n'
  fi
}

# Map the adversarial verifier's EXPLICIT verdict to the final action on the
# APPROVE path. Prints:
#   APPROVE      — verifier also approved; the clean green is confirmed (3 agents).
#   DOWNGRADE    — verifier substantiated an issue the two agents missed; synthesise.
#   INCONCLUSIVE — verifier produced no verdict (failure/cutoff); fall back to the
#                  2-agent approval rather than block a clean PR on verifier flakiness.
_debate_verify_gate() {
  case "$(_debate_verdict_of "$1")" in
    APPROVED)          printf 'APPROVE\n' ;;
    CHANGES_REQUESTED) printf 'DOWNGRADE\n' ;;
    *)                 printf 'INCONCLUSIVE\n' ;;
  esac
}

# Count finding lines tolerantly — NON-CRITICAL: used only to choose synthesis
# depth (direct vs voting) on the PROCEED path, never for the approve/error
# decision. Matches a bullet (- or *), optional indent/bold, then "[<UPPER>".
_debate_count_findings() {
  local n
  n=$(printf '%s\n' "$1" | grep -cE '^[[:space:]]*[-*][[:space:]]*\**\[[A-Z]' || true)
  n=${n//[^0-9]/}; [[ -z "$n" ]] && n=0
  printf '%s' "$n"
}

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

  # =====================================================================
  # FAST CONVERGENCE: decide from the agents' EXPLICIT verdict sentinels.
  # CRITICAL: distinguish "both agents completed and approved" (APPROVE) from
  # "an agent did not finish — failure / max-turns cutoff / garbled" (ERROR).
  # The decision NEVER depends on regex-counting free-text findings; that is the
  # false-green bug (real findings as "### [HIGH]" headings were miscounted to 0).
  # =====================================================================
  local decision
  decision=$(_debate_assess "$findings_a" "$findings_b")
  log_info >&2 "[round 1] decision=$decision" "debate"

  if [[ "$decision" == "ERROR" ]]; then
    log_error >&2 "[fast] no completed verdict from both agents (failure or max-turns cutoff) — NOT approving" "debate"
    echo '{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — at least one analysis agent did not finish (no completion verdict; likely an agent failure or a max-turns cutoff — try MRA_REVIEW_AGENT_MAX_TURNS or a PKB). This is NOT an approval; re-run or review manually.","comments":[]}'
    return
  fi

  if [[ "$decision" == "APPROVE" ]]; then
    # Second check before approving: a skeptical 3rd reviewer tries to REFUTE the
    # clean verdict (gated by MRA_REVIEW_VERIFY_APPROVE, default on). Lowers the
    # chance of a false "no issues" green — approval then needs THREE independent
    # agents, the last one adversarial.
    if [[ "${MRA_REVIEW_VERIFY_APPROVE:-1}" != "0" ]]; then
      log_progress >&2 "[verify] both approved — adversarial verifier re-checking before approving..." "debate"
      local verify_out gate
      verify_out=$(run_agent_verify "$project" "$project_dir" "$diff" "$changed_files" \
        "$lang_directive" "$model" "$claude_add_dirs" "$mra_dir" "$pkb_context" 2>/dev/null)
      gate=$(_debate_verify_gate "$verify_out")
      log_info >&2 "[verify] verifier gate=$gate" "debate"
      if [[ "$gate" == "DOWNGRADE" ]]; then
        log_warn >&2 "[verify] verifier substantiated an issue the two agents missed — synthesising a review" "debate"
        # Route the verifier's findings into synthesis as the third reviewer's input.
        run_synthesize "$project" "$project_dir" "$diff" "$changed_files" \
          "$verify_out" "(both primary reviewers approved; the finding above is from the adversarial verifier)" \
          "$consumers" "$has_api_change" "$lang_directive" "$model" "$focused_ctx" "$mra_dir"
        return
      fi
      [[ "$gate" == "INCONCLUSIVE" ]] && \
        log_warn >&2 "[verify] verifier did not complete — falling back to the 2-agent approval" "debate"
    fi
    log_success >&2 "[fast] approved (verifier confirmed)" "debate"
    echo '{"status":"APPROVED","summary":"No issues found by either agent","comments":[]}'
    return
  fi

  # decision == PROCEED — at least one CHANGES_REQUESTED. Count findings only to
  # choose synthesis depth (direct vs voting); not used for the verdict.
  local total_findings
  total_findings=$(( $(_debate_count_findings "$findings_a") + $(_debate_count_findings "$findings_b") ))
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
# max-turns: MRA_REVIEW_AGENT_MAX_TURNS (default 20). Too low cuts the agent off
# mid-exploration before it emits findings — the original false-green trigger.
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

When your analysis is complete, end your output with EXACTLY ONE of these lines on its own — it confirms completion AND states your verdict (omitting it marks the review incomplete / a failure):
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (no issues worth changing)
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you reported any [CRITICAL]/[HIGH]/[MEDIUM] issue above)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Adversarial verifier: a skeptical THIRD reviewer that runs ONLY when both
# round-1 agents approved. Its job is to REFUTE the approval — find any real
# issue the two missed — not to rubber-stamp it. Declares the same explicit
# verdict sentinel. This is the "second check before approve" that lowers the
# chance of a false clean green; approval then needs THREE independent agents,
# the last one adversarial. Gated by MRA_REVIEW_VERIFY_APPROVE (default on).
# -----------------------------------------------------------------------
run_agent_verify() {
  local project="$1" project_dir="$2" diff="$3" changed_files="$4"
  local lang_directive="$5" model="$6"
  local claude_add_dirs="$7" mra_dir="$8" pkb_context="${9:-}"

  local pkb_section=""
  if [[ -n "$pkb_context" ]]; then
    pkb_section="$pkb_context

Use the knowledge base above to understand the project structure and API surface.
Only read source files when you need exact file:line evidence for a finding.
"
  fi

  local prompt
  prompt=$(cat <<PROMPT
You are a skeptical THIRD reviewer. Two independent reviewers BOTH approved this
PR with no issues — your job is to REFUTE that, not confirm it. Assume they may
have missed something and look harder.
${pkb_section}
## Method (challenge the approval)
1. Read the diff carefully.
2. Hunt for what a quick approval misses: broken/renamed callers, null/empty/boundary
   cases, untested error paths, missing or assertion-free tests, security (injection,
   authz, leaked secrets), type-safety gaps, state/concurrency, silent breaking changes.
3. Verify each suspicion against the actual code with file:line evidence BEFORE
   reporting it. Do NOT invent issues — only report what you can substantiate.

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output
- [CRITICAL] \`file:line\` — <verified issue the two reviewers missed>
- [HIGH] \`file:line\` — <verified issue>
- [MEDIUM] \`file:line\` — <verified issue>

${lang_directive}

End your output with EXACTLY ONE of these lines on its own — it confirms completion
AND states your verdict (omitting it marks the verification incomplete):
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you substantiated a real [CRITICAL]/[HIGH]/[MEDIUM] issue above)
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (after genuinely trying to refute, you found nothing)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null
}

# -----------------------------------------------------------------------
# Agent B: Quality Auditor
# Checks patterns, security, edge cases, best practices
# Uses FULL --add-dir (needs to read surrounding code & conventions)
# max-turns: MRA_REVIEW_AGENT_MAX_TURNS (default 20). Too low cuts the agent off
# mid-exploration before it emits findings — the original false-green trigger.
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

When your analysis is complete, end your output with EXACTLY ONE of these lines on its own — it confirms completion AND states your verdict (omitting it marks the review incomplete / a failure):
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (no issues worth changing)
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you reported any [CRITICAL]/[HIGH]/[MEDIUM] issue above)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  claude -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
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

CRITICAL — string escaping: every comment body is a JSON string value. Any
double-quote character that appears INSIDE a string MUST be backslash-escaped,
otherwise the JSON is invalid and the ENTIRE review is discarded. When quoting
code, identifiers, or terms inside Chinese prose, prefer 「」, 『』, or backticks
instead of double-quotes. Also escape literal backslashes and newlines.

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
