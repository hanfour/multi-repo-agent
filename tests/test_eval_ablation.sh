#!/usr/bin/env bash
# PKB/structural ablation (issue #27): the same review case runs 2×2
# (PKB on/off × structural on/off); the report carries all four arms with
# findings + duration, stamped with the mra commit. Arms genuinely differ:
# the recorded prompts show PKB / structural sections only on their on-arms.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/claude-invoke.sh"
source "$SCRIPT_DIR/lib/detect-type.sh"
source "$SCRIPT_DIR/lib/change-detector.sh"
source "$SCRIPT_DIR/lib/structural.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"
source "$SCRIPT_DIR/lib/review-diff.sh"
source "$SCRIPT_DIR/lib/review-prompt.sh"
source "$SCRIPT_DIR/lib/review-json.sh"
source "$SCRIPT_DIR/lib/review-context.sh"
source "$SCRIPT_DIR/lib/pr-ops.sh"
source "$SCRIPT_DIR/lib/eval.sh"
source "$SCRIPT_DIR/lib/eval-ablation.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
echo '{"configVersion":2}' > "$MRA_CONFIG"
export MRA_CONFIG

# --- Fixture: workspace + git project on a feature branch, PKB + index ---
WS=$(mktemp -d)
mkdir -p "$WS/.collab"
echo '{"projects":{"proj":{"type":"app"}}}' > "$WS/.collab/dep-graph.json"
PROJ="$WS/proj"; mkdir -p "$PROJ/src/pay"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@e.c
git -C "$PROJ" config user.name T
printf 'base\n' > "$PROJ/src/pay/checkout.ts"
git -C "$PROJ" add . && git -C "$PROJ" commit -qm init
git -C "$PROJ" branch -m main
git -C "$PROJ" checkout -qb feat
printf 'changed\n' >> "$PROJ/src/pay/checkout.ts"
git -C "$PROJ" add . && git -C "$PROJ" commit -qm change

PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules" "$PROJ/.codegraph"
cat > "$PKB/meta.json" <<'EOF'
{"version":2,"moduleMap":{"pay":"src/pay"}}
EOF
printf '**proj** | app | Node\nDemo\n' > "$PKB/identity.md"

REC=$(mktemp -d); export REC
BIN=$(mktemp -d)
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$REC" | wc -l | tr -d ' ')
prompt=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-p" ]]; then prompt="$2"; shift 2; else shift; fi
done
printf '%s' "$prompt" > "$REC/prompt-$n"
echo '{"status":"COMMENT","summary":"stub","comments":[{"path":"src/pay/checkout.ts","line":1,"severity":"LOW","body":"stub finding"}]}'
STUB
chmod +x "$BIN/claude"
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  explore)  echo "BLAST-RADIUS-MARKER checkout ← called by CartController" ;;
  affected) cat >/dev/null; echo "tests/pay.test.ts" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"

# --- 1. Ablation runs and reports all four arms ---
report=$(MRA_CLAUDE_BIN="$BIN/claude" MRA_CODEGRAPH_BIN="$BIN/codegraph" \
  eval_pkb_ablation "$WS" proj --base main --model haiku 2>/dev/null)
echo "$report" | jq -e . >/dev/null 2>&1 && pass "ablation report is valid JSON" || fail "report not JSON: $(echo "$report" | head -3)"
arms=$(echo "$report" | jq '.arms | length' 2>/dev/null)
[[ "$arms" == "4" ]] && pass "report has 4 arms" || fail "arms=$arms"
combos=$(echo "$report" | jq -r '[.arms[] | "\(.pkb)-\(.structural)"] | sort | join(",")' 2>/dev/null)
[[ "$combos" == "off-off,off-on,on-off,on-on" ]] && pass "arms cover the 2×2 matrix" || fail "combos: $combos"
commit=$(echo "$report" | jq -r '.mraCommit // ""')
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] && pass "report stamped with mra commit" || fail "mraCommit: '$commit'"
echo "$report" | jq -e '.arms[0] | has("findings") and has("seconds")' >/dev/null 2>&1 \
  && pass "arms carry findings + seconds" || fail "arm metrics missing"

# --- 2. Arms genuinely differ: recorded prompts prove the toggles ---
[[ $(ls "$REC" | wc -l | tr -d ' ') == "4" ]] && pass "four model invocations recorded" || fail "invocations: $(ls "$REC")"
pkb_on=$(grep -l "Project Knowledge Base" "$REC"/prompt-* | wc -l | tr -d ' ')
[[ "$pkb_on" == "2" ]] && pass "PKB section present in exactly the 2 pkb-on arms" || fail "PKB in $pkb_on prompts"
st_on=$(grep -l "BLAST-RADIUS-MARKER" "$REC"/prompt-* | wc -l | tr -d ' ')
[[ "$st_on" == "2" ]] && pass "structural section present in exactly the 2 structural-on arms" || fail "structural in $st_on prompts"

# --- 3. Report persisted under .collab/eval ---
saved=$(find "$WS/.collab/eval" -name 'pkb-ablation-*.json' | head -1)
[[ -n "$saved" ]] && pass "report saved under .collab/eval" || fail "no saved report"

rm -rf "$WS" "$BIN" "$REC"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: eval ablation tests passed"
else
  echo "FAIL: $errors eval ablation test(s) failed"
  exit 1
fi
