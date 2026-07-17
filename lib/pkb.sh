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

PKB_VERSION=2
PKB_DIR_NAME=".mra/pkb"

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

  # --- Phase 0: Generate L0 identity (ultra-compact, ~50 tokens) ---
  _pkb_generate_identity "$project" "$project_dir" "$project_type" "$pkb"

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
  _pkb_keep_doc "$sitemap_file" "$pkb/sitemap.md"
  _pkb_keep_doc "$architecture_file" "$pkb/architecture.md"
  _pkb_keep_doc "$conventions_file" "$pkb/conventions.md"
  _pkb_keep_doc "$api_file" "$pkb/api-surface.md"

  log_info "[phase 1] core documents generated" "pkb"

  # --- Phase 2: Module summaries (sequential, based on sitemap) ---
  log_progress "[phase 2] generating module summaries..." "pkb"

  _pkb_generate_modules "$project" "$project_dir" "$project_type" \
    "$lang_directive" "$model" "$pkb"

  # --- Phase 3: Generate tunnel links (cross-module references) ---
  log_progress "[phase 3] generating tunnel links..." "pkb"
  _pkb_generate_tunnels "$pkb" "$project_dir"

  # --- Phase 4: Record change-detection baselines for incremental updates ---
  _pkb_record_mtimes "$project_dir" "$pkb"
  pkb_record_snapshot "$project_dir"

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

  # Change gate: prefer the git blob-hash snapshot (precise: per-file, catches
  # deletions, all languages — issue #20); fall back to the coarse mtime check
  # for non-git projects or pre-snapshot PKBs.
  local changed_areas
  if git -C "$project_dir" rev-parse HEAD >/dev/null 2>&1 && \
     jq -e '.snapshotCommit' "$pkb/meta.json" >/dev/null 2>&1; then
    changed_areas=$(pkb_stale_files "$project_dir")
    if [[ -z "$changed_areas" ]]; then
      log_info "no source changes detected (snapshot), skipping PKB update" "pkb"
      return 0
    fi
  else
    changed_areas=$(_pkb_check_mtimes "$project_dir")
    if [[ -z "$changed_areas" ]]; then
      log_info "no source changes detected (mtime), skipping PKB update" "pkb"
      return 0
    fi
  fi

  # If config files changed, regenerate conventions
  if echo "$changed_areas" | grep -qE 'package.json|tsconfig|eslintrc|CLAUDE.md|AGENTS.md'; then
    log_info "config files changed, conventions may need update" "pkb"
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
    module_name=$(_pkb_file_to_module "$file" "$project_dir")
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

    _pkb_keep_doc "$module_file.tmp" "$module_file"
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

  # Regenerate tunnels after module updates
  _pkb_generate_tunnels "$pkb" "$project_dir"

  # Record new change-detection baselines
  _pkb_record_mtimes "$project_dir" "$pkb"
  pkb_record_snapshot "$project_dir"

  pkb_update_meta "$project_dir"
  log_success "PKB updated for modules:$affected_modules" "pkb"
}

# ---------------------------------------------------------------------------
# Capture decisions from review results and append to conventions.md
# Called after review completes
# ---------------------------------------------------------------------------
pkb_capture_decisions() {
  local project_dir="$1" review_json="$2"

  local pkb
  pkb="$(pkb_dir "$project_dir")"
  [[ ! -d "$pkb" ]] && return

  local conventions_file="$pkb/conventions.md"
  [[ ! -f "$conventions_file" ]] && return

  # Provenance tag (issue #22): every machine-distilled decision records where
  # it came from, so entries are auditable and safely cleanable later —
  # mirroring codegraph's provenance/synthesizedBy discipline on heuristic edges.
  local short_sha source_tag
  short_sha=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  source_tag="source:review@${short_sha} $(date +%Y-%m-%d)"

  # Extract CRITICAL and HIGH findings that reveal project conventions
  local decisions
  decisions=$(echo "$review_json" | jq -r --arg tag "$source_tag" '
    .comments[]? |
    select(.severity == "CRITICAL" or .severity == "HIGH") |
    "[DECISION \($tag)] \(.body | split("\n")[0])"
  ' 2>/dev/null || true)

  if [[ -n "$decisions" && "$decisions" != "null" ]]; then
    # Append new decisions if not already present — dedup compares the BODY
    # text (never the source tag), so a re-review of the same finding, or a
    # legacy untagged copy, is not duplicated.
    while IFS= read -r decision; do
      [[ -z "$decision" ]] && continue
      local body="${decision#*\] }"
      if ! grep -qF "$(echo "$body" | cut -c1-40)" "$conventions_file" 2>/dev/null; then
        echo "$decision" >> "$conventions_file"
      fi
    done <<< "$decisions"
  fi
}

