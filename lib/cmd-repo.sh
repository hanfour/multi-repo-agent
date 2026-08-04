#!/usr/bin/env bash
# Repository, database and operational commands.
#
# Dispatched by convention from bin/mra.sh: `mra <name>` runs
# mra_cmd_<name> with dashes replaced by underscores. Adding a command means
# adding a function here — the dispatch itself is not edited (#39).
#
# Each still receives the full argv with the command name at $1, exactly as
# the case branch it replaced did, so the `shift` each body opens with means
# the same thing.

mra_cmd_db() {
  cmd_db "$@"
}

mra_cmd_test() {
  shift
  local workspace project test_mode="auto"
  workspace=$(resolve_workspace)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --integration) test_mode="integration"; shift ;;
      --mock) test_mode="mock"; shift ;;
      -*) log_error "unknown option: $1" "test"; exit 1 ;;
      *) project="$1"; shift ;;
    esac
  done
  if [[ -z "${project:-}" ]]; then
    log_error "usage: mra test <project> [--integration|--mock]" "test"
    exit 1
  fi
  case "$test_mode" in
    integration) run_cross_repo_tests "$workspace" "$project" ;;
    mock) run_project_tests "$workspace" "$project" ;;
    auto) run_cross_repo_tests "$workspace" "$project" ;;
  esac
}

mra_cmd_ci() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local ci_project="" ci_opts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-review) ci_opts+=("--with-review"); shift ;;
      -*) log_error "unknown option: $1" "ci"; exit 1 ;;
      *) ci_project="$1"; shift ;;
    esac
  done
  if [[ -z "$ci_project" ]]; then
    log_error "usage: mra ci <project> [--with-review]" "ci"; exit 1
  fi
  generate_ci_workflow "$workspace" "$ci_project" "${ci_opts[@]}"
}

mra_cmd_snapshot() {
  shift
  local workspace; workspace=$(resolve_workspace)
  create_snapshot "$workspace" "${1:-}"
}

mra_cmd_snapshots() {
  shift
  local workspace; workspace=$(resolve_workspace)
  list_snapshots "$workspace"
}

mra_cmd_rollback() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local rb_force=0 rb_ignore_integrity=0
  local rb_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) rb_force=1; shift ;;
      --ignore-integrity) rb_ignore_integrity=1; shift ;;
      *) rb_args+=("$1"); shift ;;
    esac
  done
  [[ "$rb_force" == "1" ]] && export MRA_ROLLBACK_FORCE=1
  [[ "$rb_ignore_integrity" == "1" ]] && export MRA_ROLLBACK_IGNORE_INTEGRITY=1
  if [[ "${rb_args[0]:-}" == "--all" ]]; then
    rollback_all "$workspace" "${rb_args[1]:-}"
  elif [[ -n "${rb_args[0]:-}" ]]; then
    rollback_project "$workspace" "${rb_args[0]}" "${rb_args[1]:-}"
  else
    log_error "usage: mra rollback <project|--all> [snapshot-name] [--force] [--ignore-integrity]" "rollback"
    exit 1
  fi
}

mra_cmd_trust() {
  shift
  local workspace; workspace=$(resolve_workspace)
  if [[ -z "${1:-}" ]]; then
    log_error "usage: mra trust <project>" "trust"
    exit 1
  fi
  local trust_project="$1"
  if ! validate_project_name "$trust_project"; then
    exit 1
  fi
  MRA_DOCKER_TRUST_FORCE=1 _docker_trust_check "$workspace" "$trust_project" ""
}

mra_cmd_dashboard() {
  shift
  local workspace; workspace=$(resolve_workspace)
  run_dashboard "$workspace"
}

mra_cmd_federation() {
  cmd_federation "$@"
}

mra_cmd_notify() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local subcmd="${1:-status}"; shift 2>/dev/null || true
  case "$subcmd" in
    setup) setup_notifications "$workspace" ;;
    status) show_notify_status "$workspace" ;;
    test) test_notification "$workspace" ;;
    *) log_error "usage: mra notify [setup|status|test]" "notify"; exit 1 ;;
  esac
}

mra_cmd_integration() {
  cmd_integration "$@"
}

mra_cmd_sync() {
  cmd_sync "$@"
}

mra_cmd_branch() {
  cmd_branch "$@"
}
