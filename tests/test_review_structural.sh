#!/usr/bin/env bash
# Review structural context (issue #25): a capped, best-effort prompt section
# combining symbol-level blast radius (codegraph explore over the changed
# files) and transitively affected test files. Any failure or absence of
# codegraph yields EMPTY output so the review prompt stays byte-identical.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/structural.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
echo '{"configVersion":2}' > "$MRA_CONFIG"
export MRA_CONFIG

PROJ=$(mktemp -d); mkdir -p "$PROJ/.codegraph"
BIN=$(mktemp -d)
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  explore)  echo "SYMBOL handleLogin (src/auth.ts) ← called by SessionController.create" ;;
  affected) cat >/dev/null; printf 'tests/auth.test.ts\ntests/session.test.ts\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"

CHANGED=$'src/auth.ts\nsrc/session.ts'

# --- 1. Section combines blast radius + affected tests ---
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED")
echo "$out" | grep -q "Structural Context" && pass "section header present" || fail "header missing: $(echo "$out" | head -2)"
echo "$out" | grep -q "handleLogin" && pass "blast radius content present" || fail "blast radius missing"
echo "$out" | grep -q "tests/auth.test.ts" && pass "affected tests present" || fail "affected tests missing"

# --- 2. Capped at MRA_REVIEW_STRUCTURAL_MAX_BYTES ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  explore) head -c 40000 /dev/zero | tr '\0' 'x' ;;
  affected) cat >/dev/null ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" MRA_REVIEW_STRUCTURAL_MAX_BYTES=2048 structural_review_context "$PROJ" "$CHANGED")
[[ ${#out} -le 2048 ]] && pass "section capped (${#out} bytes)" || fail "cap exceeded: ${#out} bytes"

# --- 3. Best-effort: failing CLI yields empty, never an error ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "failing CLI yields empty section" || fail "failing CLI leaked output: $out"

# --- 4. No index / no CLI / empty change set: empty (byte-identical prompt) ---
NOIDX=$(mktemp -d)
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$NOIDX" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "no .codegraph/: empty" || fail "no index leaked: $out"
out=$(MRA_CODEGRAPH_BIN="$BIN/nonexistent" structural_review_context "$PROJ" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "no CLI: empty" || fail "no CLI leaked: $out"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "" 2>&1) || true
[[ -z "$out" ]] && pass "empty change set: empty" || fail "empty changes leaked: $out"

# --- 5. review.sh wires the section into the review context ---
grep -q "structural_review_context" "$SCRIPT_DIR/lib/review.sh" \
  && pass "review.sh consumes structural_review_context" \
  || fail "review.sh does not reference structural_review_context"

rm -rf "$PROJ" "$NOIDX" "$BIN"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review structural context tests passed"
else
  echo "FAIL: $errors review structural test(s) failed"
  exit 1
fi
