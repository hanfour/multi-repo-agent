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
  jq --argjson val "$value" ".$key = \$val" "$config_file" > "$tmp" && mv "$tmp" "$config_file"
}
config_get_alias() {
  local name="$1" config_file="${2:-$MRA_CONFIG}"
  jq -r ".aliases.\"$name\" // \"null\"" "$config_file"
}
config_set_alias() {
  local name="$1" workspace="$2" git_org="$3" config_file="${4:-$MRA_CONFIG}"
  local tmp; tmp=$(mktemp)
  jq ".aliases.\"$name\" = {\"workspace\": \"$workspace\", \"gitOrg\": \"$git_org\"}" \
    "$config_file" > "$tmp" && mv "$tmp" "$config_file"
}
config_handle() {
  local key="$1" value="$2"
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
    *) log_error "unknown config key: $key" "config"; return 1 ;;
  esac
}
