#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/template.sh"
errors=0
TEST_DIR=$(mktemp -d)
generate_template "$TEST_DIR" "all" 2>/dev/null
if [[ ! -f "$TEST_DIR/.collab/repos.json.template" ]]; then echo "FAIL: repos template not created"; ((errors++)); fi
if [[ ! -f "$TEST_DIR/.collab/db.json.template" ]]; then echo "FAIL: db template not created"; ((errors++)); fi
if [[ ! -f "$TEST_DIR/.collab/manual-deps.json.template" ]]; then echo "FAIL: deps template not created"; ((errors++)); fi
# Verify templates are valid JSON
jq '.' "$TEST_DIR/.collab/repos.json.template" > /dev/null 2>&1 || { echo "FAIL: repos template invalid JSON"; ((errors++)); }
jq '.' "$TEST_DIR/.collab/db.json.template" > /dev/null 2>&1 || { echo "FAIL: db template invalid JSON"; ((errors++)); }
jq '.' "$TEST_DIR/.collab/manual-deps.json.template" > /dev/null 2>&1 || { echo "FAIL: deps template invalid JSON"; ((errors++)); }
rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all template tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
