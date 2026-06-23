#!/usr/bin/env bash
# Regression tests for lib/ask.sh interactive-mode argv construction.
#
# Verifies that ask_project --interactive emits --setting-sources user,project
# so each --add-dir repo's gitignored CLAUDE.local.md is never pulled into the
# shared cross-repo context when project-memory loading is on (mirrors the
# guard already present in lib/launch.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"   # provides log_* helpers

errors=0
TEST_DIR=$(mktemp -d)
CAPTURE=$(mktemp)

FAKE_PROJ="proj-test"
FAKE_PROJ_DIR="$TEST_DIR/workspace/$FAKE_PROJ"
mkdir -p "$FAKE_PROJ_DIR"

# ---------------------------------------------------------------------------
# Stub the claude CLI: record exact argv to $CAPTURE, one arg per line.
# ---------------------------------------------------------------------------
claude() {
  : > "$CAPTURE"
  printf '%s\n' "$@" >> "$CAPTURE"
}

# ---------------------------------------------------------------------------
# Stub all collaborators that ask_project calls before line 133.
# We only need to reach the interactive branch; stubs keep the test hermetic.
# ---------------------------------------------------------------------------
resolve_project_dir()  { echo "$FAKE_PROJ_DIR"; return 0; }
get_dep_graph_path()   { echo "/no/such/graph"; }
list_all_projects()    { :; }
resolve_with_deps()    { echo "$FAKE_PROJ"; }
pkb_exists()           { return 1; }
pkb_build_context()    { echo ""; }
config_get()           { echo ""; }
display_deps()         { :; }

# Source ask.sh AFTER stubs so sourcing doesn't trigger side-effects.
source "$SCRIPT_DIR/lib/ask.sh"

fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# ---------------------------------------------------------------------------
# Case 1: interactive ask must include --setting-sources user,project
# ---------------------------------------------------------------------------
ask_project "$TEST_DIR/workspace" "$FAKE_PROJ" --interactive "What does this do?" \
  >/dev/null 2>&1

grep -qx -- '--setting-sources' "$CAPTURE" \
  || fail "interactive ask: --setting-sources flag missing from claude argv"

grep -qx -- 'user,project' "$CAPTURE" \
  || fail "interactive ask: expected setting-sources value 'user,project'"

# ---------------------------------------------------------------------------
# Case 2: --setting-sources must appear ONCE (not duplicated)
# ---------------------------------------------------------------------------
count=$(grep -cx -- '--setting-sources' "$CAPTURE" || true)
[[ "$count" -eq 1 ]] \
  || fail "interactive ask: --setting-sources should appear exactly once (got $count)"

# ---------------------------------------------------------------------------
# Case 3: --add-dir must still be present (the project dir must be injected)
# ---------------------------------------------------------------------------
grep -qx -- '--add-dir' "$CAPTURE" \
  || fail "interactive ask: --add-dir missing from claude argv"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$TEST_DIR" "$CAPTURE"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all ask tests passed"
else
  echo "FAIL: $errors test(s) failed"
  exit 1
fi
