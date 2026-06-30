#!/usr/bin/env bash
# Regression tests for lib/launch.sh argv construction.
#
# The claude CLI rejects mixing --append-system-prompt with
# --append-system-prompt-file. launch_claude must therefore emit AT MOST ONE
# --append-system-prompt flag and NEVER the --file variant, regardless of how
# many fragments (orchestrator prompt, output-language directive, PKB context)
# it has to combine.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"   # provides log_* helpers
source "$SCRIPT_DIR/lib/launch.sh"

errors=0
TEST_DIR=$(mktemp -d)
CAPTURE=$(mktemp)
mkdir -p "$TEST_DIR/workspace/proj-a"

# Stub claude: record the exact argv it receives, one arg per line. An arg that
# itself contains newlines (the combined system prompt) spans several lines —
# fine, because we assert on flag lines and substring presence separately.
claude() {
  : > "$CAPTURE"
  printf '%s\n' "$@" >> "$CAPTURE"
  printf 'ENV:%s\n' "${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD:-unset}" >> "$CAPTURE"
}

# Stub launch_claude collaborators so the test stays hermetic.
pkb_exists()        { return 1; }
pkb_build_context() { echo ""; }
display_deps()      { :; }

# Run launch_claude with a chosen outputLanguage value ("" disables it).
run_launch() {
  local lang="$1"
  config_get() { [[ "$1" == "outputLanguage" ]] && printf '%s' "$lang" || printf ''; }
  launch_claude "$TEST_DIR/workspace" "/no/such/graph" "proj-a" >/dev/null 2>&1
}

# grep -c counts matching lines; -x forces a whole-line match so the bare flag
# is counted but the value line that may start with "--..." text is not.
file_flag_count()   { grep -cx -- '--append-system-prompt-file' "$CAPTURE" || true; }
inline_flag_count() { grep -cx -- '--append-system-prompt'      "$CAPTURE" || true; }

fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# --- Case 1: orchestrator + output language (the bug repro) ---
run_launch "繁體中文台灣用語"
[[ "$(file_flag_count)" == "0" ]]   || fail "case1: --append-system-prompt-file must never be emitted (got $(file_flag_count))"
[[ "$(inline_flag_count)" == "1" ]] || fail "case1: expected exactly one --append-system-prompt (got $(inline_flag_count))"
grep -qx -- '--add-dir' "$CAPTURE"                  || fail "case1: --add-dir missing"
grep -q 'Multi-Repo Orchestrator' "$CAPTURE"        || fail "case1: orchestrator prompt not inlined"
grep -q 'Output Language: 繁體中文台灣用語' "$CAPTURE" || fail "case1: output language directive missing"

# --- Case 2: orchestrator only (no output language configured) ---
run_launch ""
[[ "$(file_flag_count)" == "0" ]]   || fail "case2: --append-system-prompt-file must never be emitted (got $(file_flag_count))"
[[ "$(inline_flag_count)" == "1" ]] || fail "case2: expected exactly one --append-system-prompt (got $(inline_flag_count))"
grep -q 'Multi-Repo Orchestrator' "$CAPTURE"   || fail "case2: orchestrator prompt not inlined"
grep -q 'Output Language:' "$CAPTURE"           && fail "case2: language directive should be absent"

# --- Case 1b: interactive launch must restrict setting-sources to user,project ---
run_launch "繁體中文台灣用語"
grep -qx -- '--setting-sources' "$CAPTURE" || fail "case1b: --setting-sources missing"
grep -qx -- 'user,project'      "$CAPTURE" || fail "case1b: expected setting-sources value user,project"

# --- Case 3: child claude inherits the project-memory env var ---
source "$SCRIPT_DIR/lib/project-memory.sh"
PM_CONFIG=$(mktemp)
config_get() { jq -r ".$1" "$PM_CONFIG"; }   # real read against the temp config

printf '{"loadProjectMemory": true}\n' > "$PM_CONFIG"; apply_project_memory_env
launch_claude "$TEST_DIR/workspace" "/no/such/graph" "proj-a" >/dev/null 2>&1
grep -qx -- 'ENV:1' "$CAPTURE" || fail "case3: child must see ENV:1 when flag ON"

printf '{"loadProjectMemory": false}\n' > "$PM_CONFIG"; apply_project_memory_env
launch_claude "$TEST_DIR/workspace" "/no/such/graph" "proj-a" >/dev/null 2>&1
grep -qx -- 'ENV:unset' "$CAPTURE" || fail "case3: child must see ENV:unset when flag OFF"
rm -f "$PM_CONFIG"

rm -rf "$TEST_DIR" "$CAPTURE"

# --- Regression guard: MRA_CLAUDE_BIN shim (extraction seam) ---
# These assertions must FAIL before _launch_interactive is extracted (current
# code calls bare `claude` bash-function, not MRA_CLAUDE_BIN, so the shim is
# never invoked and SHIM_OUT stays empty).  They must PASS after extraction.
SHIM_DIR=$(mktemp -d)
SHIM_OUT_FILE=$(mktemp)
export SHIM_OUT="$SHIM_OUT_FILE"
cat > "$SHIM_DIR/claude" <<'SHIMSCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SHIM_OUT"
SHIMSCRIPT
chmod +x "$SHIM_DIR/claude"
export MRA_CLAUDE_BIN="$SHIM_DIR/claude"

SHIM_WS=$(mktemp -d)
mkdir -p "$SHIM_WS/fe"
printf '{}' > "$SHIM_WS/dep-graph.json"
config_get() { [[ "$1" == "outputLanguage" ]] && echo "正體中文" || echo ""; }

launch_claude "$SHIM_WS" "$SHIM_WS/dep-graph.json" fe >/dev/null 2>&1
shim_argv=$(cat "$SHIM_OUT_FILE")
asp_count=$(grep -cx -- '--append-system-prompt' <<<"$shim_argv" || true)
[[ "$asp_count" == "1" ]] || fail "shim: expected exactly one --append-system-prompt (got $asp_count)"
grep -q -- '--setting-sources' <<<"$shim_argv" || fail "shim: no --setting-sources"
grep -q 'user,project' <<<"$shim_argv" || fail "shim: wrong setting-sources value"
grep -q 'Multi-Repo Orchestrator' <<<"$shim_argv" || fail "shim: orchestrator prompt missing"
grep -q '正體中文' <<<"$shim_argv" || fail "shim: lang directive missing"

rm -rf "$SHIM_DIR" "$SHIM_WS" "$SHIM_OUT_FILE"
unset MRA_CLAUDE_BIN SHIM_OUT

if [[ $errors -eq 0 ]]; then
  echo "PASS: all launch tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
