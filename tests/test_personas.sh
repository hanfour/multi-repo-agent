#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/personas.sh"

errors=0

output=$(list_personas)
if [[ "$output" != *"security-auditor"* ]]; then
  echo "FAIL: list_personas missing security-auditor"; ((errors++))
fi

output=$(load_persona "security-auditor")
if [[ -z "$output" ]]; then
  echo "FAIL: load_persona returned empty"; ((errors++))
fi

if load_persona "nonexistent-persona" 2>/dev/null; then
  echo "FAIL: load_persona should fail on unknown name"; ((errors++))
fi

output=$(load_persona "security-auditor")
if [[ "$output" != *"ROLE:"* ]]; then
  echo "FAIL: persona missing ROLE: header"; ((errors++))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all persona tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
