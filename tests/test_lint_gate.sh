#!/usr/bin/env bash
# The local lint gate and the CI blocking gate must agree on severity.
#
# They drifted: `make lint` ran `shellcheck -S warning` and exited 1 on 49
# findings, while CI blocked only on `-S error` and reported warnings with
# continue-on-error. A documented developer command that is permanently red
# teaches everyone to ignore its output, so a real `-S error` finding would
# have gone unread (#35).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$SCRIPT_DIR/.github/workflows/repo-tests.yml"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# Severity CI actually blocks on: the shellcheck run NOT marked
# continue-on-error.
ci_gate=$(awk '
  /continue-on-error:[[:space:]]*true/ { skip = 1 }
  /shellcheck -S/ {
    if (skip) { skip = 0; next }
    match($0, /-S [a-z]+/); print substr($0, RSTART + 3, RLENGTH - 3); exit
  }
' "$CI")

# Severity `make lint` gates on.
make_gate=$(awk '
  /^lint:/       { in_target = 1; next }
  /^[a-z-]+:/    { in_target = 0 }
  in_target && /shellcheck -S/ {
    match($0, /-S [a-z]+/); print substr($0, RSTART + 3, RLENGTH - 3); exit
  }
' "$SCRIPT_DIR/Makefile")

[[ -n "$ci_gate" ]]   && ok "found the CI blocking severity ($ci_gate)" \
                      || fail "could not read the CI blocking severity from $CI"
[[ -n "$make_gate" ]] && ok "found the make lint severity ($make_gate)" \
                      || fail "could not read the make lint severity from Makefile"

if [[ "$ci_gate" == "$make_gate" ]]; then
  ok "make lint and the CI gate agree on severity"
else
  fail "gate drift — CI blocks on '-S $ci_gate' but make lint uses '-S $make_gate'"
fi

# The gate must actually be clean, or it is not a gate.
if command -v shellcheck >/dev/null 2>&1; then
  if (cd "$SCRIPT_DIR" && shellcheck -S "${make_gate:-error}" lib/*.sh bin/*.sh tests/*.sh test.sh >/dev/null 2>&1); then
    ok "the tree is clean at the gate severity"
  else
    fail "make lint would fail on a clean checkout"
  fi
else
  ok "shellcheck absent — gate cleanliness not checked here"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
