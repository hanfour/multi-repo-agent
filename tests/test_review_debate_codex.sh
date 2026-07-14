#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2}' > "$MRA_CONFIG"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/claude-invoke.sh"
source "$SCRIPT_DIR/lib/review-provider.sh"
source "$SCRIPT_DIR/lib/review.sh"
source "$SCRIPT_DIR/lib/review-debate.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

# --- Codex double harness (mirrors tests/test_review_provider.sh) ---
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init
REC="$TMP/rec"; export REC
export COUNT_FILE="$TMP/count"

# Two-call stub: call 1 = analysis (real + noise), call 2 = adversarial (drops noise).
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
echo "call=$n args=$*" >> "$REC"
if [[ "$n" == "1" ]]; then
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"pass1","comments":[{"path":"a.sh","line":1,"severity":"HIGH","body":"REAL-BUG"},{"path":"b.sh","line":2,"severity":"LOW","body":"REFUTED-NOISE"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
else
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"pass2 verified","comments":[{"path":"a.sh","line":1,"severity":"HIGH","body":"REAL-BUG"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
fi
STUB
chmod +x "$BIN/codex"

mkdir -p "$TMP/home/.codex"
cat > "$TMP/home/.codex/config.toml" <<'TOML'
model_provider = "OpenAI"
[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
requires_openai_auth = true
TOML
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"

run_debate() {
  HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" \
  MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 MRA_CODEX_BIN="$BIN/codex" \
  _run_codex_debate debate "REVIEW THIS DIFF" "" "$TMP/project" "" 6
}

# --- Scenario A: adversarial verify with intersection semantics ---
: > "$REC"; rm -f "$COUNT_FILE"
merged=$(run_debate)
[[ "$(printf '%s' "$merged" | jq -r .status)" == "CHANGES_REQUESTED" ]] \
  && pass "codex debate escalates to CHANGES_REQUESTED on a real blocker" \
  || fail "codex debate status wrong: $merged"
[[ "$(printf '%s' "$merged" | jq '.comments | length')" == "1" ]] \
  && pass "codex debate keeps only the re-verified finding" \
  || fail "codex debate comment count wrong: $merged"
case "$merged" in *REAL-BUG*) pass "codex debate retains the substantiated finding" ;; *) fail "missing REAL-BUG: $merged" ;; esac
case "$merged" in *REFUTED-NOISE*) fail "codex debate kept a refuted finding: $merged" ;; *) pass "codex debate drops the refuted finding" ;; esac
# adversarial wiring: pass2 prompt embeds pass1's finding text
rec=$(cat "$REC")
case "$rec" in *"call=2"*"REAL-BUG"*) pass "adversarial pass2 receives pass1 findings" ;; *) fail "pass2 did not receive pass1 findings: $rec" ;; esac

# --- Scenario C: pass 2 fully refutes pass 1 -> verdict downgraded to APPROVED ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
if [[ "$n" == "1" ]]; then
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"pass1 flags a maybe","comments":[{"path":"x.sh","line":3,"severity":"MEDIUM","body":"MAYBE-BUG"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
else
cat <<'OUT'
{"status":"APPROVED","summary":"refuted the maybe","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
fi
STUB
chmod +x "$BIN/codex"
: > "$REC"; rm -f "$COUNT_FILE"
merged=$(run_debate)
[[ "$(printf '%s' "$merged" | jq -r .status)" == "APPROVED" ]] \
  && pass "pass 2 refuting all findings downgrades the verdict to APPROVED" \
  || fail "adversarial downgrade failed: $merged"
[[ "$(printf '%s' "$merged" | jq '.comments | length')" == "0" ]] \
  && pass "refuted findings leave no surviving comments" \
  || fail "refuted comments not dropped: $merged"

# --- Scenario B: no false-green when a pass is truncated ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
if [[ "$n" == "1" ]]; then
cat <<'OUT'
{"status":"APPROVED","summary":"pass1 clean","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
else
# truncated: valid JSON but NO sentinel
echo '{"status":"APPROVED","summary":"cut off mid-analysis","comments":[]}'
fi
STUB
chmod +x "$BIN/codex"
: > "$REC"; rm -f "$COUNT_FILE"
merged=$(run_debate)
[[ "$(printf '%s' "$merged" | jq -r .status)" == "COMMENT" ]] \
  && pass "truncated codex pass gates to non-approving COMMENT" \
  || fail "truncated pass was not gated: $merged"
case "$(printf '%s' "$merged" | jq -r .summary)" in *REVIEW_INCOMPLETE*) pass "truncated codex debate reports REVIEW_INCOMPLETE" ;; *) fail "missing REVIEW_INCOMPLETE: $merged" ;; esac

chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"
[[ "$errors" -eq 0 ]] && echo "All codex-debate tests passed" || { echo "$errors failures"; exit 1; }
