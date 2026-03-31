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

  # --- Resolve base ref (try local, then origin/) ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  # --- Get diff ---
  local diff=""
  if [[ -d "$project_dir/.git" ]]; then
    diff=$(git -C "$project_dir" diff "${resolved_base}...HEAD" 2>/dev/null || \
           git -C "$project_dir" diff "${resolved_base}" HEAD 2>/dev/null || \
           git -C "$project_dir" diff HEAD~1 2>/dev/null || \
           echo "(diff unavailable)")
  fi

  # --- Get changed files list ---
  local changed_files=""
  if [[ -d "$project_dir/.git" ]]; then
    changed_files=$(git -C "$project_dir" diff --name-only "${resolved_base}...HEAD" 2>/dev/null || \
                    git -C "$project_dir" diff --name-only "${resolved_base}" HEAD 2>/dev/null || \
                    git -C "$project_dir" diff --name-only HEAD~1 2>/dev/null || \
                    echo "(file list unavailable)")
  fi

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

Rules for "body":
- Be specific about the problem and suggest a fix.
- For API breaking changes, mention which consumer file and line is affected.'
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
You are reviewing a pull request for the project "${project}" (type: ${project_type}).

## Instructions

1. First, read the diff below to understand what changed.
2. Then, read the actual source files around the changed code to understand the FULL CONTEXT — not just the diff lines.
3. Check the project's existing patterns, naming conventions, and architecture.
4. Apply the review criteria from your system prompt (code-reviewer.md).
5. If consumer projects are loaded, read their code to verify API compatibility.
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
- If you are unsure, flag as MEDIUM with a question.
PROMPT
}
