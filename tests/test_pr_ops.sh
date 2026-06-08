#!/usr/bin/env bash
# shellcheck disable=SC2218
# (file-wide) merge_repo and friends are sourced from lib/*.sh; this suite later
# defines same-name stubs as intentional test doubles, which older linters misread
# as "function defined later". The directive above silences that false positive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/branch-ops.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/pr-ops.sh"
source "$SCRIPT_DIR/lib/ci.sh"

errors=0
GF=$(mktemp)
# graph: "a" depends on "b" (b is a dependency of a) -> b should come before a
cat > "$GF" <<'JSON'
{"gitOrg":"x","projects":{
  "a":{"deps":{"api":["b"]},"consumedBy":[]},
  "b":{"deps":{},"consumedBy":["a"]},
  "c":{"deps":{},"consumedBy":[]}
}}
JSON

ordered=$(order_repos_by_deps "$GF" a b c)
# b must appear before a
pos_a=$(echo "$ordered" | grep -nx a | cut -d: -f1)
pos_b=$(echo "$ordered" | grep -nx b | cut -d: -f1)
if [[ -z "$pos_a" || -z "$pos_b" || "$pos_b" -ge "$pos_a" ]]; then
  echo "FAIL: dependency 'b' should be ordered before consumer 'a' (got: $(echo $ordered | tr '\n' ' '))"; errors=$((errors+1))
fi
# all three present
for r in a b c; do echo "$ordered" | grep -qx "$r" || { echo "FAIL: $r missing from order"; errors=$((errors+1)); }; done

# unrelated subset (only c) -> just c, no error
ordered2=$(order_repos_by_deps "$GF" c)
if [[ "$(echo "$ordered2" | tr -d '[:space:]')" != "c" ]]; then echo "FAIL: single repo should order to itself"; errors=$((errors+1)); fi
rm -f "$GF"

# --- pr_repo: dry-run previews, never pushes; skip rules ---
PR_DIR=$(mktemp -d)
git -C "$PR_DIR" init -b main --bare up &>/dev/null
git clone "$PR_DIR/up" "$PR_DIR/a" &>/dev/null
git -C "$PR_DIR/a" config user.email t@t.t; git -C "$PR_DIR/a" config user.name t
git -C "$PR_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PR_DIR/a" push -u origin main &>/dev/null

# on default branch (main) => skip, no push
out=$(pr_repo "$PR_DIR/a" "" false 2>&1) || true
case "$out" in *base*|*skip*|*on*) : ;; *) echo "FAIL: default-branch repo should be skipped: $out"; errors=$((errors+1)) ;; esac

# feature branch with a commit, dry-run => would-open, no remote ref created
git -C "$PR_DIR/a" checkout -b feat/x &>/dev/null
git -C "$PR_DIR/a" commit --allow-empty -m work &>/dev/null
before=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/x' || true)
out=$(pr_repo "$PR_DIR/a" "" true 2>&1) || true
case "$out" in *would*) : ;; *) echo "FAIL: dry-run should print would-open: $out"; errors=$((errors+1)) ;; esac
after=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/x' || true)
if [[ "$before" != "$after" ]]; then echo "FAIL: dry-run must not push feat/x to remote"; errors=$((errors+1)); fi

# feature branch with NO commits vs base => eligibility skip, no push
git -C "$PR_DIR/a" checkout -b feat/empty main &>/dev/null
out=$(pr_repo "$PR_DIR/a" "main" true 2>&1) || true
case "$out" in *nothing*|*"no commits"*) : ;; *) echo "FAIL: empty branch should skip (eligibility): $out"; errors=$((errors+1)) ;; esac
ref_empty=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/empty' || true)
if [[ "$ref_empty" != "0" ]]; then echo "FAIL: empty branch must not be pushed"; errors=$((errors+1)); fi
rm -rf "$PR_DIR"

# --- pr_workspace: collects feature-branch repos, orders, drives pr_repo (dry-run) ---
PW_DIR=$(mktemp -d); mkdir -p "$PW_DIR/.collab"
cat > "$PW_DIR/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]},"b":{"deps":{},"consumedBy":[]}}}
JSON
for r in a b; do
  git -C "$PW_DIR" init -b main "$r" &>/dev/null
  git -C "$PW_DIR/$r" config user.email t@t.t; git -C "$PW_DIR/$r" config user.name t
  git -C "$PW_DIR/$r" commit --allow-empty -m init &>/dev/null
done
# a on a feature branch with a commit; b stays on main
git -C "$PW_DIR/a" checkout -b feat/x &>/dev/null
git -C "$PW_DIR/a" commit --allow-empty -m work &>/dev/null

out=$(pr_workspace "$PW_DIR" "" true 2>&1) || true
# a (feature branch) -> would-open; b (on main) -> not collected
case "$out" in *would*open*) : ;; *) echo "FAIL: pr_workspace dry-run should preview feature-branch repo a: $out"; errors=$((errors+1)) ;; esac
if echo "$out" | grep -q 'b:.*would open'; then echo "FAIL: repo b (on main) should not be PR'd"; errors=$((errors+1)); fi

