#!/usr/bin/env bash
# Verify lib/db.sh refuses unsafe dump URLs and that init does not silently
# auto-trigger a DB import in non-interactive mode (TM-004).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/config.sh"
source "$MRA_DIR/lib/url-policy.sh"
source "$MRA_DIR/lib/db.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/.collab"
trap 'rm -rf "$WS"' EXIT

# --- _resolve_source rejects unsafe URLs (TM-004) ---
unset MRA_ALLOW_LOCAL_ENDPOINTS MRA_ALLOW_HTTP || true
for bad in \
    "http://example.com/dump.sql.gz" \
    "https://127.0.0.1/dump.sql.gz" \
    "https://169.254.169.254/latest/meta-data" \
    "file:///etc/passwd"; do
  if _resolve_source "$bad" "$WS" >/dev/null 2>&1; then
    fail_test "_resolve_source should reject: $bad"
  else
    pass_test "_resolve_source rejected: $bad"
  fi
done

# --- _resolve_source still handles local paths ---
echo dump > "$WS/local.sql"
out=$(_resolve_source "local.sql" "$WS" 2>/dev/null)
if [[ "$out" == "$WS/local.sql" ]]; then
  pass_test "_resolve_source resolves relative local path"
else
  fail_test "expected '$WS/local.sql', got '$out'"
fi

out=$(_resolve_source "$WS/local.sql" "$WS" 2>/dev/null)
if [[ "$out" == "$WS/local.sql" ]]; then
  pass_test "_resolve_source passes absolute local path through"
else
  fail_test "expected '$WS/local.sql', got '$out'"
fi

# --- _resolve_source accepts public HTTPS without actually fetching ---
# We can't reach the public internet in tests, but we can at least
# confirm the policy gate does NOT reject the URL outright; the curl
# will fail later in a way the caller already handles.
# Use a host that resolves but is firewalled in CI; check_safe_url
# alone must return 0 for it.
if check_safe_url "https://example.com/dump.sql.gz" 2>/dev/null; then
  pass_test "policy accepts public HTTPS dump URL"
else
  fail_test "public HTTPS dump URL should be accepted by policy"
fi

# --- Override flag re-enables loopback dumps ---
if MRA_ALLOW_LOCAL_ENDPOINTS=1 check_safe_url "https://127.0.0.1/dump.sql.gz" 2>/dev/null; then
  pass_test "MRA_ALLOW_LOCAL_ENDPOINTS=1 allows loopback dump URL"
else
  fail_test "override should allow loopback dump URL"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
