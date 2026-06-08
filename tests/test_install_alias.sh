#!/usr/bin/env bash
# Verify install.sh and lib/alias.sh quote paths safely and keep RC backups.
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/config.sh"

# Stub config_set_alias so handle_alias has somewhere to write.
config_set_alias() { :; }

# shellcheck source=../lib/alias.sh
source "$MRA_DIR/lib/alias.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

# Sandbox HOME so handle_alias writes into a temp .zshrc, not the real one.
SANDBOX_HOME=$(mktemp -d)
trap 'rm -rf "$SANDBOX_HOME" "$WS_WITH_SPACE"' EXIT
ORIGINAL_HOME="$HOME"
export HOME="$SANDBOX_HOME"
touch "$HOME/.zshrc"
echo "# pre-existing line" > "$HOME/.zshrc"

# Workspace path that contains a space — would corrupt the RC line if not
# properly shell-quoted at injection time.
WS_WITH_SPACE=$(mktemp -d "${TMPDIR:-/tmp}/mra space.XXXXXX")
mkdir -p "$WS_WITH_SPACE/.collab"
cat > "$WS_WITH_SPACE/.collab/dep-graph.json" <<'JSON'
{"version":1,"workspace":"smoke","gitOrg":"https://github.com/x","lastScan":"2026-01-01T00:00:00Z","projects":{}}
JSON

# --- Run handle_alias against the spaced workspace ---
if handle_alias "smokealias" "$WS_WITH_SPACE" >/dev/null 2>&1; then
  pass_test "handle_alias succeeded with spaced workspace path"
else
  fail_test "handle_alias should succeed with spaced workspace path"
fi

# --- Assert RC backup with mra-bak prefix exists ---
backup_count=$(find "$HOME" -maxdepth 1 -name '.zshrc.mra-bak-*' | wc -l | tr -d ' ')
if [[ "$backup_count" -ge 1 ]]; then
  pass_test "RC backup file created"
else
  fail_test "expected at least one .zshrc.mra-bak-* backup file, found $backup_count"
fi

# --- Assert RC is syntactically valid bash ---
if bash -n "$HOME/.zshrc" 2>/dev/null; then
  pass_test "generated .zshrc is syntactically valid"
else
  fail_test "generated .zshrc has syntax errors:"
  bash -n "$HOME/.zshrc" 2>&1 | sed 's/^/  /'
fi

# --- Assert the function can be sourced and resolves the spaced path ---
# We do not invoke mra.sh, only check that the function definition itself parses
# and that the embedded path is recoverable.
if bash -c "source '$HOME/.zshrc'; type -t smokealias" 2>/dev/null | grep -q function; then
  pass_test "alias function loads cleanly from RC"
else
  fail_test "alias function failed to load from generated RC"
fi

# --- Re-run to confirm idempotent update keeps creating new backups ---
if handle_alias "smokealias" "$WS_WITH_SPACE" >/dev/null 2>&1; then
  pass_test "handle_alias re-run succeeded (update existing)"
else
  fail_test "handle_alias re-run should succeed"
fi

backup_count_after=$(find "$HOME" -maxdepth 1 -name '.zshrc.mra-bak-*' | wc -l | tr -d ' ')
if [[ "$backup_count_after" -ge "$backup_count" ]]; then
  pass_test "re-run preserved or added backup files"
else
  fail_test "re-run lost backup files ($backup_count_after < $backup_count)"
fi

# --- Confirm the RC only has ONE alias block after re-run ---
block_count=$(grep -c "^# mra-alias:smokealias start$" "$HOME/.zshrc" || true)
if [[ "$block_count" -eq 1 ]]; then
  pass_test "re-run replaced old alias block instead of duplicating"
else
  fail_test "expected exactly 1 alias block after re-run, got $block_count"
fi

# --- Workspace with shell metacharacters: must NOT trigger expansion on source ---
# A path with `$` would be evaluated by bash if the generated RC line just
# wraps it in double quotes. printf '%q' produces a properly-escaped token
# that survives sourcing.
WS_WITH_DOLLAR="$SANDBOX_HOME/with\$dollar"
mkdir -p "$WS_WITH_DOLLAR/.collab"
cat > "$WS_WITH_DOLLAR/.collab/dep-graph.json" <<'JSON'
{"version":1,"workspace":"smoke","gitOrg":"https://github.com/x","lastScan":"2026-01-01T00:00:00Z","projects":{}}
JSON

if handle_alias "dollaralias" "$WS_WITH_DOLLAR" >/dev/null 2>&1; then
  pass_test "handle_alias accepted workspace path with \$"
else
  fail_test "handle_alias should accept path with \$"
fi

# Sourcing the RC and printing the MRA_WORKSPACE captured by the alias closure
# should yield the literal path, not an expansion of \$dollar.
# Behavioural assertion: source the RC then invoke the alias with a stubbed
# mra.sh that prints the MRA_WORKSPACE it received. If $dollar were expanded
# at source time, the captured value would lose "$dollar" and contain
# something like "/.../with" or empty.
stub_dir=$(mktemp -d)
mkdir -p "$stub_dir/bin"
cat > "$stub_dir/bin/mra.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$MRA_WORKSPACE"
STUB
chmod +x "$stub_dir/bin/mra.sh"

# Rewrite the alias RC line to use the stub instead of the real mra.sh, so
# we can invoke the function and observe MRA_WORKSPACE without side effects.
python3 - "$HOME/.zshrc" "$stub_dir" <<'PY'
import re, sys
rc_path, stub = sys.argv[1], sys.argv[2]
rc = open(rc_path).read()
rc = re.sub(r'(?m)^(\s*MRA_WORKSPACE=\S+ )\S+/bin/mra\.sh', rf'\1{stub}/bin/mra.sh', rc)
open(rc_path, 'w').write(rc)
PY

captured=$(bash -c "source '$HOME/.zshrc'; dollaralias")
if [[ "$captured" == "$WS_WITH_DOLLAR" ]]; then
  pass_test "alias captures literal \$ in workspace path (no expansion)"
else
  fail_test "expected MRA_WORKSPACE='$WS_WITH_DOLLAR', got '$captured'"
fi
rm -rf "$stub_dir"

export HOME="$ORIGINAL_HOME"

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