# all on default branch -> info, no would-open
git -C "$PW_DIR/a" checkout main &>/dev/null
out2=$(pr_workspace "$PW_DIR" "" true 2>&1) || true
if echo "$out2" | grep -q 'would open'; then echo "FAIL: no feature-branch repos should yield no PRs: $out2"; errors=$((errors+1)); fi
rm -rf "$PW_DIR"

# --- pr_repo: unresolvable base => warn + skip, no remote write ---
UB_DIR=$(mktemp -d)
git -C "$UB_DIR" init -b main --bare up &>/dev/null
git clone "$UB_DIR/up" "$UB_DIR/a" &>/dev/null
git -C "$UB_DIR/a" config user.email t@t.t; git -C "$UB_DIR/a" config user.name t
git -C "$UB_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$UB_DIR/a" push -u origin main &>/dev/null
git -C "$UB_DIR/a" checkout -b feat/x &>/dev/null
git -C "$UB_DIR/a" commit --allow-empty -m work &>/dev/null
out=$(pr_repo "$UB_DIR/a" "nosuchref" false 2>&1) || true
case "$out" in *"not found"*) : ;; *) echo "FAIL: unresolvable base should warn 'not found': $out"; errors=$((errors+1)) ;; esac
n_ref=$(git -C "$UB_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/x' || true)
if [[ "$n_ref" != "0" ]]; then echo "FAIL: unresolvable base must not push"; errors=$((errors+1)); fi
rm -rf "$UB_DIR"

# --- pr_workspace: a repo sitting on the --base ref is NOT a candidate ---
BC_DIR=$(mktemp -d); mkdir -p "$BC_DIR/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$BC_DIR/.collab/dep-graph.json"
git -C "$BC_DIR" init -b main a &>/dev/null
git -C "$BC_DIR/a" config user.email t@t.t; git -C "$BC_DIR/a" config user.name t
git -C "$BC_DIR/a" commit --allow-empty -m init &>/dev/null
git -C "$BC_DIR/a" checkout -b release/1 &>/dev/null   # repo a sits ON the base ref
out=$(pr_workspace "$BC_DIR" "release/1" true 2>&1) || true
if echo "$out" | grep -q 'would open'; then echo "FAIL: repo on the --base ref should not be a candidate: $out"; errors=$((errors+1)); fi
rm -rf "$BC_DIR"

# --- merge_repo skip paths (no real gh merge exercised) ---
MG_DIR=$(mktemp -d)
git -C "$MG_DIR" init -b main repo &>/dev/null
MGR="$MG_DIR/repo"
git -C "$MGR" config user.email t@t.t; git -C "$MGR" config user.name t
git -C "$MGR" commit --allow-empty -m c1 &>/dev/null

# on default branch (main) => skip, return 0, no gh
out=$(merge_repo "$MGR" merge false 2>&1) || true
case "$out" in *"default branch"*|*skip*) : ;; *) echo "FAIL: default-branch repo should skip: $out"; errors=$((errors+1)) ;; esac

# feature branch with no GitHub PR (local-only fixture) => "no open PR" skip, return 0
git -C "$MGR" checkout -b feat/x &>/dev/null
git -C "$MGR" commit --allow-empty -m work &>/dev/null
out=$(merge_repo "$MGR" merge false 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then echo "FAIL: no-PR feature branch should skip (return 0), got rc=$rc: $out"; errors=$((errors+1)); fi
case "$out" in *"no open PR"*) : ;; *) echo "FAIL: expected 'no open PR': $out"; errors=$((errors+1)) ;; esac

# dry-run on the same no-PR branch => also the no-PR skip
out=$(merge_repo "$MGR" merge true 2>&1) || true
case "$out" in *"no open PR"*) : ;; *) echo "FAIL: dry-run no-PR should skip: $out"; errors=$((errors+1)) ;; esac
rm -rf "$MG_DIR"

# --- merge_workspace: collect feature-branch repos, order deps-first, drive merge_repo (stubbed) ---
MW_DIR=$(mktemp -d); mkdir -p "$MW_DIR/.collab"
# a depends on b => b must be merged before a
cat > "$MW_DIR/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{"api":["b"]},"consumedBy":[]},"b":{"deps":{},"consumedBy":["a"]}}}
JSON
for r in a b; do
  git -C "$MW_DIR" init -b main "$r" &>/dev/null
  git -C "$MW_DIR/$r" config user.email t@t.t; git -C "$MW_DIR/$r" config user.name t
  git -C "$MW_DIR/$r" commit --allow-empty -m init &>/dev/null
  git -C "$MW_DIR/$r" checkout -b feat/x &>/dev/null
done

