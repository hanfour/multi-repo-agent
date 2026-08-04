#!/usr/bin/env bash
# macOS refuses a nested sandbox whose profile is deny-default. codex applies
# exactly such a profile for every tool command it runs, so wrapping codex in
# mra's own sandbox-exec made every command fail with
# `sandbox-exec: sandbox_apply: Operation not permitted` — no file reads, no
# grep, no git, on every macOS machine. Measured A/B against a real codex run.
#
# The fix tells codex not to sandbox itself (its own flag documents this as
# "intended solely for running in environments that are externally sandboxed")
# and moves write protection into mra's profile, which is then the only
# boundary left. These tests pin that second half: an outer profile that allows
# writes everywhere would be strictly worse than what it replaced.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/review-provider.sh" 2>/dev/null || true

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; MODEL_HOME="$TMP/model-home"; WORK="$TMP/work"
mkdir -p "$FAKE_HOME/.ssh" "$MODEL_HOME/.codex" "$WORK"

PROFILE="$TMP/codex.sb"
_review_write_codex_sandbox_profile "$PROFILE" "$FAKE_HOME" "$MODEL_HOME" "$WORK"

[[ -s "$PROFILE" ]] && ok "profile written" || fail "profile not written"

grep -q '(deny file-write\*)' "$PROFILE" \
  && ok "writes are denied by default" \
  || fail "profile does not deny writes — it would be weaker than codex's own sandbox"

for d in "$MODEL_HOME" "$WORK"; do
  # The profile stores canonical paths (/var/... becomes /private/var/... on macOS).
  canon=$(cd "$d" && pwd -P)
  grep -qF "(allow file-write* (subpath \"$canon\"))" "$PROFILE" \
    && ok "writes allowed under $(basename "$d")" \
    || fail "codex cannot write to $canon — the review will not run"
done

grep -q 'file-write-data (literal "/dev/null")' "$PROFILE" \
  && ok "devices stay writable" || fail "denying /dev/null breaks ordinary shell redirection"

grep -q "deny file-read.*\.ssh" "$PROFILE" \
  && ok "credential denial is preserved" || fail "credential denial was lost"

# --- the profile must behave, not merely read correctly ---------------------
if command -v sandbox-exec >/dev/null 2>&1; then
  sandbox-exec -f "$PROFILE" /bin/sh -c 'exit 0' 2>/dev/null \
    && ok "profile is accepted by sandbox-exec" || fail "profile is malformed"

  sandbox-exec -f "$PROFILE" /bin/sh -c "echo x > '$WORK/probe'" 2>/dev/null \
    && ok "workspace is writable under the profile" || fail "workspace write blocked"

  # The target that matters: the checked-out source the model is reviewing. A
  # temp-dir path would not prove anything, since the model home lives there.
  ESCAPE="$SCRIPT_DIR/.sandbox-escape-probe"
  rm -f "$ESCAPE"
  if sandbox-exec -f "$PROFILE" /bin/sh -c "echo x > '$ESCAPE'" 2>/dev/null; then
    fail "the model could write into the repository under review"
    rm -f "$ESCAPE"
  else
    ok "writes into the repository under review are refused"
  fi

  if sandbox-exec -f "$PROFILE" /bin/sh -c "cat '$FAKE_HOME/.ssh' >/dev/null" 2>/dev/null; then
    fail "credentials are readable under the profile"
  else
    ok "credentials are unreadable under the profile"
  fi

  sandbox-exec -f "$PROFILE" /bin/sh -c "head -c1 '$SCRIPT_DIR/README.md' >/dev/null" 2>/dev/null \
    && ok "source files remain readable" || fail "reading source is blocked — reviews need it"

  # codex runs shell commands through a pseudo-terminal. Denying /dev/ptmx does
  # not merely lose colour — the process cannot be created at all ("Failed to
  # create unified exec process"), so every command the model runs fails. That
  # is the same symptom the nested sandbox produced, from a different cause, and
  # the first write-denying profile reintroduced it.
  sandbox-exec -f "$PROFILE" /bin/sh -c 'exec 3<>/dev/ptmx' 2>/dev/null \
    && ok "a pty can be allocated" \
    || fail "/dev/ptmx is blocked — codex cannot create a process to run anything"
else
  ok "sandbox-exec absent — behavioural checks skipped"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
