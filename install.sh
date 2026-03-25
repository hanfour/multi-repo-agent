#!/usr/bin/env bash
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$MRA_DIR/lib/colors.sh"

log_progress "installing multi-repo-agent" "install"

# Detect shell config
SHELL_RC=""
if [[ -f "$HOME/.zshrc" ]]; then
  SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
  SHELL_RC="$HOME/.bashrc"
else
  log_error "cannot find .zshrc or .bashrc" "install"
  exit 1
fi

# Check if already installed
if grep -q "# multi-repo-agent" "$SHELL_RC" 2>/dev/null; then
  log_warn "already installed in $SHELL_RC, updating" "install"
  # Remove old installation
  sed -i.bak '/# multi-repo-agent start/,/# multi-repo-agent end/d' "$SHELL_RC"
  rm -f "${SHELL_RC}.bak"
fi

# Add mra function to shell config
cat >> "$SHELL_RC" <<SHELL
# multi-repo-agent start
mra() {
  "$MRA_DIR/bin/mra.sh" "\$@"
}
# multi-repo-agent end
SHELL

log_success "mra function added to $SHELL_RC" "install"
log_info "run: source $SHELL_RC" "install"
log_info "then: mra init <workspace-path> --git-org <git-url>" "install"
log_success "installation complete" "install"
