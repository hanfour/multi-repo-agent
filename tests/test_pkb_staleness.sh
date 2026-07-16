#!/usr/bin/env bash
# PKB staleness (issue #20): a git blob-hash snapshot is recorded at PKB
# generation; pkb_build_context prepends an explicit ⚠️ banner naming files
# that changed since — committed drift AND working-tree changes, including
# deletions — so agents never silently consume a stale PKB. Files already
# dirty at generation time (their content is IN the PKB) are not stale
# unless they changed again.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pkb.sh"
source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-query.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
printf '{"loadProjectMemory": true}\n' > "$MRA_CONFIG"
export MRA_CONFIG

make_project() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf 'alpha\n' > "$dir/a.txt"
  printf 'beta\n' > "$dir/b.txt"
  git -C "$dir" add . && git -C "$dir" commit -qm init
  local pkb="$dir/.mra/pkb"; mkdir -p "$pkb/modules"
  pkb_init_meta "$dir" "proj"
  printf '**proj** | app | Node.js\nDemo\n' > "$pkb/identity.md"
}

# --- 1. Fresh snapshot, no changes: no banner ---
PROJ=$(mktemp -d); make_project "$PROJ"
pkb_record_snapshot "$PROJ" 2>/dev/null
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:"; then
  fail "clean tree must have no staleness banner"
else
  pass "clean tree has no staleness banner"
fi

# --- 2. Uncommitted modification: banner names the file ---
printf 'alpha changed\n' >> "$PROJ/a.txt"
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:" && echo "$out" | grep -q "a.txt"; then
  pass "uncommitted modification triggers banner naming a.txt"
else
  fail "uncommitted modification: banner missing or file not named: $(echo "$out" | head -3)"
fi

# --- 3. Committed drift (snapshot commit != HEAD): still stale ---
git -C "$PROJ" add a.txt && git -C "$PROJ" commit -qm change
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:" && echo "$out" | grep -q "a.txt"; then
  pass "committed drift triggers banner naming a.txt"
else
  fail "committed drift: banner missing or file not named"
fi

# --- 4. Re-recording the snapshot (PKB refreshed) clears the banner ---
pkb_record_snapshot "$PROJ" 2>/dev/null
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:"; then
  fail "re-recorded snapshot must clear the banner"
else
  pass "re-recorded snapshot clears the banner"
fi

# --- 5. Deletion is detected ---
rm "$PROJ/b.txt"
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:" && echo "$out" | grep -q "b.txt"; then
  pass "deletion triggers banner naming b.txt"
else
  fail "deletion: banner missing or file not named"
fi
git -C "$PROJ" checkout -q -- b.txt

# --- 6. File dirty at generation time, unchanged since: NOT stale ---
printf 'gamma dirty\n' > "$PROJ/c.txt"   # untracked+dirty BEFORE snapshot
pkb_record_snapshot "$PROJ" 2>/dev/null
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:"; then
  fail "file dirty at snapshot time but unchanged must not be stale"
else
  pass "file dirty at snapshot time but unchanged is not stale"
fi
printf 'gamma changed again\n' > "$PROJ/c.txt"
out=$(pkb_build_context "$PROJ" "" "minimal")
if echo "$out" | grep -q "^⚠️ PKB STALENESS:" && echo "$out" | grep -q "c.txt"; then
  pass "dirty-at-snapshot file changed AGAIN is stale"
else
  fail "dirty-at-snapshot file changed again: banner missing or file not named"
fi

# --- 7. Banner caps the file list ---
rm "$PROJ/c.txt"; pkb_record_snapshot "$PROJ" 2>/dev/null
for i in $(seq 1 25); do printf 'x\n' > "$PROJ/f$i.txt"; done
out=$(pkb_build_context "$PROJ" "" "minimal")
listed=$(echo "$out" | grep -c "f[0-9]*\.txt" || true)
if [[ "$listed" -le 20 ]] && echo "$out" | grep -q "more"; then
  pass "banner caps the list ($listed listed) and notes the overflow"
else
  fail "banner cap: listed=$listed, overflow note missing"
fi
rm -rf "$PROJ"

# --- 8. Non-git project: no banner, no crash ---
NOGIT=$(mktemp -d)
mkdir -p "$NOGIT/.mra/pkb/modules"
echo '{"version":2,"lastUpdated":"2026-01-01T00:00:00Z"}' > "$NOGIT/.mra/pkb/meta.json"
printf '**p** | app | x\n' > "$NOGIT/.mra/pkb/identity.md"
out=$(pkb_build_context "$NOGIT" "" "minimal" 2>&1)
if echo "$out" | grep -q "^⚠️ PKB STALENESS:"; then
  fail "non-git project must not emit a banner"
else
  pass "non-git project: no banner, no crash"
fi
rm -rf "$NOGIT"

# --- 9. pkb_incremental_update gate: snapshot-clean tree skips, dirty tree proceeds ---
PROJ=$(mktemp -d); make_project "$PROJ"
mkdir -p "$PROJ/src/chat"; printf 'code\n' > "$PROJ/src/chat/x.ts"
git -C "$PROJ" add . && git -C "$PROJ" commit -qm src
pkb_record_snapshot "$PROJ" 2>/dev/null
log=$(pkb_incremental_update "proj" "$PROJ" "src/chat/x.ts" "haiku" "" 2>&1)
if echo "$log" | grep -qi "no source changes"; then
  pass "incremental update skips on a snapshot-clean tree"
else
  fail "incremental update did not skip on clean tree: $log"
fi
rm -rf "$PROJ"

rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: pkb staleness tests passed"
else
  echo "FAIL: $errors pkb staleness test(s) failed"
  exit 1
fi
