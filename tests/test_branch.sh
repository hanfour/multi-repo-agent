#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/branch.sh"

errors=0

assert_action() { # ahead behind dirty upstream expected
  local got
  got=$(branch_sync_action "$1" "$2" "$3" "$4")
  if [[ "$got" != "$5" ]]; then
    echo "FAIL: branch_sync_action($1,$2,$3,$4) => '$got', expected '$5'"; errors=$((errors+1))
  fi
}

# Rule 1: no upstream wins over everything
assert_action 0 0 0 "(none)"          "no-upstream"
assert_action 3 5 2 "(none)"          "no-upstream"
# Rule 2: clean and even
assert_action 0 0 0 "origin/main"     "up-to-date"
# Rule 3: ahead only
assert_action 2 0 0 "origin/main"     "ahead-only"
assert_action 2 0 4 "origin/main"     "ahead-only"
# Rule 4: diverged (reported even when dirty)
assert_action 1 1 0 "origin/main"     "diverged"
assert_action 1 3 5 "origin/main"     "diverged"
# Rule 5: behind only + dirty => dirty-skip
assert_action 0 2 1 "origin/main"     "dirty-skip"
# Rule 6: behind only + clean => fast-forward
assert_action 0 2 0 "origin/main"     "fast-forward"

# --- get_branch_state against a fixture repo ---
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/upstream"
git -C "$TEST_DIR/upstream" init -b main --bare &>/dev/null

git clone "$TEST_DIR/upstream" "$TEST_DIR/repo" &>/dev/null
git -C "$TEST_DIR/repo" config user.email t@t.t
git -C "$TEST_DIR/repo" config user.name t
git -C "$TEST_DIR/repo" commit --allow-empty -m init &>/dev/null
git -C "$TEST_DIR/repo" push -u origin main &>/dev/null

state=$(get_branch_state "$TEST_DIR/repo")
if [[ "$(branch_state_get "$state" branch)" != "main" ]]; then
  echo "FAIL: expected branch=main, got: $state"; errors=$((errors+1))
fi
if [[ "$(branch_state_get "$state" upstream)" != "origin/main" ]]; then
  echo "FAIL: expected upstream=origin/main, got: $state"; errors=$((errors+1))
fi
if [[ "$(branch_state_get "$state" sync_action)" != "up-to-date" ]]; then
  echo "FAIL: expected sync_action=up-to-date, got: $state"; errors=$((errors+1))
fi

# Detached HEAD => branch=(detached), upstream=(none) => no-upstream
sha=$(git -C "$TEST_DIR/repo" rev-parse HEAD)
git -C "$TEST_DIR/repo" checkout "$sha" &>/dev/null
state=$(get_branch_state "$TEST_DIR/repo")
if [[ "$(branch_state_get "$state" branch)" != "(detached)" ]]; then
  echo "FAIL: expected branch=(detached), got: $state"; errors=$((errors+1))
fi
if [[ "$(branch_state_get "$state" sync_action)" != "no-upstream" ]]; then
  echo "FAIL: expected sync_action=no-upstream for detached, got: $state"; errors=$((errors+1))
fi
rm -rf "$TEST_DIR"

# --- branch_row_needs_attention (args: ahead behind dirty on_default) ---
if branch_row_needs_attention 0 0 0 true; then
  echo "FAIL: clean+on-default should NOT need attention"; errors=$((errors+1))
fi
if ! branch_row_needs_attention 1 0 0 true; then
  echo "FAIL: ahead>0 should need attention"; errors=$((errors+1))
fi
if ! branch_row_needs_attention 0 0 0 false; then
  echo "FAIL: off-default should need attention"; errors=$((errors+1))
fi
if ! branch_row_needs_attention 0 0 2 true; then
  echo "FAIL: dirty>0 should need attention"; errors=$((errors+1))
fi

