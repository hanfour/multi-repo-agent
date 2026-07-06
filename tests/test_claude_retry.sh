#!/usr/bin/env bash
# Verify lib/claude-invoke.sh retries transient claude failures, retries empty
# output, does NOT retry non-transient errors, respects the retry cap, and
# surfaces (never silently swallows) claude's stderr on final failure.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; pass=$((pass+1)); }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)); }

# Make retries instant and deterministic.
sleep() { :; }
export MRA_CLAUDE_RETRY_DELAY=0
export MRA_CLAUDE_MAX_RETRIES=2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
COUNTER="$TMP/count"

# Stub `claude`. Behaviour is driven by files under $TMP so it survives the
# command-substitution subshell claude_invoke runs it in.
#   $TMP/fail_n  : emit a transient error to stderr + exit 1 for the first N calls
#   $TMP/empty_n : emit nothing (exit 0) for the first N calls
#   $TMP/mode    : "nontransient" -> always stderr "bad flag" + exit 1
claude() {
  local n; n=$(cat "$COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNTER"
  local mode; mode=$(cat "$TMP/mode" 2>/dev/null || echo "")
  if [[ "$mode" == "nontransient" ]]; then
    echo "error: unknown option --bogus" >&2; return 1
  fi
  local fail_n empty_n
  fail_n=$(cat "$TMP/fail_n" 2>/dev/null || echo 0)
  empty_n=$(cat "$TMP/empty_n" 2>/dev/null || echo 0)
  if [[ "$n" -le "$fail_n" ]]; then
    echo "API Error: Overloaded (529)" >&2; return 1
  fi
  if [[ "$n" -le "$empty_n" ]]; then
    return 0   # exit 0 but no stdout
  fi
  echo "OK-RESULT"
}

reset() { echo 0 > "$COUNTER"; rm -f "$TMP/fail_n" "$TMP/empty_n" "$TMP/mode"; }

# --- 1. transient error retried, then succeeds ---
reset; echo 2 > "$TMP/fail_n"
out=$(claude_invoke test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
if [[ "$out" == "OK-RESULT" && "$rc" -eq 0 && "$calls" -eq 3 ]]; then
  pass_test "transient error retried then succeeded (3 calls, rc 0)"
else
  fail_test "transient retry: out='$out' rc=$rc calls=$calls (want OK-RESULT/0/3)"
fi

# --- 2. empty output (exit 0) retried, then succeeds ---
reset; echo 2 > "$TMP/empty_n"
out=$(claude_invoke test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
if [[ "$out" == "OK-RESULT" && "$rc" -eq 0 && "$calls" -eq 3 ]]; then
  pass_test "empty output retried then succeeded (3 calls, rc 0)"
else
  fail_test "empty retry: out='$out' rc=$rc calls=$calls (want OK-RESULT/0/3)"
fi

# --- 3. non-transient error is NOT retried ---
reset; echo nontransient > "$TMP/mode"
out=$(claude_invoke test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
if [[ "$rc" -ne 0 && "$calls" -eq 1 ]]; then
  pass_test "non-transient error not retried (1 call, rc!=0)"
else
  fail_test "non-transient: rc=$rc calls=$calls (want rc!=0, calls=1)"
fi

# --- 4. retry cap respected (always transient) ---
reset; echo 99 > "$TMP/fail_n"
out=$(claude_invoke test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
# max=2 => 1 initial + 2 retries = 3 attempts total
if [[ "$rc" -ne 0 && "$calls" -eq 3 ]]; then
  pass_test "retry cap respected (3 attempts total, rc!=0)"
else
  fail_test "retry cap: rc=$rc calls=$calls (want rc!=0, calls=3)"
fi

# --- 5. final failure surfaces claude stderr (not swallowed) ---
reset; echo 99 > "$TMP/fail_n"
err=$(claude_invoke test -p "hi" 2>&1 >/dev/null)
if [[ "$err" == *"Overloaded"* || "$err" == *"529"* ]]; then
  pass_test "final failure surfaces claude stderr"
else
  fail_test "stderr not surfaced on failure: '$err'"
fi

# --- 6. _claude_is_transient classification ---
transient_ok=1
for s in "Overloaded" "rate limit exceeded" "HTTP 429" "500 Internal Server Error" \
         "request timed out" "connection reset by peer" "network error"; do
  _claude_is_transient 1 "$s" || { fail_test "should be transient: '$s'"; transient_ok=0; }
done
# standalone HTTP status codes are transient
for s in "returned 502 bad gateway" "status 429 too many requests" "got a 500" "ended with 504"; do
  _claude_is_transient 1 "$s" || { fail_test "should be transient (status code): '$s'"; transient_ok=0; }
done
# non-transient: unknown flag with exit 1, and any exit-0 case
_claude_is_transient 1 "unknown option --bogus" && { fail_test "should NOT be transient: bad flag"; transient_ok=0; }
_claude_is_transient 0 "Overloaded" && { fail_test "exit 0 is never a transient error"; transient_ok=0; }
# a 3-digit run INSIDE a larger number must NOT be read as a 5xx/429 status
_claude_is_transient 1 "processed 5000 files then a fatal syntax error" && { fail_test "5000 should NOT match 5xx"; transient_ok=0; }
_claude_is_transient 1 "fatal parse error at line 1500" && { fail_test "1500 should NOT match 5xx"; transient_ok=0; }
_claude_is_transient 1 "wrote 42900 bytes then aborted" && { fail_test "42900 should NOT match 429"; transient_ok=0; }
[[ "$transient_ok" -eq 1 ]] && pass_test "_claude_is_transient classifies transient vs fatal correctly"

# --- 7. --stream mode: retries a transient failure then streams stdout through ---
reset; echo 1 > "$TMP/fail_n"
out=$(claude_invoke --stream test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
if [[ "$out" == *"OK-RESULT"* && "$rc" -eq 0 && "$calls" -eq 2 ]]; then
  pass_test "--stream retries transient then streams output (2 calls, rc 0)"
else
  fail_test "--stream retry: out='$out' rc=$rc calls=$calls (want OK-RESULT/0/2)"
fi

# --- 8. --stream cannot see an empty zero-exit result, so it does NOT retry it ---
reset; echo 1 > "$TMP/empty_n"
out=$(claude_invoke --stream test -p "hi" 2>/dev/null); rc=$?
calls=$(cat "$COUNTER")
if [[ "$rc" -eq 0 && "$calls" -eq 1 ]]; then
  pass_test "--stream treats empty zero-exit as success (no retry, 1 call)"
else
  fail_test "--stream empty: rc=$rc calls=$calls (want rc 0, 1 call)"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
