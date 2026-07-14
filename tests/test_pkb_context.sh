#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"

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

# _pkb_keep_doc: invalid new output cleans a STALE-invalid dst, preserves a valid one
KD=$(mktemp -d)
printf 'Error: Reached max turns (5)\n' > "$KD/old_bad.md"
printf 'Error: Reached max turns (25)\n' > "$KD/new_bad.src"
_pkb_keep_doc "$KD/new_bad.src" "$KD/old_bad.md" 2>/dev/null
[[ -f "$KD/old_bad.md" ]] && fail "keep_doc: stale invalid dst must be removed"
printf '# Real Doc\n[CONVENTION] long enough real content to pass the length gate comfortably here.\n' > "$KD/old_good.md"
printf 'Error: Reached max turns\n' > "$KD/new_bad2.src"
_pkb_keep_doc "$KD/new_bad2.src" "$KD/old_good.md" 2>/dev/null
[[ -f "$KD/old_good.md" ]] || fail "keep_doc: valid prior dst must be preserved when regen flakes"
printf '# New Real\n[CONVENTION] enough real content here to be accepted as a valid document.\n' > "$KD/new_good.src"
_pkb_keep_doc "$KD/new_good.src" "$KD/target.md"
[[ -f "$KD/target.md" ]] || fail "keep_doc: valid new doc must be written to dst"
rm -rf "$KD"

if [[ $errors -eq 0 ]]; then echo "PASS: all pkb_context tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
