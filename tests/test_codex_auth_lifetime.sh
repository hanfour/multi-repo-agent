#!/usr/bin/env bash
# Codex auth-file lifetime (issue #17): the temp CODEX_HOME auth.json must
# survive for the whole codex invocation (stream reconnects re-read it), be
# removed promptly after the process exits, and the opt-in TTL timer must
# neither outlive the invocation (wait-on-sleeper hang) nor stay on by default.
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
source "$SCRIPT_DIR/lib/review-post.sh"
source "$SCRIPT_DIR/lib/review-pr-discussion.sh"
source "$SCRIPT_DIR/lib/review-strategy.sh"
source "$SCRIPT_DIR/lib/review-json.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project" "$TMP/dep"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init

REC="$TMP/rec"; export REC
mkdir -p "$TMP/home/.codex"
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"
export HOME="$TMP/home"
export MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1
add_dirs=$(build_add_dir_string "$TMP/dep")

# Stub that reads the auth file twice: at startup and again after a delay —
# the second read models a codex stream-reconnect re-reading auth.json.
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
a1=$([[ -e "$HOME/.codex/auth.json" ]] && echo present || echo absent)
sleep "${CODEX_STUB_RECONNECT_DELAY:-2}"
a2=$([[ -e "$HOME/.codex/auth.json" ]] && echo present || echo absent)
echo "auth1=$a1 auth2=$a2" >> "$REC"
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"

# --- 1. Default (no TTL env): auth survives a mid-run reconnect re-read ---
: > "$REC"
unset MRA_CODEX_AUTH_FILE_TTL_SECONDS
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "")
rec=$(cat "$REC")
[[ "$out" == "<codex-output>" ]] && pass "default lifetime: codex output returned" || fail "default lifetime: output wrong: $out"
case "$rec" in
  *"auth1=present auth2=present"*) pass "default lifetime: auth file survives reconnect re-read" ;;
  *) fail "default lifetime: auth file vanished mid-run (stream reconnect would 401): $rec" ;;
esac
[[ -z "$(find "$TMP" -maxdepth 1 -name 'model-home.*' -print -quit)" ]] \
  && pass "default lifetime: model HOME (and auth copy) cleaned up after exit" \
  || fail "default lifetime: model HOME leaked"

# --- 2. Opt-in TTL=0 still deletes immediately (explicit tight window) ---
: > "$REC"
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 CODEX_STUB_RECONNECT_DELAY=1 \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "")
rec=$(cat "$REC")
case "$rec" in
  *"auth2=absent"*) pass "opt-in TTL=0: auth file deleted during execution" ;;
  *) fail "opt-in TTL=0: auth file not deleted: $rec" ;;
esac

# --- 3. A large opt-in TTL must not block the return (no wait-on-sleeper) ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"
start=$SECONDS
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=8 \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "")
elapsed=$((SECONDS - start))
if [[ "$elapsed" -lt 5 ]]; then
  pass "opt-in TTL=8: call returns promptly after codex exit (${elapsed}s)"
else
  fail "opt-in TTL=8: call blocked ${elapsed}s waiting for the TTL sleeper (issue #18 hang path)"
fi
[[ "$out" == "<codex-output>" ]] && pass "opt-in TTL=8: codex output returned" || fail "opt-in TTL=8: output wrong: $out"

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: codex auth lifetime tests passed"
else
  echo "FAIL: $errors codex auth lifetime test(s) failed"
  exit 1
fi
