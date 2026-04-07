#!/usr/bin/env bash
# Project Knowledge Base (PKB) — cumulative project understanding
#
# Instead of re-reading the entire codebase each time, agents build and
# maintain a distilled knowledge base per project. This dramatically
# reduces token usage for repeated operations (review, develop, ask).
#
# Structure:  <project>/.mra/pkb/
#   sitemap.md      — file tree + module purpose index
#   architecture.md — patterns, data flow, tech stack, key decisions
#   conventions.md  — coding style, naming, tooling, testing approach
#   api-surface.md  — external endpoints, exports, event contracts
#   meta.json       — tracking: when generated, source hashes, version
#   modules/
#     <name>.md     — per-module deep summary (features, hooks, stores)

PKB_VERSION=1
PKB_DIR_NAME=".mra/pkb"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
pkb_dir() {
  local project_dir="$1"
  echo "$project_dir/$PKB_DIR_NAME"
}

pkb_exists() {
  local project_dir="$1"
  [[ -f "$(pkb_dir "$project_dir")/meta.json" ]]
}

pkb_age_hours() {
  local project_dir="$1"
  local meta_file="$(pkb_dir "$project_dir")/meta.json"
  if [[ ! -f "$meta_file" ]]; then echo "999999"; return; fi

  local last_updated
  last_updated=$(jq -r '.lastUpdated // "1970-01-01T00:00:00Z"' "$meta_file" 2>/dev/null)
  local now_epoch last_epoch
  now_epoch=$(date +%s)
  last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated" +%s 2>/dev/null || echo "0")
  echo $(( (now_epoch - last_epoch) / 3600 ))
}

# ---------------------------------------------------------------------------
# Meta management
# ---------------------------------------------------------------------------
pkb_init_meta() {
  local project_dir="$1" project="$2"
  local pkb="$(pkb_dir "$project_dir")"
  mkdir -p "$pkb/modules"

  cat > "$pkb/meta.json" <<EOF
{
  "version": $PKB_VERSION,
  "project": "$project",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastUpdated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastReviewedCommit": "$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "")",
  "generatedFiles": [],
  "moduleCount": 0
}
EOF
}

