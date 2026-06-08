#!/usr/bin/env bash
# Project-path canonicalization for the MRA CLI.
#
# Many commands take a `project` argument from the operator, an MCP tool
# caller, a CI workflow input, or a `.collab/dep-graph.json` entry, and
# join it onto `$workspace` to obtain a filesystem directory. Without
# validation an attacker who influences any of those inputs can use `..`,
# absolute paths, or symlinks to make MRA load Claude context from,
# export to, or otherwise touch directories outside the workspace.
#
# This module centralises two checks:
#
#   validate_project_name <name>
#     Lexical allowlist. Accepts `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, which
#     covers every project name we have seen in real workspaces and
#     rejects path separators, `..`, leading dots/dashes, whitespace,
#     control characters, and absurdly long inputs.
#
#   resolve_project_dir <workspace> <project>
#     Lexical check + realpath containment. Returns the resolved
#     absolute path on stdout when the project directory exists and
#     resolves to a strict descendant of realpath(workspace). Fails
#     closed otherwise.
#
# Callers should `set -e` or check return codes. Errors are emitted via
# `log_error` with the tag "project-path" so they are easy to grep for.

# shellcheck shell=bash

validate_project_name() {
  local name="${1-}"

  if [[ -z "$name" ]]; then
    log_error "project name is empty" "project-path"
    declare -F log_security_event >/dev/null && \
      log_security_event "project-path" "reject" "reason=empty" "subject="
    return 1
  fi

  if (( ${#name} > 64 )); then
    log_error "project name longer than 64 chars: ${name:0:32}..." "project-path"
    declare -F log_security_event >/dev/null && \
      log_security_event "project-path" "reject" "reason=too_long" "subject=${name:0:64}"
    return 1
  fi

  # Allowlist: first char must be alnum, rest may add `._-`. No path
  # separators, no leading dot/dash, no whitespace, no control chars.
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    log_error "project name contains disallowed characters: $name" "project-path"
    declare -F log_security_event >/dev/null && \
      log_security_event "project-path" "reject" "reason=disallowed_chars" "subject=$name"
    return 1
  fi

  # Defensive: even though the regex above forbids them, reject `..` and
  # `.` segments explicitly so a future regex regression cannot reopen
  # path traversal.
  case "$name" in
    .|..|*/*|*\\*)
      log_error "project name contains path separator or traversal: $name" "project-path"
      declare -F log_security_event >/dev/null && \
        log_security_event "project-path" "reject" "reason=traversal" "subject=$name"
      return 1
      ;;
  esac

  return 0
}

resolve_project_dir() {
  local workspace="${1-}" project="${2-}"

  if [[ -z "$workspace" ]]; then
    log_error "workspace is empty" "project-path"
    return 1
  fi

  if ! validate_project_name "$project"; then
    return 1
  fi

  local ws_real
  ws_real=$(cd "$workspace" 2>/dev/null && pwd -P) || {
    log_error "workspace does not exist: $workspace" "project-path"
    return 1
  }

  local candidate="$ws_real/$project"
  if [[ ! -d "$candidate" ]]; then
    log_error "project directory does not exist: $project" "project-path"
    return 1
  fi

  local resolved
  resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || {
    log_error "could not resolve project path: $project" "project-path"
    return 1
  }

  # Realpath containment: the resolved path must be a strict descendant
  # of the resolved workspace. This catches symlinks that escape.
  case "$resolved" in
    "$ws_real"/*) printf '%s\n' "$resolved"; return 0 ;;
    *)
      log_error "project resolves outside workspace: $project -> $resolved" "project-path"
      declare -F log_security_event >/dev/null && \
        log_security_event "project-path" "reject" "reason=escapes_workspace" \
          "subject=$project" "resolved=$resolved" "workspace=$ws_real"
      return 1
      ;;
  esac
}
