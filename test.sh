#!/usr/bin/env bash
# Run every shell test under tests/ and the mcp-server node test suite.
# Emits a green/red summary and exits non-zero on any failure.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$MRA_DIR"

SHELL_PASS=0
SHELL_FAIL=0
FAILED_FILES=()

run_one() {
  local script="$1"
  local name
  name=$(basename "$script")
  printf '\n>>> %s\n' "$name"
  local logfile
  logfile=$(mktemp)
  if bash "$script" >"$logfile" 2>&1; then
    SHELL_PASS=$((SHELL_PASS + 1))
    tail -3 "$logfile" | sed 's/^/   /'
  else
    SHELL_FAIL=$((SHELL_FAIL + 1))
    FAILED_FILES+=("$name")
    tail -20 "$logfile" | sed 's/^/   /'
  fi
  rm -f "$logfile"
}

shopt -s nullglob
for script in "$MRA_DIR"/tests/test_*.sh; do
  [[ -f "$script" ]] || continue
  run_one "$script"
done
shopt -u nullglob

NODE_RC=0
NODE_NOTE=""
if [[ -f "$MRA_DIR/mcp-server/package.json" ]]; then
  printf '\n>>> mcp-server (npm test)\n'
  if [[ ! -d "$MRA_DIR/mcp-server/node_modules" ]]; then
    echo "   skipped: run 'npm --prefix mcp-server install' first"
    NODE_NOTE="(skipped: deps not installed)"
  else
    npm_log=$(mktemp)
    if (cd "$MRA_DIR/mcp-server" && npm test --silent) >"$npm_log" 2>&1; then
      tail -8 "$npm_log" | sed 's/^/   /'
    else
      NODE_RC=1
      tail -20 "$npm_log" | sed 's/^/   /'
    fi
    rm -f "$npm_log"
  fi
fi

printf '\n=== Summary ===\n'
printf 'shell tests: %d passed, %d failed\n' "$SHELL_PASS" "$SHELL_FAIL"
if [[ -n "$NODE_NOTE" ]]; then
  printf 'mcp-server : %s\n' "$NODE_NOTE"
elif [[ $NODE_RC -eq 0 ]]; then
  printf 'mcp-server : ok\n'
else
  printf 'mcp-server : failed\n'
fi

if (( SHELL_FAIL > 0 )); then
  printf '\nFailed shell tests:\n'
  printf '  - %s\n' "${FAILED_FILES[@]}"
fi

if (( SHELL_FAIL > 0 || NODE_RC != 0 )); then
  exit 1
fi
exit 0
