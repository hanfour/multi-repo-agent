#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/personas.sh"
source "$SCRIPT_DIR/lib/test-audit.sh"

errors=0

# find_test_files returns empty on missing dir
output=$(find_test_files "/nonexistent")
if [[ -n "$output" ]]; then echo "FAIL: expected empty on missing dir"; errors=$((errors+1)); fi

# find_test_files finds *test* files
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/src" "$tmpdir/tests"
touch "$tmpdir/tests/foo.test.js" "$tmpdir/tests/bar_test.go" "$tmpdir/src/nothing.js"
output=$(find_test_files "$tmpdir")
if [[ "$output" != *"foo.test.js"* ]]; then echo "FAIL: missing foo.test.js"; errors=$((errors+1)); fi
if [[ "$output" != *"bar_test.go"* ]]; then echo "FAIL: missing bar_test.go"; errors=$((errors+1)); fi
if [[ "$output" == *"nothing.js"* ]]; then echo "FAIL: should not include nothing.js"; errors=$((errors+1)); fi
rm -rf "$tmpdir"

# build_audit_prompt must include ROLE and principles
prompt=$(build_audit_prompt "tests/foo.test.js" "describe('x')" "")
if [[ "$prompt" != *"ROLE: Test Architect"* ]]; then
  echo "FAIL: prompt missing ROLE"; errors=$((errors+1))
fi
if [[ "$prompt" != *"11 PRINCIPLES"* ]]; then
  echo "FAIL: prompt missing 11 PRINCIPLES"; errors=$((errors+1))
fi
if [[ "$prompt" != *"tests/foo.test.js"* ]]; then
  echo "FAIL: prompt missing file path"; errors=$((errors+1))
fi
if [[ "$prompt" != *"describe('x')"* ]]; then
  echo "FAIL: prompt missing file content"; errors=$((errors+1))
fi

# Language directive injection
prompt_lang=$(build_audit_prompt "tests/foo.test.js" "describe('x')" "Use 繁體中文 for output.")
if [[ "$prompt_lang" != *"Use 繁體中文 for output."* ]]; then
  echo "FAIL: prompt missing language directive"; errors=$((errors+1))
fi

# Build respects literal content: must not evaluate $(whoami) in file body
prompt_inj=$(build_audit_prompt "tests/foo.test.js" 'echo $(whoami) and `id`' "")
if [[ "$prompt_inj" != *'$(whoami)'* ]]; then
  echo "FAIL: file contents should be kept literal (no command substitution)"; errors=$((errors+1))
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all test-audit tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
