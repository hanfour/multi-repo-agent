#!/usr/bin/env bash
# The bin/mra.sh `prd) --new` greenfield dispatch fork.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

MRA="$SCRIPT_DIR/bin/mra.sh"
WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"; printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS/.collab/dep-graph.json"
# a claude stub that records the injected system prompt
SHIM=$(mktemp -d); export SHIM_OUT=$(mktemp)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$SHIM_OUT"\n' > "$SHIM/claude"; chmod +x "$SHIM/claude"

run() { ( cd "$WS" && MRA_WORKSPACE="$WS" MRA_CLAUDE_BIN="$SHIM/claude" bash "$MRA" "$@" </dev/null ) 2>&1; }

# 1. --new <name> forks to greenfield: launched prompt contains the greenfield markers
: > "$SHIM_OUT"; rc_out=$(run prd --new billing); rc=$?
grep -q 'BRAND-NEW project' "$SHIM_OUT" && ok "--new forks to greenfield prompt" || fail "greenfield prompt not launched: $rc_out"
grep -q 'mra prd-scaffold' "$SHIM_OUT" && ok "greenfield instructs prd-scaffold" || fail "no scaffold handoff in prompt"
[[ "$(grep -cx -- '--add-dir' "$SHIM_OUT")" == "0" ]] && ok "greenfield loads zero repos" || fail "greenfield added --add-dir"

# 2. --new with a flag value is rejected (never captured as a repo name)
out=$(run prd --new --no-sync); rc=$?
[[ "$rc" -ne 0 ]] && ok "--new --no-sync rejected" || fail "--new captured a flag as name"

# 3. --new with a bad slug rejected
out=$(run prd --new -bad); [[ "$?" -ne 0 ]] && ok "--new -bad rejected" || fail "bad slug accepted"

# 4. --new with a stray positional rejected
out=$(run prd --new billing extra); [[ "$?" -ne 0 ]] && ok "--new + stray positional rejected" || fail "stray positional accepted"

# 5. greenfield does NOT reach list_all_projects/validate_repo_subset:
#    the dep-graph has zero projects; if the brownfield branch ran with no args it would
#    launch orchestrator/prd with 0 projects — assert the greenfield prompt ran instead (covered by #1).
rm -rf "$WS" "$SHIM" "$SHIM_OUT"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd dispatch tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
