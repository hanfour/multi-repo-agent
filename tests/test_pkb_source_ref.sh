#!/usr/bin/env bash
# PKB analysis reads the selected remote ref without changing the local checkout.
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mra-pkb-source-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_HOME="$TEST_TMP/home"
STUB_BIN="$TEST_TMP/bin"
MRA_CONFIG_FILE="$TEST_TMP/config.json"
AGENT_LOG="$TEST_TMP/agent-seen.log"
mkdir -p "$TEST_HOME" "$STUB_BIN"
export HOME="$TEST_HOME"
printf '{"outputLanguage": null}\n' > "$MRA_CONFIG_FILE"

cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
project_dir=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--add-dir" && $# -gt 1 ]]; then
    project_dir="$2"
    shift 2
  else
    shift
  fi
done

marker="unknown"
if [[ -f "$project_dir/LOCAL_ONLY_MARKER" ]]; then
  marker="checkout"
elif [[ -f "$project_dir/DEVELOPMENT_MARKER" ]]; then
  marker="development"
elif [[ -f "$project_dir/MAIN_MARKER" ]]; then
  marker="main"
fi
printf '%s\n' "$marker" >> "$MRA_TEST_AGENT_LOG"

if [[ "${MRA_TEST_AGENT_FAIL:-0}" == "1" ]]; then
  printf 'Error: synthetic agent failure\n'
  exit 0
fi
cat <<'DOC'
# Generated Analysis

This document describes the synthetic repository structure, stable components,
data flow, and conventions observed by the test agent. The content is long
enough to pass the knowledge base document validation rules.
DOC
STUB
chmod +x "$STUB_BIN/claude"

errors=0
passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }

setup_repo() {
  local label="$1" clone_mode="${2:-}" case_dir="$TEST_TMP/$1"
  CASE_DIR="$case_dir"
  WORKSPACE="$case_dir/workspace"
  ORIGIN="$case_dir/origin.git"
  SEED="$case_dir/seed"
  CLONE="$WORKSPACE/sample-app"
  mkdir -p "$WORKSPACE/.collab" "$SEED"
  git init --bare -q "$ORIGIN"
  git -C "$SEED" init -q
  git -C "$SEED" config user.email test@example.com
  git -C "$SEED" config user.name Test
  printf 'main source\n' > "$SEED/MAIN_MARKER"
  git -C "$SEED" add .
  GIT_AUTHOR_DATE='2025-01-01T00:00:00+00:00' GIT_COMMITTER_DATE='2025-01-01T00:00:00+00:00' \
    git -C "$SEED" commit -qm 'main baseline'
  git -C "$SEED" branch -M main
  git -C "$SEED" remote add origin "$ORIGIN"
  git -C "$SEED" push -q -u origin main
  git -C "$SEED" checkout -qb development
  printf 'development source\n' > "$SEED/DEVELOPMENT_MARKER"
  git -C "$SEED" add .
  GIT_AUTHOR_DATE='2025-01-02T03:04:05+00:00' GIT_COMMITTER_DATE='2025-01-02T03:04:05+00:00' \
    git -C "$SEED" commit -qm 'development baseline'
  git -C "$SEED" push -q -u origin development
  git -C "$SEED" checkout -qb feature/stale main
  printf 'stale feature source\n' > "$SEED/FEATURE_MARKER"
  git -C "$SEED" add .
  GIT_AUTHOR_DATE='2025-01-03T00:00:00+00:00' GIT_COMMITTER_DATE='2025-01-03T00:00:00+00:00' \
    git -C "$SEED" commit -qm 'stale feature baseline'
  git -C "$SEED" push -q -u origin feature/stale
  git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
  if [[ "$clone_mode" == "single-branch" ]]; then
    git clone -q --single-branch --branch feature/stale "$ORIGIN" "$CLONE"
  else
    git clone -q --branch feature/stale "$ORIGIN" "$CLONE"
  fi
  printf 'uncommitted checkout file\n' > "$CLONE/LOCAL_ONLY_MARKER"
  write_repos_json development
}

write_repos_json() {
  local ref="${1:-}"
  if [[ -n "$ref" ]]; then
    jq -n --arg ref "$ref" '{repos:[{name:"sample-app",clone:true,branch:"main",pkbRef:$ref}]}' \
      > "$WORKSPACE/.collab/repos.json"
  else
    printf '{"repos":[{"name":"sample-app","clone":true,"branch":"main"}]}\n' \
      > "$WORKSPACE/.collab/repos.json"
  fi
}

