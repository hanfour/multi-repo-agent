#!/usr/bin/env bash
# PKB moduleMap (issue #21): module membership is fact-driven — PKB generation
# records each module's actual directory in meta.json, and file→module lookup
# consults that map (longest prefix wins) before falling back to the legacy
# path-regex guesses, so non-standard layouts stop being invisible.
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

log_info(){ :; } ; log_progress(){ :; } ; log_warn(){ :; } ; log_success(){ :; }

PROJ=$(mktemp -d)
PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules" "$PROJ/services/chat" "$PROJ/services/chat-api"
cat > "$PKB/meta.json" <<'EOF'
{"version":2,"lastUpdated":"2026-01-01T00:00:00Z",
 "moduleMap":{"chat":"services/chat","chat-api":"services/chat-api"}}
EOF

# --- 1. Non-standard layout resolves through the map (regex would miss) ---
out=$(pkb_modules_from_files "services/chat/x.ts" "$PROJ")
[[ "$out" == "chat" ]] && pass "map lookup resolves non-standard layout" || fail "map lookup: got '$out', want 'chat'"

# --- 2. Longest prefix wins (chat-api must not match chat) ---
out=$(pkb_modules_from_files "services/chat-api/z.ts" "$PROJ")
[[ "$out" == "chat-api" ]] && pass "longest-prefix match picks chat-api" || fail "longest-prefix: got '$out', want 'chat-api'"

# --- 3. _pkb_module_to_dir consults the map ---
out=$(_pkb_module_to_dir "$PROJ" "chat")
[[ "$out" == "$PROJ/services/chat" ]] && pass "module_to_dir resolves via map" || fail "module_to_dir: got '$out'"

# --- 4. Map miss falls back to legacy regex ---
out=$(pkb_modules_from_files "src/features/pay/y.ts" "$PROJ")
[[ "$out" == "pay" ]] && pass "map miss falls back to regex" || fail "regex fallback: got '$out', want 'pay'"

# --- 5. No project_dir / no map: legacy behaviour unchanged ---
out=$(pkb_modules_from_files "src/features/pay/y.ts")
[[ "$out" == "pay" ]] && pass "legacy call without project_dir unchanged" || fail "legacy call: got '$out'"
rm -rf "$PROJ"

# --- 6. Generation records the moduleMap ---
PROJ=$(mktemp -d)
PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules" "$PROJ/src/modules/auth"
printf 'code\n' > "$PROJ/src/modules/auth/index.ts"
echo '{"version":2}' > "$PKB/meta.json"
BIN=$(mktemp -d)
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "# Module: auth"
echo "This is a sufficiently long generated module summary used in tests to pass the validity gate."
STUB
chmod +x "$BIN/claude"
PATH="$BIN:$PATH" _pkb_generate_modules "proj" "$PROJ" "app" "" "haiku" "$PKB" >/dev/null 2>&1
recorded=$(jq -r '.moduleMap.auth // ""' "$PKB/meta.json" 2>/dev/null)
[[ "$recorded" == "src/modules/auth" ]] && pass "generation records moduleMap entry" || fail "generation moduleMap: got '$recorded', want 'src/modules/auth'"
rm -rf "$PROJ" "$BIN"

if [[ $errors -eq 0 ]]; then
  echo "PASS: pkb moduleMap tests passed"
else
  echo "FAIL: $errors pkb moduleMap test(s) failed"
  exit 1
fi