# stub merge_repo to record call order (avoids any gh)
MERGE_LOG=$(mktemp)
merge_repo() { echo "$(basename "$1")" >> "$MERGE_LOG"; return 0; }

merge_workspace "$MW_DIR" merge true &>/dev/null
pa=$(grep -nx a "$MERGE_LOG" | cut -d: -f1); pb=$(grep -nx b "$MERGE_LOG" | cut -d: -f1)
if [[ -z "$pa" || -z "$pb" || "$pb" -ge "$pa" ]]; then
  echo "FAIL: merge order should be b before a (got: $(tr '\n' ' ' < "$MERGE_LOG"))"; errors=$((errors+1))
fi

# all on default branch => no candidates
git -C "$MW_DIR/a" checkout main &>/dev/null; git -C "$MW_DIR/b" checkout main &>/dev/null
out=$(merge_workspace "$MW_DIR" merge true 2>&1) || true
case "$out" in *"no feature-branch repos"*) : ;; *) echo "FAIL: all-on-main should report no candidates: $out"; errors=$((errors+1)) ;; esac
rm -rf "$MW_DIR" "$MERGE_LOG"

unset -f merge_repo

# --- merge_workspace stop-on-first-failure: first repo fails => second not processed, non-zero ---
SF_DIR=$(mktemp -d); mkdir -p "$SF_DIR/.collab"
# a depends on b => order is b then a; make b (first) fail
cat > "$SF_DIR/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{"api":["b"]},"consumedBy":[]},"b":{"deps":{},"consumedBy":["a"]}}}
JSON
for r in a b; do
  git -C "$SF_DIR" init -b main "$r" &>/dev/null
  git -C "$SF_DIR/$r" config user.email t@t.t; git -C "$SF_DIR/$r" config user.name t
  git -C "$SF_DIR/$r" commit --allow-empty -m init &>/dev/null
  git -C "$SF_DIR/$r" checkout -b feat/x &>/dev/null
done
SF_LOG=$(mktemp)
# stub: fail on b (the first in dep order), succeed otherwise
merge_repo() { local n; n=$(basename "$1"); echo "$n" >> "$SF_LOG"; [[ "$n" == "b" ]] && return 1; return 0; }
if merge_workspace "$SF_DIR" merge true &>/dev/null; then sf_rc=0; else sf_rc=$?; fi
if [[ $sf_rc -eq 0 ]]; then echo "FAIL: merge_workspace should return non-zero when a repo fails"; errors=$((errors+1)); fi
if grep -qx a "$SF_LOG"; then echo "FAIL: 'a' should NOT be processed after 'b' failed (stop-on-first-failure)"; errors=$((errors+1)); fi
grep -qx b "$SF_LOG" || { echo "FAIL: 'b' should have been attempted"; errors=$((errors+1)); }
unset -f merge_repo
rm -rf "$SF_DIR" "$SF_LOG"

# --- branch merge dispatch: invalid --strategy rejected (before gh/workspace) ---
DSP=$(mktemp -d); mkdir -p "$DSP/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DSP/.collab/dep-graph.json"
if out=$(MRA_WORKSPACE="$DSP" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --strategy bogus 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: invalid --strategy should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"merge|squash|rebase"*|*strategy*) : ;; *) echo "FAIL: expected strategy error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DSP"

# --- merge_repo accepts delete_branch param without breaking the skip path ---
# Re-source pr-ops.sh: the stop-on-first-failure block above left merge_repo unset via stub cleanup
source "$SCRIPT_DIR/lib/pr-ops.sh"
DB_DIR=$(mktemp -d)
git -C "$DB_DIR" init -b main repo &>/dev/null
DBR="$DB_DIR/repo"
git -C "$DBR" config user.email t@t.t; git -C "$DBR" config user.name t
git -C "$DBR" commit --allow-empty -m c1 &>/dev/null
git -C "$DBR" checkout -b feat/x &>/dev/null
git -C "$DBR" commit --allow-empty -m work &>/dev/null
out=$(merge_repo "$DBR" merge false true 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then echo "FAIL: merge_repo w/ delete_branch should still skip no-PR (rc=$rc): $out"; errors=$((errors+1)); fi
case "$out" in *"no open PR"*) : ;; *) echo "FAIL: expected no-PR skip: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DB_DIR"

# --- merge_workspace passes delete_branch through to merge_repo (stubbed) ---
DBW_DIR=$(mktemp -d); mkdir -p "$DBW_DIR/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$DBW_DIR/.collab/dep-graph.json"
git -C "$DBW_DIR" init -b main a &>/dev/null
git -C "$DBW_DIR/a" config user.email t@t.t; git -C "$DBW_DIR/a" config user.name t
git -C "$DBW_DIR/a" commit --allow-empty -m init &>/dev/null
git -C "$DBW_DIR/a" checkout -b feat/x &>/dev/null
DBW_LOG=$(mktemp)
merge_repo() { echo "delete=$4" >> "$DBW_LOG"; return 0; }
merge_workspace "$DBW_DIR" merge true true &>/dev/null
case "$(cat "$DBW_LOG")" in *"delete=true"*) : ;; *) echo "FAIL: merge_workspace should pass delete_branch=true to merge_repo: $(cat "$DBW_LOG")"; errors=$((errors+1)) ;; esac
unset -f merge_repo
rm -rf "$DBW_DIR" "$DBW_LOG"

