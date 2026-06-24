#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pkb.sh"

errors=0
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

PROJ=$(mktemp -d)
PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules"
echo '{"version":2,"lastUpdated":"2026-01-01T00:00:00Z"}' > "$PKB/meta.json"
printf '**proj** | app | Node.js\nDemo\n' > "$PKB/identity.md"
# conventions.md has NO tagged lines -> exercises the verbatim fallback path
printf 'VERBATIM_CONVENTIONS_MARKER full text here\n' > "$PKB/conventions.md"

MRA_CONFIG=$(mktemp)

# flag ON -> verbatim conventions must be suppressed
printf '{"loadProjectMemory": true}\n' > "$MRA_CONFIG"
out=$(pkb_build_context "$PROJ" "" "full")
echo "$out" | grep -q 'VERBATIM_CONVENTIONS_MARKER' && fail "ON: verbatim conventions must be suppressed"
echo "$out" | grep -q 'proj' || fail "ON: identity (non-conventions context) must still load"

# flag OFF -> verbatim conventions present (legacy behaviour)
printf '{"loadProjectMemory": false}\n' > "$MRA_CONFIG"
out=$(pkb_build_context "$PROJ" "" "full")
echo "$out" | grep -q 'VERBATIM_CONVENTIONS_MARKER' || fail "OFF: verbatim conventions must load"

rm -rf "$PROJ"; rm -f "$MRA_CONFIG"

# _pkb_valid_doc: a generated PKB doc must be substantive — never an agent error
# string (a cut-off generator emits "Error: Reached max turns") nor trivially
# short. This guards the PKB from being polluted with garbage that the review
# agents would then consume as context.
_pkb_valid_doc "Error: Reached max turns (5)" && fail "valid_doc: must reject the max-turns error string"
_pkb_valid_doc "" && fail "valid_doc: must reject empty"
_pkb_valid_doc "   " && fail "valid_doc: must reject whitespace-only"
_pkb_valid_doc "short" && fail "valid_doc: must reject too-short output"
_pkb_valid_doc "# Conventions: proj

## Coding Style
[CONVENTION] prefer const; use type over interface; no any.
## Naming
[CONVENTION] kebab-case files, PascalCase components." || fail "valid_doc: must accept a real doc"

if [[ $errors -eq 0 ]]; then echo "PASS: all pkb_context tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
