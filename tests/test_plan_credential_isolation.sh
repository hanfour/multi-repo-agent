#!/usr/bin/env bash
# The plan path sends a prompt to a model too, and had none of the protections
# the review path grew.
#
# lib/model-provider.sh:call_model — reached by `mra plan --dual` and the plan
# council — invoked claude and codex with the operator's whole environment:
# GH_TOKEN readable, ~/.ssh and ~/.codex readable, no watchdog, stdin inherited.
# The review path unsets the tokens, redirects HOME, copies only the credential
# the provider needs, denies the rest through a sandbox, bounds the call and
# closes stdin. Same threat model, one of the two paths.
#
# The stdin and watchdog halves are the hang family issues #17/#18 fixed for
# reviews and left untouched here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This file asserts what does NOT reach the child, so it owns its credential
# environment rather than inheriting the developer's (see test_review_provider).
unset GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export MRA_CONFIG="$TMP/config.json"; echo '{"configVersion":2}' > "$MRA_CONFIG"
mkdir -p "$TMP/bin" "$TMP/proj" "$TMP/home/.codex"
printf '{"OPENAI_API_KEY":"plan-test-key"}\n' > "$TMP/home/.codex/auth.json"
mkdir -p "$TMP/home/.claude"
printf '{"claudeAiOauth":{"accessToken":"test-only-token"}}\n' > "$TMP/home/.claude/.credentials.json"
REC="$TMP/rec"; export REC

for lib in colors config review-verdict args claude-invoke review-provider model-provider; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/$lib.sh" 2>/dev/null || true
done

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: gh=${GH_TOKEN-unset} github=${GITHUB_TOKEN-unset} home=$HOME" >> "$REC"
echo "<claude-out>"
STUB
# Decisive stdin probe: the parent feeds a marker in. Reading it back means
# stdin was inherited; reading nothing means it was redirected away. Testing
# "is stdin at EOF" cannot tell /dev/null from a pipe nobody has written yet.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
line=""
IFS= read -r -t 2 line 2>/dev/null || true
stdin_state=closed
[[ "$line" == "PARENT-STDIN-MARKER" ]] && stdin_state=inherited
echo "codex: $* | gh=${GH_TOKEN-unset} github=${GITHUB_TOKEN-unset} home=$HOME stdin=$stdin_state" >> "$REC"
echo "<codex-out>"
STUB
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"

run_with_creds() {
  : > "$REC"
  GH_TOKEN=plan-secret GITHUB_TOKEN=plan-secret2 \
  HOME="$TMP/home" \
  MRA_CLAUDE_BIN="$TMP/bin/claude" MRA_CODEX_BIN="$TMP/bin/codex" \
    call_model "$1" "PROMPT" sonnet "$TMP/proj" "" 4 >/dev/null 2>&1 <<< "PARENT-STDIN-MARKER" || true
  cat "$REC"
}

# --- claude branch ----------------------------------------------------------
rec=$(run_with_creds claude)
case "$rec" in
  *"gh=unset github=unset"*) ok "claude child cannot read GitHub credentials" ;;
  *) fail "claude child inherited GitHub credentials: $rec" ;;
esac
case "$rec" in
  *"home=$TMP/home"*) fail "claude child runs with the operator's real HOME: $rec" ;;
  *) ok "claude child gets an isolated HOME" ;;
esac

# --- codex branch -----------------------------------------------------------
# The sandbox is what denies the model ~/.ssh, ~/.aws and ~/.codex. Where it is
# unavailable the isolation refuses to run codex at all rather than hand it the
# operator's credentials with only the env stripped — the same contract the
# review path has had, now shared. Linux CI exercises this branch; macOS the
# other.
rec=$(run_with_creds codex)

if ! command -v sandbox-exec >/dev/null 2>&1; then
  [[ -z "$rec" ]] && ok "codex is refused where no sandbox can be applied" \
                  || fail "codex ran unsandboxed with the operator's credentials: $rec"
  : > "$REC"
  out=$(GH_TOKEN=plan-secret HOME="$TMP/home" MRA_CODEX_BIN="$TMP/bin/codex" \
        MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 \
        call_model codex "PROMPT" sonnet "$TMP/proj" "" 4 2>&1 || true)
  esc=$(cat "$REC")
  case "$esc" in
    *"gh=unset"*) ok "the explicit escape hatch still strips the tokens" ;;
    "") fail "the escape hatch did not run codex at all: $out" ;;
    *) fail "the escape hatch leaked GitHub credentials: $esc" ;;
  esac
  grep -q 'watchdog\|alarm' "$SCRIPT_DIR/lib/model-provider.sh" \
    && ok "the plan path bounds its model call" \
    || fail "an unbounded model call can hang the plan indefinitely (#18's family)"
  echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
  exit $((errors > 0 ? 1 : 0))
fi
case "$rec" in
  *"gh=unset github=unset"*) ok "codex child cannot read GitHub credentials" ;;
  *) fail "codex child inherited GitHub credentials: $rec" ;;
esac
case "$rec" in
  *"home=$TMP/home"*) fail "codex child runs with the operator's real HOME: $rec" ;;
  *) ok "codex child gets an isolated HOME" ;;
esac
case "$rec" in
  *"stdin=inherited"*) fail "codex inherited stdin — the #18 freeze, unbounded: $rec" ;;
  *) ok "codex stdin is closed" ;;
esac

# codex must be sandboxed by exactly one layer, same rule as the review path.
if command -v sandbox-exec >/dev/null 2>&1; then
  case "$rec" in
    *"--dangerously-bypass-approvals-and-sandbox"*) ok "codex defers to the outer sandbox" ;;
    *) fail "codex nests its own sandbox inside mra's — every command fails: $rec" ;;
  esac
else
  case "$rec" in
    *"-s read-only"*|*"--sandbox read-only"*) ok "codex sandboxes itself when mra cannot" ;;
    *) fail "no sandbox on either layer: $rec" ;;
  esac
fi

# --- the call must be time-bounded -----------------------------------------
grep -q 'watchdog\|alarm' "$SCRIPT_DIR/lib/model-provider.sh" \
  && ok "the plan path bounds its model call" \
  || fail "an unbounded model call can hang the plan indefinitely (#18's family)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
