#!/usr/bin/env bash
# PKB decision provenance (issue #22): decisions captured from review findings
# carry a source tag ([DECISION source:review@<sha> <date>]) so every piece of
# machine-distilled knowledge is auditable and cleanable; dedup still works on
# the body text, and L1 context extraction still picks tagged lines up.
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
git -C "$PROJ" init -q
git -C "$PROJ" config user.email test@example.com
git -C "$PROJ" config user.name Test
printf 'x\n' > "$PROJ/a.txt"
git -C "$PROJ" add . && git -C "$PROJ" commit -qm init
SHA=$(git -C "$PROJ" rev-parse --short HEAD)

PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules"
echo '{"version":2,"lastUpdated":"2026-01-01T00:00:00Z"}' > "$PKB/meta.json"
printf '**proj** | app | Node.js\nDemo\n' > "$PKB/identity.md"
printf '# Conventions: proj\n[DECISION] legacy untagged decision line\n' > "$PKB/conventions.md"

REVIEW_JSON='{"status":"CHANGES_REQUESTED","summary":"s","comments":[{"path":"a.txt","line":1,"severity":"HIGH","body":"Always validate webhook signatures before processing.\nMore detail."}]}'

# --- 1. Captured decision carries a provenance source tag ---
pkb_capture_decisions "$PROJ" "$REVIEW_JSON"
if grep -qE "^\[DECISION source:review@[0-9a-f]+ [0-9]{4}-[0-9]{2}-[0-9]{2}\] Always validate webhook signatures" "$PKB/conventions.md"; then
  pass "captured decision carries source:review@sha + date tag"
else
  fail "provenance tag missing: $(grep 'webhook' "$PKB/conventions.md" || echo '<not captured at all>')"
fi
if grep -q "review@$SHA" "$PKB/conventions.md"; then
  pass "source tag records the current HEAD short sha"
else
  fail "source tag sha wrong: $(grep 'source:' "$PKB/conventions.md" || true)"
fi

# --- 2. Re-capturing the same finding does not duplicate ---
pkb_capture_decisions "$PROJ" "$REVIEW_JSON"
n=$(grep -c "Always validate webhook signatures" "$PKB/conventions.md")
[[ "$n" -eq 1 ]] && pass "dedup: same finding captured once" || fail "dedup: found $n copies"

# --- 3. L1 context extraction picks up tagged AND legacy decision lines ---
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "Always validate webhook signatures"; then
  pass "L1 extraction includes source-tagged decision"
else
  fail "L1 extraction missed source-tagged decision"
fi
if echo "$out" | grep -q "legacy untagged decision line"; then
  pass "L1 extraction still includes legacy untagged decision"
else
  fail "L1 extraction lost legacy untagged decision"
fi

rm -rf "$PROJ"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: pkb provenance tests passed"
else
  echo "FAIL: $errors pkb provenance test(s) failed"
  exit 1
fi
