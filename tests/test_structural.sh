#!/usr/bin/env bash
# Structural layer foundation (issue #23): thin, bounded wrappers around the
# codegraph CLI. Adopt-if-exists, never index on the user's behalf, and
# degrade gracefully — no codegraph anywhere means zero behaviour change.
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

PROJ=$(mktemp -d)
BIN=$(mktemp -d)
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  impact)   echo '{"symbol":"'"$2"'","impact":["callerA","callerB"]}' ;;
  query)    echo '{"results":[{"name":"'"$2"'"}]}' ;;
  affected) cat >/dev/null; echo "tests/affected_a.test.ts" ;;
  *) echo "unknown: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"

# --- 1. Availability gates: CLI missing / index missing / both present ---
out=$(MRA_CODEGRAPH_BIN="$BIN/nonexistent" structural_available "$PROJ" && echo yes || echo no)
[[ "$out" == "no" ]] && pass "unavailable when CLI missing" || fail "CLI-missing gate: got $out"

out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_available "$PROJ" && echo yes || echo no)
[[ "$out" == "no" ]] && pass "unavailable when project has no .codegraph/" || fail "no-index gate: got $out"

mkdir -p "$PROJ/.codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_available "$PROJ" && echo yes || echo no)
[[ "$out" == "yes" ]] && pass "available with CLI + index" || fail "available gate: got $out"

# --- 2. Config kill switch: structural.provider=off wins over presence ---
echo '{"configVersion":2,"structural":{"provider":"off"}}' > "$MRA_CONFIG"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_available "$PROJ" && echo yes || echo no)
[[ "$out" == "no" ]] && pass "structural.provider=off disables the layer" || fail "kill switch: got $out"
echo '{"configVersion":2}' > "$MRA_CONFIG"

# --- 3. Wrappers return the CLI's JSON ---
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_impact "$PROJ" "handleLogin")
echo "$out" | grep -q '"callerA"' && pass "structural_impact returns CLI output" || fail "impact output: $out"

out=$(printf 'src/a.ts\n' | MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_affected "$PROJ")
[[ "$out" == "tests/affected_a.test.ts" ]] && pass "structural_affected pipes stdin through" || fail "affected output: $out"

# --- 4. Bounded: a hung CLI is killed, an oversized output is capped ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
sleep 60
STUB
chmod +x "$BIN/codegraph"
start=$SECONDS
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" MRA_STRUCTURAL_TIMEOUT_SECONDS=2 structural_impact "$PROJ" "x") ; rc=$?
elapsed=$((SECONDS - start))
if [[ "$rc" -ne 0 && "$elapsed" -lt 30 ]]; then
  pass "hung CLI bounded in ${elapsed}s with rc=$rc"
else
  fail "hung CLI: rc=$rc elapsed=${elapsed}s"
fi

cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
head -c 200000 /dev/zero | tr '\0' 'x'
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_impact "$PROJ" "x")
size=${#out}
if [[ "$size" -le 65536 ]]; then
  pass "oversized output capped ($size bytes)"
else
  fail "output not capped: $size bytes"
fi

# --- 5. Analyze-side adopt / hint messaging ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
echo ok
STUB
chmod +x "$BIN/codegraph"
msg=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_analyze_hint "proj" "$PROJ" 2>&1)
echo "$msg" | grep -qi "adopt" && pass "indexed project: adopt message" || fail "adopt message missing: $msg"

rm -rf "$PROJ/.codegraph"
msg=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_analyze_hint "proj" "$PROJ" 2>&1)
echo "$msg" | grep -q "codegraph init" && pass "unindexed project: init hint (never runs it)" || fail "init hint missing: $msg"

msg=$(MRA_CODEGRAPH_BIN="$BIN/nonexistent" structural_analyze_hint "proj" "$PROJ" 2>&1)
[[ -z "$msg" ]] && pass "no CLI: silent (zero behaviour change)" || fail "no-CLI must be silent: $msg"

rm -rf "$PROJ" "$BIN"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: structural foundation tests passed"
else
  echo "FAIL: $errors structural test(s) failed"
  exit 1
fi