# --- branch merge --delete-branch is accepted and threaded (no-PR fixture => skip, exit 0) ---
DBD=$(mktemp -d); mkdir -p "$DBD/.collab"; echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$DBD/.collab/dep-graph.json"
git -C "$DBD" init -b main a &>/dev/null
git -C "$DBD/a" config user.email t@t.t; git -C "$DBD/a" config user.name t
git -C "$DBD/a" commit --allow-empty -m init &>/dev/null
git -C "$DBD/a" checkout -b feat/x &>/dev/null
git -C "$DBD/a" commit --allow-empty -m work &>/dev/null
if out=$(MRA_WORKSPACE="$DBD" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --delete-branch --dry-run 2>&1); then rc=0; else rc=$?; fi
case "$out" in *"unknown option"*) echo "FAIL: --delete-branch should be a recognized flag: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$DBD"

# --- validate_repo_subset: names + existence, full-scan, reports ALL failures ---
VS=$(mktemp -d)
git -C "$VS" init -b main a &>/dev/null
git -C "$VS/a" config user.email t@t.t; git -C "$VS/a" config user.name t
git -C "$VS/a" commit --allow-empty -m i &>/dev/null
mkdir -p "$VS/notrepo"

# empty subset (no repo names) -> vacuously valid (return 0)
if ! validate_repo_subset "$VS"; then echo "FAIL: empty subset should pass"; errors=$((errors+1)); fi
# valid existing repo -> pass (return 0)
if ! validate_repo_subset "$VS" a; then echo "FAIL: valid repo 'a' should pass"; errors=$((errors+1)); fi
# missing repo -> non-zero + "not a git repo"
if out=$(validate_repo_subset "$VS" ghost 2>&1); then echo "FAIL: missing repo should fail"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
# non-git dir -> non-zero
if validate_repo_subset "$VS" notrepo 2>/dev/null; then echo "FAIL: non-git dir should fail"; errors=$((errors+1)); fi
# path-like name -> non-zero + "invalid repo name"
if out=$(validate_repo_subset "$VS" "a/b" 2>&1); then echo "FAIL: path-like name should fail"; errors=$((errors+1)); fi
case "$out" in *"invalid repo name"*) : ;; *) echo "FAIL: expected 'invalid repo name': $out"; errors=$((errors+1)) ;; esac
# dash-like name -> non-zero (validate_repo_name rejects -*)
if validate_repo_subset "$VS" "-x" 2>/dev/null; then echo "FAIL: dash name should be rejected"; errors=$((errors+1)); fi
# reports ALL failures, still non-zero
out=$(validate_repo_subset "$VS" ghost "a/b" 2>&1) || true
n=$(printf '%s\n' "$out" | grep -c -e 'not a git repo' -e 'invalid repo name')
if [[ "$n" -lt 2 ]]; then echo "FAIL: should report all failures (got $n): $out"; errors=$((errors+1)); fi
# mixed valid+invalid -> the whole set fails
if validate_repo_subset "$VS" a ghost 2>/dev/null; then echo "FAIL: any bad name fails the set"; errors=$((errors+1)); fi
rm -rf "$VS"

# --- warn_excluded_feature_deps: warn only for excluded deps that are on a feature branch ---
WE=$(mktemp -d); mkdir -p "$WE/.collab"
cat > "$WE/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{"api":["b"]},"consumedBy":[]},"b":{"deps":{},"consumedBy":["a"]}}}
JSON
for r in a b; do
  git -C "$WE" init -b main "$r" &>/dev/null
  git -C "$WE/$r" config user.email t@t.t; git -C "$WE/$r" config user.name t
  git -C "$WE/$r" commit --allow-empty -m i &>/dev/null
done
GF2="$WE/.collab/dep-graph.json"
# b on a feature branch, excluded from subset {a} -> warn
git -C "$WE/b" checkout -b feat/x &>/dev/null
out=$(warn_excluded_feature_deps "$WE" "$GF2" a 2>&1) || true
case "$out" in *"depends on 'b'"*) : ;; *) echo "FAIL: should warn about excluded feature-branch dep b: $out"; errors=$((errors+1)) ;; esac
# b included in subset {a b} -> no warn
out=$(warn_excluded_feature_deps "$WE" "$GF2" a b 2>&1) || true
if printf '%s' "$out" | grep -q "depends on"; then echo "FAIL: dep in subset should not warn: $out"; errors=$((errors+1)); fi
# b on default branch (not a feature branch) and excluded -> no warn
git -C "$WE/b" checkout main &>/dev/null
out=$(warn_excluded_feature_deps "$WE" "$GF2" a 2>&1) || true
if printf '%s' "$out" | grep -q "depends on"; then echo "FAIL: excluded dep on default branch should not warn: $out"; errors=$((errors+1)); fi
# empty subset -> no-op, no warning, no error
out=$(warn_excluded_feature_deps "$WE" "$GF2" 2>&1) || true
if printf '%s' "$out" | grep -q "depends on"; then echo "FAIL: empty subset should not warn: $out"; errors=$((errors+1)); fi
rm -rf "$WE"

