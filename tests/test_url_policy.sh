#!/usr/bin/env bash
# Verify lib/url-policy.sh blocks SSRF-prone destinations (TM-008).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/url-policy.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

# --- HTTPS-only by default ---
unset MRA_ALLOW_LOCAL_ENDPOINTS MRA_ALLOW_HTTP || true
for bad in \
    "http://example.com/contract.json" \
    "file:///etc/passwd" \
    "javascript:alert(1)" \
    "data:text/plain,abc" \
    "ftp://example.com/x" \
    "" \
    "not-a-url"; do
  if check_safe_url "$bad" 2>/dev/null; then
    fail_test "should reject: $bad"
  else
    pass_test "rejected: $bad"
  fi
done

# --- Private / loopback / link-local literals rejected ---
for bad in \
    "https://127.0.0.1/x" \
    "https://localhost/x" \
    "https://10.0.0.5/x" \
    "https://192.168.1.1/x" \
    "https://172.16.0.1/x" \
    "https://172.31.255.255/x" \
    "https://169.254.169.254/latest/meta-data" \
    "https://[::1]/x" \
    "https://0.0.0.0/x"; do
  if check_safe_url "$bad" 2>/dev/null; then
    fail_test "should reject private/loopback: $bad"
  else
    pass_test "rejected: $bad"
  fi
done

# --- Public HTTPS destinations allowed ---
for good in \
    "https://hooks.slack.com/services/T/B/X" \
    "https://discord.com/api/webhooks/X/Y" \
    "https://example.com/contract.json" \
    "https://172.32.0.1/x"; do
  if check_safe_url "$good" 2>/dev/null; then
    pass_test "accepted: $good"
  else
    fail_test "should accept public HTTPS: $good"
  fi
done

# --- Override flag re-enables local endpoints ---
if MRA_ALLOW_LOCAL_ENDPOINTS=1 check_safe_url "https://127.0.0.1/x" 2>/dev/null; then
  pass_test "MRA_ALLOW_LOCAL_ENDPOINTS=1 allowed loopback"
else
  fail_test "override should allow loopback"
fi

# --- HTTP override ---
if MRA_ALLOW_HTTP=1 check_safe_url "http://example.com/x" 2>/dev/null; then
  pass_test "MRA_ALLOW_HTTP=1 allowed http://"
else
  fail_test "override should allow http://"
fi
# Both overrides combined for http+local
if MRA_ALLOW_HTTP=1 MRA_ALLOW_LOCAL_ENDPOINTS=1 check_safe_url "http://127.0.0.1/x" 2>/dev/null; then
  pass_test "both overrides allowed http://127.0.0.1"
else
  fail_test "both overrides should allow http://127.0.0.1"
fi

# --- safe_curl_args returns a usable list ---
args=("dummy")
mapfile -t args < <(safe_curl_args)
joined="${args[*]}"
if [[ "$joined" == *"--max-time"* && "$joined" == *"--max-filesize"* ]]; then
  pass_test "safe_curl_args includes --max-time and --max-filesize"
else
  fail_test "safe_curl_args missing limits: $joined"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
