#!/usr/bin/env bash
# security-log.sh — append-only JSONL audit of security-relevant events.
#
# Each security control (project-path validation, URL policy, rollback
# confirmation, Docker trust gate) already writes a human-readable log
# line via log_warn / log_error. That output is fine for the operator
# but useless for after-the-fact audit: it goes to stderr, mixed with
# other tags, with no structure.
#
# This module adds a second sink: an append-only JSONL file that
# downstream tooling (mra doctor, grep, jq, log aggregators) can
# query for security-relevant decisions. The intent is "I want to
# know how many MCP project rejections happened today" or "did
# something rollback yesterday and was it confirmed?".
#
# Destination:
#   1. If MRA_WORKSPACE is set and its dir exists → write to
#      $MRA_WORKSPACE/.collab/logs/security.log
#   2. Otherwise → fallback $HOME/.mra/security.log
#
# Each line is a single JSON object: { ts, category, action, ...kv }
# where ts is ISO-8601 UTC, category is a stable string ("project-path",
# "url-policy", "rollback", "trust"), action is a verb ("reject",
# "grant", "refuse", "integrity-fail"), and any extra "key=value"
# arguments become string fields.
#
# log_security_event <category> <action> [key=value ...]
log_security_event() {
  local category="${1-}" action="${2-}"
  shift 2 2>/dev/null || return 0

  # Pick log destination. Workspace-scoped writes win when MRA_WORKSPACE
  # points at a real workspace; otherwise fall back to the per-user
  # location so events from one-off CLI invocations are not lost.
  local log_dir log_file
  if [[ -n "${MRA_WORKSPACE:-}" && -d "$MRA_WORKSPACE" ]]; then
    log_dir="$MRA_WORKSPACE/.collab/logs"
  else
    log_dir="$HOME/.mra"
  fi
  log_file="$log_dir/security.log"
  mkdir -p "$log_dir" 2>/dev/null || return 0

  # Build the JSON line via jq so values are correctly escaped no matter
  # what characters they contain. Each k=v argument becomes a top-level
  # string field. Unknown / malformed pairs are silently dropped to keep
  # logging side-effect-free.
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local jq_args=(-n --arg ts "$ts" --arg category "$category" --arg action "$action")
  local jq_obj='{ts:$ts, category:$category, action:$action'
  local pair key value safe_key
  for pair in "$@"; do
    [[ "$pair" != *=* ]] && continue
    key="${pair%%=*}"
    value="${pair#*=}"
    # jq variable names cannot contain `-`; substitute to keep them safe.
    safe_key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9_' '_')
    [[ -z "$safe_key" ]] && continue
    jq_args+=(--arg "$safe_key" "$value")
    # Emit the field under the ORIGINAL key name (operators read this,
    # not the sanitized form), but resolve via the safe variable.
    jq_obj+=", \"$key\": \$$safe_key"
  done
  jq_obj+='}'

  jq -c "${jq_args[@]}" "$jq_obj" >> "$log_file" 2>/dev/null || return 0
}
