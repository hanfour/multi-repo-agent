#!/usr/bin/env bash
# Verify lib/security-log.sh emits well-formed JSONL events to the right
# destination (workspace log when MRA_WORKSPACE is set, fallback otherwise).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/security-log.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$WS" "$FAKE_HOME"' EXIT
mkdir -p "$WS/.collab"
ORIGINAL_HOME="$HOME"
export HOME="$FAKE_HOME"

# --- Workspace log: MRA_WORKSPACE set → writes to $WS/.collab/logs/security.log ---
MRA_WORKSPACE="$WS" log_security_event "project-path" "reject" \
  "subject=../etc" "reason=traversal"
ws_log="$WS/.collab/logs/security.log"
if [[ -f "$ws_log" ]]; then
  pass_test "workspace log file created"
else
  fail_test "expected $ws_log to exist"
fi

# --- Line should be valid JSON ---
last=$(tail -1 "$ws_log" 2>/dev/null)
if echo "$last" | jq -e . >/dev/null 2>&1; then
  pass_test "log line is valid JSON"
else
  fail_test "log line is not valid JSON: $last"
fi

# --- JSON has expected keys ---
if echo "$last" | jq -e '.ts and .category == "project-path" and .action == "reject" and .subject == "../etc" and .reason == "traversal"' >/dev/null 2>&1; then
  pass_test "log line carries category, action, and KV pairs"
else
  fail_test "log line missing expected fields: $last"
fi

# --- Timestamps look ISO-8601 ---
ts=$(echo "$last" | jq -r '.ts')
if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass_test "timestamp is ISO-8601 UTC"
else
  fail_test "timestamp not ISO-8601 UTC: $ts"
fi

# --- Multiple events accumulate ---
MRA_WORKSPACE="$WS" log_security_event "url-policy" "reject" "url=https://127.0.0.1/x"
MRA_WORKSPACE="$WS" log_security_event "rollback" "grant" "project=alpha" "snapshot=snap1"
line_count=$(wc -l < "$ws_log" | tr -d ' ')
if [[ "$line_count" -eq 3 ]]; then
  pass_test "three events accumulated"
else
  fail_test "expected 3 lines, got $line_count"
fi

# --- Fallback: no MRA_WORKSPACE → writes to $HOME/.mra/security.log ---
unset MRA_WORKSPACE || true
log_security_event "trust" "grant" "project=beta"
fb_log="$HOME/.mra/security.log"
if [[ -f "$fb_log" ]] && jq -e '.category == "trust"' < "$fb_log" >/dev/null 2>&1; then
  pass_test "fallback log written to \$HOME/.mra/security.log"
else
  fail_test "expected fallback log at $fb_log"
fi

# --- Workspace log unaffected by fallback write ---
new_count=$(wc -l < "$ws_log" | tr -d ' ')
if [[ "$new_count" -eq 3 ]]; then
  pass_test "workspace log untouched when MRA_WORKSPACE unset"
else
  fail_test "workspace log changed unexpectedly: $new_count lines"
fi

# --- Values containing spaces / quotes survive the JSON encoding ---
MRA_WORKSPACE="$WS" log_security_event "project-path" "reject" \
  'subject=name with "quote" and space' "reason=traversal & ctrl"
last=$(tail -1 "$ws_log")
got=$(echo "$last" | jq -r '.subject')
if [[ "$got" == 'name with "quote" and space' ]]; then
  pass_test "JSON encoding survives quotes and spaces"
else
  fail_test "expected literal 'name with \"quote\" and space', got '$got'"
fi

# --- Workspace logs dir is created on demand ---
WS2=$(mktemp -d)
trap 'rm -rf "$WS" "$FAKE_HOME" "$WS2"' EXIT
# Note: no mkdir of .collab/logs — helper must create it.
MRA_WORKSPACE="$WS2" log_security_event "trust" "grant" "project=gamma"
if [[ -f "$WS2/.collab/logs/security.log" ]]; then
  pass_test "helper creates logs dir on demand"
else
  fail_test "expected helper to mkdir .collab/logs"
fi

export HOME="$ORIGINAL_HOME"

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
