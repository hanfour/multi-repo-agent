#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
errors=0
TEST_CONFIG=$(mktemp)
cat > "$TEST_CONFIG" <<'EOF'
{
  "autoScan": true,
  "depthDefault": 1,
  "aliases": {},
  "subAgentWorkflow": {
    "reviewLoopMax": 3,
    "autoCommit": true,
    "autoPR": true
  }
}
EOF
result=$(config_get "autoScan" "$TEST_CONFIG")
if [[ "$result" != "true" ]]; then echo "FAIL: autoScan should be true, got $result"; errors=$((errors+1)); fi
result=$(config_get "depthDefault" "$TEST_CONFIG")
if [[ "$result" != "1" ]]; then echo "FAIL: depthDefault should be 1, got $result"; errors=$((errors+1)); fi
config_set "autoScan" "false" "$TEST_CONFIG"
result=$(config_get "autoScan" "$TEST_CONFIG")
if [[ "$result" != "false" ]]; then echo "FAIL: autoScan should be false after set, got $result"; errors=$((errors+1)); fi
result=$(config_get_alias "nonexistent" "$TEST_CONFIG")
if [[ "$result" != "null" ]]; then echo "FAIL: nonexistent alias should return null, got $result"; errors=$((errors+1)); fi

# config_set_string stores arbitrary strings safely (quotes included) —
# string values must never be spliced into a JSON literal.
config_set_string "outputLanguage" 'zh-TW "quoted" value' "$TEST_CONFIG"
result=$(config_get "outputLanguage" "$TEST_CONFIG")
if [[ "$result" != 'zh-TW "quoted" value' ]]; then echo "FAIL: config_set_string mangled value, got $result"; errors=$((errors+1)); fi

# config_handle output-language goes through the safe string path
if ! MRA_CONFIG="$TEST_CONFIG" config_handle "output-language" 'ja "テスト"' >/dev/null 2>&1; then
  echo "FAIL: config_handle output-language should accept quoted value"; errors=$((errors+1))
fi
result=$(config_get "outputLanguage" "$TEST_CONFIG")
if [[ "$result" != 'ja "テスト"' ]]; then echo "FAIL: output-language with quotes mangled, got $result"; errors=$((errors+1)); fi

# config_set cleans up its temp file when jq rejects the value
tmp_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
config_set "autoScan" 'not-json' "$TEST_CONFIG" 2>/dev/null || true
tmp_after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$tmp_after" -gt "$tmp_before" ]]; then echo "FAIL: config_set leaked a temp file on jq failure"; errors=$((errors+1)); fi

# config_handle ghAccounts accepts a JSON object (the per-repo gh-login map mra prd-issues reads)
if ! MRA_CONFIG="$TEST_CONFIG" config_handle "ghAccounts" '{"onead":"HanfourHuangOneAD"}' >/dev/null 2>&1; then
  echo "FAIL: config_handle ghAccounts should accept a JSON object"; errors=$((errors+1))
fi
result=$(config_get "ghAccounts" "$TEST_CONFIG" | jq -r '.onead')
if [[ "$result" != "HanfourHuangOneAD" ]]; then echo "FAIL: ghAccounts.onead should be HanfourHuangOneAD, got $result"; errors=$((errors+1)); fi
# a non-object value is rejected (not silently stored)
if MRA_CONFIG="$TEST_CONFIG" config_handle "ghAccounts" 'not-an-object' >/dev/null 2>&1; then
  echo "FAIL: config_handle ghAccounts should reject a non-object value"; errors=$((errors+1))
fi

rm -f "$TEST_CONFIG"
if [[ $errors -eq 0 ]]; then echo "PASS: all config tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
