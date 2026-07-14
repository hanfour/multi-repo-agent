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
source "$SCRIPT_DIR/lib/review-pr-discussion.sh"
source "$SCRIPT_DIR/lib/review-strategy.sh"
source "$SCRIPT_DIR/lib/review-json.sh"
source "$SCRIPT_DIR/lib/review-personas.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init
REC="$TMP/rec"; export REC

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex-persona: $*" >> "$REC"
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"persona found an issue","comments":[{"path":"app.txt","line":1,"severity":"MEDIUM","body":"PERSONA-FINDING"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
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

: > "$REC"
findings=$(HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" \
  MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 MRA_CODEX_BIN="$BIN/codex" \
  run_persona_review "proj" "$TMP/project" "DIFF" "app.txt" \
    "security-auditor test-architect" "" "" "" "" "" codex)

case "$findings" in *PERSONA-FINDING*) pass "codex personas produce findings" ;; *) fail "no persona findings: $findings" ;; esac
rec=$(cat "$REC")
[[ "$(grep -c 'codex-persona:' "$REC")" == "2" ]] && pass "each persona runs a codex pass" || fail "expected 2 codex persona passes: $rec"
case "$rec" in *"exec --sandbox read-only"*) pass "personas route through the codex provider path" ;; *) fail "personas did not use codex exec: $rec" ;; esac

chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"
[[ "$errors" -eq 0 ]] && echo "All codex-persona tests passed" || { echo "$errors failures"; exit 1; }
