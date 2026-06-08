#!/usr/bin/env bash

show_diff_summary() {
  local workspace="$1"
  local graph_file="$workspace/.collab/dep-graph.json"

  [[ ! -f "$graph_file" ]] && { log_error "not initialized" "diff"; return 1; }

  local has_changes=false

  printf "%-20s %-15s %-10s %-10s %s\n" "PROJECT" "BRANCH" "UNPUSHED" "UNCOMMIT" "CHANGED FILES"
  printf "%s\n" "--------------------------------------------------------------------------------"

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    local project_dir="$workspace/$project"
    [[ ! -d "$project_dir/.git" ]] && continue

    local branch uncommitted unpushed
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    uncommitted=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # Safe way to get unpushed commits without failing on branch with no upstream
    unpushed=0
    if git -C "$project_dir" rev-parse @{upstream} &>/dev/null; then
      unpushed=$(git -C "$project_dir" log --oneline @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')
    fi

    [[ "$uncommitted" -eq 0 && "$unpushed" -eq 0 ]] && continue

    has_changes=true

    local changed_files
    changed_files=$(git -C "$project_dir" status --porcelain 2>/dev/null | head -3 | awk '{print $2}' | paste -sd, -)
    local total; total=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [[ "$total" -gt 3 ]] && changed_files="$changed_files (+$((total - 3)) more)"
    [[ ${#branch} -gt 14 ]] && branch="${branch:0:11}..."

    printf "%-20s %-15s %-10s %-10s %s\n" "$project" "$branch" "$unpushed" "$uncommitted" "$changed_files"
  done < <(jq -r '.projects | keys[]' "$graph_file")

  if [[ "$has_changes" == "false" ]]; then
    log_success "all projects clean" "diff"
  fi
  return 0
}
