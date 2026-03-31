#!/usr/bin/env bash
# Build context-aware review prompt for Claude Code CLI
#
# This script assembles a prompt that includes:
# 1. The PR diff
# 2. Dependency graph context (consumers, upstream deps)
# 3. API change classification
# 4. Instructions to read actual source code, not just the diff

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

  # --- Get diff ---
  local diff=""
  if [[ -d "$project_dir/.git" ]]; then
    diff=$(git -C "$project_dir" diff "${base_ref}...HEAD" 2>/dev/null || \
           git -C "$project_dir" diff HEAD~1 2>/dev/null || \
           echo "(diff unavailable)")
  fi

  # --- Get changed files list ---
  local changed_files=""
  if [[ -d "$project_dir/.git" ]]; then
    changed_files=$(git -C "$project_dir" diff --name-only "${base_ref}...HEAD" 2>/dev/null || \
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

## Review Output

Produce your review in the standard format:

If no issues found:
\`\`\`
Status: APPROVED
Summary: <one-line summary>
Notes:
  - <optional feedback>
\`\`\`

If issues found:
\`\`\`
Status: CHANGES_REQUESTED
Summary: <one-line summary>
Issues:
  - [CRITICAL] <file>:<line> - <description>
  - [HIGH] <file>:<line> - <description>
  - [MEDIUM] <file>:<line> - <description>
\`\`\`

Important:
- Only flag issues that are in the DIFF. Do not review unchanged code.
- For API changes with consumers loaded, check the actual consumer source code.
- Be specific: include file names and line numbers.
- If you are unsure, flag as MEDIUM with a question.
PROMPT
}
