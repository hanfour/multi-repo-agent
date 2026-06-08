#!/usr/bin/env bash
check_tool() {
  local tool="$1" purpose="$2"
  if command -v "$tool" &>/dev/null; then
    log_success "$tool: ok" "check"
    return 0
  else
    log_error "$tool: not found ($purpose)" "check"
    return 1
  fi
}
check_yq() {
  if command -v yq &>/dev/null; then
    log_success "yq: ok" "check"; return 0
  else
    log_warn "yq: not found (YAML parsing - install with: brew install yq)" "check"; return 1
  fi
}
check_docker_running() {
  if docker info &>/dev/null 2>&1; then
    log_success "docker daemon: running" "check"; return 0
  else
    log_error "docker daemon: not running (start Docker Desktop)" "check"; return 1
  fi
}
check_gh_auth() {
  if gh auth status &>/dev/null 2>&1; then
    log_success "gh auth: ok" "check"; return 0
  else
    log_warn "gh auth: not authenticated (run: gh auth login)" "check"; return 1
  fi
}
check_git_ssh() {
  if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    log_success "git ssh: ok" "check"; return 0
  else
    log_warn "git ssh: cannot verify (run: ssh -T git@github.com)" "check"; return 1
  fi
}
run_preflight() {
  local failed=0
  check_tool "git" "version control" || ((failed++))
  check_tool "docker" "container runtime" || ((failed++))
  check_tool "jq" "JSON parsing" || ((failed++))
  check_tool "gh" "GitHub CLI" || ((failed++))
  check_yq || ((failed++))
  check_docker_running || ((failed++))
  check_gh_auth || ((failed++))
  check_git_ssh || ((failed++))
  if [[ $failed -gt 0 ]]; then
    log_warn "$failed check(s) failed - some features may not work" "check"; return 1
  fi
  return 0
}
