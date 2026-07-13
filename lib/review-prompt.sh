#!/usr/bin/env bash
# Build context-aware review prompt for Claude Code CLI
#
# Two output modes:
#   - "terminal": human-readable text (default, for mra review <project>)
#   - "inline":   JSON for GitHub inline PR review (for mra review <project> --pr N)

build_review_prompt() {
  local project="$1"
  local project_dir="$2"
  local graph_file="$3"
  local base_ref="${4:-main}"
  local project_type="${5:-unknown}"
  local consumers="${6:-}"
  local deps="${7:-}"
  local has_api_change="${8:-false}"
  local output_language="${9:-}"
  local output_mode="${10:-terminal}"
  local mode="${11:-range}"
  local range_expr="${12:-}"

  # Back-compat / safety net: a caller that omits range_expr in range mode
  # falls back to "<base_ref>...HEAD" (base_ref is param 4, already resolved by some callers).
  if [[ "$mode" == "range" && -z "$range_expr" ]]; then
    range_expr="${base_ref}...HEAD"
  fi

  # --- Get diff (mode/range_expr resolved by review.sh) ---
  local diff
  diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")

  # --- Build consumer context instructions ---
  local consumer_context=""
  if [[ -n "$consumers" && "$has_api_change" == "true" ]]; then
    consumer_context="
## Cross-Project Consumer Analysis (CRITICAL)

This PR modifies API surface code. The following projects consume this project's API:
Consumers: ${consumers}

You MUST:
1. Read the consumer projects' source code to find where they call the changed API endpoints.
2. Check if any renamed/removed fields, changed response shapes, or new required parameters will break consumers.
3. For each consumer, identify the specific files and lines that reference the changed API.
4. Report any breaking changes as CRITICAL issues with the exact consumer file and line.

Do NOT guess — actually read the consumer code using the loaded project directories."
  fi

  # --- Build dependency context ---
  local dep_context=""
  if [[ -n "$deps" ]]; then
    dep_context="
## Upstream Dependencies

This project depends on: ${deps}
If the diff changes how upstream APIs are called, verify the call matches the upstream's current interface."
  fi

  # --- Language directive ---
  local lang_directive=""
  if [[ -n "$output_language" ]]; then
    lang_directive="
Use ${output_language} for all descriptive output in your review."
  fi

  # --- Mode-aware opening line ---
  local review_subject="a pull request"
  if [[ "$mode" == "working" ]]; then
    review_subject="the uncommitted working-tree changes"
  elif [[ "$mode" == "range" && -n "$range_expr" && "$range_expr" != *"...HEAD" ]]; then
    review_subject="the changes in '${range_expr}'"
  fi

  # --- Output format instructions ---
  local output_instructions=""
  if [[ "$output_mode" == "inline" ]]; then
    output_instructions='## Output Format (STRICT JSON)

You MUST output ONLY valid JSON with no text before or after. No markdown fences. No explanation outside the JSON.

{
  "status": "APPROVED" | "CHANGES_REQUESTED",
  "summary": "<one-line summary of the review>",
  "comments": [
    {
      "path": "<file path relative to project root>",
      "line": <line number in the NEW version of the file>,
      "severity": "CRITICAL" | "HIGH" | "MEDIUM",
      "body": "<review comment explaining the issue and how to fix>"
    }
  ]
}

Rules for the "line" field:
- Use the line number from the NEW (right-side) version of the diff.
- The line MUST be within the diff hunk (a changed or adjacent line). GitHub rejects comments on lines not in the diff.
- If a deleted line is the issue, comment on the nearest remaining line in the same hunk.

Rules for "comments":
- Only include comments for issues found in the DIFF. Do not comment on unchanged code.
- Each comment must reference a specific file and line.
- If status is APPROVED, comments array should be empty or contain only positive notes.
- Only include CRITICAL/HIGH/MEDIUM comments for in-scope, reachable defects. Do not comment on missing future features, placeholders, or product assumptions unless they create a concrete reachable bug now.

Rules for "body":
- Be specific about the problem and suggest a fix.
- For API breaking changes, mention which consumer file and line is affected.
- For every CRITICAL/HIGH/MEDIUM issue, include scope relation, reachable path, evidence, impact, and why it should block this PR now.

## Completion (REQUIRED)
After the JSON object, output EXACTLY ONE final line on its own — it confirms the
review finished:
===MRA-REVIEW-COMPLETE: APPROVED===           (status APPROVED)
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===   (status CHANGES_REQUESTED)
Omitting this line marks the review INCOMPLETE (it will not be treated as an approval).'
  else
    output_instructions='## Review Output

Produce your review in this format:

If no issues found:
```
Status: APPROVED
Summary: <one-line summary>
Notes:
  - <optional feedback>
```

If issues found:
```
Status: CHANGES_REQUESTED
Summary: <one-line summary>
Issues:
  - [CRITICAL] <file>:<line> - <description>
  - [HIGH] <file>:<line> - <description>
  - [MEDIUM] <file>:<line> - <description>
```'
  fi

  # --- Assemble prompt ---
  cat <<PROMPT
You are reviewing ${review_subject} for the project "${project}" (type: ${project_type}).

## Instructions

1. First, read the diff below to understand what changed.
2. Then, read the actual source files around the changed code to understand the FULL CONTEXT — not just the diff lines.
3. Check the project's existing patterns, naming conventions, and architecture.
4. Apply the review criteria from your system prompt (code-reviewer.md).
5. If consumer projects are loaded, read their code to verify API compatibility.

## Scope and Severity Gate

Before reporting an issue, infer the PR scope from the task/PR description, linked issue, commit messages, changed files, and existing PR discussion. Treat explicit "out of scope" comments as scope constraints unless the implementation creates a reachable security, data integrity, crash, or regression risk.

A CRITICAL/HIGH/MEDIUM finding must satisfy all of these:
- The issue is introduced or exposed by this diff.
- A user, API client, or system job can reach it today.
- The impact is concrete: security/authz, data loss/corruption/privacy leak, production crash, critical regression, or material breakage of this PR's scoped feature.
- The finding is actionable by a code change in this PR.

Do not mark missing future functionality as CRITICAL/HIGH/MEDIUM. A visible UI affordance such as an Add/Edit/Delete button is not proof that the workflow is in scope. For a list-page PR, missing create/edit/delete/detail behavior is non-blocking unless the PR explicitly includes that workflow or the enabled control leads to a reachable broken route/state, incorrect mutation, security issue, severe user confusion in the scoped flow, or regression.

If a concern depends on an unstated product rule or unclear scope, do not file a blocking comment. Leave it out or mention it only as a non-blocking question in the summary/notes if the output format supports notes.
${consumer_context}
${dep_context}
${lang_directive}

## Changed Files

${changed_files}

## Diff

\`\`\`diff
${diff}
\`\`\`

${output_instructions}

Important:
- Only flag issues that are in the DIFF. Do not review unchanged code.
- For API changes with consumers loaded, check the actual consumer source code.
- Be specific: include file names and line numbers.
- If you are unsure whether behavior is a bug or product scope, do not file a HIGH/MEDIUM comment; ask a non-blocking question instead.
PROMPT
}
