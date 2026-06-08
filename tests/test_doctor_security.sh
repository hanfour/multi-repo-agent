#!/usr/bin/env bash
# Verify the doctor security audit reports the conditions listed in the
# threat-model "Detection ideas" column (TM-002, TM-004, TM-005, TM-008,
# TM-010).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/doctor.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/.collab/contracts"
trap 'rm -rf "$WS"' EXIT

# --- Baseline: empty workspace, no security flags raised ---
unset MRA_MCP_OPEN_MODE || true
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if ! echo "$out" | grep -qi "warn\|error" ; then
  pass_test "baseline doctor_security has no warnings"
else
  fail_test "baseline reported warnings unexpectedly: $out"
fi

# --- TM-002: MCP open mode flagged ---
out=$(MRA_MCP_OPEN_MODE=1 doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qi "open mode\|open_mode\|MRA_MCP_OPEN_MODE"; then
  pass_test "TM-002 open mode reported"
else
  fail_test "expected open-mode warning, got: $out"
fi

# --- TM-008: remote federation subscription flagged ---
cat > "$WS/.collab/contracts/subscriptions.json" <<'JSON'
[{"url":"https://example.com/contract.json","subscribedAt":"now","lastFetched":null}]
JSON
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qi "subscription\|federation"; then
  pass_test "TM-008 remote subscription reported"
else
  fail_test "expected remote subscription notice, got: $out"
fi

# --- TM-008: remote notify webhook flagged ---
cat > "$WS/.collab/notify.json" <<'JSON'
{"webhooks":[{"name":"x","type":"slack","url":"https://hooks.slack.com/services/X/Y/Z","enabled":true,"minLevel":"warn"}]}
JSON
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qi "webhook\|notify"; then
  pass_test "TM-008 remote webhook reported"
else
  fail_test "expected webhook notice, got: $out"
fi

# --- TM-004: remote DB dump source flagged ---
cat > "$WS/.collab/db.json" <<'JSON'
{"databases":{"mysql":{"engine":"mysql","schemas":{"app":{"source":"https://dumps.example.com/app.sql.gz","usedBy":["app"]}}}}}
JSON
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qi "dump\|remote db\|db.json"; then
  pass_test "TM-004 remote dump source reported"
else
  fail_test "expected dump notice, got: $out"
fi

# --- TM-005: trusted Docker projects listed ---
cat > "$WS/.collab/trusted-projects.json" <<'JSON'
{"trusted":["alpha","beta"]}
JSON
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qE "alpha.*beta|trusted.*project"; then
  pass_test "TM-005 trusted projects reported"
else
  fail_test "expected trusted-projects info, got: $out"
fi

# --- TM-010: world-writable MRA_DIR flagged ---
fake_mra=$(mktemp -d)
chmod 777 "$fake_mra"
out=$(MRA_DIR="$fake_mra" doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qi "world-writable\|writable"; then
  pass_test "TM-010 world-writable MRA_DIR reported"
else
  fail_test "expected world-writable warning, got: $out"
fi
rm -rf "$fake_mra"

# --- doctor_security returns "pass fail warn" counts on stdout ---
counts=$(doctor_security "$WS" 2>/dev/null)
if [[ "$counts" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
  pass_test "doctor_security emits 'pass fail warn' to stdout"
else
  fail_test "expected three numbers on stdout, got: '$counts'"
fi

# --- doctor_security surfaces recent security events from JSONL log ---
mkdir -p "$WS/.collab/logs"
{
  printf '{"ts":"%s","category":"url-policy","action":"reject","reason":"loopback_host"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","category":"url-policy","action":"reject","reason":"http_not_allowed"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","category":"trust","action":"grant","project":"alpha"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$WS/.collab/logs/security.log"
out=$(doctor_security "$WS" 2>&1 1>/dev/null)
if echo "$out" | grep -qE "url-policy/reject: 2" && echo "$out" | grep -qE "trust/grant: 1"; then
  pass_test "doctor_security summarises recent JSONL events by category/action"
else
  fail_test "expected summary lines, got: $out"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
