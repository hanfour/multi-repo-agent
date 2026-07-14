#!/usr/bin/env bash
# Debate agent runners (Impact Analyst, Quality Auditor, adversarial verifier, critique-refine, vote, synthesize) with their prompts.

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
$(_review_pr_discussion_prompt)
## Method
1. Read diff → identify added, modified, DELETED items.
2. For each deleted/renamed export: grep the project for remaining references. Report with file:line.
3. For modified signatures: search callers, verify compatibility.
4. Check for: duplicate definitions, duplicate imports, leftover debug artifacts, dead code.
5. Async safety: emit() vs emitAsync(), return type accuracy, await in try/catch.
${consumer_note}

## Scope and Severity Gate
Report [CRITICAL]/[HIGH]/[MEDIUM] only for defects introduced or exposed by this diff that are reachable today and materially affect security/authz, data integrity, privacy, production stability, an existing shipped flow, API compatibility, or this PR's stated objective.

Do not escalate missing future functionality, placeholders, optional workflows, cosmetic gaps, or unclear product assumptions. A visible Add/Edit/Delete button is not proof that the workflow is in scope; for a list-page PR, missing create/edit/delete/detail behavior is non-blocking unless the PR explicitly includes it or the enabled control leads to a reachable broken route/state, incorrect mutation, security issue, severe scoped-flow confusion, or regression.

If a concern depends on product scope or an unstated rule, ask a non-blocking question instead of reporting [HIGH]/[MEDIUM].

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output
- [CRITICAL] \`file:line\` — <verified issue with evidence>
- [HIGH] \`file:line\` — <verified issue with evidence>
- [MEDIUM] \`file:line\` — <reachable scoped issue with evidence>

If no references found for a deleted item: "Verified: <item> has no remaining references."

${lang_directive}

IMPORTANT: You MUST search the codebase using file reading/grep. Every finding must include exact file and line, reachable path, impact, and why it blocks this PR now.

When your analysis is complete, end your output with EXACTLY ONE of these lines on its own — it confirms completion AND states your verdict (omitting it marks the review incomplete / a failure):
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (no issues worth changing)
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you reported any [CRITICAL]/[HIGH]/[MEDIUM] issue above)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
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
$(_review_pr_discussion_prompt)
## Method (challenge the approval)
1. Read the diff carefully.
2. Hunt for what a quick approval misses: broken/renamed callers, null/empty/boundary
   cases, untested error paths, missing or assertion-free tests, security (injection,
   authz, leaked secrets), type-safety gaps, state/concurrency, silent breaking changes.
3. Verify each suspicion against the actual code with file:line evidence BEFORE
   reporting it. Do NOT invent issues — only report what you can substantiate.

## Scope and Severity Gate
Only refute the approval with issues introduced or exposed by this diff that are reachable today and materially affect security/authz, data integrity, privacy, production stability, an existing shipped flow, API compatibility, or this PR's stated objective.

Do not escalate missing future functionality, placeholders, optional workflows, cosmetic gaps, or unclear product assumptions. A visible Add/Edit/Delete button is not proof that the workflow is in scope; for a list-page PR, missing create/edit/delete/detail behavior is non-blocking unless the PR explicitly includes it or the enabled control leads to a reachable broken route/state, incorrect mutation, security issue, severe scoped-flow confusion, or regression.

## Diff
\`\`\`diff
${diff}
\`\`\`

## Changed Files
${changed_files}

## Output
- [CRITICAL] \`file:line\` — <verified issue the two reviewers missed>
- [HIGH] \`file:line\` — <verified issue>
- [MEDIUM] \`file:line\` — <reachable scoped issue with evidence>

${lang_directive}

End your output with EXACTLY ONE of these lines on its own — it confirms completion
AND states your verdict (omitting it marks the verification incomplete):
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you substantiated a real [CRITICAL]/[HIGH]/[MEDIUM] issue above)
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (after genuinely trying to refute, you found nothing)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
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
$(_review_pr_discussion_prompt)
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

## Scope and Severity Gate
Report [CRITICAL]/[HIGH]/[MEDIUM] only for defects introduced or exposed by this diff that are reachable today and materially affect security/authz, data integrity, privacy, production stability, an existing shipped flow, API compatibility, or this PR's stated objective.

Do not escalate missing future functionality, placeholders, optional workflows, cosmetic gaps, or unclear product assumptions. A visible Add/Edit/Delete button is not proof that the workflow is in scope; for a list-page PR, missing create/edit/delete/detail behavior is non-blocking unless the PR explicitly includes it or the enabled control leads to a reachable broken route/state, incorrect mutation, security issue, severe scoped-flow confusion, or regression.

If a concern depends on product scope or an unstated rule, ask a non-blocking question instead of reporting [HIGH]/[MEDIUM].

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
- [MEDIUM] \`file:line\` — <reachable scoped issue with evidence>

${lang_directive}

IMPORTANT: Read actual source files. Base findings on code, not assumptions. Every finding must include a reachable path, impact, and why it blocks this PR now.

When your analysis is complete, end your output with EXACTLY ONE of these lines on its own — it confirms completion AND states your verdict (omitting it marks the review incomplete / a failure):
===${MRA_REVIEW_SENTINEL_TOKEN}: APPROVED===           (no issues worth changing)
===${MRA_REVIEW_SENTINEL_TOKEN}: CHANGES_REQUESTED===   (you reported any [CRITICAL]/[HIGH]/[MEDIUM] issue above)
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns "${MRA_REVIEW_AGENT_MAX_TURNS:-20}" \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
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

## Scope and Severity Gate
Keep only findings introduced or exposed by this diff that are reachable today and materially affect security/authz, data integrity, privacy, production stability, an existing shipped flow, API compatibility, or this PR's stated objective.

Do not keep findings about missing future functionality, placeholders, optional workflows, cosmetic gaps, or unclear product assumptions unless they create a concrete reachable bug now. If a concern depends on product scope, remove it or downgrade it to a non-blocking question instead of [HIGH]/[MEDIUM].

## Output: Your REFINED findings list ONLY
- [CRITICAL] \`file:line\` — <issue with evidence>
- [HIGH] \`file:line\` — <issue with evidence>
- [MEDIUM] \`file:line\` — <reachable scoped issue with evidence>

${lang_directive}

Only include findings with evidence from actual source code, reachable path, impact, and why it blocks this PR now.
PROMPT
)

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 5 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
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
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 3 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
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
4. Drop any finding that does not explain scope relation, reachable path, concrete impact, and why it matters in this PR now.
5. Drop missing future features, placeholders, optional workflows, cosmetic gaps, and unclear product assumptions unless they create a concrete reachable bug now.
6. A visible Add/Edit/Delete button is not proof that the workflow is in scope; for a list-page PR, missing create/edit/delete/detail behavior is non-blocking unless the PR explicitly includes it or the enabled control leads to a reachable broken route/state, incorrect mutation, security issue, severe scoped-flow confusion, or regression.
7. Status is APPROVED only if there are zero CRITICAL or HIGH issues.
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
      \"body\": \"<review comment — include scope relation, reachable path, evidence, impact, and why it matters now>\"
    }
  ]
}

Rules for line numbers:
- Use line numbers from the NEW (right-side) version of the diff.
- Lines MUST be within a diff hunk. If the issue is on a deleted line, use the nearest remaining line in the same hunk."

  local _ad_arr=()
  expand_add_dir_string _ad_arr "$claude_add_dirs"
  _review_without_github_credentials claude_invoke debate -p "$prompt" \
    "${_ad_arr[@]}" \
    --model "$model" \
    --max-turns 3 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project"
}
