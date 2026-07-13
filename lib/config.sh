#!/usr/bin/env bash
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MRA_CONFIG="${MRA_CONFIG:-$MRA_DIR/config.json}"
config_get() {
  local key="$1" config_file="${2:-$MRA_CONFIG}"
  jq -r ".$key" "$config_file"
}
config_set() {
  local key="$1" value="$2" config_file="${3:-$MRA_CONFIG}"
  local tmp; tmp=$(mktemp)
  if jq --argjson val "$value" ".$key = \$val" "$config_file" > "$tmp"; then
    mv "$tmp" "$config_file"
  else
    rm -f "$tmp"
    log_error "invalid JSON value for $key: $value" "config"
    return 1
  fi
}

# String values go through --arg (jq does the quoting); splicing the
# value into a JSON literal breaks on embedded quotes.
config_set_string() {
  local key="$1" value="$2" config_file="${3:-$MRA_CONFIG}"
  local tmp; tmp=$(mktemp)
  if jq --arg val "$value" ".$key = \$val" "$config_file" > "$tmp"; then
    mv "$tmp" "$config_file"
  else
    rm -f "$tmp"
    log_error "failed to set $key" "config"
    return 1
  fi
}
config_set_bool_word() {
  local key="$1" value="$2"
  case "$value" in
    true|on|1)  config_set "$key" "true" ;;
    false|off|0) config_set "$key" "false" ;;
    *) log_error "invalid value for $key: $value (use on/off)" "config"; return 1 ;;
  esac
}
config_get_alias() {
  local name="$1" config_file="${2:-$MRA_CONFIG}"
  jq -r --arg name "$name" '.aliases[$name] // "null"' "$config_file"
}
config_set_alias() {
  local name="$1" workspace="$2" git_org="$3" config_file="${4:-$MRA_CONFIG}"
  local tmp; tmp=$(mktemp)
  jq --arg name "$name" --arg ws "$workspace" --arg org "$git_org" \
    '.aliases[$name] = {"workspace": $ws, "gitOrg": $org}' \
    "$config_file" > "$tmp" && mv "$tmp" "$config_file"
}
config_handle() {
  local key="$1" value="$2"
  if [[ $# -lt 2 ]]; then
    log_error "usage: mra config <key> <value>" "config"
    return 1
  fi
  case "$key" in
    auto-scan)
      if [[ "$value" == "on" ]]; then config_set "autoScan" "true"; log_success "autoScan enabled" "config"
      elif [[ "$value" == "off" ]]; then config_set "autoScan" "false"; log_success "autoScan disabled" "config"
      else log_error "invalid value: $value (use on/off)" "config"; return 1; fi ;;
    parallel-test)
      if [[ "$value" == "on" || "$value" == "off" ]]; then
        config_set "parallelTest" "$( [[ "$value" == "on" ]] && echo true || echo false )"
        log_success "parallelTest $value" "config"
      else log_error "invalid value: $value (use on/off)" "config"; return 1; fi ;;
    output-language)
      config_set_string "outputLanguage" "$value"
      log_success "outputLanguage set to: $value" "config" ;;
    project-memory)
      if [[ "$value" == "on" || "$value" == "off" ]]; then
        config_set "loadProjectMemory" "$( [[ "$value" == "on" ]] && echo true || echo false )"
        log_success "loadProjectMemory $value" "config"
      else log_error "invalid value: $value (use on/off)" "config"; return 1; fi ;;
    ghAccounts)
      if ! printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1; then
        log_error "ghAccounts must be a JSON object mapping owner-org -> gh login, e.g. '{\"acme\":\"my-gh-login\"}'" "config"; return 1
      fi
      config_set "ghAccounts" "$value" && log_success "ghAccounts set (per-repo gh login map for mra prd-issues)" "config" ;;
    review.providerMode)
      case "$value" in
        claude|codex|fallback|dual)
          config_set_string "$key" "$value"
          log_success "$key set to: $value" "config" ;;
        *) log_error "$key must be one of: claude, codex, fallback, dual" "config"; return 1 ;;
      esac ;;
    review.primaryProvider|review.secondaryProvider)
      case "$value" in
        claude|codex)
          config_set_string "$key" "$value"
          log_success "$key set to: $value" "config" ;;
        *) log_error "$key must be one of: claude, codex" "config"; return 1 ;;
      esac ;;
    review.allowUserOverride|review.context.loadAgentsMd|review.context.loadLegacyClaudeMd|review.context.loadClaudeRules|review.context.loadClaudeSettingsLocal)
      config_set_bool_word "$key" "$value" && log_success "$key set to: $value" "config" ;;
    review.dualMergePolicy)
      case "$value" in
        union|primary|intersection)
          config_set_string "$key" "$value"
          log_success "$key set to: $value" "config" ;;
        *) log_error "review.dualMergePolicy must be one of: union, primary, intersection" "config"; return 1 ;;
      esac ;;
    review.models.claude|review.models.codex)
      config_set_string "$key" "$value"
      log_success "$key set to: $value" "config" ;;
    review.context.loadClaudeSkills)
      case "$value" in
        summary|full|off|false|none)
          config_set_string "$key" "$value"
          log_success "$key set to: $value" "config" ;;
        *) log_error "review.context.loadClaudeSkills must be one of: summary, full, off" "config"; return 1 ;;
      esac ;;
    *) log_error "unknown config key: $key" "config"; return 1 ;;
  esac
}