run_analyze() {
  MRA_WORKSPACE="$WORKSPACE" MRA_CONFIG="$MRA_CONFIG_FILE" \
    MRA_TEST_AGENT_LOG="$AGENT_LOG" MRA_PKB_FROM_REF="${MRA_PKB_FROM_REF:-1}" \
    HOME="$TEST_HOME" \
    PATH="$STUB_BIN:$PATH" bash "$MRA_DIR/bin/mra.sh" analyze sample-app "$@"
}

run_capture() {
  local rc=0
  LAST_OUTPUT=$(run_analyze "$@" 2>&1) || rc=$?
  return "$rc"
}

capture_checkout() {
  local label="$1"
  git -C "$CLONE" rev-parse HEAD > "$CASE_DIR/$label.head"
  git -C "$CLONE" symbolic-ref --quiet --short HEAD > "$CASE_DIR/$label.branch" || printf 'detached\n' > "$CASE_DIR/$label.branch"
  git -C "$CLONE" status --porcelain=v2 --branch --untracked-files=all > "$CASE_DIR/$label.status"
  cksum "$CLONE/LOCAL_ONLY_MARKER" > "$CASE_DIR/$label.local-checksum"
  git -C "$CLONE" stash list --format='%H %gd %gs' > "$CASE_DIR/$label.stash"
}

assert_checkout_unchanged() {
  local label="$1"
  if cmp -s "$CASE_DIR/$label.head" "$CASE_DIR/after.head" && \
      cmp -s "$CASE_DIR/$label.branch" "$CASE_DIR/after.branch" && \
      cmp -s "$CASE_DIR/$label.status" "$CASE_DIR/after.status" && \
      cmp -s "$CASE_DIR/$label.local-checksum" "$CASE_DIR/after.local-checksum" && \
      cmp -s "$CASE_DIR/$label.stash" "$CASE_DIR/after.stash"; then
    pass "$label preserved HEAD, branch, status, local content, and stash list"
  else
    fail "$label changed HEAD, branch, status, local content, or stash list"
  fi
}

pkb_fingerprint() {
  if [[ -d "$CLONE/.mra/pkb" ]]; then
    find "$CLONE/.mra/pkb" -type f -exec cksum {} \; | sort
  else
    printf 'absent\n'
  fi
}

assert_worktree_clean() {
  local paths clone_real
  clone_real=$(cd "$CLONE" && pwd -P)
  paths=$(git -C "$CLONE" worktree list --porcelain | awk '$1 == "worktree" { print $2 }')
  if [[ "$paths" == "$clone_real" ]]; then
    pass "no temporary worktree remains"
  else
    fail "temporary worktree remains registered: $paths"
  fi
}

assert_agent_marker() {
  local expected="$1" count
  count=$(grep -c "^$expected$" "$AGENT_LOG" 2>/dev/null || true)
  if [[ "$count" -ge 4 ]]; then
    pass "PKB generators read the $expected source"
  else
    fail "expected four generators to read $expected; got $count"
  fi
}

assert_source_meta() {
  local expected_ref="$1" expected_sha="$2" expected_date="$3" expected_fetched="$4"
  if jq -e --arg ref "$expected_ref" --arg sha "$expected_sha" --arg date "$expected_date" \
      --argjson fetched "$expected_fetched" \
      '.sourceRef == $ref and .sourceSha == $sha and .sourceCommitDate == $date and .sourceFetched == $fetched' \
      "$CLONE/.mra/pkb/meta.json" >/dev/null; then
    pass "metadata records $expected_ref provenance"
  else
    fail "metadata has incorrect provenance for $expected_ref"
  fi
}

setup_repo primary
git -C "$CLONE" stash push -u -m 'test baseline stash' >/dev/null
git -C "$CLONE" stash apply >/dev/null
dev_sha=$(git --git-dir="$ORIGIN" rev-parse refs/heads/development)
dev_date=$(git --git-dir="$ORIGIN" show -s --format=%cI refs/heads/development)
main_sha=$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)
main_date=$(git --git-dir="$ORIGIN" show -s --format=%cI refs/heads/main)

