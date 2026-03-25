#!/usr/bin/env bash
# Alias management for mra

handle_alias() {
  local name="$1" workspace="$2" git_org="${3:-}"

  if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    log_error "invalid alias name: '$name' (use alphanumeric, underscore, hyphen)" "alias"
    return 1
  fi

  # Resolve workspace to absolute path
  if [[ -d "$workspace" ]]; then
    workspace=$(cd "$workspace" && pwd)
  else
    log_error "workspace directory not found: $workspace" "alias"
    return 1
  fi

  # Check workspace is initialized
  if [[ ! -f "$workspace/.collab/dep-graph.json" ]]; then
    log_error "workspace not initialized (run: mra init $workspace --git-org <url>)" "alias"
    return 1
  fi

  # Get git-org from existing dep-graph if not provided
  if [[ -z "$git_org" ]]; then
    git_org=$(jq -r '.gitOrg' "$workspace/.collab/dep-graph.json")
  fi

  config_set_alias "$name" "$workspace" "$git_org"

  # Write shell function to .zshrc so alias is callable from terminal
  local shell_rc="$HOME/.zshrc"
  [[ ! -f "$shell_rc" ]] && shell_rc="$HOME/.bashrc"

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Remove old alias if exists
  if grep -q "# mra-alias:$name start" "$shell_rc" 2>/dev/null; then
    sed -i.bak "/# mra-alias:$name start/,/# mra-alias:$name end/d" "$shell_rc"
    rm -f "${shell_rc}.bak"
  fi

  cat >> "$shell_rc" <<SHELL
# mra-alias:$name start
$name() {
  MRA_WORKSPACE="$workspace" "$mra_dir/bin/mra.sh" "\$@"
}
# mra-alias:$name end
SHELL

  log_success "alias '$name' -> $workspace (added to $shell_rc)" "alias"
  log_info "run: source $shell_rc" "alias"
}
