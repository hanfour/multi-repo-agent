#!/usr/bin/env bash
# Verify lib/project-path.sh rejects unsafe project names and resolves safe ones.
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/project-path.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/web-api" "$WS/.collab"
# Symlink that escapes the workspace — should be rejected by realpath containment check.
mkdir -p "$WS/../escape-target"
ln -s "$WS/../escape-target" "$WS/escape-link"

# --- validate_project_name: rejects unsafe patterns ---
for bad in "" ".." "../etc" "/etc" "a/b" "a\\b" $'a\nb' ".hidden" "-leading-dash" "name with space" "$(printf 'ctrl\tname')" "$(printf 'a%0.s' {1..65})"; do
  if validate_project_name "$bad" 2>/dev/null; then
    fail_test "validate_project_name should reject: $(printf %q "$bad")"
  else
    pass_test "validate_project_name rejected: $(printf %q "$bad")"
  fi
done

# --- validate_project_name: accepts safe patterns ---
for good in "web-api" "user_service" "v0.5" "Alpha123" "a"; do
  if validate_project_name "$good" 2>/dev/null; then
    pass_test "validate_project_name accepted: $good"
  else
    fail_test "validate_project_name should accept: $good"
  fi
done

# --- resolve_project_dir: lexical reject ---
if resolve_project_dir "$WS" "../etc" >/dev/null 2>&1; then
  fail_test "resolve_project_dir should reject lexical traversal '../etc'"
else
  pass_test "resolve_project_dir rejected lexical traversal"
fi

# --- resolve_project_dir: realpath containment (symlink escape) ---
if resolve_project_dir "$WS" "escape-link" >/dev/null 2>&1; then
  fail_test "resolve_project_dir should reject symlink that escapes workspace"
else
  pass_test "resolve_project_dir rejected symlink escape"
fi

# --- resolve_project_dir: missing directory ---
if resolve_project_dir "$WS" "no-such-project" >/dev/null 2>&1; then
  fail_test "resolve_project_dir should fail when project directory does not exist"
else
  pass_test "resolve_project_dir rejected missing project"
fi

# --- resolve_project_dir: happy path returns absolute path under workspace ---
resolved=$(resolve_project_dir "$WS" "web-api" 2>/dev/null)
expected=$(cd "$WS/web-api" && pwd -P)
if [[ "$resolved" == "$expected" ]]; then
  pass_test "resolve_project_dir returned realpath for safe project"
else
  fail_test "resolve_project_dir returned '$resolved', expected '$expected'"
fi

# Cleanup
rm -rf "$WS" "$WS/../escape-target" 2>/dev/null

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
