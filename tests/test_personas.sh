#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/personas.sh"

errors=0

output=$(list_personas)
if [[ "$output" != *"security-auditor"* ]]; then
  echo "FAIL: list_personas missing security-auditor"; errors=$((errors+1))
fi

if load_persona "nonexistent-persona" 2>/dev/null; then
  echo "FAIL: load_persona should fail on unknown name"; errors=$((errors+1))
fi

for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect; do
  body=$(load_persona "$p" 2>/dev/null || echo "")
  if [[ -z "$body" ]]; then
    echo "FAIL: persona $p did not load"; errors=$((errors+1))
    continue
  fi
  if [[ "$body" != *"ROLE:"* ]]; then
    echo "FAIL: persona $p missing ROLE: header"; errors=$((errors+1))
  fi
done

if [[ $errors -eq 0 ]]; then
  echo "PASS: all persona tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
