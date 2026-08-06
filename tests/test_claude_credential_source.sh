#!/usr/bin/env bash
# The review path redirects HOME so the model cannot read the operator's
# credentials, then copies in the one credential the provider needs. For claude
# it copied ~/.claude/.credentials.json — a file that does not exist on macOS,
# where the credential lives in the login Keychain.
#
# So every claude review on macOS ran unauthenticated. It surfaced as
#   claude failed (ec=1) after 1 attempt(s) with no stderr
# because "Not logged in · Please run /login" goes to stdout, not stderr.
#
# claude is the SECONDARY provider: codex fails, mra falls back to claude, and
# claude fails too. The fallback was dead exactly when it was needed, and the
# failure looked like "claude is also broken" rather than "we never gave it the
# credential".
#
# Redirecting HOME is what breaks it: macOS finds the login keychain at
# $HOME/Library/Keychains. Symlinking the keychain into the isolated HOME would
# work and would hand the model every secret in it — the opposite of the point.
# Extract the single item instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/review-provider.sh" 2>/dev/null || true

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- file source wins and is copied verbatim --------------------------------
SRC="$TMP/home-with-file"; mkdir -p "$SRC/.claude"
printf '{"claudeAiOauth":{"accessToken":"from-file"}}\n' > "$SRC/.claude/.credentials.json"
DEST="$TMP/model-a"; mkdir -p "$DEST/.claude"
MRA_SECURITY_KEYCHAIN_READER=/nonexistent \
  _review_provision_claude_credential "$SRC" "$DEST"
if [[ -s "$DEST/.claude/.credentials.json" ]] && grep -q 'from-file' "$DEST/.claude/.credentials.json"; then
  ok "an existing credentials file is used"
else
  fail "the file source was not copied"
fi
perms=$(stat -f '%Lp' "$DEST/.claude/.credentials.json" 2>/dev/null || stat -c '%a' "$DEST/.claude/.credentials.json" 2>/dev/null)
[[ "$perms" == "600" ]] && ok "copied credential is 0600" || fail "credential is $perms, not 0600"

# --- keychain fallback, used only when there is no file ---------------------
READER="$TMP/fake-security"
cat > "$READER" <<'STUB'
#!/usr/bin/env bash
printf '{"claudeAiOauth":{"accessToken":"from-keychain"}}\n'
STUB
chmod +x "$READER"

SRC2="$TMP/home-no-file"; mkdir -p "$SRC2/.claude"
DEST2="$TMP/model-b"; mkdir -p "$DEST2/.claude"
MRA_SECURITY_KEYCHAIN_READER="$READER" \
  _review_provision_claude_credential "$SRC2" "$DEST2"
if grep -q 'from-keychain' "$DEST2/.claude/.credentials.json" 2>/dev/null; then
  ok "the keychain is used when no file exists"
else
  fail "no credential was provisioned from the keychain"
fi

# The file must win — the keychain reader is a fallback, not an override.
DEST3="$TMP/model-c"; mkdir -p "$DEST3/.claude"
MRA_SECURITY_KEYCHAIN_READER="$READER" \
  _review_provision_claude_credential "$SRC" "$DEST3"
grep -q 'from-file' "$DEST3/.claude/.credentials.json" 2>/dev/null \
  && ok "an existing file takes precedence over the keychain" \
  || fail "the keychain overrode an existing credentials file"

# --- neither source: say so, do not hand the model a doomed call ------------
EMPTY_READER="$TMP/empty-security"
printf '#!/usr/bin/env bash\nexit 1\n' > "$EMPTY_READER"; chmod +x "$EMPTY_READER"
DEST4="$TMP/model-d"; mkdir -p "$DEST4/.claude"
out=$(MRA_SECURITY_KEYCHAIN_READER="$EMPTY_READER" \
      _review_provision_claude_credential "$SRC2" "$DEST4" 2>&1); rc=$?

[[ $rc -ne 0 ]] && ok "no credential anywhere is reported as a failure" \
                || fail "returned success with no credential — the call would fail later with no stderr"
case "$out" in
  *credential*|*login*) ok "the message names the problem" ;;
  *) fail "unhelpful message: $out" ;;
esac
[[ ! -s "$DEST4/.claude/.credentials.json" ]] && ok "no empty credential file is left behind" \
                                              || fail "wrote an empty credential file"

# --- an ANTHROPIC_API_KEY is its own credential -----------------------------
DEST5="$TMP/model-e"; mkdir -p "$DEST5/.claude"
ANTHROPIC_API_KEY=sk-test-key MRA_SECURITY_KEYCHAIN_READER="$EMPTY_READER" \
  _review_provision_claude_credential "$SRC2" "$DEST5" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "ANTHROPIC_API_KEY counts as authenticated" \
               || fail "refused despite an API key in the environment"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
