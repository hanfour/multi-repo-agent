#!/usr/bin/env bash

detect_ide() {
  if command -v cursor &>/dev/null; then echo "cursor"
  elif command -v code &>/dev/null; then echo "code"
  else echo ""; fi
}

open_project() {
  local workspace="$1"; shift
  local projects=() with_deps=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-deps) with_deps=true; shift ;;
      *) projects+=("$1"); shift ;;
    esac
  done

  [[ ${#projects[@]} -eq 0 ]] && { log_error "usage: mra open <project> [--with-deps]" "open"; return 1; }

  if [[ "$with_deps" == "true" ]]; then
    local graph_file; graph_file=$(get_dep_graph_path "$workspace")
    local resolved; resolved=$(for p in "${projects[@]}"; do resolve_with_deps "$p" 1 "$graph_file"; done | sort -u)
    projects=(); while IFS= read -r p; do [[ -n "$p" ]] && projects+=("$p"); done <<< "$resolved"
  fi

  local ide; ide=$(detect_ide)
  [[ -z "$ide" ]] && { log_error "no IDE found (install VS Code or Cursor)" "open"; return 1; }

  for project in "${projects[@]}"; do
    local project_dir="$workspace/$project"
    if [[ -d "$project_dir" ]]; then
      log_progress "opening $project in $ide" "open"
      "$ide" "$project_dir"
    else log_warn "$project: directory not found" "open"; fi
  done

  log_success "opened ${#projects[@]} project(s) in $ide" "open"
}
