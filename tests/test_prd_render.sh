#!/usr/bin/env bash
# prd_render_html: renders .collab markdown to sibling .html with guards.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/prd-issues.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"

# 1. Valid .collab markdown -> non-empty sibling .html, echoes the path.
MD="$WS/.collab/requirements/REQ-2026-0001.md"
printf '# Title\n\nbody\n' > "$MD"
out=$(prd_render_html "$MD"); rc=$?
assert_eq "render rc" "0" "$rc"
assert_eq "echoes html path" "${MD%.md}.html" "$out"
[[ -s "${MD%.md}.html" ]] && ok "html non-empty" || fail "html missing/empty"

# 2. Source OUTSIDE .collab -> refuse (no-repo-mutation guard).
OUT="$WS/notcollab.md"; printf '# x\n' > "$OUT"
prd_render_html "$OUT" >/dev/null 2>&1; assert_eq "refuse non-.collab source" "1" "$?"

# 3. Empty source -> fail loudly (render-html.py would still write a template).
EMPTY="$WS/.collab/requirements/REQ-2026-0002.md"; : > "$EMPTY"
prd_render_html "$EMPTY" >/dev/null 2>&1; assert_eq "empty source fails" "1" "$?"

# 4. Missing source -> fail.
prd_render_html "$WS/.collab/requirements/REQ-2026-9999.md" >/dev/null 2>&1; assert_eq "missing source fails" "1" "$?"

rm -rf "$WS"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-render tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
