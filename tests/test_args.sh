#!/usr/bin/env bash
# lib/args.sh — --add-dir serialisation must survive a round trip, and the
# guard in front of its eval must actually hold.
#
# The guard used to be a blacklist of `;`, `&&`, `||`, backtick and `$(`.
# printf %q output never contains those unescaped, so the blacklist looked
# sufficient — but it let through process substitution (which executes),
# parameter expansion, tilde expansion and globbing (GHSA-8m99-vc82-25m4).
# A blacklist over shell metacharacters cannot be made complete; these tests
# pin the allowlist behaviour instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/args.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- round trip: whatever build_add_dir_string emits must come back intact ---
roundtrip() {
  local label="$1"; shift
  local s arr=()
  s=$(build_add_dir_string "$@")
  if ! expand_add_dir_string arr "$s"; then
    fail "$label — legitimate path rejected: $s"; return
  fi
  local want=() p
  for p in "$@"; do want+=(--add-dir "$p"); done
  if [[ "${arr[*]@Q}" == "${want[*]@Q}" ]]; then
    ok "$label"
  else
    fail "$label — got [${arr[*]}] want [${want[*]}]"
  fi
}

roundtrip "plain path"            /a/b
roundtrip "two paths"             /a/b /c/d
roundtrip "path with space"       "/a b/c"
roundtrip "path with quote"       "/a'b"
roundtrip "path with dollar"      '/a$b'
roundtrip "path with backtick"    '/a`b'
roundtrip "path with parens"      '/a(b)'
roundtrip "path with glob char"   '/a*b'
roundtrip "path with semicolon"   '/a;b'
roundtrip "path with pipe"        '/a|b'
roundtrip "literal tilde"         '~'
roundtrip "unicode path"          '/專案/測試'

empty_arr=(x)
expand_add_dir_string empty_arr ""
[[ ${#empty_arr[@]} -eq 0 ]] && ok "empty string yields empty array" \
  || fail "empty string should clear the array, got [${empty_arr[*]}]"

# --- the guard must reject anything that is not printf %q --add-dir pairs ----
refuses() {
  local label="$1" payload="$2"
  local arr=(sentinel)
  if expand_add_dir_string arr "$payload" 2>/dev/null; then
    fail "$label — accepted: $payload (produced [${arr[*]}])"
  elif [[ ${#arr[@]} -ne 0 ]]; then
    fail "$label — rejected but left the array populated: [${arr[*]}]"
  else
    ok "$label"
  fi
}

# GHSA-8m99-vc82-25m4: these four all slipped past the blacklist.
refuses "process substitution"  '--add-dir <(id)'
refuses "output substitution"   '--add-dir >(cat)'
refuses "parameter expansion"   '--add-dir ${HOME}'
refuses "bare parameter"        '--add-dir $HOME'
refuses "tilde expansion"       '--add-dir ~'
refuses "glob"                  '--add-dir /etc/pas*'
# Previously covered by the blacklist — must stay rejected.
refuses "command substitution"  '--add-dir $(id)'
refuses "backtick"              '--add-dir `id`'
refuses "semicolon chain"       '--add-dir /a; id'
refuses "and chain"             '--add-dir /a && id'
refuses "or chain"              '--add-dir /a || id'
# Structural: the payload must be --add-dir pairs and nothing else.
refuses "stray flag"            '--add-file /a'
refuses "bare path"             '/a/b'
refuses "odd number of tokens"  '--add-dir /a --add-dir'
refuses "redirection"           '--add-dir /a > /tmp/x'

# --- and the process-substitution payload must not have EXECUTED -------------
marker="$TMP/executed"
arr=()
if expand_add_dir_string arr "--add-dir <(touch '$marker'; echo done)" 2>/dev/null; then
  # Accepted: drain the substituted fd so the child has finished before we
  # look, otherwise this races and can report a false clean.
  [[ ${#arr[@]} -ge 2 ]] && cat "${arr[1]}" >/dev/null 2>&1
fi
[[ -e "$marker" ]] && fail "process substitution EXECUTED through the guard" \
  || ok "process substitution never executes"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
