#!/usr/bin/env bash
# Verify every user-supplied <project> CLI entry point rejects path
# traversal names and symlink escapes via resolve_project_dir, instead
# of joining "$workspace/$project" with only a -d check (TM-001).
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WS="$TMP/ws"
mkdir -p "$WS/.collab" "$TMP/evil" "$TMP/bin"
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{"version":1,"workspace":"test","projects":{}}
JSON

# Symlink inside the workspace that resolves outside it.
ln -s "$TMP/evil" "$WS/escape-link"

# Stub claude/gh/codex so a missing rejection cannot reach real tools.
for tool in claude gh codex; do
  printf '#!/usr/bin/env bash\necho "{}"\nexit 0\n' > "$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done

REJECT_PATTERN='disallowed characters|traversal|outside workspace|project-path'

# run_mra <args...> — runs the CLI against the test workspace with stubs.
run_mra() {
  MRA_WORKSPACE="$WS" PATH="$TMP/bin:$PATH" \
    bash "$MRA_DIR/bin/mra.sh" "$@" 2>&1
}

# expect_reject <label> <args...> — command must fail AND emit a
# project-path rejection.
expect_reject() {
  local label="$1"; shift
  local out rc=0
  out=$(run_mra "$@") || rc=$?
  if [[ $rc -ne 0 ]] && echo "$out" | grep -qE "$REJECT_PATTERN"; then
    pass_test "$label rejected"
  else
    fail_test "$label should reject (rc=$rc, out=${out:0:200})"
  fi
}

# --- CLI entry points: lexical traversal name ---
expect_reject "analyze ../evil"     analyze "../evil"
expect_reject "plan ../evil"        plan "../evil" "do something"
expect_reject "test-audit ../evil"  test-audit "../evil"
expect_reject "review ../evil"      review "../evil"
expect_reject "eval-review ../evil" eval-review "../evil" --pr 1
expect_reject "load ../evil"        "../evil" --no-sync

# --- CLI entry points: symlink escape (passes lexical check) ---
expect_reject "analyze escape-link" analyze "escape-link"

# --- rollback_project: function-level ---
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/config.sh"
source "$MRA_DIR/lib/deps.sh"
source "$MRA_DIR/lib/snapshot.sh"

out=""
rc=0
out=$(MRA_ROLLBACK_FORCE=1 rollback_project "$WS" "../evil" "any" 2>&1) || rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -qE "$REJECT_PATTERN"; then
  pass_test "rollback_project ../evil rejected"
else
  fail_test "rollback_project ../evil should reject (rc=$rc, out=${out:0:200})"
fi

rc=0
out=$(MRA_ROLLBACK_FORCE=1 rollback_project "$WS" "escape-link" "any" 2>&1) || rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -qE "$REJECT_PATTERN"; then
  pass_test "rollback_project escape-link rejected"
else
  fail_test "rollback_project escape-link should reject (rc=$rc, out=${out:0:200})"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
