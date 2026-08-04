#!/usr/bin/env bash
# Run every shell test under tests/ and the mcp-server node test suite.
# Emits a green/red summary and exits non-zero on any failure.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$MRA_DIR"

SHELL_PASS=0
SHELL_FAIL=0
FAILED_FILES=()

# Logs of FAILING tests are kept here so a failure can be diagnosed after the
# fact. run_one used to print `tail -20` inline and immediately delete the log,
# so a failure that scrolled past — or any invocation that filtered stdout —
# lost the detail permanently. That is how an observed 97-of-98 run became
# unreproducible (#52). Passing tests clean up after themselves.
TEST_LOG_DIR="${MRA_TEST_LOG_DIR:-$MRA_DIR/.mra-test-logs}"
rm -rf "$TEST_LOG_DIR"
mkdir -p "$TEST_LOG_DIR"

run_one() {
  local script="$1"
  local name
  name=$(basename "$script")
  printf '\n>>> %s\n' "$name"
  local logfile="$TEST_LOG_DIR/${name%.sh}.log"
  if bash "$script" >"$logfile" 2>&1; then
    SHELL_PASS=$((SHELL_PASS + 1))
    tail -3 "$logfile" | sed 's/^/   /'
    rm -f "$logfile"
  else
    SHELL_FAIL=$((SHELL_FAIL + 1))
    FAILED_FILES+=("$name")
    # Prefix every line with the test name: filtering this stream (a grep for
    # a summary line, a CI log search) must still say WHICH test produced it.
    tail -20 "$logfile" | sed "s|^|   [$name] |"
  fi
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
    # A suite that could not run is not a suite that passed. Leaving NODE_RC at
    # 0 here made a fresh checkout print a green summary while the whole
    # TypeScript suite sat unexecuted (#34).
    echo "   NOT RUN: deps missing — run 'npm --prefix mcp-server install' first"
    NODE_RC=1
    NODE_NOTE="NOT RUN (deps not installed) — counted as a failure, not a pass"
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
  printf '\nFull logs kept for diagnosis: %s\n' "$TEST_LOG_DIR"
else
  rmdir "$TEST_LOG_DIR" 2>/dev/null || true
fi

if (( SHELL_FAIL > 0 || NODE_RC != 0 )); then
  exit 1
fi
exit 0
