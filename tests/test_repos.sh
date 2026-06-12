#!/usr/bin/env bash
# Verify lib/repos.sh list helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/repos.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

# --- repos_sorted_entries: emits one compact object per repo, sorted by name ---
input='[{"name":"zeta","description":"z"},{"name":"alpha","description":"a"},{"name":"mid","description":"m"}]'
output=$(repos_sorted_entries "$input")

line_count=$(echo "$output" | wc -l | tr -d ' ')
[[ "$line_count" == "3" ]] && pass_test "emits one line per repo" || fail_test "expected 3 lines, got $line_count"

first=$(echo "$output" | head -1 | jq -r '.name')
last=$(echo "$output" | tail -1 | jq -r '.name')
[[ "$first" == "alpha" && "$last" == "zeta" ]] && pass_test "entries sorted by name" || fail_test "expected alpha..zeta, got $first..$last"

# --- malformed input falls back to unsorted emission rather than dying ---
unsorted='[{"name":"b"},{"name":"a"}]'
output=$(repos_sorted_entries "$unsorted")
[[ -n "$output" ]] && pass_test "non-empty output for valid input" || fail_test "output empty"

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
