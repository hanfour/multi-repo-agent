#!/usr/bin/env bash
# PKB query: build review context and map changed files to modules.

# ---------------------------------------------------------------------------
# Build context string for agents — 4-layer memory stack (mempalace-inspired)
#
# L0: Identity   (~50 tokens)  — project name, type, one-line purpose
# L1: Essential   (~200 tokens) — core conventions + architecture summary
# L2: Room Recall (on-demand)  — module summaries relevant to changed files
# L3: Deep Search (on-demand)  — full architecture + api-surface + all modules
#
# Layer mapping (backwards-compatible with old tier names):
#   minimal  → L0 + L1 (~250 tokens wake-up cost)
#   standard → L0 + L1 + relevant L2 (~500-800 tokens)
#   full     → L0 + L1 + L2 + L3 (~800-1500 tokens)
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

  local native_memory=false
  [[ "$(config_get loadProjectMemory 2>/dev/null)" != "false" ]] && native_memory=true

  local context=""

  # --- Staleness banner (issue #20): never silently serve a stale PKB ---
  # Files changed since the snapshot are named explicitly so the agent reads
  # them directly and keeps trusting the PKB for everything else.
  local stale_files
  stale_files=$(pkb_stale_files "$project_dir" 2>/dev/null || true)
  if [[ -n "$stale_files" ]]; then
    local stale_count shown
    stale_count=$(printf '%s\n' "$stale_files" | wc -l | tr -d '[:space:]')
    shown=$(printf '%s\n' "$stale_files" | head -20)
    context="⚠️ PKB STALENESS: ${stale_count} file(s) changed since this PKB was generated. Read these files directly instead of trusting PKB claims about them; the PKB is still reliable for everything else:
${shown}"
    if [[ "$stale_count" -gt 20 ]]; then
      context="${context}
(+$((stale_count - 20)) more)"
    fi
    context="${context}

"
  fi

  # --- L0: Identity (always loaded, ~50 tokens) ---
  local identity_file="$pkb/identity.md"
  if [[ -f "$identity_file" ]]; then
    context="${context}## Project Identity
$(cat "$identity_file")
"
  fi

  # --- L1: Essential conventions (always loaded, ~200 tokens) ---
  # Extract only tagged [CONVENTION] and [PATTERN] lines from conventions.md
  local conventions_file="$pkb/conventions.md"
  if [[ -f "$conventions_file" ]]; then
    local essential
    # Tag prefixes match with or without a provenance suffix, e.g. both
    # "[DECISION]" and "[DECISION source:review@abc 2026-07-16]" (issue #22).
    essential=$(grep -E '^\[CONVENTION[] ]|^\[PATTERN[] ]|^\[DECISION[] ]|^## |^# ' "$conventions_file" 2>/dev/null || true)
    if [[ -n "$essential" ]]; then
      context="${context}
## Essential Conventions
${essential}
"
    elif [[ "$native_memory" == false ]]; then
      # Fallback: load full conventions if no tags found (pre-v2 PKB)
      context="${context}
## Conventions
$(cat "$conventions_file")
"
    fi
  fi

  # Tunnel links (always include if available)
  local tunnels_file="$pkb/tunnels.md"
  if [[ -f "$tunnels_file" && -s "$tunnels_file" ]]; then
    context="${context}
## Cross-Module References
$(cat "$tunnels_file")
"
  fi

  # --- L2: Room Recall (standard tier — relevant modules only) ---
  if [[ "$tier" == "standard" || "$tier" == "full" ]]; then
    # Include sitemap for navigation
    local sitemap_file="$pkb/sitemap.md"
    if [[ -f "$sitemap_file" ]]; then
      context="${context}
## Sitemap
$(cat "$sitemap_file")
"
    fi

    # Include architecture overview
    local arch_file="$pkb/architecture.md"
    if [[ -f "$arch_file" ]]; then
      context="${context}
## Architecture
$(cat "$arch_file")
"
    fi

    # Include relevant module summaries (room recall)
    if [[ -n "$relevant_modules" ]]; then
      for mod in $relevant_modules; do
        local mod_file="$pkb/modules/${mod}.md"
        if [[ -f "$mod_file" && -s "$mod_file" ]]; then
          context="${context}
## Module: ${mod}
$(cat "$mod_file")
"
        fi
      done
    fi
  fi

  # --- L3: Deep Search (full tier — everything) ---
  if [[ "$tier" == "full" ]]; then
    # API surface
    local api_file="$pkb/api-surface.md"
    if [[ -f "$api_file" ]]; then
      context="${context}
## API Surface
$(cat "$api_file")
"
    fi

    # Full conventions (not just tagged lines) — skip when claude loads
    # CLAUDE.md/rules natively to avoid a verbatim second copy.
    if [[ -f "$conventions_file" && "$native_memory" == false ]]; then
      context="${context}
## Full Conventions
$(cat "$conventions_file")
"
    fi

    # All module summaries (not just relevant ones)
    if [[ -z "$relevant_modules" ]]; then
      for mod_file in "$pkb"/modules/*.md; do
        [[ -f "$mod_file" && -s "$mod_file" ]] || continue
        local mod_name
        mod_name=$(basename "$mod_file" .md)
        context="${context}
## Module: ${mod_name}
$(cat "$mod_file")
"
      done
    fi
  fi

  echo "$context"
}

# Determine relevant modules from a list of changed files.
# project_dir (optional) enables the fact-driven moduleMap lookup (issue #21).
pkb_modules_from_files() {
  local changed_files="$1" project_dir="${2:-}"
  local -A seen=()
  local result=""

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local mod
    mod=$(_pkb_file_to_module "$file" "$project_dir")
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
#
# Fact-driven lookup first (issue #21): the moduleMap recorded at PKB
# generation knows each module's ACTUAL directory, so non-standard layouts
# resolve correctly; the longest matching prefix wins. The legacy path-regex
# guesses remain as the fallback for map misses and pre-map PKBs.
# ---------------------------------------------------------------------------
_pkb_file_to_module() {
  local file="$1" project_dir="${2:-}"

  if [[ -n "$project_dir" ]]; then
    local map
    map=$(jq -c '.moduleMap // {}' "$(pkb_dir "$project_dir")/meta.json" 2>/dev/null || echo '{}')
    if [[ -n "$map" && "$map" != "{}" ]]; then
      local best="" best_len=0 mod dir
      while IFS=$'\t' read -r mod dir; do
        [[ -n "$mod" && -n "$dir" ]] || continue
        if [[ "$file" == "$dir"/* && ${#dir} -gt $best_len ]]; then
          best="$mod"; best_len=${#dir}
        fi
      done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$map" 2>/dev/null)
      if [[ -n "$best" ]]; then
        echo "$best"
        return
      fi
    fi
  fi

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

  # moduleMap first (issue #21): the recorded actual directory wins
  local mapped
  mapped=$(jq -r --arg m "$module_name" '.moduleMap[$m] // ""' \
    "$(pkb_dir "$project_dir")/meta.json" 2>/dev/null || echo "")
  if [[ -n "$mapped" && -d "$project_dir/$mapped" ]]; then
    echo "$project_dir/$mapped"
    return
  fi

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
