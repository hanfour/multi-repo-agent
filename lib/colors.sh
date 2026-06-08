#!/usr/bin/env bash
# Color output utility for mra CLI
# Usage: log_success "message" "tag"

readonly CLR_RESET='\033[0m'
readonly CLR_WHITE='\033[1;37m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_YELLOW='\033[0;33m'
readonly CLR_RED='\033[0;31m'

_log() {
  local color="$1" message="$2" tag="${3:-}"
  if [[ -n "$tag" ]]; then
    printf "${color}[%s]${CLR_RESET} %s\n" "$tag" "$message"
  else
    printf "${color}%s${CLR_RESET}\n" "$message"
  fi
}

log_progress() { _log "$CLR_WHITE" "$1" "${2:-}"; }
log_success()  { _log "$CLR_GREEN" "$1" "${2:-}"; }
log_info()     { _log "$CLR_CYAN"  "$1" "${2:-}"; }
log_warn()     { _log "$CLR_YELLOW" "$1" "${2:-}"; }
log_error()    { _log "$CLR_RED"   "$1" "${2:-}"; }