# --- pr_workspace subset: only named repos previewed; no-subset unchanged ---
PS=$(mktemp -d); mkdir -p "$PS/.collab"
cat > "$PS/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]},"b":{"deps":{},"consumedBy":[]},"c":{"deps":{},"consumedBy":[]}}}
JSON
for r in a b c; do
  git -C "$PS" init -b main "$r" &>/dev/null
  git -C "$PS/$r" config user.email t@t.t; git -C "$PS/$r" config user.name t
  git -C "$PS/$r" commit --allow-empty -m i &>/dev/null
  git -C "$PS/$r" checkout -b feat/x &>/dev/null
  git -C "$PS/$r" commit --allow-empty -m work &>/dev/null
done
# subset {a c} -> a and c previewed, b excluded
out=$(pr_workspace "$PS" "" true a c 2>&1) || true
printf '%s\n' "$out" | grep -q 'a:.*would open' || { echo "FAIL: a should be previewed: $out"; errors=$((errors+1)); }
printf '%s\n' "$out" | grep -q 'c:.*would open' || { echo "FAIL: c should be previewed: $out"; errors=$((errors+1)); }
if printf '%s\n' "$out" | grep -q 'b:.*would open'; then echo "FAIL: b (excluded) should not be previewed: $out"; errors=$((errors+1)); fi
# no subset -> all three previewed (unchanged behavior)
out=$(pr_workspace "$PS" "" true 2>&1) || true
for r in a b c; do printf '%s\n' "$out" | grep -q "$r:.*would open" || { echo "FAIL: no-subset should preview $r: $out"; errors=$((errors+1)); }; done
rm -rf "$PS"

# --- pr_workspace subset: a named repo on the default branch -> skip+info, others proceed ---
PD=$(mktemp -d); mkdir -p "$PD/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]},"b":{"deps":{},"consumedBy":[]}}}' > "$PD/.collab/dep-graph.json"
for r in a b; do
  git -C "$PD" init -b main "$r" &>/dev/null
  git -C "$PD/$r" config user.email t@t.t; git -C "$PD/$r" config user.name t
  git -C "$PD/$r" commit --allow-empty -m i &>/dev/null
done
git -C "$PD/a" checkout -b feat/x &>/dev/null; git -C "$PD/a" commit --allow-empty -m w &>/dev/null
out=$(pr_workspace "$PD" "" true a b 2>&1) || true
printf '%s\n' "$out" | grep -q 'a:.*would open' || { echo "FAIL: a should preview: $out"; errors=$((errors+1)); }
case "$out" in *"b: on base branch"*) : ;; *) echo "FAIL: b on default should skip with info: $out"; errors=$((errors+1)) ;; esac
if printf '%s\n' "$out" | grep -q 'b:.*would open'; then echo "FAIL: b should not be PR'd: $out"; errors=$((errors+1)); fi
rm -rf "$PD"

# --- pr_workspace subset: a named repo in detached HEAD -> warn (not a false "on base branch") ---
PH=$(mktemp -d); mkdir -p "$PH/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$PH/.collab/dep-graph.json"
git -C "$PH" init -b main a &>/dev/null
git -C "$PH/a" config user.email t@t.t; git -C "$PH/a" config user.name t
git -C "$PH/a" commit --allow-empty -m i &>/dev/null
git -C "$PH/a" commit --allow-empty -m i2 &>/dev/null
git -C "$PH/a" checkout --detach HEAD &>/dev/null
out=$(pr_workspace "$PH" "" true a 2>&1) || true
case "$out" in *"detached HEAD"*) : ;; *) echo "FAIL: detached repo in subset should warn 'detached HEAD': $out"; errors=$((errors+1)) ;; esac
if printf '%s' "$out" | grep -q "on base branch"; then echo "FAIL: detached repo must not claim 'on base branch': $out"; errors=$((errors+1)); fi
rm -rf "$PH"

# --- merge_workspace subset: only named repos merged (stubbed merge_repo) ---
MS_DIR=$(mktemp -d); mkdir -p "$MS_DIR/.collab"
cat > "$MS_DIR/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]},"b":{"deps":{},"consumedBy":[]}}}
JSON
for r in a b; do
  git -C "$MS_DIR" init -b main "$r" &>/dev/null
  git -C "$MS_DIR/$r" config user.email t@t.t; git -C "$MS_DIR/$r" config user.name t
  git -C "$MS_DIR/$r" commit --allow-empty -m i &>/dev/null
  git -C "$MS_DIR/$r" checkout -b feat/x &>/dev/null
