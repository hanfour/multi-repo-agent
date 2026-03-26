#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/workflow.sh"
source "$SCRIPT_DIR/lib/notify.sh"

errors=0
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.collab/logs"

# Test _level_passes
if ! _level_passes "error" "warn"; then echo "FAIL: error should pass warn filter"; ((errors++)); fi
if ! _level_passes "warn" "warn"; then echo "FAIL: warn should pass warn filter"; ((errors++)); fi
if _level_passes "info" "warn"; then echo "FAIL: info should NOT pass warn filter"; ((errors++)); fi
if ! _level_passes "critical" "info"; then echo "FAIL: critical should pass info filter"; ((errors++)); fi

# Test setup_notifications creates template
setup_notifications "$TEST_DIR" 2>/dev/null
notify_config="$TEST_DIR/.collab/notify.json"
if [[ ! -f "$notify_config" ]]; then echo "FAIL: notify.json not created"; ((errors++)); fi

# Test template is valid JSON with webhooks array
webhook_count=$(jq '.webhooks | length' "$notify_config" 2>/dev/null)
if [[ "$webhook_count" != "2" ]]; then echo "FAIL: should have 2 webhooks, got $webhook_count"; ((errors++)); fi

# Test notify with no enabled webhooks (should succeed silently)
notify "$TEST_DIR" "test-event" "test message" "info" 2>/dev/null
# Should not error

# Test convenience functions exist
if ! type notify_test_failed &>/dev/null; then echo "FAIL: notify_test_failed not defined"; ((errors++)); fi
if ! type notify_scan_complete &>/dev/null; then echo "FAIL: notify_scan_complete not defined"; ((errors++)); fi
if ! type notify_escalation &>/dev/null; then echo "FAIL: notify_escalation not defined"; ((errors++)); fi

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all notify tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
