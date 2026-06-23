#!/usr/bin/env bash
# Verify lib/lint.sh#lint_load_profile resolves bundled and inline profiles.
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/lint.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/.collab"

# 1. No profile file -> default (empty rules).
rules=$(lint_load_profile "$WS")
if [[ "$(echo "$rules" | jq 'length')" == "0" ]]; then
  pass_test "missing lint-profile.json yields empty rules"
else
  fail_test "expected empty rules, got: $rules"
fi

# 2. {"profile":"ts-strict"} -> 5 rules from bundled template.
echo '{"profile":"ts-strict"}' > "$WS/.collab/lint-profile.json"
rules=$(lint_load_profile "$WS")
count=$(echo "$rules" | jq 'length')
if [[ "$count" == "5" ]]; then
  pass_test "ts-strict bundle resolves to 5 rules"
else
  fail_test "expected 5 ts-strict rules, got: $count"
fi

# 3. Inline rules win over profile name.
cat > "$WS/.collab/lint-profile.json" <<'JSON'
{
  "profile": "ts-strict",
  "rules": [
    { "id": "no-todo", "severity": "warn", "pattern": "TODO", "message": "TODO left in code", "line_excludes": [], "file_excludes": [] }
  ]
}
JSON
rules=$(lint_load_profile "$WS")
if [[ "$(echo "$rules" | jq -r '.[0].id')" == "no-todo" ]]; then
  pass_test "inline rules override bundled profile"
else
  fail_test "inline rules should override; got: $rules"
fi

# 4. Unknown profile name -> default (empty), with warning.
echo '{"profile":"does-not-exist"}' > "$WS/.collab/lint-profile.json"
rules=$(lint_load_profile "$WS" 2>/dev/null)
if [[ "$(echo "$rules" | jq 'length')" == "0" ]]; then
  pass_test "unknown profile name falls back to default"
else
  fail_test "unknown profile should fall back to default"
fi

# 5. Legacy 'oneAD' profile -> default, with a migration warning naming ts-strict.
echo '{"profile":"oneAD"}' > "$WS/.collab/lint-profile.json"
warn=$(lint_load_profile "$WS" 2>&1 >/dev/null)
rules=$(lint_load_profile "$WS" 2>/dev/null)
if [[ "$(echo "$rules" | jq 'length')" == "0" ]] && echo "$warn" | grep -q "ts-strict"; then
  pass_test "legacy 'oneAD' profile warns and points to ts-strict"
else
  fail_test "expected migration warning naming ts-strict; got rules=$rules warn=$warn"
fi

rm -rf "$WS"

echo ""
echo "=== lint-profile: $pass passed, $errors failed ==="
[[ $errors -eq 0 ]]