# pkbRef wins over the existing branch field and the clone's stale checkout.
: > "$AGENT_LOG"
capture_checkout pkbref
if run_capture; then pass "pkbRef analyze succeeds"; else fail "pkbRef analyze failed: $LAST_OUTPUT"; fi
assert_agent_marker development
assert_source_meta origin/development "$dev_sha" "$dev_date" true
capture_checkout after
assert_checkout_unchanged pkbref
assert_worktree_clean
if jq -e --arg tmp "$TEST_TMP" '[.. | strings | select(contains($tmp))] | length == 0' \
    "$CLONE/.mra/pkb/meta.json" >/dev/null; then
  pass "metadata contains no deleted temporary path"
else
  fail "metadata points into the removed temporary worktree"
fi
if jq -e '([(.sourceMtimes // {}) | keys[]] | all(startswith("/") | not)) and ([ (.snapshotDirty // {}) | keys[] ] | all(startswith("/") | not))' \
    "$CLONE/.mra/pkb/meta.json" >/dev/null; then
  pass "mtime and snapshot baselines use relative paths"
else
  fail "mtime or snapshot baseline contains an absolute path"
fi

source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/pkb.sh"
source "$MRA_DIR/lib/pkb-cache.sh"
source "$MRA_DIR/lib/pkb-query.sh"
config_get() { printf 'true\n'; }
incremental_log=$(pkb_incremental_update sample-app "$CLONE" "LOCAL_ONLY_MARKER" 2>&1)
if [[ "$incremental_log" == *"skipping incremental update"* ]]; then
  pass "incremental update skips a ref-built PKB"
else
  fail "incremental update did not skip a ref-built PKB: $incremental_log"
fi
stale_report=$(pkb_stale_files "$CLONE")
if [[ "$stale_report" == "built from origin/development@${dev_sha:0:7} on $dev_date" ]]; then
  pass "ref-built PKB freshness reports its source commit without checkout files"
else
  fail "ref-built PKB freshness reported unexpected checkout staleness: $stale_report"
fi
source_context=$(pkb_build_context "$CLONE" "" "minimal")
if [[ "$source_context" == *"PKB SOURCE: built from origin/development@${dev_sha:0:7} on $dev_date"* && \
    "$source_context" != *"LOCAL_ONLY_MARKER"* ]]; then
  pass "review context shows ref provenance without checkout file warnings"
else
  fail "review context has incorrect ref freshness: $source_context"
fi

# Explicit --ref overrides the configured pkbRef.
: > "$AGENT_LOG"
capture_checkout explicit
if run_capture --ref main; then pass "explicit --ref analyze succeeds"; else fail "explicit --ref analyze failed: $LAST_OUTPUT"; fi
assert_agent_marker main
assert_source_meta origin/main "$main_sha" "$main_date" true
capture_checkout after
assert_checkout_unchanged explicit
assert_worktree_clean

# Explicit refspec fetch works in a single-branch clone.
setup_repo single_branch single-branch
: > "$AGENT_LOG"
capture_checkout single_branch
if run_capture; then pass "single-branch ref analyze succeeds"; else fail "single-branch analyze failed: $LAST_OUTPUT"; fi
assert_agent_marker development
assert_source_meta origin/development "$dev_sha" "$dev_date" true
capture_checkout after
assert_checkout_unchanged single_branch
assert_worktree_clean

# origin/HEAD is the next source when pkbRef is absent.
git -C "$CLONE" remote set-head origin development
write_repos_json
: > "$AGENT_LOG"
capture_checkout origin_head
if run_capture; then pass "origin/HEAD analyze succeeds"; else fail "origin/HEAD analyze failed: $LAST_OUTPUT"; fi
assert_agent_marker development
assert_source_meta origin/development "$dev_sha" "$dev_date" true
capture_checkout after
assert_checkout_unchanged origin_head
assert_worktree_clean

# A failed local fetch can use the cached remote tracking ref.
git -C "$CLONE" remote set-url origin "$CASE_DIR/missing-origin.git"
write_repos_json development
: > "$AGENT_LOG"
capture_checkout fetch_fallback
if run_capture; then pass "cached-ref fallback analyze succeeds"; else fail "cached-ref fallback failed: $LAST_OUTPUT"; fi
assert_agent_marker development
if [[ "$LAST_OUTPUT" == *"using cached origin/development at $dev_date"* ]]; then
  pass "fetch failure warning includes cached commit date"
else
  fail "fetch failure warning omitted the cached commit date"
fi
assert_source_meta origin/development "$dev_sha" "$dev_date" false
capture_checkout after
assert_checkout_unchanged fetch_fallback
assert_worktree_clean

