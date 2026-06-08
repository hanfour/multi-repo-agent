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

# Keep a timestamped backup so the operator can recover if our edits go wrong
# (TM-010). The previous version called `sed -i.bak` and immediately removed
# the `.bak` file, leaving no recovery path.
BACKUP_TS=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${SHELL_RC}.mra-bak-${BACKUP_TS}"
cp "$SHELL_RC" "$BACKUP_FILE"
log_info "backed up $SHELL_RC -> $BACKUP_FILE" "install"

# Check if already installed
if grep -q "# multi-repo-agent" "$SHELL_RC" 2>/dev/null; then
  log_warn "already installed in $SHELL_RC, updating" "install"
  # Remove old installation. The transient `.bak` from sed is unrelated to
  # our recovery backup and is safe to discard.
  sed -i.bak '/# multi-repo-agent start/,/# multi-repo-agent end/d' "$SHELL_RC"
  rm -f "${SHELL_RC}.bak"
fi

# Quote MRA_DIR via printf '%q' before injecting it into the heredoc. Without
# this, a path containing spaces, `$`, backticks, or quotes would either
# break the generated function or, worse, allow shell expansion at source
# time. printf '%q' yields a token that is safe to embed unquoted (TM-010).
MRA_DIR_Q=$(printf '%q' "$MRA_DIR")

# Add mra function to shell config
cat >> "$SHELL_RC" <<SHELL
# multi-repo-agent start
mra() {
  ${MRA_DIR_Q}/bin/mra.sh "\$@"
}
# multi-repo-agent end
SHELL

log_success "mra function added to $SHELL_RC" "install"
log_info "run: source $SHELL_RC" "install"
log_info "then: mra init <workspace-path> --git-org <git-url>" "install"
log_success "installation complete" "install"
