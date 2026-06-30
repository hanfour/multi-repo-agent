#!/usr/bin/env bash
# prd_launch context assembly + REQ-id allocation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/launch.sh"
source "$SCRIPT_DIR/lib/prd.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

WS=$(mktemp -d); mkdir -p "$WS/fe/.git" "$WS/be/.git" "$WS/.collab/requirements"; printf '{}' > "$WS/g.json"

# REQ-id allocation: distinct under "concurrency"
a=$(_prd_alloc_req_id "$WS" 2026); b=$(_prd_alloc_req_id "$WS" 2026)
[[ "$a" != "$b" ]] && ok "alloc yields distinct ids ($a,$b)" || fail "alloc collided: $a==$b"
[[ "$a" =~ ^REQ-2026-[0-9]{4}$ ]] && ok "alloc id format" || fail "bad id: $a"

# prd_launch argv via stub
SHIM=$(mktemp -d); export SHIM_OUT=$(mktemp)
cat > "$SHIM/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SHIM_OUT"
SH
chmod +x "$SHIM/claude"; export MRA_CLAUDE_BIN="$SHIM/claude"
config_get() { echo ""; }; display_deps() { :; }
prd_launch "$WS" "$WS/g.json" fe be >/dev/null 2>&1
argv=$(cat "$SHIM_OUT")
grep -q 'PM/brainstorm\|mra prd session\|prd-issues --req' <<<"$argv" && ok "prd-agent prompt/fragments injected" || fail "prd prompt missing"
[[ "$(grep -c -- '--add-dir' <<<"$argv")" == "2" ]] && ok "two --add-dir (fe,be)" || fail "wrong add-dir count"
grep -q 'user,project' <<<"$argv" && ok "setting-sources" || fail "no setting-sources"
[[ -n "${MRA_PRD_REQ_ID:-}" ]] && ok "exports MRA_PRD_REQ_ID" || fail "no MRA_PRD_REQ_ID"
assert_eq "exports MRA_PRD_PROJECTS" "fe be" "${MRA_PRD_PROJECTS:-}"

rm -rf "$WS" "$SHIM"; unset MRA_CLAUDE_BIN
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-cli tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
