#!/usr/bin/env bash
# Pure helpers + state-machine transitions for `mra dev`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev-agent.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- _dev_slugify ---
assert_eq "slugify lowercases + dashes"   "add-foo-bar"  "$(_dev_slugify 'Add Foo Bar!')"
assert_eq "slugify collapses separators"  "a-b"          "$(_dev_slugify '  a   ///  b  ')"

# --- _dev_parse_sentinel ---
assert_eq "DONE sentinel"        "DONE"               "$(_dev_parse_sentinel 'work done ===MRA-DEV-DONE===')"
assert_eq "BLOCKED carries reason" "BLOCKED:no docker" "$(_dev_parse_sentinel '===MRA-DEV-BLOCKED: no docker===')"
assert_eq "missing sentinel fail-safe" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'I analyzed but stopped')"
# DONE token must not be inferred from prose (false-green guard, mirrors review subsystem)
assert_eq "prose 'done' is not DONE" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'the task is done now')"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-state-machine tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
