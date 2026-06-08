#!/usr/bin/env bash
# Cleanup orphan containers and old logs

cleanup_containers() {
  log_progress "cleaning orphan containers" "clean"
  local removed
  removed=$(docker ps -a --filter "name=mra-" --filter "status=exited" -q 2>/dev/null)
  if [[ -n "$removed" ]]; then
    echo "$removed" | xargs docker rm &>/dev/null
    local count
    count=$(echo "$removed" | wc -l | tr -d ' ')
    log_success "removed $count orphan container(s)" "clean"
  else
    log_success "no orphan containers found" "clean"
  fi
}

cleanup_logs() {
  local workspace="$1" max_age="${2:-7}"
  local log_dir="$workspace/.collab/logs"

  if [[ ! -d "$log_dir" ]]; then
    log_success "no logs directory" "clean"
    return 0
  fi

  log_progress "cleaning logs older than ${max_age}d" "clean"
  local count
  count=$(find "$log_dir" -name "*.log" -mtime +"$max_age" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    find "$log_dir" -name "*.log" -mtime +"$max_age" -delete 2>/dev/null
    log_success "removed $count old log(s)" "clean"
  else
    log_success "no old logs found" "clean"
  fi
}

handle_clean() {
  local workspace="$1" logs_older_than="${2:-7}"
  cleanup_containers
  cleanup_logs "$workspace" "$logs_older_than"
}
