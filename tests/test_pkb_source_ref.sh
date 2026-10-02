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
GIT_FETCH_LOG="$TEST_TMP/git-fetch.log"
REAL_GIT=$(command -v git)
mkdir -p "$TEST_HOME" "$STUB_BIN"
export HOME="$TEST_HOME"
export MRA_TEST_REAL_GIT="$REAL_GIT" MRA_TEST_GIT_FETCH_LOG="$GIT_FETCH_LOG"
printf '{"outputLanguage": null}\n' > "$MRA_CONFIG_FILE"
source "$MRA_DIR/lib/pkb-source.sh"

cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
project_dir=""
prompt=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-p" && $# -gt 1 ]]; then
    prompt="$2"
    shift 2
  elif [[ "$1" == "--add-dir" && $# -gt 1 ]]; then
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

doc=""
case "$prompt" in
  *"SITEMAP document"*) doc="sitemap.md" ;;
  *"ARCHITECTURE document"*) doc="architecture.md" ;;
  *"CONVENTIONS document"*) doc="conventions.md" ;;
  *"API SURFACE document"*) doc="api-surface.md" ;;
esac
fail_doc=false
if [[ -n "$doc" ]]; then
  case ",${MRA_TEST_AGENT_FAIL_DOCS:-}," in
    *",$doc,"*) fail_doc=true ;;
  esac
fi
if [[ "${MRA_TEST_AGENT_FAIL:-0}" == "1" || "$fail_doc" == "true" ]]; then
  printf 'Error: synthetic agent failure\n'
  exit 0
fi
cat <<'DOC'
# Generated Analysis

This document describes the synthetic repository structure, stable components,
data flow, and conventions observed by the test agent. The content is long
enough to pass the knowledge base document validation rules.
DOC
printf 'Stub generation id: %s\n' "$$"
STUB
chmod +x "$STUB_BIN/claude"

errors=0
passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }

assert_https_url() {
  local label="$1" input="$2" expected="$3" actual
  actual=$(_pkb_source_https_url "$input")
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_https_url "SCP-style GitHub URL is normalized" \
  'git@github.com:acme/legacy-api' 'https://github.com/acme/legacy-api.git'
assert_https_url "SCP-style GitHub URL keeps the .git suffix" \
  'git@github.com:acme/legacy-api.git' 'https://github.com/acme/legacy-api.git'
assert_https_url "SSH GitHub URL is normalized" \
  'ssh://git@github.com/acme/legacy-api' 'https://github.com/acme/legacy-api.git'
assert_https_url "HTTPS GitHub URL passes through" \
  'https://github.com/acme/legacy-api' 'https://github.com/acme/legacy-api'
assert_https_url "non-GitHub host is rejected" 'git@gitlab.com:acme/legacy-api.git' ''
assert_https_url "local path is rejected" '/tmp/legacy-api.git' ''

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

assert_source_fetch_via() {
  local expected="$1"
  if jq -e --arg via "$expected" '.sourceFetchVia == $via' \
      "$CLONE/.mra/pkb/meta.json" >/dev/null; then
    pass "metadata records source fetch via $expected"
  else
    fail "metadata has incorrect sourceFetchVia; expected $expected"
  fi
}

cat > "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
is_fetch=false
for arg in "$@"; do
  if [[ "$arg" == fetch ]]; then is_fetch=true; fi
done
if [[ "$is_fetch" == true ]]; then
  {
    printf 'FETCH\n'
    printf 'ARG=%q\n' "$@"
    printf 'CONFIG_COUNT=%s\n' "${GIT_CONFIG_COUNT:-}"
    printf 'CONFIG_KEY_0=%s\n' "${GIT_CONFIG_KEY_0:-}"
    printf 'CONFIG_VALUE_0=%s\n' "${GIT_CONFIG_VALUE_0:-}"
    printf 'TOKEN_ENV_SET=%s\n' "${MRA_GIT_FETCH_TOKEN+x}"
    printf 'END\n'
  } >> "$MRA_TEST_GIT_FETCH_LOG"
  if [[ "${MRA_TEST_GIT_FAIL_FETCH:-0}" == 1 ]]; then exit 1; fi
fi
exec "$MRA_TEST_REAL_GIT" "$@"
STUB
chmod +x "$STUB_BIN/git"

# Exercise authenticated fetch against a local bare origin through Git's URL rewrite.
setup_repo token_fetch
token='mra-test-token-value'
token_sha=$(git --git-dir="$ORIGIN" rev-parse refs/heads/development)
token_date=$(git --git-dir="$ORIGIN" show -s --format=%cI refs/heads/development)
git -C "$CLONE" remote set-url origin 'git@github.com:acme/legacy-api.git'
git -C "$CLONE" config url."$ORIGIN".insteadOf 'https://github.com/acme/legacy-api.git'
: > "$GIT_FETCH_LOG"
if MRA_GIT_FETCH_TOKEN="$token" run_capture; then
  pass "token-authenticated ref analyze succeeds"
else
  fail "token-authenticated ref analyze failed: $LAST_OUTPUT"
fi
assert_source_fetch_via https-token
assert_source_meta origin/development "$token_sha" "$token_date" true
if grep -Fqx 'ARG=https://github.com/acme/legacy-api.git' "$GIT_FETCH_LOG" && \
    grep -Fqx 'ARG=+refs/heads/development:refs/remotes/origin/development' "$GIT_FETCH_LOG"; then
  pass "token fetch uses the HTTPS URL and explicit refspec"
else
  fail "token fetch did not record the expected URL and refspec: $(<"$GIT_FETCH_LOG")"
fi
if grep -Fqx 'CONFIG_COUNT=1' "$GIT_FETCH_LOG" && \
    grep -Fqx 'CONFIG_KEY_0=http.https://github.com/.extraheader' "$GIT_FETCH_LOG"; then
  pass "token fetch scopes the GitHub extraheader config to the fetch"
else
  fail "token fetch did not record the expected extraheader config"
fi
encoded_header=$(sed -n 's/^CONFIG_VALUE_0=//p' "$GIT_FETCH_LOG" | head -1)
encoded_header="${encoded_header#Authorization: Basic }"
if decoded_header=$(printf '%s' "$encoded_header" | base64 -d 2>/dev/null); then
  :
else
  decoded_header=$(printf '%s' "$encoded_header" | base64 -D 2>/dev/null || true)
fi
[[ "$decoded_header" == "x-access-token:$token" ]] \
  && pass "extraheader decodes to the token authorization value" \
  || fail "extraheader did not decode to the expected authorization value"
if ! grep -F "$token" "$GIT_FETCH_LOG" >/dev/null && \
    grep -Fqx 'TOKEN_ENV_SET=' "$GIT_FETCH_LOG"; then
  pass "token is absent from fetch argv and child token environment"
else
  fail "token leaked into recorded fetch arguments or child environment"
fi
if jq -e --arg token "$token" '[.. | strings | select(contains($token))] | length == 0' \
    "$CLONE/.mra/pkb/meta.json" >/dev/null && [[ "$LAST_OUTPUT" != *"$token"* ]]; then
  pass "token is absent from metadata and command output"
else
  fail "token leaked into metadata or command output"
fi
[[ "$(git -C "$CLONE" remote get-url origin)" == 'git@github.com:acme/legacy-api.git' ]] \
  && pass "token fetch leaves origin configuration unchanged" \
  || fail "token fetch changed origin configuration"

# Without a token, the existing origin-name fetch path is used.
git -C "$CLONE" remote set-url origin "$ORIGIN"
: > "$GIT_FETCH_LOG"
if run_capture; then pass "token-unset origin ref analyze succeeds"; else fail "token-unset analyze failed: $LAST_OUTPUT"; fi
assert_source_fetch_via origin
if grep -Fqx 'ARG=origin' "$GIT_FETCH_LOG" && grep -Fqx 'CONFIG_COUNT=' "$GIT_FETCH_LOG"; then
  pass "token-unset fetch uses origin without token config"
else
  fail "token-unset fetch did not use the existing origin path: $(<"$GIT_FETCH_LOG")"
fi

# Failed HTTPS and origin attempts both use the cached remote ref, without networking.
git -C "$CLONE" remote set-url origin 'git@github.com:acme/legacy-api.git'
: > "$GIT_FETCH_LOG"
if MRA_TEST_GIT_FAIL_FETCH=1 MRA_GIT_FETCH_TOKEN="$token" run_capture; then
  pass "failed token and origin fetches use the cached ref"
else
  fail "failed-fetch fallback analyze failed: $LAST_OUTPUT"
fi
assert_source_fetch_via none
fetch_count=$(grep -c '^FETCH$' "$GIT_FETCH_LOG" || true)
if [[ "$fetch_count" -eq 2 ]] && grep -Fqx 'ARG=https://github.com/acme/legacy-api.git' "$GIT_FETCH_LOG" && \
    grep -Fqx 'ARG=origin' "$GIT_FETCH_LOG"; then
  pass "failed token fetch is followed by one origin fetch"
else
  fail "expected HTTPS then origin fetch attempts, found $fetch_count: $(<"$GIT_FETCH_LOG")"
fi

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

# A ref build with only failed core generation preserves the prior PKB.
: > "$AGENT_LOG"
old_sitemap=$(<"$CLONE/.mra/pkb/sitemap.md")
before_pkb=$(pkb_fingerprint)
if MRA_TEST_AGENT_FAIL=1 run_capture; then
  fail "failed ref regeneration unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"nothing was regenerated"* && "$LAST_OUTPUT" == *"origin/development"* ]]; then
    pass "failed ref regeneration reports that no core docs were regenerated"
  else
    fail "failed ref regeneration error was unclear: $LAST_OUTPUT"
  fi
fi
new_sitemap=$(<"$CLONE/.mra/pkb/sitemap.md")
[[ "$new_sitemap" == "$old_sitemap" ]] && pass "valid prior document survives generator failure" || fail "valid prior document was lost"
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "failed ref regeneration preserves every PKB file" || fail "failed ref regeneration changed the PKB"
if [[ "$LAST_OUTPUT" == *"generation failed/cut off"* ]]; then
  pass "stubbed generator failure was exercised"
else
  fail "stubbed generator did not report its failure"
fi
[[ ! -e "$CLONE/.mra/pkb.lock" ]] && pass "failed ref regeneration releases its lock" || fail "failed ref regeneration left a lock"
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
  if [[ "$LAST_OUTPUT" == *"nothing was regenerated"* && "$LAST_OUTPUT" == *"origin/development"* ]]; then
    pass "generation with no regenerated core docs is rejected with the ref"
  else
    fail "generation without core docs failed unclearly: $LAST_OUTPUT"
  fi
fi
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "prior PKB survives missing core docs" || fail "missing core docs replaced the prior PKB"
assert_worktree_clean

# A ref build with no regenerated core docs leaves every prior PKB file untouched.
setup_repo all_failed_prior
if run_capture; then pass "baseline PKB for all-failed case is generated"; else fail "baseline PKB generation failed: $LAST_OUTPUT"; fi
jq -e '.sourceStaleDocs == []' "$CLONE/.mra/pkb/meta.json" >/dev/null && \
  pass "fully generated ref PKB records no stale docs" || fail "fully generated ref PKB omitted the empty stale-doc list"
before_pkb=$(pkb_fingerprint)
if MRA_TEST_AGENT_FAIL=1 run_capture; then
  fail "ref generation with all four core generators failing unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"origin/development"* && "$LAST_OUTPUT" == *"nothing was regenerated"* ]]; then
    pass "all-failed ref build names its ref and says nothing was regenerated"
  else
    fail "all-failed ref build error was unclear: $LAST_OUTPUT"
  fi
fi
[[ "$(pkb_fingerprint)" == "$before_pkb" ]] && pass "all-failed ref build preserves every PKB file" || fail "all-failed ref build changed the PKB"
[[ ! -e "$CLONE/.mra/pkb.lock" ]] && pass "all-failed ref build releases its lock" || fail "all-failed ref build left a lock"
assert_worktree_clean

# A partial ref build installs regenerated docs and reports the preserved ones.
setup_repo partial_core_docs
if run_capture; then pass "baseline PKB for partial case is generated"; else fail "partial case baseline failed: $LAST_OUTPUT"; fi
jq -e '.sourceStaleDocs == []' "$CLONE/.mra/pkb/meta.json" >/dev/null && \
  pass "successful ref build records an empty stale-doc list" || fail "successful ref build omitted the empty stale-doc list"
if MRA_TEST_AGENT_FAIL_DOCS='sitemap.md,conventions.md' run_capture; then
  pass "partial ref build installs regenerated core docs"
else
  fail "partial ref build failed: $LAST_OUTPUT"
fi
if jq -e '.sourceStaleDocs == ["sitemap.md", "conventions.md"]' "$CLONE/.mra/pkb/meta.json" >/dev/null; then
  pass "partial ref metadata lists exactly the two kept core docs"
else
  fail "partial ref metadata has an incorrect stale-doc list"
fi
stale_report=$(pkb_stale_files "$CLONE")
if [[ "$stale_report" == *"(kept from an earlier build: sitemap.md, conventions.md)"* ]]; then
  pass "ref provenance report names both kept docs"
else
  fail "ref provenance report omitted kept docs: $stale_report"
fi
source_context=$(pkb_build_context "$CLONE" "" "minimal")
if [[ "$source_context" == *"PKB SOURCE: built from origin/development@"* && \
    "$source_context" == *"kept from an earlier build: sitemap.md, conventions.md"* ]]; then
  pass "review banner names both kept docs"
else
  fail "review banner omitted kept docs: $source_context"
fi
assert_worktree_clean

# Kept module summaries are reported without affecting the core-doc success gate.
mkdir -p "$CLONE/.mra/pkb/modules"
printf '# Module: retained\n\nA valid prior module summary remains available.\n' > "$CLONE/.mra/pkb/modules/retained.md"
if run_capture; then
  pass "all-core-success ref build installs with a kept module summary"
else
  fail "all-core-success ref build failed with a kept module summary: $LAST_OUTPUT"
fi
if jq -e '.sourceStaleDocs == ["modules/retained.md"]' "$CLONE/.mra/pkb/meta.json" >/dev/null; then
  pass "module summary is reported without marking core docs stale"
else
  fail "module summary was not reported independently: $(jq -c '.sourceStaleDocs' "$CLONE/.mra/pkb/meta.json")"
fi
stale_report=$(pkb_stale_files "$CLONE")
if [[ "$stale_report" == *"(kept from an earlier build: modules/retained.md)"* ]]; then
  pass "ref provenance report names the kept module summary"
else
  fail "ref provenance report omitted the kept module summary: $stale_report"
fi
assert_worktree_clean

# With no prior PKB, a fully failed ref generation creates no PKB directory.
setup_repo no_prior_all_failed
[[ ! -e "$CLONE/.mra/pkb" ]] && pass "no-prior fixture starts without a PKB" || fail "no-prior fixture unexpectedly has a PKB"
if MRA_TEST_AGENT_FAIL=1 run_capture; then
  fail "all-failed ref generation without a prior PKB unexpectedly succeeded"
else
  if [[ "$LAST_OUTPUT" == *"origin/development"* && "$LAST_OUTPUT" == *"nothing was regenerated"* ]]; then
    pass "no-prior all-failed ref build reports no regenerated docs"
  else
    fail "no-prior all-failed ref build error was unclear: $LAST_OUTPUT"
  fi
fi
[[ ! -e "$CLONE/.mra/pkb" ]] && pass "no-prior all-failed ref build creates no PKB" || fail "no-prior all-failed ref build created a PKB"
[[ ! -e "$CLONE/.mra/pkb.lock" ]] && pass "no-prior all-failed ref build releases its lock" || fail "no-prior all-failed ref build left a lock"
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
