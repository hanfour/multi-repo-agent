#!/usr/bin/env bash
# Structural tunnels (issue #26): the capitalized-word scan becomes a
# PROPOSER; codegraph verifies each candidate is a real symbol (query) and
# supplies its real referencing files (callers), aggregated to modules via the
# moduleMap. Noise words disappear; without codegraph the legacy grep
# behaviour is unchanged.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/structural.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }
log_info(){ :; }

MRA_CONFIG=$(mktemp)
echo '{"configVersion":2}' > "$MRA_CONFIG"
export MRA_CONFIG

make_fixture() {
  PROJ=$(mktemp -d)
  PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules" "$PROJ/.codegraph"
  cat > "$PKB/meta.json" <<'EOF'
{"version":2,"moduleMap":{"chat":"services/chat","billing":"services/billing"}}
EOF
  cat > "$PKB/modules/chat.md" <<'EOF'
# Module: chat
Uses PaymentService for checkout. RandomWord appears here too.
EOF
  cat > "$PKB/modules/billing.md" <<'EOF'
# Module: billing
Defines PaymentService. RandomWord also mentioned in prose.
EOF
}

BIN=$(mktemp -d)
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "query PaymentService")   echo '[{"name":"PaymentService","file":"services/billing/payment.ts"}]' ;;
  "query RandomWord")       echo '[]' ;;
  "callers PaymentService") echo '[{"file":"services/chat/send.ts"},{"file":"services/billing/util.ts"}]' ;;
  "callers RandomWord")     echo '[]' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"

# --- 1. codegraph path: verified entity with real cross-module reference ---
make_fixture
MRA_CODEGRAPH_BIN="$BIN/codegraph" _pkb_generate_tunnels "$PKB" "$PROJ" 2>/dev/null
if [[ -f "$PKB/tunnels.md" ]]; then
  grep -q "PaymentService" "$PKB/tunnels.md" && pass "verified entity kept" || fail "PaymentService missing: $(cat "$PKB/tunnels.md")"
  grep -q "billing" "$PKB/tunnels.md" && pass "defining module recorded" || fail "defining module missing"
  grep -q "chat" "$PKB/tunnels.md" && pass "referencing module recorded" || fail "referencing module missing"
  grep -q "RandomWord" "$PKB/tunnels.md" && fail "noise word survived codegraph verification" || pass "noise word dropped"
  grep -qi "source: codegraph" "$PKB/tunnels.md" && pass "provenance header present" || fail "source header missing"
else
  fail "tunnels.md not generated on codegraph path"
fi
rm -rf "$PROJ"

# --- 2. No codegraph CLI: legacy grep behaviour unchanged ---
make_fixture
MRA_CODEGRAPH_BIN="$BIN/nonexistent" _pkb_generate_tunnels "$PKB" "$PROJ" 2>/dev/null
if [[ -f "$PKB/tunnels.md" ]]; then
  grep -q "RandomWord" "$PKB/tunnels.md" && pass "legacy path keeps heuristic entities" || fail "legacy path lost entities"
  grep -qi "source: codegraph" "$PKB/tunnels.md" && fail "legacy path must not claim codegraph provenance" || pass "legacy path has no codegraph header"
else
  fail "legacy path produced no tunnels.md"
fi
rm -rf "$PROJ"

# --- 3. Failing CLI falls back to the legacy scan ---
make_fixture
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/codegraph"
MRA_CODEGRAPH_BIN="$BIN/codegraph" _pkb_generate_tunnels "$PKB" "$PROJ" 2>/dev/null
if [[ -f "$PKB/tunnels.md" ]] && grep -q "PaymentService" "$PKB/tunnels.md"; then
  pass "failing CLI falls back to the heuristic scan"
else
  fail "failing CLI: no fallback tunnels produced"
fi
rm -rf "$PROJ" "$BIN"

# --- 4. Legacy single-arg call keeps working (callers not yet migrated) ---
make_fixture
_pkb_generate_tunnels "$PKB" 2>/dev/null
[[ -f "$PKB/tunnels.md" ]] && pass "single-arg legacy invocation still works" || fail "single-arg invocation broke"
rm -rf "$PROJ"

rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: structural tunnels tests passed"
else
  echo "FAIL: $errors structural tunnels test(s) failed"
  exit 1
fi