pkb_update_meta() {
  local project_dir="$1"
  local pkb="$(pkb_dir "$project_dir")"
  local meta_file="$pkb/meta.json"
  [[ ! -f "$meta_file" ]] && return

  local module_count
  module_count=$(find "$pkb/modules" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')

  local generated_files
  generated_files=$(find "$pkb" -name '*.md' -not -path '*/modules/*' 2>/dev/null | \
    while read -r f; do basename "$f"; done | jq -R -s 'split("\n") | map(select(length > 0))')

  local tmp
  tmp=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg commit "$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "")" \
     --argjson mc "$module_count" \
     --argjson gf "$generated_files" \
     '.lastUpdated = $ts | .lastReviewedCommit = $commit | .moduleCount = $mc | .generatedFiles = $gf' \
     "$meta_file" > "$tmp" && mv "$tmp" "$meta_file"
}

# ---------------------------------------------------------------------------
# Generate PKB — full initial analysis
# Uses multiple sub-agents in parallel for speed
# ---------------------------------------------------------------------------
pkb_generate() {
  local project="$1"
  local project_dir="$2"
  local model="${3:-sonnet}"
  local output_language="${4:-}"

  local pkb
  pkb="$(pkb_dir "$project_dir")"
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  log_progress "generating PKB for $project..." "pkb"

  # Initialize
  pkb_init_meta "$project_dir" "$project"

  local lang_directive=""
  [[ -n "$output_language" ]] && lang_directive="Use ${output_language} for all output."

  # Detect project type
  local project_type="unknown"
  if type detect_project_type &>/dev/null; then
    project_type=$(detect_project_type "$project_dir" 2>/dev/null || echo "unknown")
  fi

  # --- Phase 1: Parallel generation of 4 core documents ---
  log_progress "[phase 1] generating core knowledge documents (4 agents in parallel)..." "pkb"

  local sitemap_file architecture_file conventions_file api_file
  sitemap_file=$(mktemp)
  architecture_file=$(mktemp)
  conventions_file=$(mktemp)
  api_file=$(mktemp)

  # Agent 1: Sitemap
  _pkb_generate_sitemap "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" > "$sitemap_file" 2>/dev/null &
  local pid1=$!

  # Agent 2: Architecture
  _pkb_generate_architecture "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" > "$architecture_file" 2>/dev/null &
  local pid2=$!

  # Agent 3: Conventions
  _pkb_generate_conventions "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" > "$conventions_file" 2>/dev/null &
  local pid3=$!

  # Agent 4: API Surface
  _pkb_generate_api_surface "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" > "$api_file" 2>/dev/null &
  local pid4=$!

  wait $pid1 || true
  wait $pid2 || true
  wait $pid3 || true
  wait $pid4 || true

  # Write results
  [[ -s "$sitemap_file" ]] && mv "$sitemap_file" "$pkb/sitemap.md" || rm -f "$sitemap_file"
  [[ -s "$architecture_file" ]] && mv "$architecture_file" "$pkb/architecture.md" || rm -f "$architecture_file"
  [[ -s "$conventions_file" ]] && mv "$conventions_file" "$pkb/conventions.md" || rm -f "$conventions_file"
  [[ -s "$api_file" ]] && mv "$api_file" "$pkb/api-surface.md" || rm -f "$api_file"

  log_info "[phase 1] core documents generated" "pkb"

  # --- Phase 2: Module summaries (sequential, based on sitemap) ---
  log_progress "[phase 2] generating module summaries..." "pkb"

  _pkb_generate_modules "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" "$pkb"

  # Finalize
  pkb_update_meta "$project_dir"

  local file_count
  file_count=$(find "$pkb" -name '*.md' | wc -l | tr -d '[:space:]')
  log_success "PKB generated: $file_count knowledge documents in $pkb" "pkb"
}

# ---------------------------------------------------------------------------
# Incremental update — after review or development
# Only updates modules affected by the diff
# ---------------------------------------------------------------------------
pkb_incremental_update() {
  local project="$1"
  local project_dir="$2"
  local changed_files="$3"
  local model="${4:-haiku}"
  local output_language="${5:-}"

  local pkb
  pkb="$(pkb_dir "$project_dir")"

  if ! pkb_exists "$project_dir"; then
    log_warn "PKB not found for $project, run 'mra analyze $project' first" "pkb"
    return 1
  fi

  local lang_directive=""
  [[ -n "$output_language" ]] && lang_directive="Use ${output_language} for all output."

  # Identify affected modules from changed files
  local affected_modules=""
  local -A seen_modules=()

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # Extract module name from path (e.g., src/features/chat/... → chat)
    local module_name
    module_name=$(_pkb_file_to_module "$file")
    [[ -z "$module_name" ]] && continue
    if [[ -z "${seen_modules[$module_name]+x}" ]]; then
      seen_modules["$module_name"]=1
      affected_modules="$affected_modules $module_name"
    fi
  done <<< "$changed_files"

  if [[ -z "${affected_modules// /}" ]]; then
    return 0
  fi

  log_progress "updating PKB modules:$affected_modules" "pkb"

  local project_type="unknown"
  if type detect_project_type &>/dev/null; then
    project_type=$(detect_project_type "$project_dir" 2>/dev/null || echo "unknown")
  fi

  for module_name in $affected_modules; do
    local existing_summary=""
    local module_file="$pkb/modules/${module_name}.md"
    [[ -f "$module_file" ]] && existing_summary=$(cat "$module_file")

    local module_dir
    module_dir=$(_pkb_module_to_dir "$project_dir" "$module_name")
    [[ -z "$module_dir" || ! -d "$module_dir" ]] && continue

    _pkb_update_one_module "$project_dir" "$module_name" "$module_dir" \
      "$existing_summary" "$changed_files" "$lang_directive" "$model" \
      > "$module_file.tmp" 2>/dev/null

    if [[ -s "$module_file.tmp" ]]; then
      mv "$module_file.tmp" "$module_file"
    else
      rm -f "$module_file.tmp"
    fi
  done

  # Also update sitemap if new files were added
  local has_new_files
  has_new_files=$(echo "$changed_files" | head -20 | while read -r f; do
    [[ -z "$f" ]] && continue
    git -C "$project_dir" log --diff-filter=A --format="" -- "$f" 2>/dev/null | head -1
  done | wc -l | tr -d '[:space:]')

  if [[ "$has_new_files" -gt 0 && -f "$pkb/sitemap.md" ]]; then
    log_info "new files detected, updating sitemap..." "pkb"
    _pkb_update_sitemap "$project" "$project_dir" "$pkb/sitemap.md" \
      "$changed_files" "$lang_directive" "$model"
  fi

  pkb_update_meta "$project_dir"
  log_success "PKB updated for modules:$affected_modules" "pkb"
}

# ---------------------------------------------------------------------------
# Build context string for agents — replaces --add-dir with knowledge docs
#
# Tier system (inspired by OpenHarness on-demand skill loading):
#   minimal  — sitemap + conventions only (~200-400 lines, navigation + rules)
#   standard — minimal + architecture + api-surface (~500-800 lines)
#   full     — standard + all relevant module summaries (~800-1500 lines)
#
# Default tier is "minimal" to reduce token usage. Agents that need deeper
# understanding can request higher tiers.
# ---------------------------------------------------------------------------
pkb_build_context() {
  local project_dir="$1"
  local relevant_modules="${2:-}"  # space-separated module names, empty = all
  local tier="${3:-minimal}"       # minimal | standard | full

  local pkb
  pkb="$(pkb_dir "$project_dir")"

  if ! pkb_exists "$project_dir"; then
    echo ""
    return
  fi

  local context="
## Project Knowledge Base (tier: $tier)

Distilled knowledge about this project. Use as primary context — only read source
files when you need exact line numbers or to verify specific code.
"

  # Tier: minimal — always included
  for doc in sitemap conventions; do
    local doc_file="$pkb/${doc}.md"
    if [[ -f "$doc_file" ]]; then
      context="${context}
### ${doc^}
$(cat "$doc_file")
"
    fi
  done

  # Tier: standard — add architecture + api-surface
  if [[ "$tier" == "standard" || "$tier" == "full" ]]; then
    for doc in architecture api-surface; do
      local doc_file="$pkb/${doc}.md"
      if [[ -f "$doc_file" ]]; then
        context="${context}
### ${doc^}
$(cat "$doc_file")
"
      fi
    done
  fi

  # Tier: full — add module summaries
  if [[ "$tier" == "full" ]]; then
    if [[ -n "$relevant_modules" ]]; then
      for mod in $relevant_modules; do
        local mod_file="$pkb/modules/${mod}.md"
        if [[ -f "$mod_file" && -s "$mod_file" ]]; then
          context="${context}
### Module: ${mod}
$(cat "$mod_file")
"
        fi
      done
    else
      for mod_file in "$pkb"/modules/*.md; do
        [[ -f "$mod_file" && -s "$mod_file" ]] || continue
        local mod_name
        mod_name=$(basename "$mod_file" .md)
        context="${context}
### Module: ${mod_name}
$(cat "$mod_file")
"
      done
    fi
  fi

  echo "$context"
}

# Determine relevant modules from a list of changed files
pkb_modules_from_files() {
  local changed_files="$1"
  local -A seen=()
  local result=""

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local mod
    mod=$(_pkb_file_to_module "$file")
    [[ -z "$mod" ]] && continue
    if [[ -z "${seen[$mod]+x}" ]]; then
      seen["$mod"]=1
      result="$result $mod"
    fi
  done <<< "$changed_files"

  echo "${result# }"
}

# ---------------------------------------------------------------------------
# Internal: Map file path → module name
# ---------------------------------------------------------------------------
_pkb_file_to_module() {
  local file="$1"

  # Common patterns:
  # src/features/<module>/...  → module
  # src/modules/<module>/...   → module
  # app/<module>/...           → module
  # lib/<module>/...           → module
  # packages/<module>/...      → module
  # frontend/src/features/<module>/... → module
  # backend/src/<module>/...   → module

  local module=""
  if [[ "$file" =~ (src|app|lib|packages)/(features|modules|domains|pages|routes)/([^/]+) ]]; then
    module="${BASH_REMATCH[3]}"
  elif [[ "$file" =~ (frontend|backend)/src/(features|modules|domains)/([^/]+) ]]; then
    module="${BASH_REMATCH[3]}"
  elif [[ "$file" =~ (frontend|backend)/src/([^/]+) ]]; then
    module="${BASH_REMATCH[2]}"
  elif [[ "$file" =~ src/([^/]+) ]]; then
    module="${BASH_REMATCH[1]}"
  fi

  # Skip generic dirs
  case "$module" in
    components|utils|helpers|types|styles|assets|public|__tests__|test|spec) module="" ;;
  esac

  echo "$module"
}

_pkb_module_to_dir() {
  local project_dir="$1" module_name="$2"

  # Try common patterns
  for pattern in \
    "src/features/$module_name" \
    "src/modules/$module_name" \
    "frontend/src/features/$module_name" \
    "frontend/src/modules/$module_name" \
    "backend/src/modules/$module_name" \
    "backend/src/$module_name" \
    "app/$module_name" \
    "lib/$module_name" \
    "packages/$module_name"; do
    local dir="$project_dir/$pattern"
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return
    fi
  done

  echo ""
}

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
)" --add-dir "$project_dir" --model "$model" --max-turns 5 --setting-sources "project"
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
)" --add-dir "$project_dir" --model "$model" --max-turns 5 --setting-sources "project"
}

_pkb_generate_conventions() {
  local project="$1" project_dir="$2" project_type="$3"
  local lang_directive="$4" model="$5"

  claude -p "$(cat <<PROMPT
You are a code quality analyst. Generate a CONVENTIONS document for "$project" (type: $project_type).

## Your Task
1. Read config files: .eslintrc*, tsconfig*, prettier*, .editorconfig, CLAUDE.md, AGENTS.md, .claude/rules/.
2. Read a sample of source files to identify actual coding patterns.
3. Document: naming conventions, import style, error handling patterns, testing approach.
4. Note any project-specific rules or deviations from standard.

## Output Format (markdown)
# Conventions: $project

## Coding Style
- ...

## Naming Conventions
- ...

## Import & Module Patterns
- ...

## Error Handling
- ...

## Testing Approach
- ...

## Project-Specific Rules
- ...

${lang_directive}

Only document patterns actually used in the codebase. Don't assume or prescribe.
PROMPT
)" --add-dir "$project_dir" --model "$model" --max-turns 5 --setting-sources "project"
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
)" --add-dir "$project_dir" --model "$model" --max-turns 5 --setting-sources "project"
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

  # Clean empty files
  find "$pkb/modules" -name '*.md' -empty -delete 2>/dev/null
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
)" --add-dir "$mod_dir" --model "$model" --max-turns 3 --setting-sources "project"
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
)" --add-dir "$module_dir" --model "$model" --max-turns 3 --setting-sources "project"
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
)" --add-dir "$project_dir" --model "$model" --max-turns 3 --setting-sources "project" 2>/dev/null)

  if [[ -n "$updated" ]]; then
    echo "$updated" > "$sitemap_file"
  fi
}
