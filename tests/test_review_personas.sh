#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/personas.sh"
source "$SCRIPT_DIR/lib/review-personas.sh"

errors=0

output=$(default_review_personas)
if [[ -z "$output" ]]; then
  echo "FAIL: default_review_personas empty"; errors=$((errors+1))
fi

for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect; do
  if [[ "$output" != *"$p"* ]]; then
    echo "FAIL: default set missing $p"; errors=$((errors+1))
  fi
done

prompt=$(build_persona_prompt "security-auditor" "diff --git a/x b/x" "x.js")
if [[ "$prompt" != *"ROLE: Security Auditor"* ]]; then
  echo "FAIL: prompt missing ROLE"; errors=$((errors+1))
fi
if [[ "$prompt" != *"diff --git a/x b/x"* ]]; then
  echo "FAIL: prompt missing diff"; errors=$((errors+1))
fi

# build_persona_prompt should fail on unknown persona
if build_persona_prompt "bogus-persona-xyz" "d" "c" 2>/dev/null; then
  echo "FAIL: build_persona_prompt should return non-zero on unknown persona"; errors=$((errors+1))
fi

# PKB context should be injected when provided
prompt_pkb=$(build_persona_prompt "security-auditor" "d" "c" "" "SENTINEL_PKB_LINE")
if [[ "$prompt_pkb" != *"SENTINEL_PKB_LINE"* ]]; then
  echo "FAIL: prompt missing PKB context"; errors=$((errors+1))
fi

# Consumer section should appear when consumers provided
prompt_cons=$(build_persona_prompt "security-auditor" "d" "c" "consumer-a consumer-b")
if [[ "$prompt_cons" != *"Consumer projects: consumer-a consumer-b"* ]]; then
  echo "FAIL: prompt missing consumer section"; errors=$((errors+1))
fi

# Language directive should appear when provided
prompt_lang=$(build_persona_prompt "security-auditor" "d" "c" "" "" "Use 繁體中文 for output.")
if [[ "$prompt_lang" != *"Use 繁體中文 for output."* ]]; then
  echo "FAIL: prompt missing language directive"; errors=$((errors+1))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all review-personas tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
