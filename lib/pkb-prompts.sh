#!/usr/bin/env bash
# PKB prompt builders: generate/update sitemap, architecture, conventions, API surface, modules, identity, tunnels.

# ---------------------------------------------------------------------------
# Internal: Agent calls for PKB generation
# ---------------------------------------------------------------------------
_pkb_generate_sitemap() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5"

  claude -p "$(cat <<PROMPT
You are a project analyzer. Generate a SITEMAP document for the project "$project" (type: $project_type).

## Your Task
1. List the directory tree (important dirs only, skip node_modules, .git, dist, build, coverage).
2. For each significant directory, write a 1-line purpose description.
3. For each key file (entry points, configs, main modules), write a 1-line description.
4. Group by feature/module, not by file type.

## Output Format (markdown)
# Sitemap: $project

## Directory Structure
\`\`\`
<tree output with annotations>
\`\`\`

## Module Index
| Module | Path | Purpose |
|--------|------|---------|
| ... | ... | ... |

## Key Files
| File | Purpose |
|------|---------|
| ... | ... |

${lang_directive}

Be concise. Each description should be under 20 words.
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

_pkb_generate_architecture() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5"

  claude -p "$(cat <<PROMPT
You are a software architect. Generate an ARCHITECTURE document for "$project" (type: $project_type).

## Your Task
1. Identify the tech stack (framework, language, major libraries).
2. Map the architecture pattern (MVC, DDD, feature-based, layered, etc.).
3. Document the data flow (how requests/events flow through the system).
4. Note key technical decisions and their rationale (if visible from code/comments).
5. Map state management approach (if frontend).
6. Document dependency injection / service patterns (if backend).

## Output Format (markdown)
# Architecture: $project

## Tech Stack
- ...

## Architecture Pattern
...

## Data Flow
...

## State Management (if applicable)
...

## Key Technical Decisions
- ...

${lang_directive}

Focus on patterns that a new reviewer would need to understand to give accurate feedback.
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

_pkb_generate_conventions() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5"

  claude -p "$(cat <<PROMPT
You are a code quality analyst. Generate a CONVENTIONS document for "$project" (type: $project_type).

## Your Task
1. Read config files: .eslintrc*, tsconfig*, prettier*, .editorconfig, CLAUDE.md, AGENTS.md, .claude/rules/. Distilling these project-convention docs into the output is the PRIMARY purpose — always read and summarise them.
2. Read a sample of source files to identify actual coding patterns.
3. Document: naming conventions, import style, error handling patterns, testing approach.
4. Note any project-specific rules or deviations from standard.

## Output Format (markdown)

IMPORTANT: Prefix each rule/pattern with a classification tag:
- [CONVENTION] — coding style rules (naming, imports, formatting)
- [PATTERN] — architecture/design patterns used in the codebase
- [DECISION] — explicit technical decisions (why X was chosen over Y)

# Conventions: $project

## Coding Style
[CONVENTION] ...

## Naming Conventions
[CONVENTION] ...

## Import & Module Patterns
[PATTERN] ...

## Error Handling
[PATTERN] ...

## Testing Approach
[CONVENTION] ...

## Key Technical Decisions
[DECISION] ...

## Project-Specific Rules
[CONVENTION] ...

${lang_directive}

Only document patterns actually used in the codebase. Don't assume or prescribe.
Every line must start with [CONVENTION], [PATTERN], or [DECISION] tag.
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

_pkb_generate_api_surface() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5"

  claude -p "$(cat <<PROMPT
You are an API analyst. Generate an API SURFACE document for "$project" (type: $project_type).

## Your Task
1. Find all external API endpoints (REST routes, GraphQL schemas, gRPC services).
2. Find all public exports (packages, shared types, hooks, utilities).
3. Find event contracts (emitted events, message queues, WebSocket messages).
4. For each, document: name, method, path/signature, purpose.

## Output Format (markdown)
# API Surface: $project

## REST Endpoints (if any)
| Method | Path | Purpose |
|--------|------|---------|
| ... | ... | ... |

## Public Exports (if any)
| Export | From | Purpose |
|--------|------|---------|
| ... | ... | ... |

## Events / Messages (if any)
| Event | Payload | Direction |
|-------|---------|-----------|
| ... | ... | ... |

## Shared Types
| Type | From | Used By |
|------|------|---------|
| ... | ... | ... |

${lang_directive}

If a category has no entries, omit it entirely. Be precise with paths and signatures.
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

_pkb_generate_modules() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5" pkb="$6"

  # Discover feature modules using find (avoids glob no-match errors)
  local modules=()
  local search_dirs=(
    "src/features" "src/modules" "src/domains"
    "frontend/src/features" "frontend/src/modules"
    "backend/src/modules" "backend/src"
    "app" "lib" "packages"
  )

  for search_dir in "${search_dirs[@]}"; do
    local full_dir="$project_dir/$search_dir"
    [[ -d "$full_dir" ]] || continue
    while IFS= read -r mod_path; do
      [[ -z "$mod_path" ]] && continue
      local mod_name
      mod_name=$(basename "$mod_path")
      # Skip generic dirs
      case "$mod_name" in
        components|utils|helpers|types|styles|assets|public|__tests__|test|spec|node_modules|.git|dist|build|coverage) continue ;;
      esac
      modules+=("$mod_name:$mod_path")
    done < <(find "$full_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done

  # Deduplicate by module name (first match wins)
  local -A seen_mods=()
  local unique_modules=()
  for entry in "${modules[@]}"; do
    local name="${entry%%:*}"
    if [[ -z "${seen_mods[$name]+x}" ]]; then
      seen_mods["$name"]=1
      unique_modules+=("$entry")
    fi
  done
  modules=("${unique_modules[@]}")

  if [[ ${#modules[@]} -eq 0 ]]; then
    log_info "no feature modules detected, skipping module summaries" "pkb"
    return
  fi

  log_info "found ${#modules[@]} modules to analyze" "pkb"

  # Record each module's ACTUAL directory into meta.json (issue #21) so
  # file→module lookup is fact-driven instead of path-regex guessing.
  local map_json="{}"
  for entry in "${modules[@]}"; do
    local m_name="${entry%%:*}" m_dir="${entry#*:}"
    map_json=$(jq --arg k "$m_name" --arg v "${m_dir#"$project_dir"/}" '. + {($k): $v}' <<<"$map_json")
  done
  local meta_tmp
  meta_tmp=$(mktemp)
  if jq --argjson m "$map_json" '.moduleMap = $m' "$pkb/meta.json" > "$meta_tmp" 2>/dev/null; then
    mv "$meta_tmp" "$pkb/meta.json"
  else
    rm -f "$meta_tmp"
  fi

  # Generate module summaries (batch 3 at a time to avoid overloading)
  local batch_size=3
  local i=0
  while [[ $i -lt ${#modules[@]} ]]; do
    local pids=()
    local j=0
    while [[ $j -lt $batch_size && $((i + j)) -lt ${#modules[@]} ]]; do
      local entry="${modules[$((i + j))]}"
      local mod_name="${entry%%:*}"
      local mod_dir="${entry#*:}"

      _pkb_generate_one_module "$project" "$mod_name" "$mod_dir" \
        "$project_type" "$lang_directive" "$model" \
        > "$pkb/modules/${mod_name}.md" 2>/dev/null &
      pids+=($!)
      j=$((j + 1))
    done

    for pid in "${pids[@]}"; do wait "$pid" || true; done
    i=$((i + batch_size))
  done

  # Drop empty AND invalid (cut-off / error-string) module docs so a failed
  # generator never pollutes the PKB. Module gen writes directly in the
  # background above, so it can't go through _pkb_keep_doc — validate here.
  find "$pkb/modules" -name '*.md' -empty -delete 2>/dev/null
  for _m in "$pkb/modules"/*.md; do
    [[ -f "$_m" ]] || continue
    _pkb_valid_doc "$(cat "$_m")" || { log_warn "PKB: module $(basename "$_m") generation failed/cut off — dropping" "pkb" >&2; rm -f "$_m"; }
  done
}

_pkb_generate_one_module() {
  local project="$1" mod_name="$2" mod_dir="$3"
  local project_type="$4" lang_directive="$5" model="$6"

  claude -p "$(cat <<PROMPT
Analyze the module "$mod_name" in project "$project" and produce a concise summary.

## Your Task
1. Read all files in this module directory.
2. Identify: purpose, key components/functions, external dependencies, exports.
3. Note important business logic or domain rules.
4. Document any non-obvious patterns or gotchas.

## Output Format (markdown)
# Module: $mod_name

## Purpose
<1-2 sentences>

## Key Components
| Name | Type | Purpose |
|------|------|---------|
| ... | ... | ... |

## Dependencies
- Internal: ...
- External: ...

## Business Rules / Gotchas
- ...

${lang_directive}

Keep it concise — this will be used as context for code review and development agents.
PROMPT
)" --add-dir "$mod_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

# ---------------------------------------------------------------------------
# Internal: Incremental update helpers
# ---------------------------------------------------------------------------
_pkb_update_one_module() {
  local project_dir="$1" module_name="$2" module_dir="$3"
  local existing_summary="$4" changed_files="$5"
  local lang_directive="$6" model="$7"

  local relevant_changes
  relevant_changes=$(echo "$changed_files" | grep "$module_name" || true)

  claude -p "$(cat <<PROMPT
Update the module summary for "$module_name" based on recent changes.

## Current Summary
${existing_summary}

## Recent Changes (files modified)
${relevant_changes}

## Your Task
1. Read the changed files to understand what was modified.
2. Update the summary to reflect the current state.
3. Keep the same markdown format as the existing summary.
4. If the module purpose or key components changed, update those sections.
5. Add new components/exports if they were added.
6. Remove references to deleted components.

${lang_directive}

Output the COMPLETE updated summary (not a diff).
PROMPT
)" --add-dir "$module_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project"
}

# ---------------------------------------------------------------------------
# L0: Generate ultra-compact identity file (~50 tokens)
# No LLM call needed — derived from project metadata
# ---------------------------------------------------------------------------
_pkb_generate_identity() {
  local project="$1" project_dir="$2" project_type="$3" pkb="$4"

  local tech_stack=""
  # Detect tech stack from files
  [[ -f "$project_dir/package.json" ]] && tech_stack="Node.js"
  [[ -f "$project_dir/Gemfile" ]] && tech_stack="Ruby/Rails"
  [[ -f "$project_dir/go.mod" ]] && tech_stack="Go"
  [[ -f "$project_dir/requirements.txt" || -f "$project_dir/pyproject.toml" ]] && tech_stack="Python"

  # Detect frontend framework
  if [[ -f "$project_dir/package.json" ]]; then
    local pkg
    pkg=$(cat "$project_dir/package.json" 2>/dev/null)
    echo "$pkg" | grep -q '"react"' && tech_stack="$tech_stack/React"
    echo "$pkg" | grep -q '"vue"' && tech_stack="$tech_stack/Vue"
    echo "$pkg" | grep -q '"next"' && tech_stack="$tech_stack/Next.js"
    echo "$pkg" | grep -q '"@nestjs/core"' && tech_stack="NestJS"
  fi
  [[ -z "$tech_stack" ]] && tech_stack="unknown"

  # Try to get description from package.json or README first line
  local description=""
  if [[ -f "$project_dir/package.json" ]]; then
    description=$(jq -r '.description // ""' "$project_dir/package.json" 2>/dev/null)
  fi
  if [[ -z "$description" && -f "$project_dir/README.md" ]]; then
    description=$(head -5 "$project_dir/README.md" | grep -v '^#' | grep -v '^$' | head -1)
  fi
  [[ -z "$description" ]] && description="$project_type project"

  cat > "$pkb/identity.md" <<EOF
**${project}** | ${project_type} | ${tech_stack}
${description}
EOF
  log_info "[L0] identity generated (~50 tokens)" "pkb"
}

# ---------------------------------------------------------------------------
# Tunnel linking: detect shared entities across module summaries
# Creates tunnels.md with cross-reference map
# ---------------------------------------------------------------------------
_pkb_generate_tunnels() {
  local pkb="$1"
  local tunnels_file="$pkb/tunnels.md"
  local -A entity_modules=()

  # Scan all module summaries for entity references
  for mod_file in "$pkb"/modules/*.md; do
    [[ -f "$mod_file" && -s "$mod_file" ]] || continue
    local mod_name
    mod_name=$(basename "$mod_file" .md)

    # Extract capitalized entity names (likely types/components)
    local entities
    entities=$(grep -oE '\b[A-Z][a-zA-Z]{2,}\b' "$mod_file" 2>/dev/null | sort -u || true)
    while IFS= read -r entity; do
      [[ -z "$entity" ]] && continue
      # Skip common noise words
      case "$entity" in
        Module|Purpose|Name|Type|Table|Key|Components|Dependencies|Internal|External|Business|Rules|Gotchas) continue ;;
      esac
      if [[ -n "${entity_modules[$entity]+x}" ]]; then
        entity_modules["$entity"]="${entity_modules[$entity]}, $mod_name"
      else
        entity_modules["$entity"]="$mod_name"
      fi
    done <<< "$entities"
  done

  # Write tunnels (only entities appearing in 2+ modules)
  local has_tunnels=false
  {
    echo "# Cross-Module References (Tunnels)"
    echo ""
    echo "| Entity | Modules |"
    echo "|--------|---------|"
    for entity in $(echo "${!entity_modules[@]}" | tr ' ' '\n' | sort); do
      local modules="${entity_modules[$entity]}"
      if [[ "$modules" == *","* ]]; then
        echo "| ${entity} | ${modules} |"
        has_tunnels=true
      fi
    done
  } > "$tunnels_file"

  if [[ "$has_tunnels" == "true" ]]; then
    local tunnel_count
    tunnel_count=$(grep -c '|' "$tunnels_file" || true)
    tunnel_count=$((tunnel_count - 2))  # subtract header rows
    log_info "[tunnels] $tunnel_count cross-module references detected" "pkb"
  else
    rm -f "$tunnels_file"
    log_info "[tunnels] no cross-module references found" "pkb"
  fi
}

_pkb_update_sitemap() {
  local project="$1" project_dir="$2" sitemap_file="$3"
  local changed_files="$4" lang_directive="$5" model="$6"

  local current_sitemap
  current_sitemap=$(cat "$sitemap_file")

  local updated
  updated=$(claude -p "$(cat <<PROMPT
Update the project sitemap based on recent file changes.

## Current Sitemap
${current_sitemap}

## Changed/Added Files
${changed_files}

## Your Task
1. Add any new files/directories to the appropriate section.
2. Update descriptions if file purposes changed.
3. Keep the same markdown format.
4. Remove entries for deleted files.

${lang_directive}

Output the COMPLETE updated sitemap (not a diff).
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns "${MRA_PKB_AGENT_MAX_TURNS:-25}" --setting-sources "project" 2>/dev/null)

  if [[ -n "$updated" ]]; then
    echo "$updated" > "$sitemap_file"
  fi
}
