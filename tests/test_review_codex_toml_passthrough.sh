#!/usr/bin/env bash
# --ignore-user-config drops every runtime knob in ~/.codex/config.toml, not
# just the transport ones MRA already restores. Context window and the
# auto-compact threshold decide when a long review starts losing detail to
# compaction, so they have to survive into the child too.
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

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
{ printf 'codex:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$REC"
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"

write_toml() {
  cat > "$TMP/home/.codex/config.toml"
  # transport section always present so the provider path stays realistic
  cat >> "$TMP/home/.codex/config.toml" <<'TOML'

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://relay.example.test:2880"
wire_api = "responses"
TOML
}

run_codex() {
  : > "$REC"
  HOME="$TMP/home" MRA_REVIEW_MODEL_HOME="$TMP/model-home" \
    MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_CODEX_BIN="$BIN/codex" \
    review_call_model review codex "PROMPT" "" "$TMP/project" "" 6 "" >/dev/null
  cat "$REC"
}

# --- valid knobs are forwarded ----------------------------------------------
write_toml <<'TOML'
model_provider = "OpenAI"
model_context_window = 1000000
model_auto_compact_token_limit = 900000
service_tier = "fast"
disable_response_storage = true
TOML
rec=$(run_codex)
case "$rec" in *"[-c] [model_context_window=1000000]"*) pass "context window forwarded" ;; *) fail "context window missing: $rec" ;; esac
case "$rec" in *"[-c] [model_auto_compact_token_limit=900000]"*) pass "auto-compact limit forwarded" ;; *) fail "auto-compact limit missing: $rec" ;; esac
case "$rec" in *'[-c] [service_tier="fast"]'*) pass "service tier forwarded" ;; *) fail "service tier missing: $rec" ;; esac
case "$rec" in *"[-c] [disable_response_storage=true]"*) pass "response storage flag forwarded" ;; *) fail "response storage flag missing: $rec" ;; esac

# --- a comment on the value line must not leak into the override ------------
write_toml <<'TOML'
model_provider = "OpenAI"
model_context_window = 1000000   # bumped for long reviews
TOML
rec=$(run_codex)
case "$rec" in *"[-c] [model_context_window=1000000]"*) pass "trailing comment is stripped" ;; *) fail "comment leaked into override: $rec" ;; esac

# --- absent knobs are not forged --------------------------------------------
write_toml <<'TOML'
model_provider = "OpenAI"
TOML
rec=$(run_codex)
case "$rec" in *"model_context_window"*) fail "absent context window must not be sent: $rec" ;; *) pass "absent context window sends no override" ;; esac
case "$rec" in *"service_tier"*) fail "absent service tier must not be sent: $rec" ;; *) pass "absent service tier sends no override" ;; esac
case "$rec" in *"disable_response_storage"*) fail "absent storage flag must not be sent: $rec" ;; *) pass "absent storage flag sends no override" ;; esac

# --- non-numeric / hostile values are rejected -------------------------------
write_toml <<'TOML'
model_provider = "OpenAI"
model_context_window = "1000000"
model_auto_compact_token_limit = 900000
TOML
rec=$(run_codex)
case "$rec" in *"model_auto_compact_token_limit=900000"*) pass "valid sibling still forwarded" ;; *) fail "valid sibling dropped: $rec" ;; esac

write_toml <<'TOML'
model_provider = "OpenAI"
model_context_window = 1000000
service_tier = "fast\"\n[projects.\"/untrusted\"]\ntrust_level = \"trusted"
disable_response_storage = maybe
TOML
rec=$(run_codex)
case "$rec" in *"/untrusted"*|*"trust_level"*) fail "service tier spliced attacker TOML: $rec" ;; *) pass "hostile service tier cannot splice TOML" ;; esac
case "$rec" in *"disable_response_storage"*) fail "non-boolean storage flag must be dropped: $rec" ;; *) pass "non-boolean storage flag is dropped" ;; esac
case "$rec" in *"[-c] [model_context_window=1000000]"*) pass "hostile neighbour does not block valid knob" ;; *) fail "valid knob lost: $rec" ;; esac

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: codex toml passthrough tests passed"
else
  echo "FAIL: $errors codex toml passthrough test(s) failed"
  exit 1
fi
