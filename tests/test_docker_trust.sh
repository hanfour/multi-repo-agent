#!/usr/bin/env bash
# Verify Docker first-time trust gate (TM-005).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/docker-exec.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/.collab" "$WS/alpha"
trap 'rm -rf "$WS"' EXIT

# Sane compose file under the project directory.
cat > "$WS/alpha/docker-compose.yml" <<'YAML'
services:
  alpha:
    image: ruby:3.2
YAML

# Compose file OUTSIDE the project directory — simulates a maliciously
# placed compose file that mounts paths it should not.
cat > "$WS/strange-compose.yml" <<'YAML'
services:
  alpha:
    image: ruby:3.2
YAML

# --- First-time, non-interactive, no FORCE → must refuse ---
unset MRA_DOCKER_TRUST_FORCE || true
if _docker_trust_check "$WS" "alpha" "$WS/alpha/docker-compose.yml" </dev/null 2>/dev/null; then
  fail_test "first-time non-interactive should refuse"
else
  pass_test "first-time non-interactive refused"
fi

# Trust file should NOT have been created.
if [[ ! -f "$WS/.collab/trusted-projects.json" ]]; then
  pass_test "refused trust did not create trust file"
else
  fail_test "trust file leaked on refusal"
fi

# --- MRA_DOCKER_TRUST_FORCE=1 bypasses prompt and records trust ---
if MRA_DOCKER_TRUST_FORCE=1 _docker_trust_check "$WS" "alpha" "$WS/alpha/docker-compose.yml" </dev/null 2>/dev/null; then
  pass_test "MRA_DOCKER_TRUST_FORCE=1 granted trust"
else
  fail_test "FORCE should grant trust"
fi

# Trust file should now exist and contain alpha.
if [[ -f "$WS/.collab/trusted-projects.json" ]] && \
   jq -e '.trusted | index("alpha")' "$WS/.collab/trusted-projects.json" >/dev/null 2>&1; then
  pass_test "trust file records alpha"
else
  fail_test "trust file missing or does not record alpha"
fi

# --- Second call: project is now trusted; no FORCE needed ---
unset MRA_DOCKER_TRUST_FORCE || true
if _docker_trust_check "$WS" "alpha" "$WS/alpha/docker-compose.yml" </dev/null 2>/dev/null; then
  pass_test "already-trusted project passes without prompt"
else
  fail_test "already-trusted project should pass"
fi

# --- Compose file outside project dir: warn but still gate by trust ---
# Even if alpha is already trusted, an out-of-tree compose path is a red
# flag that should at least produce a warning we can detect.
warn_output=$(_docker_trust_check "$WS" "alpha" "$WS/strange-compose.yml" </dev/null 2>&1 || true)
if echo "$warn_output" | grep -qi "compose"; then
  pass_test "out-of-tree compose path produced a warning"
else
  fail_test "expected a warning for out-of-tree compose, got: $warn_output"
fi

# --- Second project still requires trust (alpha trusted, beta not) ---
mkdir -p "$WS/beta"
cat > "$WS/beta/docker-compose.yml" <<'YAML'
services:
  beta:
    image: ruby:3.2
YAML
unset MRA_DOCKER_TRUST_FORCE || true
if _docker_trust_check "$WS" "beta" "$WS/beta/docker-compose.yml" </dev/null 2>/dev/null; then
  fail_test "untrusted project 'beta' should still refuse"
else
  pass_test "untrusted project 'beta' refused while alpha trusted"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
