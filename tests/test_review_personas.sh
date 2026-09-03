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
if run_persona_review "proj" "/tmp" "d" "x.js" "security-auditor" "" "" "" "" "" claude >/dev/null 2>"$persona_err"; then
  persona_rc=0
else
  persona_rc=$?
fi
if [[ "$persona_rc" -eq 0 ]]; then
  echo "FAIL: 失敗的 persona 應回傳非零退出碼"; errors=$((errors+1))
fi
if ! grep -q "rc=42" "$persona_err"; then
  echo "FAIL: expected failed persona log to report the real rc (42), got: $(cat "$persona_err")"; errors=$((errors+1))
fi
if grep -q "rc=0" "$persona_err"; then
  echo "FAIL: failed persona log incorrectly reports rc=0"; errors=$((errors+1))
fi
rm -f "$persona_err"

# 所有 persona 都失敗時，呼叫端必須拿到非零退出碼，才能阻止空的 findings
# 被送去 synthesize，避免沒有完成任何檢查卻產出 APPROVED。
review_call_model() { return 1; }
all_failed_out=$(mktemp)
all_failed_err=$(mktemp)
if run_persona_review "proj" "/tmp" "d" "x.js" \
  "security-auditor performance-hawk" "" "" "" "" "" claude \
  >"$all_failed_out" 2>"$all_failed_err"; then
  all_failed_rc=0
else
  all_failed_rc=$?
fi
if [[ "$all_failed_rc" -eq 0 ]]; then
  echo "FAIL: 所有 persona 失敗時應回傳非零退出碼"; errors=$((errors+1))
fi
if ! grep -q "PERSONAS_ALL_FAILED" "$all_failed_err"; then
  echo "FAIL: 所有 persona 失敗時應記錄 PERSONAS_ALL_FAILED"; errors=$((errors+1))
fi
rm -f "$all_failed_out" "$all_failed_err"

# 部分失敗仍要交出成功 persona 的輸出，且不能誤判成全部失敗。
review_call_model() {
  local prompt="$3"
  if [[ "$prompt" == *"ROLE: Performance Hawk"* ]]; then
    return 1
  fi
  printf '%s\n' "PARTIAL-PERSONA-FINDING"
}
partial_err=$(mktemp)
if partial_out=$(run_persona_review "proj" "/tmp" "d" "x.js" \
  "security-auditor performance-hawk" "" "" "" "" "" claude \
  2>"$partial_err"); then
  partial_rc=0
else
  partial_rc=$?
fi
if [[ "$partial_rc" -ne 0 ]]; then
  echo "FAIL: 部分 persona 失敗時應回傳 0，實際 rc=$partial_rc"; errors=$((errors+1))
fi
if [[ "$partial_out" != *"PARTIAL-PERSONA-FINDING"* ]]; then
  echo "FAIL: 部分失敗時應保留成功 persona 的輸出"; errors=$((errors+1))
fi
if grep -q "PERSONAS_ALL_FAILED" "$partial_err"; then
  echo "FAIL: 部分失敗時不應記錄 PERSONAS_ALL_FAILED"; errors=$((errors+1))
fi
rm -f "$partial_err"

# run_persona_review must give convention-auditor its own max_turns override
# (MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS), falling back to the shared
# MRA_REVIEW_PERSONA_MAX_TURNS when unset — other personas must never be
# affected by the override.
turns_log=$(mktemp)
review_call_model() {
  local prompt="$3" max_turns="$7"
  if [[ "$prompt" == *"ROLE: Convention Auditor"* ]]; then
    echo "convention-auditor:$max_turns" >> "$turns_log"
  else
    echo "other:$max_turns" >> "$turns_log"
  fi
}

# Case 1: neither env var set — both personas fall back to the hardcoded
# default (8).
: > "$turns_log"
run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude >/dev/null 2>/dev/null
if ! grep -q "^convention-auditor:8$" "$turns_log"; then
  echo "FAIL: expected convention-auditor to get default max_turns 8 with no env vars set, got: $(cat "$turns_log")"; errors=$((errors+1))
fi
if ! grep -q "^other:8$" "$turns_log"; then
  echo "FAIL: expected other personas to get default max_turns 8 with no env vars set, got: $(cat "$turns_log")"; errors=$((errors+1))
fi

