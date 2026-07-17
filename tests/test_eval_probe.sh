#!/usr/bin/env bash
# PKB deterministic probe (issue #27): a fixed fixture + question set exercises
# the shipped PKB selection machinery (moduleMap lookup, regex fallback,
# staleness detection) with NO LLM involved. The JSON report is stamped with
# the mra commit so runs are comparable across commits; repeat runs are stable.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/structural.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"
source "$SCRIPT_DIR/lib/eval-probe.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
echo '{"configVersion":2}' > "$MRA_CONFIG"
export MRA_CONFIG

OUT=$(mktemp)

# --- 1. Probe runs green and emits a well-formed, SHA-stamped report ---
if eval_pkb_probe --out "$OUT" >/dev/null 2>&1; then
  pass "probe exits 0 on a healthy build"
else
  fail "probe exited non-zero"
fi
jq -e . "$OUT" >/dev/null 2>&1 && pass "report is valid JSON" || fail "report not JSON: $(head -2 "$OUT")"
commit=$(jq -r '.mraCommit // ""' "$OUT" 2>/dev/null)
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] && pass "report stamped with mra commit ($commit)" || fail "mraCommit missing/invalid: '$commit'"

cases=$(jq '.cases | length' "$OUT" 2>/dev/null)
[[ -n "$cases" && "$cases" -ge 5 ]] && pass "question set has $cases cases (≥5)" || fail "too few cases: $cases"

recall=$(jq -r '.recall' "$OUT" 2>/dev/null)
[[ "$recall" == "1" || "$recall" == "1.0" || "$recall" == "1.00" ]] && pass "recall is 1.0 on a healthy build" || fail "recall not 1.0: $recall"

fails=$(jq '[.cases[] | select(.pass == false)] | length' "$OUT" 2>/dev/null)
[[ "$fails" == "0" ]] && pass "no failing cases" || fail "$fails case(s) failing: $(jq -c '[.cases[] | select(.pass == false) | .name]' "$OUT")"

# --- 2. Stability: a second run yields the same case outcomes ---
OUT2=$(mktemp)
eval_pkb_probe --out "$OUT2" >/dev/null 2>&1
r1=$(jq -S '{recall, cases: [.cases[] | {name, pass, got}]}' "$OUT" 2>/dev/null)
r2=$(jq -S '{recall, cases: [.cases[] | {name, pass, got}]}' "$OUT2" 2>/dev/null)
[[ -n "$r1" && "$r1" == "$r2" ]] && pass "repeat run is byte-stable (modulo timestamp)" || fail "runs differ"

rm -f "$OUT" "$OUT2" "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: eval probe tests passed"
else
  echo "FAIL: $errors eval probe test(s) failed"
  exit 1
fi
