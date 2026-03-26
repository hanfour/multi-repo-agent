#!/usr/bin/env bash

show_logs() {
  local workspace="$1" filter_project="${2:-}"
  local log_dir="$workspace/.collab/logs"

  [[ ! -d "$log_dir" ]] && { log_info "no logs yet" "log"; return 0; }

  local log_files
  if [[ -n "$filter_project" ]]; then
    log_files=$(find "$log_dir" -name "*-${filter_project}.log" -type f 2>/dev/null | sort -r | head -20)
  else
    log_files=$(find "$log_dir" -name "*.log" -type f 2>/dev/null | sort -r | head -20)
  fi

  [[ -z "$log_files" ]] && { log_info "no logs found${filter_project:+ for $filter_project}" "log"; return 0; }

  local count; count=$(echo "$log_files" | wc -l | tr -d ' ')
  log_info "showing $count most recent log(s)${filter_project:+ for $filter_project}" "log"
  echo ""

  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    log_info "--- $(basename "$log_file") ---" ""
    cat "$log_file"
    echo ""
  done <<< "$log_files"
}