# --- branch_format_row produces one line containing the key fields ---
row=$(branch_format_row "repo=api"$'\n'"branch=feat/x"$'\n'"upstream=origin/feat/x"$'\n'"ahead=2"$'\n'"behind=1"$'\n'"dirty=0"$'\n'"sync_action=diverged")
case "$row" in
  *api*feat/x*diverged*) : ;;
  *) echo "FAIL: row missing fields: $row"; errors=$((errors+1)) ;;
esac
if [[ "$(printf '%s' "$row" | wc -l | tr -d ' ')" != "0" ]]; then
  echo "FAIL: row should be a single line (no trailing newline)"; errors=$((errors+1))
fi

# --- branch_push_action (args: ahead behind upstream branch) ---
assert_push() { # ahead behind upstream branch expected
  local got
  got=$(branch_push_action "$1" "$2" "$3" "$4")
  if [[ "$got" != "$5" ]]; then
    echo "FAIL: branch_push_action($1,$2,$3,$4) => '$got', expected '$5'"; errors=$((errors+1))
  fi
}
# Rule 1: detached wins over no-upstream
assert_push 0 0 "(none)"      "(detached)" "skip-detached"
assert_push 5 0 "(none)"      "(detached)" "skip-detached"
# Rule 2: real branch, no upstream
assert_push 0 0 "(none)"      "feat/x"     "push-new"
assert_push 3 0 "(none)"      "feat/x"     "push-new"
# Rule 3: even
assert_push 0 0 "origin/main" "main"       "up-to-date"
# Rule 4: ahead only
assert_push 2 0 "origin/main" "main"       "push"
# Rule 5: diverged
assert_push 2 3 "origin/main" "main"       "skip-diverged"
# Rule 6: behind only
assert_push 0 4 "origin/main" "main"       "skip-behind"

# --- branch_state_json: jq-built object, correct types, injection-safe ---
STATE_A=$'repo=app\nbranch=feat/x\nupstream=origin/feat/x\nahead=2\nbehind=0\ndirty=1\nsync_action=ahead-only'
obj=$(branch_state_json "$STATE_A" false true)
printf '%s' "$obj" | jq -e . >/dev/null 2>&1 || { echo "FAIL: branch_state_json output is not valid JSON: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.repo')" == "app" ]] || { echo "FAIL: .repo wrong: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.branch')" == "feat/x" ]] || { echo "FAIL: .branch wrong: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.sync_action')" == "ahead-only" ]] || { echo "FAIL: .sync_action wrong: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '.ahead==2 and .behind==0 and .dirty==1' >/dev/null 2>&1 || { echo "FAIL: numeric fields wrong: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '(.ahead|type)=="number" and (.behind|type)=="number" and (.dirty|type)=="number"' >/dev/null 2>&1 || { echo "FAIL: ahead/behind/dirty should be JSON numbers: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '(.on_default|type)=="boolean" and (.needs_attention|type)=="boolean"' >/dev/null 2>&1 || { echo "FAIL: on_default/needs_attention should be JSON booleans: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '.on_default==false and .needs_attention==true' >/dev/null 2>&1 || { echo "FAIL: boolean values wrong: $obj"; errors=$((errors+1)); }

# injection-safety: a branch name with a double-quote stays valid JSON
STATE_Q=$'repo=app\nbranch=feat/q"x\nupstream=(none)\nahead=0\nbehind=0\ndirty=0\nsync_action=no-upstream'
objq=$(branch_state_json "$STATE_Q" true false)
printf '%s' "$objq" | jq -e . >/dev/null 2>&1 || { echo "FAIL: quote in branch name broke JSON: $objq"; errors=$((errors+1)); }
[[ "$(printf '%s' "$objq" | jq -r '.branch')" == 'feat/q"x' ]] || { echo "FAIL: quoted branch name not preserved: $objq"; errors=$((errors+1)); }

# guard: a non-boolean on_default is rejected (return non-zero, no JSON)
if branch_state_json "$STATE_A" notabool true >/dev/null 2>&1; then echo "FAIL: branch_state_json should reject a non-boolean on_default"; errors=$((errors+1)); fi

# --- branch status --json dispatch (real CLI via MRA_WORKSPACE) ---
# workspace: repo a on default branch (clean), repo b on a feature branch
WSJ=$(mktemp -d)
for r in a b; do
  git -C "$WSJ" init -b main "$r" &>/dev/null
  git -C "$WSJ/$r" config user.email t@t.t; git -C "$WSJ/$r" config user.name t
  git -C "$WSJ/$r" commit --allow-empty -m init &>/dev/null
done
git -C "$WSJ/b" checkout -b feat/x &>/dev/null

# 3. array of ALL repos (length 2, includes the needs_attention:false one)
out=$(MRA_WORKSPACE="$WSJ" bash "$SCRIPT_DIR/bin/mra.sh" branch status --json 2>/dev/null)
printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --json should output a JSON array: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq 'length')" == "2" ]] || { echo "FAIL: array should have 2 repos: $out"; errors=$((errors+1)); }
# 4. needs_attention correct: a (default, clean) false; b (feature branch) true
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="a") | .needs_attention')" == "false" ]] || { echo "FAIL: repo a needs_attention should be false: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="b") | .needs_attention')" == "true" ]] || { echo "FAIL: repo b needs_attention should be true: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="b") | .branch')" == "feat/x" ]] || { echo "FAIL: repo b branch should be feat/x: $out"; errors=$((errors+1)); }
# 5. stdout is clean: the whole thing parses as JSON (no header/log contamination)
printf '%s' "$out" | jq . >/dev/null 2>&1 || { echo "FAIL: --json stdout must be pure JSON: $out"; errors=$((errors+1)); }
case "$out" in *'[branch]'*|*REPO*BRANCH*) echo "FAIL: --json stdout must not contain table header / log tags: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WSJ"

