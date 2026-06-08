#!/usr/bin/env bash
get_usage_file() {
  local workspace="$1"
  echo "$workspace/.collab/usage.json"
}

record_usage() {
  local workspace="$1" tokens_in="$2" tokens_out="$3" cost="$4" command="$5"
  local usage_file; usage_file=$(get_usage_file "$workspace")
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local today; today=$(date -u +%Y-%m-%d)

  # Initialize if not exists
  if [[ ! -f "$usage_file" ]]; then
    echo '{"totalCost":0,"totalInputTokens":0,"totalOutputTokens":0,"sessions":0,"daily":{},"history":[]}' > "$usage_file"
  fi

  local tmp; tmp=$(mktemp)
  jq --argjson tin "$tokens_in" --argjson tout "$tokens_out" --argjson c "$cost" \
     --arg cmd "$command" --arg ts "$now" --arg day "$today" \
    '.totalCost += $c |
     .totalInputTokens += $tin |
     .totalOutputTokens += $tout |
     .sessions += 1 |
     .daily[$day].cost = ((.daily[$day].cost // 0) + $c) |
     .daily[$day].sessions = ((.daily[$day].sessions // 0) + 1) |
     .history = (.history + [{"timestamp": $ts, "command": $cmd, "inputTokens": $tin, "outputTokens": $tout, "cost": $c}]) |
     .history = (.history | .[-100:])' \
    "$usage_file" > "$tmp" && mv "$tmp" "$usage_file"
}

show_cost() {
  local workspace="$1"
  local usage_file; usage_file=$(get_usage_file "$workspace")

  if [[ ! -f "$usage_file" ]]; then
    log_info "no usage data yet" "cost"
    return 0
  fi

  local total_cost total_in total_out sessions
  total_cost=$(jq -r '.totalCost' "$usage_file")
  total_in=$(jq -r '.totalInputTokens' "$usage_file")
  total_out=$(jq -r '.totalOutputTokens' "$usage_file")
  sessions=$(jq -r '.sessions' "$usage_file")

  echo ""
  log_info "Claude API Usage Summary" "cost"
  echo ""
  printf "  Total cost:          \$%.4f\n" "$total_cost"
  printf "  Total input tokens:  %s\n" "$total_in"
  printf "  Total output tokens: %s\n" "$total_out"
  printf "  Total sessions:      %s\n" "$sessions"
  echo ""

  # Daily breakdown (last 7 days)
  log_info "Daily breakdown (last 7 days):" "cost"
  jq -r '.daily | to_entries | sort_by(.key) | reverse | .[:7][] | "  \(.key): $\(.value.cost | tostring | .[0:8]) (\(.value.sessions) sessions)"' \
    "$usage_file" 2>/dev/null || echo "  (no daily data)"
  echo ""
}

reset_cost() {
  local workspace="$1"
  local usage_file; usage_file=$(get_usage_file "$workspace")
  echo '{"totalCost":0,"totalInputTokens":0,"totalOutputTokens":0,"sessions":0,"daily":{},"history":[]}' > "$usage_file"
  log_success "usage data reset" "cost"
}