done
MS_LOG=$(mktemp)
merge_repo() { echo "$(basename "$1")" >> "$MS_LOG"; return 0; }
# subset {a} -> only a merged, b excluded
merge_workspace "$MS_DIR" merge true false "" a &>/dev/null
grep -qx a "$MS_LOG" || { echo "FAIL: subset {a} should merge a"; errors=$((errors+1)); }
if grep -qx b "$MS_LOG"; then echo "FAIL: b (excluded) should not be merged"; errors=$((errors+1)); fi
# named repo on default branch -> skip+info, not passed to merge_repo
: > "$MS_LOG"
git -C "$MS_DIR/b" checkout main &>/dev/null
out=$(merge_workspace "$MS_DIR" merge true false "" a b 2>&1) || true
grep -qx a "$MS_LOG" || { echo "FAIL: a should still merge: $out"; errors=$((errors+1)); }
if grep -qx b "$MS_LOG"; then echo "FAIL: b on default should not reach merge_repo"; errors=$((errors+1)); fi
case "$out" in *"b: on default branch"*) : ;; *) echo "FAIL: b on default should info-skip: $out"; errors=$((errors+1)) ;; esac
unset -f merge_repo
rm -rf "$MS_DIR" "$MS_LOG"

# --- merge_workspace subset: detached-HEAD named repo -> warn (not a false "on default branch") ---
MH_DIR=$(mktemp -d); mkdir -p "$MH_DIR/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$MH_DIR/.collab/dep-graph.json"
git -C "$MH_DIR" init -b main a &>/dev/null
git -C "$MH_DIR/a" config user.email t@t.t; git -C "$MH_DIR/a" config user.name t
git -C "$MH_DIR/a" commit --allow-empty -m i &>/dev/null
git -C "$MH_DIR/a" commit --allow-empty -m i2 &>/dev/null
git -C "$MH_DIR/a" checkout --detach HEAD &>/dev/null
MH_LOG=$(mktemp)
merge_repo() { echo "$(basename "$1")" >> "$MH_LOG"; return 0; }
out=$(merge_workspace "$MH_DIR" merge true false "" a 2>&1) || true
case "$out" in *"detached HEAD"*) : ;; *) echo "FAIL: detached repo in subset should warn 'detached HEAD': $out"; errors=$((errors+1)) ;; esac
if printf '%s' "$out" | grep -q "on default branch"; then echo "FAIL: detached repo must not claim 'on default branch': $out"; errors=$((errors+1)); fi
if grep -qx a "$MH_LOG"; then echo "FAIL: detached repo should not reach merge_repo"; errors=$((errors+1)); fi
unset -f merge_repo
rm -rf "$MH_DIR" "$MH_LOG"

# --- branch pr dispatch: subset validation runs BEFORE gh-auth; unknown flag rejected ---
DP=$(mktemp -d); mkdir -p "$DP/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DP/.collab/dep-graph.json"
# missing repo -> abort with "not a git repo", and NOT a gh-auth error (ordering proof)
if out=$(MRA_WORKSPACE="$DP" bash "$SCRIPT_DIR/bin/mra.sh" branch pr ghost 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: branch pr with missing repo should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
case "$out" in *"gh authentication"*) echo "FAIL: must fail on subset validation before gh-auth: $out"; errors=$((errors+1)) ;; *) : ;; esac
# unknown flag -> non-zero exit + "unknown option"
if out=$(MRA_WORKSPACE="$DP" bash "$SCRIPT_DIR/bin/mra.sh" branch pr -x 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: unknown flag should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"unknown option"*) : ;; *) echo "FAIL: unknown flag should error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DP"
# usage line advertises [repos...]
grep -q 'branch pr .*\[repos\.\.\.\]' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise 'branch pr ... [repos...]'"; errors=$((errors+1)); }

# --- branch merge dispatch: subset validation runs BEFORE gh-auth; strategy still checked ---
DM=$(mktemp -d); mkdir -p "$DM/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DM/.collab/dep-graph.json"
# missing repo -> abort with "not a git repo", NOT a gh-auth error
if out=$(MRA_WORKSPACE="$DM" bash "$SCRIPT_DIR/bin/mra.sh" branch merge ghost 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: branch merge with missing repo should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
case "$out" in *"gh authentication"*) echo "FAIL: must fail on subset validation before gh-auth: $out"; errors=$((errors+1)) ;; *) : ;; esac
# invalid --strategy still rejected even with a repo arg
if out=$(MRA_WORKSPACE="$DM" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --strategy bogus somerepo 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: invalid strategy should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"merge|squash|rebase"*|*strategy*) : ;; *) echo "FAIL: invalid strategy should error: $out"; errors=$((errors+1)) ;; esac
# unknown flag -> non-zero exit + "unknown option"
if out=$(MRA_WORKSPACE="$DM" bash "$SCRIPT_DIR/bin/mra.sh" branch merge -x 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: unknown flag should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"unknown option"*) : ;; *) echo "FAIL: unknown flag should error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DM"
# usage line advertises [repos...]
grep -q 'branch merge .*\[repos\.\.\.\]' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise 'branch merge ... [repos...]'"; errors=$((errors+1)); }