# Case 2: only the shared var set — every persona (including
# convention-auditor) uses it, matching pre-change behavior.
: > "$turns_log"
MRA_REVIEW_PERSONA_MAX_TURNS=20 run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude >/dev/null 2>/dev/null
if ! grep -q "^convention-auditor:20$" "$turns_log"; then
  echo "FAIL: expected convention-auditor to fall back to shared max_turns 20, got: $(cat "$turns_log")"; errors=$((errors+1))
fi
if ! grep -q "^other:20$" "$turns_log"; then
  echo "FAIL: expected other personas to use shared max_turns 20, got: $(cat "$turns_log")"; errors=$((errors+1))
fi

# Case 3: both vars set — convention-auditor uses its own override, other
# personas stay on the shared value.
: > "$turns_log"
MRA_REVIEW_PERSONA_MAX_TURNS=20 MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS=30 \
  run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude >/dev/null 2>/dev/null
if ! grep -q "^convention-auditor:30$" "$turns_log"; then
  echo "FAIL: expected convention-auditor to use its own override 30, got: $(cat "$turns_log")"; errors=$((errors+1))
fi
if ! grep -q "^other:20$" "$turns_log"; then
  echo "FAIL: expected other personas to stay on shared max_turns 20 despite convention-auditor override, got: $(cat "$turns_log")"; errors=$((errors+1))
fi
rm -f "$turns_log"
unset -f review_call_model

# run_persona_review must be able to keep each persona's RAW output when
# MRA_REVIEW_PERSONA_DUMP_DIR is set. Without it, the only thing that
# survives a review is the synthesized JSON, so "the persona never looked at
# this file" and "the persona flagged it but synthesize dropped it" are
# indistinguishable — that gap is what this dump exists to close.
review_call_model() {
  local prompt="$3"
  if [[ "$prompt" == *"ROLE: Convention Auditor"* ]]; then
    echo "RAW-OUT convention-auditor"
    echo "RAW-ERR convention-auditor" >&2
  else
    echo "RAW-OUT security-auditor"
    echo "RAW-ERR security-auditor" >&2
  fi
}

# Case 1: env var unset — nothing is written anywhere (behaviour unchanged).
dump_probe=$(mktemp -d)
run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude >/dev/null 2>/dev/null
if [[ -n "$(ls -A "$dump_probe" 2>/dev/null)" ]]; then
  echo "FAIL: nothing should be dumped when MRA_REVIEW_PERSONA_DUMP_DIR is unset"; errors=$((errors+1))
fi
rmdir "$dump_probe" 2>/dev/null

# Case 2: env var set — one .txt per persona holding its raw stdout.
dump_dir=$(mktemp -d)/nested   # also asserts the dir is created when missing
MRA_REVIEW_PERSONA_DUMP_DIR="$dump_dir" \
  run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude >/dev/null 2>/dev/null
for p in convention-auditor security-auditor; do
  if [[ ! -f "$dump_dir/$p.txt" ]]; then
    echo "FAIL: expected raw stdout dump at $dump_dir/$p.txt"; errors=$((errors+1))
  elif ! grep -q "RAW-OUT $p" "$dump_dir/$p.txt"; then
    echo "FAIL: $p.txt should hold that persona's own raw output, got: $(cat "$dump_dir/$p.txt")"; errors=$((errors+1))
  fi
done

# Case 3: stderr is dumped too — needed to tell "ran and stayed silent about
# this file" apart from "died on max turns and contributed nothing".
for p in convention-auditor security-auditor; do
  if [[ ! -f "$dump_dir/$p.err" ]]; then
    echo "FAIL: expected raw stderr dump at $dump_dir/$p.err"; errors=$((errors+1))
  elif ! grep -q "RAW-ERR $p" "$dump_dir/$p.err"; then
    echo "FAIL: $p.err should hold that persona's own stderr, got: $(cat "$dump_dir/$p.err")"; errors=$((errors+1))
  fi
done

# Case 4: dumping must not change what run_persona_review returns.
out_with_dump=$(MRA_REVIEW_PERSONA_DUMP_DIR="$dump_dir" \
  run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude 2>/dev/null)
out_without=$(run_persona_review "proj" "/tmp" "d" "x.js" "convention-auditor security-auditor" "" "" "" "" "" claude 2>/dev/null)
if [[ "$out_with_dump" != "$out_without" ]]; then
  echo "FAIL: dumping changed the findings returned to the caller"; errors=$((errors+1))
fi
rm -rf "$(dirname "$dump_dir")"
unset -f review_call_model

if [[ $errors -eq 0 ]]; then
  echo "PASS: all review-personas tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
