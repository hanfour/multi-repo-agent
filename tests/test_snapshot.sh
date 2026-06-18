#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/project-path.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Setup: create workspace with dep-graph and a git repo
mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"myapp":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/myapp"
cd "$TEST_DIR/myapp"
git init -b main . &>/dev/null
git config user.email t@t
git config user.name t
echo "v1" > file.txt
git add file.txt && git -c commit.gpgsign=false commit -m "v1" &>/dev/null
COMMIT_V1=$(git rev-parse HEAD)

# --- Existing behaviour: create, rollback, list, delete ---
create_snapshot "$TEST_DIR" "test-snap" 2>/dev/null
snapshots_file=$(get_snapshots_file "$TEST_DIR")
[[ -f "$snapshots_file" ]] && pass_test "snapshots file created" || fail_test "snapshots file not created"

snap_count=$(jq 'length' "$snapshots_file")
[[ "$snap_count" == "1" ]] && pass_test "one snapshot recorded" || fail_test "should have 1 snapshot, got $snap_count"

# --- TM-009: create_snapshot embeds integrity hash ---
if jq -e '.[0].integrity | type == "string"' "$snapshots_file" >/dev/null 2>&1; then
  pass_test "snapshot carries integrity hash"
else
  fail_test "expected .[0].integrity string"
fi

# Make a v2 commit so we can verify rollback actually moves HEAD back.
cd "$TEST_DIR/myapp"
echo "v2" > file.txt
git add file.txt && git -c commit.gpgsign=false commit -m "v2" &>/dev/null
COMMIT_V2=$(git rev-parse HEAD)
[[ "$COMMIT_V1" != "$COMMIT_V2" ]] && pass_test "v1 and v2 commits differ" || fail_test "commits should differ"

# --- TM-009: rollback refuses without confirmation in non-interactive mode ---
unset MRA_ROLLBACK_FORCE || true
if rollback_project "$TEST_DIR" "myapp" "test-snap" </dev/null >/dev/null 2>&1; then
  fail_test "rollback should refuse without confirmation"
else
  pass_test "rollback refused without confirmation"
fi
current=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
[[ "$current" == "$COMMIT_V2" ]] && pass_test "HEAD did not move on refused rollback" || fail_test "HEAD moved unexpectedly: $current"

# --- TM-009: MRA_ROLLBACK_FORCE=1 bypasses the confirmation prompt ---
if MRA_ROLLBACK_FORCE=1 rollback_project "$TEST_DIR" "myapp" "test-snap" </dev/null >/dev/null 2>&1; then
  pass_test "MRA_ROLLBACK_FORCE=1 allowed rollback"
else
  fail_test "MRA_ROLLBACK_FORCE=1 should allow rollback"
fi
COMMIT_AFTER=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
[[ "$COMMIT_AFTER" == "$COMMIT_V1" ]] && pass_test "rollback restored v1 commit" || fail_test "expected $COMMIT_V1, got $COMMIT_AFTER"
[[ "$(cat "$TEST_DIR/myapp/file.txt")" == "v1" ]] && pass_test "rollback restored v1 file content" || fail_test "file content not v1"

# --- TM-009: integrity tamper detected and refused even with --force ---
tmp=$(mktemp)
jq '(.[] | select(.name=="test-snap") | .projects.myapp.commit) = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$snapshots_file" > "$tmp" && mv "$tmp" "$snapshots_file"
git -C "$TEST_DIR/myapp" reset --hard "$COMMIT_V2" -q
if MRA_ROLLBACK_FORCE=1 rollback_project "$TEST_DIR" "myapp" "test-snap" </dev/null >/dev/null 2>&1; then
  fail_test "tampered snapshot should be refused"
else
  pass_test "tampered snapshot was refused"
fi
current=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
[[ "$current" == "$COMMIT_V2" ]] && pass_test "HEAD did not move on tampered rollback" || fail_test "HEAD moved on tampered rollback"

# --- TM-009: explicit ignore-integrity flag re-enables the rollback ---
# Restore a real commit so rollback has a valid target; the hash is still
# stale (we never recomputed) so only the ignore flag should let it pass.
tmp=$(mktemp)
jq --arg c "$COMMIT_V1" '(.[] | select(.name=="test-snap") | .projects.myapp.commit) = $c' "$snapshots_file" > "$tmp" && mv "$tmp" "$snapshots_file"
if MRA_ROLLBACK_FORCE=1 MRA_ROLLBACK_IGNORE_INTEGRITY=1 \
     rollback_project "$TEST_DIR" "myapp" "test-snap" </dev/null >/dev/null 2>&1; then
  pass_test "MRA_ROLLBACK_IGNORE_INTEGRITY=1 bypassed stale hash"