# --- pr_workspace subset: dependency order respected within the subset (spec §17.5 #6) ---
PO=$(mktemp -d); mkdir -p "$PO/.collab"
# a depends on b => b must be PR'd before a
cat > "$PO/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"x","projects":{"a":{"deps":{"api":["b"]},"consumedBy":[]},"b":{"deps":{},"consumedBy":["a"]}}}
JSON
for r in a b; do
  git -C "$PO" init -b main "$r" &>/dev/null
  git -C "$PO/$r" config user.email t@t.t; git -C "$PO/$r" config user.name t
  git -C "$PO/$r" commit --allow-empty -m i &>/dev/null
  git -C "$PO/$r" checkout -b feat/x &>/dev/null
  git -C "$PO/$r" commit --allow-empty -m work &>/dev/null
done
out=$(pr_workspace "$PO" "" true a b 2>&1) || true
pos_a=$(printf '%s\n' "$out" | grep -n 'a: would open' | head -1 | cut -d: -f1)
pos_b=$(printf '%s\n' "$out" | grep -n 'b: would open' | head -1 | cut -d: -f1)
if [[ -z "$pos_a" || -z "$pos_b" || "$pos_b" -ge "$pos_a" ]]; then
  echo "FAIL: within subset, dependency 'b' should be PR'd before consumer 'a' (got: $(printf '%s' "$out" | tr '\n' ' '))"; errors=$((errors+1))
fi
rm -rf "$PO"

# Re-source pr-ops.sh: the MH_DIR block above left merge_repo unset via stub cleanup
source "$SCRIPT_DIR/lib/pr-ops.sh"

# --- merge_repo CI gate: ci_wait_timeout="" uses one-shot gh pr checks; non-empty uses wait_for_pr_checks ---
CG_DIR=$(mktemp -d)
git -C "$CG_DIR" init -b main repo &>/dev/null
CGR="$CG_DIR/repo"
git -C "$CGR" config user.email t@t.t; git -C "$CGR" config user.name t
git -C "$CGR" commit --allow-empty -m c1 &>/dev/null
git -C "$CGR" checkout -b feat/x &>/dev/null
git -C "$CGR" commit --allow-empty -m work &>/dev/null
CG_LOG=$(mktemp)
# stub gh: pr view -> OPEN+MERGEABLE; pr checks -> record + pass; pr merge -> ok
gh() {
  case "$2" in
    view) echo '{"number":7,"state":"OPEN","mergeable":"MERGEABLE"}' ;;
    checks) echo "checks-called" >> "$CG_LOG"; return 0 ;;
    merge) return 0 ;;
    *) return 0 ;;
  esac
}
# stub wait_for_pr_checks: record + green
wait_for_pr_checks() { echo "WAIT_CALLED" >> "$CG_LOG"; return 0; }

# 6. ci_wait_timeout="" (default) -> one-shot gate (gh pr checks), NOT wait_for_pr_checks
: > "$CG_LOG"
merge_repo "$CGR" merge false false "" &>/dev/null
grep -q 'checks-called' "$CG_LOG" || { echo "FAIL: empty ci_wait_timeout should call one-shot gh pr checks: $(cat "$CG_LOG")"; errors=$((errors+1)); }
if grep -q 'WAIT_CALLED' "$CG_LOG"; then echo "FAIL: empty ci_wait_timeout must NOT poll wait_for_pr_checks"; errors=$((errors+1)); fi

# 7. ci_wait_timeout=60 (non-dry-run) -> wait_for_pr_checks, NOT one-shot
: > "$CG_LOG"
merge_repo "$CGR" merge false "" 60 &>/dev/null
grep -q 'WAIT_CALLED' "$CG_LOG" || { echo "FAIL: non-empty ci_wait_timeout should poll wait_for_pr_checks: $(cat "$CG_LOG")"; errors=$((errors+1)); }
if grep -q 'checks-called' "$CG_LOG"; then echo "FAIL: poll path must NOT call one-shot gh pr checks"; errors=$((errors+1)); fi