# 6. empty workspace -> []
WSE=$(mktemp -d)
out=$(MRA_WORKSPACE="$WSE" bash "$SCRIPT_DIR/bin/mra.sh" branch status --json 2>/dev/null)
[[ "$(printf '%s' "$out" | jq -c '.')" == "[]" ]] || { echo "FAIL: empty workspace should yield []: $out"; errors=$((errors+1)); }
rm -rf "$WSE"

# 7. text mode (no --json) regression: still prints table header + the feature-branch row
WST=$(mktemp -d)
git -C "$WST" init -b main b &>/dev/null
git -C "$WST/b" config user.email t@t.t; git -C "$WST/b" config user.name t
git -C "$WST/b" commit --allow-empty -m init &>/dev/null
git -C "$WST/b" checkout -b feat/x &>/dev/null
out=$(MRA_WORKSPACE="$WST" bash "$SCRIPT_DIR/bin/mra.sh" branch status 2>/dev/null)
case "$out" in *REPO*BRANCH*) : ;; *) echo "FAIL: text mode should print the table header: $out"; errors=$((errors+1)) ;; esac
case "$out" in *feat/x*) : ;; *) echo "FAIL: text mode should show the feature branch row: $out"; errors=$((errors+1)) ;; esac
rm -rf "$WST"

# 8. failure-path stdout discipline: a repo whose fetch fails, with --fetch --json
WSF=$(mktemp -d)
git -C "$WSF" init -b main c &>/dev/null
git -C "$WSF/c" config user.email t@t.t; git -C "$WSF/c" config user.name t
git -C "$WSF/c" commit --allow-empty -m init &>/dev/null
git -C "$WSF/c" remote add origin /nonexistent/repo/path.git   # fetch will fail
ERRF=$(mktemp)
if out=$(MRA_WORKSPACE="$WSF" bash "$SCRIPT_DIR/bin/mra.sh" branch status --fetch --json 2>"$ERRF"); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: fetch-failure run should exit non-zero"; errors=$((errors+1)); }
printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: stdout should still be a JSON array despite fetch failure: $out"; errors=$((errors+1)); }
grep -q 'fetch failed' "$ERRF" || { echo "FAIL: fetch failure message should be on stderr: $(cat "$ERRF")"; errors=$((errors+1)); }
case "$out" in *'[branch]'*) echo "FAIL: stdout must not contain the [branch] log tag: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WSF" "$ERRF"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all branch tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
