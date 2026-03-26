#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/cost.sh"
errors=0
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.collab"
# Test record and read
record_usage "$TEST_DIR" 100 50 0.005 "mra ask erp test"
usage_file=$(get_usage_file "$TEST_DIR")
if [[ ! -f "$usage_file" ]]; then echo "FAIL: usage file not created"; ((errors++)); fi
total=$(jq '.totalCost' "$usage_file")
if [[ "$total" != "0.005" ]]; then echo "FAIL: total cost should be 0.005, got $total"; ((errors++)); fi
sessions=$(jq '.sessions' "$usage_file")
if [[ "$sessions" != "1" ]]; then echo "FAIL: sessions should be 1, got $sessions"; ((errors++)); fi
# Test second record
record_usage "$TEST_DIR" 200 100 0.01 "mra ask masa test"
total=$(jq '.totalCost' "$usage_file")
if [[ "$total" != "0.015" ]]; then echo "FAIL: total cost should be 0.015, got $total"; ((errors++)); fi
# Test reset
reset_cost "$TEST_DIR" 2>/dev/null
total=$(jq '.totalCost' "$usage_file")
if [[ "$total" != "0" ]]; then echo "FAIL: total should be 0 after reset, got $total"; ((errors++)); fi
rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all cost tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
