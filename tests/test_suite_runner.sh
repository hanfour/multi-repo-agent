#!/usr/bin/env bash
# test.sh must never report success for a suite it did not run.
#
# It used to print "skipped: run 'npm --prefix mcp-server install' first" when
# mcp-server/node_modules was absent, leave NODE_RC at 0, and exit 0 — so a
# fresh checkout got a green summary while 24 TypeScript tests never executed
# (#34). CI installs deps and was unaffected, which is exactly why the hole
# survived: the only environments that hit it were local ones.
#
# Exercised against a throwaway tree so the real suite is not re-entered.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A tree with a declared mcp-server but no installed deps, and no shell tests,
# so the mcp-server outcome alone decides the exit status.
mkdir -p "$TMP/tests" "$TMP/mcp-server"
printf '%s\n' '{"name":"stub","scripts":{"test":"true"}}' > "$TMP/mcp-server/package.json"
cp "$SCRIPT_DIR/test.sh" "$TMP/test.sh"

out=$(bash "$TMP/test.sh" 2>&1); rc=$?

if [[ $rc -ne 0 ]]; then
  ok "uninstalled mcp-server deps make the run fail"
else
  fail "run exited 0 despite never executing the mcp-server suite"
fi

case "$out" in
  *"mcp-server : ok"*) fail "summary claims mcp-server ok when it did not run" ;;
  *)                   ok "summary does not claim mcp-server ok" ;;
esac

# The operator still needs to be told what to do about it.
case "$out" in
  *"npm --prefix mcp-server install"*) ok "summary keeps the remediation hint" ;;
  *) fail "remediation hint lost" ;;
esac

# Control: with deps present and passing, the same tree exits 0. Guards against
# fixing the fail-open by making the runner unconditionally fail.
mkdir -p "$TMP/mcp-server/node_modules"
out2=$(bash "$TMP/test.sh" 2>&1); rc2=$?
if [[ $rc2 -eq 0 ]]; then
  ok "installed deps with a passing suite still exit 0"
else
  fail "runner now fails even when the mcp-server suite passes: $out2"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
