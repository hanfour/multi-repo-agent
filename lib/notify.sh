#!/usr/bin/env bash
# Notification system: Slack/Discord/generic webhooks

get_notify_config() {
  local workspace="$1"
  echo "$workspace/.collab/notify.json"
}

# Send a notification to all configured webhooks
notify() {
  local workspace="$1" event="$2" message="$3" level="${4:-info}"
  local notify_config; notify_config=$(get_notify_config "$workspace")

  # Also log to .collab/logs
  mra_log "$workspace" "notify" "[$level] $event: $message" 2>/dev/null || true

  [[ ! -f "$notify_config" ]] && return 0  # No webhooks configured, silent skip

  local webhooks
  webhooks=$(jq -r '.webhooks // [] | .[] | select(.enabled == true) | @base64' "$notify_config" 2>/dev/null)

  [[ -z "$webhooks" ]] && return 0

  while IFS= read -r webhook_b64; do
    [[ -z "$webhook_b64" ]] && continue
    local webhook; webhook=$(echo "$webhook_b64" | base64 -d 2>/dev/null || echo "$webhook_b64" | base64 -D 2>/dev/null)
    local url type name
    url=$(echo "$webhook" | jq -r '.url')
    type=$(echo "$webhook" | jq -r '.type // "generic"')
    name=$(echo "$webhook" | jq -r '.name // "unnamed"')

    # Check level filter
    local min_level; min_level=$(echo "$webhook" | jq -r '.minLevel // "info"')
    if ! _level_passes "$level" "$min_level"; then
      continue
    fi

    case "$type" in
      slack)
        _send_slack "$url" "$event" "$message" "$level"
        ;;
      discord)
        _send_discord "$url" "$event" "$message" "$level"
        ;;
      generic|*)
        _send_generic "$url" "$event" "$message" "$level"
        ;;
    esac
  done <<< "$webhooks"
}

# Level comparison: does $level pass the $min_level filter?
_level_passes() {
  local level="$1" min_level="$2"
  local -A level_num=(["info"]=0 ["warn"]=1 ["error"]=2 ["critical"]=3)
  local ln=${level_num[$level]:-0}
  local mn=${level_num[$min_level]:-0}
  [[ $ln -ge $mn ]]
}

# Slack webhook
_send_slack() {
  local url="$1" event="$2" message="$3" level="$4"
  local color
  case "$level" in
    info) color="#36a64f" ;;
    warn) color="#daa038" ;;
    error|critical) color="#cc0000" ;;
    *) color="#808080" ;;
  esac

  local payload
  payload=$(jq -n \
    --arg text "[$level] $event" \
    --arg msg "$message" \
    --arg color "$color" \
    '{
      attachments: [{
        color: $color,
        title: $text,
        text: $msg,
        footer: "multi-repo-agent",
        ts: (now | floor)
      }]
    }')

  curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$url" &>/dev/null && \
    log_success "slack notification sent" "notify" || \
    log_warn "slack notification failed" "notify"
}

# Discord webhook
_send_discord() {
  local url="$1" event="$2" message="$3" level="$4"
  local color
  case "$level" in
    info) color=3066993 ;;
    warn) color=15105570 ;;
    error|critical) color=13369344 ;;
    *) color=8421504 ;;
  esac

  local payload
  payload=$(jq -n \
    --arg title "[$level] $event" \
    --arg desc "$message" \
    --argjson color "$color" \
    '{
      embeds: [{
        title: $title,
        description: $desc,
        color: $color,
        footer: { text: "multi-repo-agent" }
      }]
    }')

  curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$url" &>/dev/null && \
    log_success "discord notification sent" "notify" || \
    log_warn "discord notification failed" "notify"
}

# Generic webhook (POST JSON)
_send_generic() {
  local url="$1" event="$2" message="$3" level="$4"

  local payload
  payload=$(jq -n \
    --arg event "$event" \
    --arg message "$message" \
    --arg level "$level" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source "multi-repo-agent" \
    '{event: $event, message: $message, level: $level, timestamp: $timestamp, source: $source}')

  curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$url" &>/dev/null && \
    log_success "webhook notification sent" "notify" || \
    log_warn "webhook notification failed" "notify"
}

# Convenience functions for common events
notify_scan_complete() {
  local workspace="$1" dep_count="$2"
  notify "$workspace" "scan-complete" "Dependency scan found $dep_count relationship(s)" "info"
}

notify_test_failed() {
  local workspace="$1" project="$2" exit_code="$3"
  notify "$workspace" "test-failed" "Tests failed for $project (exit $exit_code)" "error"
}

notify_test_passed() {
  local workspace="$1" project="$2"
  notify "$workspace" "test-passed" "Tests passed for $project" "info"
}

notify_pr_created() {
  local workspace="$1" project="$2" pr_url="$3"
  notify "$workspace" "pr-created" "PR created for $project: $pr_url" "info"
}

notify_review_complete() {
  local workspace="$1" project="$2" result="$3"
  local level="info"
  [[ "$result" == "CHANGES_REQUESTED" ]] && level="warn"
  notify "$workspace" "review-complete" "Code review for $project: $result" "$level"
}

notify_contract_violation() {
  local workspace="$1" project="$2" details="$3"
  notify "$workspace" "contract-violation" "Contract violation in $project: $details" "error"
}

notify_escalation() {
  local workspace="$1" project="$2" summary="$3"
  notify "$workspace" "escalation" "Escalation for $project: $summary" "critical"
}

# Setup: create notify.json template
setup_notifications() {
  local workspace="$1"
  local notify_config; notify_config=$(get_notify_config "$workspace")

  if [[ -f "$notify_config" ]]; then
    log_info "notify.json already exists" "notify"
    return 0
  fi

  cat > "$notify_config" <<'TMPL'
{
  "webhooks": [
    {
      "name": "slack-dev",
      "type": "slack",
      "url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
      "enabled": false,
      "minLevel": "warn"
    },
    {
      "name": "discord-dev",
      "type": "discord",
      "url": "https://discord.com/api/webhooks/YOUR/WEBHOOK/URL",
      "enabled": false,
      "minLevel": "error"
    }
  ]
}
TMPL
  log_success "notify.json template created: $notify_config" "notify"
  log_info "edit the file to add your webhook URLs and set enabled: true" "notify"
}

# Show notification config status
show_notify_status() {
  local workspace="$1"
  local notify_config; notify_config=$(get_notify_config "$workspace")

  if [[ ! -f "$notify_config" ]]; then
    log_info "notifications not configured (run: mra notify setup)" "notify"
    return 0
  fi

  echo ""
  printf "%-20s %-10s %-10s %-10s %s\n" "NAME" "TYPE" "ENABLED" "MIN LEVEL" "URL"
  printf "%s\n" "--------------------------------------------------------------------------------"

  jq -r '.webhooks[] | "\(.name)|\(.type)|\(.enabled)|\(.minLevel // "info")|\(.url | .[0:50])"' "$notify_config" 2>/dev/null | \
    while IFS='|' read -r name type enabled min_level url; do
      local status
      [[ "$enabled" == "true" ]] && status="yes" || status="no"
      printf "%-20s %-10s %-10s %-10s %s...\n" "$name" "$type" "$status" "$min_level" "$url"
    done
  echo ""
}

# Test: send a test notification
test_notification() {
  local workspace="$1"
  notify "$workspace" "test" "This is a test notification from mra" "info"
  log_success "test notification sent to all enabled webhooks" "notify"
}
