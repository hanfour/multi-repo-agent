#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/personas.sh"
source "$SCRIPT_DIR/lib/review-personas.sh"

errors=0

output=$(default_review_personas)
if [[ -z "$output" ]]; then
  echo "FAIL: default_review_personas empty"; ((errors++))
fi

for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect; do
  if [[ "$output" != *"$p"* ]]; then
    echo "FAIL: default set missing $p"; ((errors++))
  fi
done

prompt=$(build_persona_prompt "security-auditor" "diff --git a/x b/x" "x.js")
if [[ "$prompt" != *"ROLE: Security Auditor"* ]]; then
  echo "FAIL: prompt missing ROLE"; ((errors++))
fi
if [[ "$prompt" != *"diff --git a/x b/x"* ]]; then
  echo "FAIL: prompt missing diff"; ((errors++))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all review-personas tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