# 8. dry-run + ci_wait_timeout=60 -> preview mentions wait; wait_for_pr_checks NOT called
: > "$CG_LOG"
out=$(merge_repo "$CGR" merge true "" 60 2>&1) || true
case "$out" in *"would wait for CI (timeout 60s)"*) : ;; *) echo "FAIL: dry-run preview should mention CI wait: $out"; errors=$((errors+1)) ;; esac
if grep -q 'WAIT_CALLED' "$CG_LOG"; then echo "FAIL: dry-run must NOT poll"; errors=$((errors+1)); fi

# 8b. poll returns 2 (timeout) -> "did not finish within 60s", non-zero
wait_for_pr_checks() { return 2; }
if out=$(merge_repo "$CGR" merge false false 60 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: timeout poll should make merge_repo return non-zero"; errors=$((errors+1)); fi
case "$out" in *"did not finish within 60s"*) : ;; *) echo "FAIL: expected timeout stop message: $out"; errors=$((errors+1)) ;; esac

# 8c. poll returns 1 (failed) -> "CI not green — stopping", non-zero
wait_for_pr_checks() { return 1; }
if out=$(merge_repo "$CGR" merge false false 60 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: failed poll should make merge_repo return non-zero"; errors=$((errors+1)); fi
case "$out" in *"CI not green — stopping"*) : ;; *) echo "FAIL: expected not-green stop message: $out"; errors=$((errors+1)) ;; esac

unset -f gh wait_for_pr_checks
source "$SCRIPT_DIR/lib/ci.sh"   # restore real wait_for_pr_checks
rm -rf "$CG_DIR" "$CG_LOG"

# --- merge_workspace threads ci_wait_timeout (5th arg) through to merge_repo ---
TW_DIR=$(mktemp -d); mkdir -p "$TW_DIR/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$TW_DIR/.collab/dep-graph.json"
git -C "$TW_DIR" init -b main a &>/dev/null
git -C "$TW_DIR/a" config user.email t@t.t; git -C "$TW_DIR/a" config user.name t
git -C "$TW_DIR/a" commit --allow-empty -m i &>/dev/null
git -C "$TW_DIR/a" checkout -b feat/x &>/dev/null
TW_LOG=$(mktemp)
merge_repo() { echo "ci=$5" >> "$TW_LOG"; return 0; }
# subset {a}, ci_wait_timeout=120
merge_workspace "$TW_DIR" merge true false 120 a &>/dev/null
case "$(cat "$TW_LOG")" in *"ci=120"*) : ;; *) echo "FAIL: merge_workspace should thread ci_wait_timeout=120 to merge_repo: $(cat "$TW_LOG")"; errors=$((errors+1)) ;; esac
# default (no ci arg, no subset) -> merge_repo gets empty ci_wait_timeout
: > "$TW_LOG"
merge_workspace "$TW_DIR" merge true &>/dev/null
case "$(cat "$TW_LOG")" in *"ci="*) : ;; *) echo "FAIL: merge_repo should be invoked in default path: $(cat "$TW_LOG")"; errors=$((errors+1)) ;; esac
if grep -q 'ci=120' "$TW_LOG"; then echo "FAIL: default path should not carry a timeout"; errors=$((errors+1)); fi
unset -f merge_repo
rm -rf "$TW_DIR" "$TW_LOG"

# --- branch merge dispatch: --wait-ci / --ci-timeout parsing + order-independent validation ---
DC=$(mktemp -d); mkdir -p "$DC/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DC/.collab/dep-graph.json"
# 10. --ci-timeout without --wait-ci -> error, non-zero
if out=$(MRA_WORKSPACE="$DC" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --ci-timeout 60 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: --ci-timeout without --wait-ci should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"requires --wait-ci"*) : ;; *) echo "FAIL: expected 'requires --wait-ci': $out"; errors=$((errors+1)) ;; esac
# 11. --ci-timeout BEFORE --wait-ci -> accepted (no validation error), order-independent
out=$(MRA_WORKSPACE="$DC" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --ci-timeout 60 --wait-ci 2>&1) || true
case "$out" in *"requires --wait-ci"*|*"positive integer"*) echo "FAIL: timeout-before-wait should be accepted: $out"; errors=$((errors+1)) ;; *) : ;; esac
# 12. non-integer --ci-timeout -> error
if out=$(MRA_WORKSPACE="$DC" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --ci-timeout abc --wait-ci 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: non-integer --ci-timeout should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"positive integer"*) : ;; *) echo "FAIL: expected 'positive integer': $out"; errors=$((errors+1)) ;; esac
# 13. --wait-ci with a bad subset repo -> subset validation before gh-auth (Phase 9 ordering proof)
if out=$(MRA_WORKSPACE="$DC" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --wait-ci ghost 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: bad subset repo should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
case "$out" in *"gh authentication"*) echo "FAIL: subset validation must precede gh-auth: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$DC"
# usage advertises --wait-ci / --ci-timeout
grep -q 'branch merge .*--wait-ci' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise --wait-ci"; errors=$((errors+1)); }

if [[ $errors -eq 0 ]]; then
  echo "PASS: pr-ops ordering tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