# A failed fetch without a cached remote ref falls back to the checkout.
git -C "$CLONE" update-ref -d refs/remotes/origin/development
write_repos_json development
: > "$AGENT_LOG"
capture_checkout missing_cached_ref
if run_capture; then pass "missing cached ref fallback analyze succeeds"; else fail "missing cached ref fallback failed: $LAST_OUTPUT"; fi
assert_agent_marker checkout
if [[ "$LAST_OUTPUT" == *"origin/development is unavailable"* ]]; then
  pass "missing cached ref warning names the unavailable source"
else
  fail "missing cached ref warning omitted the unavailable source"
fi
local_sha=$(git -C "$CLONE" rev-parse HEAD)
local_date=$(git -C "$CLONE" show -s --format=%cI HEAD)
assert_source_meta checkout:feature/stale "$local_sha" "$local_date" false
capture_checkout after
assert_checkout_unchanged missing_cached_ref
assert_worktree_clean

# Without pkbRef or origin/HEAD, analysis uses the current checkout as-is.
git -C "$CLONE" remote set-url origin "$ORIGIN"
git -C "$CLONE" remote set-head origin -d >/dev/null 2>&1 || true
write_repos_json
local_sha=$(git -C "$CLONE" rev-parse HEAD)
local_short=$(git -C "$CLONE" rev-parse --short=7 HEAD)
local_date=$(git -C "$CLONE" show -s --format=%cI HEAD)
: > "$AGENT_LOG"
capture_checkout checkout_fallback
if run_capture; then pass "checkout fallback analyze succeeds"; else fail "checkout fallback failed: $LAST_OUTPUT"; fi
assert_agent_marker checkout
if [[ "$LAST_OUTPUT" == *"current checkout feature/stale@$local_short"* ]]; then
  pass "fallback warning names branch and short SHA"
else
  fail "fallback warning omitted checkout branch and SHA"
fi
assert_source_meta checkout:feature/stale "$local_sha" "$local_date" false
capture_checkout after
assert_checkout_unchanged checkout_fallback

# Invalid refs are rejected before a lock, worktree, or PKB change.
before_pkb=$(pkb_fingerprint)
capture_checkout invalid_ref
if run_capture --ref 'bad ref'; then
  fail "invalid ref unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"invalid PKB source ref"* ]]; then pass "invalid ref is rejected clearly"; else fail "invalid ref error was unclear: $LAST_OUTPUT"; fi
fi
capture_checkout after
assert_checkout_unchanged invalid_ref
[[ ! -e "$CLONE/.mra/pkb.lock" ]] && pass "invalid ref creates no lock" || fail "invalid ref left a lock"
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "invalid ref leaves PKB unchanged" || fail "invalid ref changed the PKB"
assert_worktree_clean

# A lock owned by a dead process is recovered.
dead_pid=99999999
mkdir -p "$CLONE/.mra/pkb.lock"
printf '%s %s\n' "$dead_pid" "$(date +%s)" > "$CLONE/.mra/pkb.lock/owner"
capture_checkout stale_lock
if run_capture; then pass "dead-pid lock is recovered"; else fail "dead-pid lock recovery failed: $LAST_OUTPUT"; fi
if [[ "$LAST_OUTPUT" == *"removed stale PKB lock for pid $dead_pid"* ]]; then
  pass "stale lock recovery is logged"
else
  fail "stale lock recovery was not logged: $LAST_OUTPUT"
fi
capture_checkout after
assert_checkout_unchanged stale_lock
[[ ! -e "$CLONE/.mra/pkb.lock" ]] && pass "recovered lock is released" || fail "recovered lock remains"
assert_worktree_clean

# A live lock prevents generation without disturbing the checkout or PKB.
before_pkb=$(pkb_fingerprint)
mkdir -p "$CLONE/.mra/pkb.lock"
printf '%s %s\n' "$$" "$(date +%s)" > "$CLONE/.mra/pkb.lock/owner"
capture_checkout locked
if run_capture; then
  fail "held lock unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"PKB analysis already running"* ]]; then pass "held lock exits with a clear error"; else fail "held lock error was unclear: $LAST_OUTPUT"; fi
fi
capture_checkout after
assert_checkout_unchanged locked
[[ -d "$CLONE/.mra/pkb.lock" ]] && pass "held lock is left untouched" || fail "held lock was removed"
[[ -f "$CLONE/.mra/pkb.lock/owner" ]] && pass "live lock owner is preserved" || fail "live lock owner was removed"
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "held lock leaves PKB unchanged" || fail "held lock changed the PKB"
assert_worktree_clean
rm -f "$CLONE/.mra/pkb.lock/owner"
rmdir "$CLONE/.mra/pkb.lock"

