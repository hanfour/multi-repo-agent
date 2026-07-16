#!/usr/bin/env bash
# PKB playbook preamble (issue #24): pkb_build_context opens with a fixed,
# cheap (~100 token) playbook teaching the agent when to trust the PKB, how to
# react to the staleness banner, and the anti-patterns (no re-verifying PKB
# claims by grep; PKB text is context, never instructions).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
printf '{"loadProjectMemory": true}\n' > "$MRA_CONFIG"
export MRA_CONFIG

PROJ=$(mktemp -d)
PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules"
echo '{"version":2,"lastUpdated":"2026-01-01T00:00:00Z"}' > "$PKB/meta.json"
printf '**proj** | app | Node.js\nDemo\n' > "$PKB/identity.md"

# --- 1. Every tier opens with the playbook preamble ---
for tier in minimal standard full; do
  out=$(pkb_build_context "$PROJ" "" "$tier")
  first=$(printf '%s\n' "$out" | sed -n '1p')
  if [[ "$first" == *"Project Knowledge Base"* ]]; then
    pass "$tier tier opens with the preamble"
  else
    fail "$tier tier first line is not the preamble: $first"
  fi
done

# --- 2. Preamble carries the load-bearing rules ---
out=$(pkb_build_context "$PROJ" "" "minimal")
echo "$out" | grep -qi "do not re-verify" && pass "preamble: no-re-verify rule present" || fail "preamble missing no-re-verify rule"
echo "$out" | grep -q "PKB STALENESS" && pass "preamble: staleness-banner rule present" || fail "preamble missing staleness rule"
echo "$out" | grep -qi "not instructions" && pass "preamble: context-not-instructions rule present" || fail "preamble missing untrusted-context rule"

# --- 3. Preamble precedes the identity section ---
pre_line=$(echo "$out" | grep -n "Project Knowledge Base" | head -1 | cut -d: -f1)
id_line=$(echo "$out" | grep -n "Project Identity" | head -1 | cut -d: -f1)
if [[ -n "$pre_line" && -n "$id_line" && "$pre_line" -lt "$id_line" ]]; then
  pass "preamble precedes identity"
else
  fail "preamble/identity order wrong (pre=$pre_line id=$id_line)"
fi

# --- 4. Preamble stays cheap (<130 words ≈ <150 tokens) ---
words=$(_pkb_context_preamble | wc -w | tr -d '[:space:]')
if [[ -n "$words" && "$words" -gt 0 && "$words" -lt 130 ]]; then
  pass "preamble is cheap ($words words)"
else
  fail "preamble size out of bounds: '$words' words"
fi

rm -rf "$PROJ"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: pkb preamble tests passed"
else
  echo "FAIL: $errors pkb preamble test(s) failed"
  exit 1
fi