else
  fail_test "ignore-integrity flag should allow rollback"
fi

# --- Stash failure must abort rollback before the destructive reset ---
# The confirmation prompt promises "uncommitted changes ... will be
# stashed"; if the stash fails, proceeding to `git reset --hard` would
# destroy the work the operator was told is safe.
command git -C "$TEST_DIR/myapp" reset --hard "$COMMIT_V2" -q
echo "dirty" >> "$TEST_DIR/myapp/file.txt"

# Mock git inside a subshell so the override stays scoped to this one test.
# A script-level git() would make shellcheck (SC2218) treat every real `git`
# call above as a reference to this later definition. rollback_project still
# resolves git() at call time within the subshell, so the stash-push mock holds.
rc=0
(
  git() {
    if [[ "$*" == *"stash push"* ]]; then return 1; fi
    command git "$@"
  }
  MRA_ROLLBACK_FORCE=1 MRA_ROLLBACK_IGNORE_INTEGRITY=1 \
    rollback_project "$TEST_DIR" "myapp" "test-snap" </dev/null >/dev/null 2>&1
) || rc=$?

[[ $rc -ne 0 ]] && pass_test "rollback failed when stash failed" || fail_test "rollback should fail when stash fails"
current=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
[[ "$current" == "$COMMIT_V2" ]] && pass_test "HEAD did not move after stash failure" || fail_test "HEAD moved despite stash failure"
grep -q "dirty" "$TEST_DIR/myapp/file.txt" && pass_test "uncommitted work preserved after stash failure" || fail_test "uncommitted work lost despite stash failure"
command git -C "$TEST_DIR/myapp" checkout -- file.txt

# --- rollback_all: continue past per-project failures, report at end ---
# Under `set -e` (as in bin/mra.sh) a failing rollback_project must not
# abort the loop and silently leave a partial rollback.
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"aaa":{"type":"rails-api","deps":{},"consumedBy":[]},"myapp":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF
mkdir -p "$TEST_DIR/aaa"
cd "$TEST_DIR/aaa"
git init -b main . &>/dev/null
git config user.email t@t
git config user.name t
echo "a1" > a.txt
git add a.txt && git -c commit.gpgsign=false commit -m "a1" &>/dev/null

command git -C "$TEST_DIR/myapp" reset --hard "$COMMIT_V2" -q
create_snapshot "$TEST_DIR" "all-snap" 2>/dev/null

# Break "aaa" (sorts before myapp in the rollback loop) and move myapp
# away from the snapshotted commit so the rollback has real work to do.
rm -rf "$TEST_DIR/aaa/.git"
command git -C "$TEST_DIR/myapp" reset --hard "$COMMIT_V1" -q

rc=0
out=$( (set -e; MRA_ROLLBACK_FORCE=1 rollback_all "$TEST_DIR" "all-snap" </dev/null) 2>&1 ) || rc=$?

[[ $rc -ne 0 ]] && pass_test "rollback_all reported failure" || fail_test "rollback_all should return non-zero when a project fails"
current=$(git -C "$TEST_DIR/myapp" rev-parse HEAD)
[[ "$current" == "$COMMIT_V2" ]] && pass_test "rollback_all continued past failing project" || fail_test "rollback_all aborted before rolling back myapp (got $current)"
echo "$out" | grep -qi "fail" && pass_test "rollback_all summarized failures" || fail_test "rollback_all should summarize failures in output"
delete_snapshot "$TEST_DIR" "all-snap" 2>/dev/null

# --- Existing: list_snapshots output ---
output=$(list_snapshots "$TEST_DIR" 2>&1)
[[ "$output" == *"test-snap"* ]] && pass_test "list_snapshots shows test-snap" || fail_test "list should show test-snap"

# --- Existing: delete_snapshot ---
delete_snapshot "$TEST_DIR" "test-snap" 2>/dev/null
snap_count=$(jq 'length' "$snapshots_file")
[[ "$snap_count" == "0" ]] && pass_test "delete_snapshot removed entry" || fail_test "should have 0 snapshots after delete, got $snap_count"

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
