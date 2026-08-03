#!/usr/bin/env bash
# Codex reviews run with an explicitly pinned model and reasoning effort.
# `--ignore-user-config` means ~/.codex/config.toml never reaches the review
# child, so both values must travel as explicit flags or they silently fall
# back to whatever the Codex CLI defaults to.
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

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

BIN="$TMP/bin"; REC="$TMP/rec"; export REC
mkdir -p "$BIN" "$TMP/project" "$TMP/home/.codex"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add app.txt
git -C "$TMP/project" commit -qm init
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"

# argv is recorded element-by-element: `--model "a b"` and an injected
# `-c sandbox_mode=...` are indistinguishable under "$*", and only the latter
# is an actual escape.
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
{ printf 'codex:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$REC"
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"

run_codex() {
  : > "$REC"
  HOME="$TMP/home" MRA_REVIEW_MODEL_HOME="$TMP/model-home" \
    MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_CODEX_BIN="$BIN/codex" \
    review_call_model review codex "PROMPT" "" "$TMP/project" "" 6 "" >/dev/null
  cat "$REC"
}

# --- effort resolution -------------------------------------------------------
[[ -z "$(review_provider_codex_reasoning_effort)" ]] \
  && pass "unset reasoning effort resolves empty (defers to Codex default)" \
  || fail "unset reasoning effort should resolve empty"

config_set_string "review.codexReasoningEffort" "max" >/dev/null
[[ "$(review_provider_codex_reasoning_effort)" == "max" ]] \
  && pass "configured reasoning effort is returned" \
  || fail "configured reasoning effort not returned"

# --- effort reaches the codex child -----------------------------------------
rec=$(run_codex)
case "$rec" in *'[-c] [model_reasoning_effort="max"]'*) pass "codex receives configured reasoning effort" ;; *) fail "codex missing reasoning effort: $rec" ;; esac

# --- pinned model reaches the codex child ------------------------------------
config_set_string "review.models.codex" "gpt-5.6-luna" >/dev/null
rec=$(run_codex)
case "$rec" in *"[--model] [gpt-5.6-luna]"*) pass "codex receives pinned model" ;; *) fail "codex missing pinned model: $rec" ;; esac

# --- absent effort is not forged --------------------------------------------
config_set_string "review.codexReasoningEffort" "" >/dev/null
rec=$(run_codex)
case "$rec" in *"model_reasoning_effort"*) fail "empty effort must not be sent: $rec" ;; *) pass "empty reasoning effort sends no override" ;; esac

# --- hostile values cannot splice extra TOML ---------------------------------
config_set_string "review.codexReasoningEffort" 'max"
[projects."/untrusted"]
trust_level = "trusted' >/dev/null
rec=$(run_codex)
case "$rec" in *"/untrusted"*|*"trust_level"*) fail "reasoning effort spliced attacker TOML: $rec" ;; *) pass "hostile reasoning effort cannot splice TOML" ;; esac
case "$rec" in *"model_reasoning_effort"*) fail "invalid reasoning effort must be dropped: $rec" ;; *) pass "invalid reasoning effort is dropped" ;; esac

config_set_string "review.codexReasoningEffort" "max" >/dev/null
config_set_string "review.models.codex" 'gpt" -c sandbox_mode="danger-full-access' >/dev/null
rec=$(run_codex)
case "$rec" in *"[-c] [sandbox_mode="*) fail "model value became a separate config override: $rec" ;; *) pass "hostile model value stays one argv element" ;; esac

# --- config_handle validation ------------------------------------------------
if config_handle "review.codexReasoningEffort" "max" >/dev/null 2>&1; then
  pass "config_handle accepts review.codexReasoningEffort"
else
  fail "config_handle rejected a valid review.codexReasoningEffort"
fi
if config_handle "review.codexReasoningEffort" 'bad value"' >/dev/null 2>&1; then
  fail "config_handle accepted a hostile reasoning effort"
else
  pass "config_handle rejects hostile reasoning effort"
fi

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: codex reasoning effort tests passed"
else
  echo "FAIL: $errors codex reasoning effort test(s) failed"
  exit 1
fi
