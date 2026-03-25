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
if [[ "$result" != "true" ]]; then echo "FAIL: autoScan should be true, got $result"; ((errors++)); fi
result=$(config_get "depthDefault" "$TEST_CONFIG")
if [[ "$result" != "1" ]]; then echo "FAIL: depthDefault should be 1, got $result"; ((errors++)); fi
config_set "autoScan" "false" "$TEST_CONFIG"
result=$(config_get "autoScan" "$TEST_CONFIG")
if [[ "$result" != "false" ]]; then echo "FAIL: autoScan should be false after set, got $result"; ((errors++)); fi
result=$(config_get_alias "onead" "$TEST_CONFIG")
if [[ "$result" != "null" ]]; then echo "FAIL: nonexistent alias should return null, got $result"; ((errors++)); fi
rm -f "$TEST_CONFIG"
if [[ $errors -eq 0 ]]; then echo "PASS: all config tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
