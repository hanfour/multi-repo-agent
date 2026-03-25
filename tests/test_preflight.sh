#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
errors=0
if ! check_tool "git" "version control"; then
  echo "FAIL: git should be found"; ((errors++))
fi
if check_tool "nonexistent_tool_xyz" "fake tool" 2>/dev/null; then
  echo "FAIL: nonexistent tool should not be found"; ((errors++))
fi
if type run_preflight &>/dev/null; then
  echo "PASS: run_preflight function exists"
else
  echo "FAIL: run_preflight not defined"; ((errors++))
fi
if [[ $errors -eq 0 ]]; then
  echo "PASS: all preflight tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