# The opt-out keeps the old behavior and reads the local feature checkout.
setup_repo disabled
: > "$AGENT_LOG"
capture_checkout disabled
if MRA_PKB_FROM_REF=0 run_capture; then pass "MRA_PKB_FROM_REF=0 analyze succeeds"; else fail "opt-out analyze failed: $LAST_OUTPUT"; fi
assert_agent_marker checkout
if jq -e 'has("sourceRef") | not' "$CLONE/.mra/pkb/meta.json" >/dev/null; then
  pass "opt-out keeps legacy metadata behavior"
else
  fail "opt-out unexpectedly records source-ref metadata"
fi
capture_checkout after
assert_checkout_unchanged disabled
assert_worktree_clean

# A valid prior document copied into the temporary worktree survives bad agent output.
: > "$AGENT_LOG"
old_sitemap=$(<"$CLONE/.mra/pkb/sitemap.md")
if MRA_TEST_AGENT_FAIL=1 run_capture; then pass "failed-agent regeneration completes with preserved docs"; else fail "failed-agent regeneration failed: $LAST_OUTPUT"; fi
new_sitemap=$(<"$CLONE/.mra/pkb/sitemap.md")
[[ "$new_sitemap" == "$old_sitemap" ]] && pass "valid prior document survives generator failure" || fail "valid prior document was lost"
if [[ "$LAST_OUTPUT" == *"generation failed/cut off"* ]]; then
  pass "stubbed generator failure was exercised"
else
  fail "stubbed generator did not report its failure"
fi
assert_worktree_clean

# Missing core docs abort installation and leave the prior PKB intact.
setup_repo no_core_docs
mkdir -p "$CLONE/.mra/pkb"
printf '{"version":2}\n' > "$CLONE/.mra/pkb/meta.json"
printf 'prior PKB marker\n' > "$CLONE/.mra/pkb/prior.marker"
before_pkb=$(pkb_fingerprint)
: > "$AGENT_LOG"
if MRA_TEST_AGENT_FAIL=1 run_capture; then
  fail "generation without core docs unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"did not produce sitemap.md"* ]]; then
    pass "generation without core docs is rejected"
  else
    fail "generation without core docs failed unclearly: $LAST_OUTPUT"
  fi
fi
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "prior PKB survives missing core docs" || fail "missing core docs replaced the prior PKB"
assert_worktree_clean

# A PKB appearing after the old directory is backed up is kept, not nested into.
setup_repo install_race
: > "$AGENT_LOG"
if run_capture; then pass "install race fixture PKB generated"; else fail "install race fixture failed: $LAST_OUTPUT"; fi
REAL_MV=$(command -v mv)
INSTALL_TARGET="$(cd "$CLONE/.mra" && pwd -P)/pkb"
cat > "$STUB_BIN/mv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" == "$MRA_TEST_INSTALL_TARGET" && "$2" == "$MRA_TEST_INSTALL_TARGET".backup.* ]]; then
  "$MRA_TEST_REAL_MV" "$@"
  mkdir -p "$MRA_TEST_INSTALL_TARGET"
  printf 'concurrent PKB\n' > "$MRA_TEST_INSTALL_TARGET/CONCURRENT_MARKER"
  exit 0
fi
exec "$MRA_TEST_REAL_MV" "$@"
STUB
chmod +x "$STUB_BIN/mv"
if MRA_TEST_INSTALL_TARGET="$INSTALL_TARGET" MRA_TEST_REAL_MV="$REAL_MV" run_capture; then
  fail "install race unexpectedly succeeded: $LAST_OUTPUT"
else
  if [[ "$LAST_OUTPUT" == *"PKB appeared during generation"* ]]; then
    pass "install race aborts before moving the stage"
  else
    fail "install race failed unclearly: $LAST_OUTPUT"
  fi
fi
rm -f "$STUB_BIN/mv"
[[ -f "$CLONE/.mra/pkb/CONCURRENT_MARKER" ]] && pass "existing concurrent PKB is kept" || fail "concurrent PKB was overwritten"
if find "$CLONE/.mra/pkb" -maxdepth 1 -name 'pkb.stage.*' | grep -q .; then
  fail "stage was moved inside the existing PKB"
else
  pass "stage was not nested inside the existing PKB"
fi
assert_worktree_clean

echo "---"
echo "Passed: $passes"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
