#!/usr/bin/env bash

show_status() {
  local workspace="$1"
  local graph_file="$workspace/.collab/dep-graph.json"
  local db_json="$workspace/.collab/db.json"

  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "status"; return 1; }

  local last_scan; last_scan=$(jq -r '.lastScan // "never"' "$graph_file")
  log_info "workspace: $(jq -r '.workspace' "$graph_file") | last scan: $last_scan" "status"
  echo ""

  printf "%-20s %-12s %-15s %-8s %s\n" "PROJECT" "TYPE" "BRANCH" "CHANGES" "STATUS"
  printf "%s\n" "--------------------------------------------------------------------------------"

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local project_dir="$workspace/$project"
    local project_type; project_type=$(jq -r --arg p "$project" '.projects[$p].type // "?"' "$graph_file")

    if [[ ! -d "$project_dir/.git" ]]; then
      printf "%-20s %-12s %-15s %-8s %s\n" "$project" "$project_type" "-" "-" "not cloned"
      continue
    fi

    local branch changes status_info
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    status_info="ok"

    [[ "$changes" -gt 0 ]] && status_info="$changes uncommitted"
    [[ ${#branch} -gt 14 ]] && branch="${branch:0:11}..."

    printf "%-20s %-12s %-15s %-8s %s\n" "$project" "$project_type" "$branch" "$changes" "$status_info"
  done < <(jq -r '.projects | keys[]' "$graph_file")

  echo ""
  if [[ -f "$db_json" ]]; then
    log_info "databases:" "status"
    while IFS= read -r db_name; do
      [[ -z "$db_name" ]] && continue
      local container_name="mra-db-$db_name"
      local engine; engine=$(jq -r --arg n "$db_name" '.databases[$n].engine // "?"' "$db_json")

      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        log_success "  $db_name ($engine): running" ""
      else
        log_warn "  $db_name ($engine): stopped" ""
      fi
    done < <(jq -r '.databases | keys[]' "$db_json")
  fi
}
