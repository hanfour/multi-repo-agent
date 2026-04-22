#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/personas.sh"
source "$SCRIPT_DIR/lib/plan-council.sh"

errors=0

output=$(default_plan_personas)
for p in security-auditor api-contract-guardian performance-hawk; do
  if [[ "$output" != *"$p"* ]]; then
    echo "FAIL: default plan personas missing $p"; ((errors++))
  fi
done

prompt=$(build_plan_prompt "refactoring-sage" "Migrate auth to JWT" "" "")
if [[ "$prompt" != *"ROLE: Refactoring Sage"* ]]; then
  echo "FAIL: plan prompt missing ROLE"; ((errors++))
fi
if [[ "$prompt" != *"Migrate auth to JWT"* ]]; then
  echo "FAIL: plan prompt missing task"; ((errors++))
fi
if [[ "$prompt" != *"independent"* ]]; then
  echo "FAIL: plan prompt missing independence instruction"; ((errors++))
fi

# Unknown persona should fail
if build_plan_prompt "bogus-xyz" "task" 2>/dev/null; then
  echo "FAIL: build_plan_prompt should reject unknown persona"; ((errors++))
fi

# PKB context should be injected
prompt_pkb=$(build_plan_prompt "security-auditor" "migrate auth" "SENTINEL_PKB")
if [[ "$prompt_pkb" != *"SENTINEL_PKB"* ]]; then
  echo "FAIL: plan prompt missing PKB context"; ((errors++))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all plan-council tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
