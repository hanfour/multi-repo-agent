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

# With no env var set, convention-auditor must NOT be included, and the
# default set must be exactly the original 5 names.
for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect; do
  if [[ "$output" != *"$p"* ]]; then
    echo "FAIL: default set missing $p"; errors=$((errors+1))
  fi
done
if [[ "$output" == *"convention-auditor"* ]]; then
  echo "FAIL: default set should not include convention-auditor when MRA_REVIEW_ENABLE_CONVENTION_AUDITOR is unset"; errors=$((errors+1))
fi
if [[ "$(echo "$output" | wc -w | tr -d ' ')" != "5" ]]; then
  echo "FAIL: default set should have exactly 5 personas by default, got: $output"; errors=$((errors+1))
fi

# With MRA_REVIEW_ENABLE_CONVENTION_AUDITOR=1, convention-auditor must be
# included, growing the default set to 6.
output_with_auditor=$(MRA_REVIEW_ENABLE_CONVENTION_AUDITOR=1 default_review_personas)
if [[ "$output_with_auditor" != *"convention-auditor"* ]]; then
  echo "FAIL: default set should include convention-auditor when MRA_REVIEW_ENABLE_CONVENTION_AUDITOR=1"; errors=$((errors+1))
fi
if [[ "$(echo "$output_with_auditor" | wc -w | tr -d ' ')" != "6" ]]; then
  echo "FAIL: default set should have exactly 6 personas when convention-auditor is enabled, got: $output_with_auditor"; errors=$((errors+1))
fi

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

# Coverage checklist must NOT appear in prompt when the env var is unset —
# default behavior must match the pre-branch template exactly.
prompt_no_coverage=$(build_persona_prompt "security-auditor" "d" "x.js
y.js")
if [[ "$prompt_no_coverage" == *"account for every file in the Changed Files list"* ]]; then
  echo "FAIL: prompt should not include coverage checklist requirement by default"; errors=$((errors+1))
fi

# Coverage checklist should appear in prompt when explicitly enabled
prompt_coverage=$(MRA_REVIEW_ENABLE_COVERAGE_CHECKLIST=1 build_persona_prompt "security-auditor" "d" "x.js
y.js")
if [[ "$prompt_coverage" != *"account for every file in the Changed Files list"* ]]; then
  echo "FAIL: prompt missing coverage checklist requirement when MRA_REVIEW_ENABLE_COVERAGE_CHECKLIST=1"; errors=$((errors+1))
fi

# run_persona_review must log the REAL exit code of a failed persona call.
# Regression coverage for the `if ! wait "$pid"; then rc=$?` bug: negating
# wait's result before capturing $? always yielded 0/1 (never the actual
# exit code), so every "failed (rc=...)" log line read rc=0 regardless of
# the real failure. Stub review_call_model to fail with a distinctive code
# and assert the logged rc matches it.
review_call_model() { return 42; }
persona_err=$(mktemp)
run_persona_review "proj" "/tmp" "d" "x.js" "security-auditor" "" "" "" "" "" claude >/dev/null 2>"$persona_err"
if ! grep -q "rc=42" "$persona_err"; then
  echo "FAIL: expected failed persona log to report the real rc (42), got: $(cat "$persona_err")"; errors=$((errors+1))
fi
if grep -q "rc=0" "$persona_err"; then
  echo "FAIL: failed persona log incorrectly reports rc=0"; errors=$((errors+1))
fi
rm -f "$persona_err"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all review-personas tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
