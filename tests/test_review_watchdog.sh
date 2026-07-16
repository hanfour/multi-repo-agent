#!/usr/bin/env bash
# Provider watchdog (issue #18): a codex child that hangs (or waits on stdin
# that never closes) must never block mra forever — the invocation is bounded
# by MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS (default 900, 0 disables) and codex
# gets /dev/null stdin so it cannot wait for input mra never sends.
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

mkdir -p "$TMP/home/.codex"
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"
export HOME="$TMP/home"
export MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1
add_dirs=$(build_add_dir_string "$TMP/dep")

# --- 1. Hung codex child is killed by the watchdog and reported ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
sleep 60
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"
errlog="$TMP/errlog"
start=$SECONDS
rc=0
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS=2 \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "" 2>"$errlog") || rc=$?
elapsed=$((SECONDS - start))
if [[ "$elapsed" -lt 30 ]]; then
  pass "watchdog: hung codex bounded in ${elapsed}s"
else
  fail "watchdog: hung codex blocked ${elapsed}s (unbounded wait)"
fi
[[ "$rc" -ne 0 ]] && pass "watchdog: timeout surfaces as non-zero rc ($rc)" || fail "watchdog: timeout returned rc=0"
if grep -qi "timed out" "$errlog"; then
  pass "watchdog: timeout is reported explicitly"
else
  fail "watchdog: no timeout message in stderr: $(tail -3 "$errlog" 2>/dev/null)"
fi

# --- 2. Codex must not inherit a caller stdin that never closes ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"
start=$SECONDS
rc=0
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS=60 \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "" < <(sleep 8)) || rc=$?
elapsed=$((SECONDS - start))
if [[ "$elapsed" -lt 5 ]]; then
  pass "stdin: codex gets immediate EOF instead of the caller's open pipe (${elapsed}s)"
else
  fail "stdin: codex blocked ${elapsed}s waiting for caller stdin EOF"
fi
[[ "$out" == "<codex-output>" ]] && pass "stdin: codex output returned" || fail "stdin: output wrong: $out"

# --- 3. Watchdog explicitly disabled (=0) still returns output normally ---
start=$SECONDS
out=$(MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_CODEX_BIN="$BIN/codex" \
  MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS=0 \
  review_call_model review codex "PROMPT" "" "$TMP/project" "$add_dirs" 6 "")
[[ "$out" == "<codex-output>" ]] && pass "disabled: MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS=0 runs unwrapped" || fail "disabled: output wrong: $out"

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review watchdog tests passed"
else
  echo "FAIL: $errors review watchdog test(s) failed"
  exit 1
fi
