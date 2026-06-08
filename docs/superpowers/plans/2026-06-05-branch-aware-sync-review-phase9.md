# Branch pr/merge repo subset (Phase 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `mra branch pr` and `mra branch merge` accept an optional trailing `[repos…]` list that restricts the operation to that subset, mirroring `mra branch new <name> [repos…]`.

**Architecture:** The subset is resolved entirely above the single-repo workers (`pr_repo`/`merge_repo` are untouched). Two new helpers in `lib/pr-ops.sh` — `validate_repo_subset` (fail-fast name/existence check, called by the dispatch before the gh-auth preflight) and `warn_excluded_feature_deps` (advisory warning). `pr_workspace`/`merge_workspace` gain an optional trailing repo-list; empty = current full-workspace scan unchanged.

**Tech Stack:** Bash (shell library + `bin/mra.sh` dispatch), custom PASS/FAIL test harness in `tests/test_pr_ops.sh`, `jq`/`git`/`gh`.

**Spec:** `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` §17.

---

## File Structure

- **`lib/pr-ops.sh`** (modify) — add `validate_repo_subset` and `warn_excluded_feature_deps`; refactor `pr_workspace`/`merge_workspace` to accept an optional trailing subset.
- **`bin/mra.sh`** (modify) — `branch pr` / `branch merge` dispatch: collect positional repos, validate before `check_gh_auth`, pass subset through; usage lines updated.
- **`tests/test_pr_ops.sh`** (modify) — source `branch-ops.sh`; add subset tests for both helpers, both workspace functions, and both dispatch paths.

Reference facts (read before starting):
- `validate_repo_name` lives in `lib/branch-ops.sh:17` (rejects `-*`, `.`, `..`, `*/*`).
- `should_skip_dir` lives in `lib/sync.sh:36` (true for non-git / missing dir).
- `get_project_deps project graph_file` lives in `lib/deps.sh:19` (prints deps one per line).
- `bin/mra.sh` sources `branch-ops.sh` (line 18), `pr-ops.sh` (line 20), `deps.sh` (line 21) — all helpers are in scope at dispatch time.
- `tests/test_pr_ops.sh` currently sources colors/sync/branch/deps/pr-ops — it does NOT source `branch-ops.sh` yet.

---

## Task 1: `validate_repo_subset` helper

**Files:**
- Modify: `tests/test_pr_ops.sh` (add `source branch-ops.sh` near the top, then append tests at end)
- Modify: `lib/pr-ops.sh` (add function)

- [ ] **Step 1: Add the missing source line to the test file**

In `tests/test_pr_ops.sh`, after the existing `source "$SCRIPT_DIR/lib/branch.sh"` line, add:

```bash
source "$SCRIPT_DIR/lib/branch-ops.sh"
```

- [ ] **Step 2: Write the failing test** (append at the end of `tests/test_pr_ops.sh`, before the final summary/exit block)

```bash
# --- validate_repo_subset: names + existence, fail-fast, reports ALL failures ---
VS=$(mktemp -d)
git -C "$VS" init -b main a &>/dev/null
git -C "$VS/a" config user.email t@t.t; git -C "$VS/a" config user.name t
git -C "$VS/a" commit --allow-empty -m i &>/dev/null
mkdir -p "$VS/notrepo"

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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL output `validate_repo_subset: command not found` (or non-zero exit) for the new block.

- [ ] **Step 4: Write the implementation** (add to `lib/pr-ops.sh`, after `order_repos_by_deps`, before `pr_repo`)

```bash
# Validate an explicit repo subset against the workspace: each name must pass
# validate_repo_name and resolve to a non-skipped git repo. Reports ALL failures,
# returns non-zero if any. Side-effect-free (no gh, no writes) so the dispatch can
# call it before the gh-auth preflight.
validate_repo_subset() {
  local workspace="$1"; shift
  local failed=0 r dir
  for r in "$@"; do
    if ! validate_repo_name "$r"; then
      log_error "invalid repo name: '$r'" "branch"; failed=$((failed+1)); continue
    fi
    dir="$workspace/$r"
    if should_skip_dir "$dir"; then
      log_error "$r: not a git repo" "branch"; failed=$((failed+1)); continue
    fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (no new FAIL lines; final summary shows 0 errors).

- [ ] **Step 6: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): validate_repo_subset (names + existence, fail-fast)"
```

---

## Task 2: `warn_excluded_feature_deps` helper

**Files:**
- Modify: `tests/test_pr_ops.sh` (append tests)
- Modify: `lib/pr-ops.sh` (add function)

- [ ] **Step 1: Write the failing test** (append at end of `tests/test_pr_ops.sh`)

```bash
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
rm -rf "$WE"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL `warn_excluded_feature_deps: command not found`.

- [ ] **Step 3: Write the implementation** (add to `lib/pr-ops.sh`, after `validate_repo_subset`)

```bash
# Advisory warning: for each repo in the subset, if it depends (per the dep graph)
# on a repo that is itself on a feature branch but NOT in the subset, warn (the
# PR/merge order may be incomplete). Pure logging — never changes control flow.
# Signature: warn_excluded_feature_deps workspace graph_file subset...
warn_excluded_feature_deps() {
  local workspace="$1" graph_file="$2"; shift 2
  local subset=("$@")
  local subset_str=" ${subset[*]} "
  local r dep ddir dbr ddef
  for r in "${subset[@]}"; do
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      [[ "$subset_str" == *" $dep "* ]] && continue   # dep is in the subset — fine
      ddir="$workspace/$dep"
      [[ -d "$ddir" ]] || continue
      should_skip_dir "$ddir" && continue
      dbr=$(git -C "$ddir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
      ddef=$(get_default_branch "$ddir")
      if [[ "$dbr" != "(detached)" && "$dbr" != "$ddef" ]]; then
        log_warn "$r: depends on '$dep' (on feature branch '$dbr', not in selected subset) — PR/merge order may be incomplete" "branch"
      fi
    done < <(get_project_deps "$r" "$graph_file")
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors).

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): warn_excluded_feature_deps (advisory cross-subset dep warning)"
```

---

## Task 3: `pr_workspace` accepts an optional subset

**Files:**
- Modify: `tests/test_pr_ops.sh` (append tests)
- Modify: `lib/pr-ops.sh` (replace `pr_workspace`)

- [ ] **Step 1: Write the failing test** (append at end of `tests/test_pr_ops.sh`)

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `pr_workspace` ignores the extra args today, so `b:.*would open` appears (b not excluded) and the default-branch skip message is absent.

- [ ] **Step 3: Write the implementation** (replace the entire `pr_workspace` function in `lib/pr-ops.sh`)

```bash
# Open PRs across feature-branch repos in dependency order. Optional trailing
# repo names restrict the operation to that subset (default-branch repos in the
# subset are skipped with info; excluded feature-branch deps trigger a warning).
# No subset args = full-workspace scan (unchanged). Returns non-zero if any failed.
pr_workspace() {
  local workspace="$1" base="$2" dry_run="${3:-false}"
  local subset=("${@:4}")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  # Names to consider: explicit subset, or every workspace git repo.
  local consider=() dir name
  if [[ ${#subset[@]} -gt 0 ]]; then
    consider=("${subset[@]}")
  else
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      should_skip_dir "$dir" && continue
      consider+=("$name")
    done
  fi

  # Keep only feature-branch repos; in subset mode, info-skip default-branch ones.
  local candidates=() br base_ref
  for name in "${consider[@]}"; do
    dir="$workspace/$name"
    should_skip_dir "$dir" && continue
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    base_ref="$base"
    [[ -z "$base_ref" ]] && base_ref=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$base_ref" ]]; then
      candidates+=("$name")
    elif [[ ${#subset[@]} -gt 0 ]]; then
      log_info "$name: on base branch '$base_ref' — nothing to PR, skipping" "branch"
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "no feature-branch repos to PR" "branch"; return 0
  fi

  if [[ ${#subset[@]} -gt 0 ]]; then
    warn_excluded_feature_deps "$workspace" "$graph_file" "${candidates[@]}"
  fi

  local ordered=() failed=0 r
  while IFS= read -r r; do
    [[ -n "$r" ]] && ordered+=("$r")
  done < <(order_repos_by_deps "$graph_file" "${candidates[@]}")
  for r in "${ordered[@]}"; do
    if ! pr_repo "$workspace/$r" "$base" "$dry_run"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors) — including the pre-existing `pr_workspace` tests (no-subset path unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): pr_workspace optional [repos...] subset"
```

---

## Task 4: `merge_workspace` accepts an optional subset

**Files:**
- Modify: `tests/test_pr_ops.sh` (append tests)
- Modify: `lib/pr-ops.sh` (replace `merge_workspace`)

- [ ] **Step 1: Write the failing test** (append at end of `tests/test_pr_ops.sh`)

```bash
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
merge_workspace "$MS_DIR" merge true false a &>/dev/null
grep -qx a "$MS_LOG" || { echo "FAIL: subset {a} should merge a"; errors=$((errors+1)); }
if grep -qx b "$MS_LOG"; then echo "FAIL: b (excluded) should not be merged"; errors=$((errors+1)); fi
# named repo on default branch -> skip+info, not passed to merge_repo
: > "$MS_LOG"
git -C "$MS_DIR/b" checkout main &>/dev/null
out=$(merge_workspace "$MS_DIR" merge true false a b 2>&1) || true
grep -qx a "$MS_LOG" || { echo "FAIL: a should still merge: $out"; errors=$((errors+1)); }
if grep -qx b "$MS_LOG"; then echo "FAIL: b on default should not reach merge_repo"; errors=$((errors+1)); fi
case "$out" in *"b: on default branch"*) : ;; *) echo "FAIL: b on default should info-skip: $out"; errors=$((errors+1)) ;; esac
unset -f merge_repo
rm -rf "$MS_DIR" "$MS_LOG"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — current `merge_workspace` ignores extra args, so `b` is merged (appears in `$MS_LOG`) and the default-branch info-skip message is absent.

- [ ] **Step 3: Write the implementation** (replace the entire `merge_workspace` function in `lib/pr-ops.sh`)

```bash
# Merge open PRs across feature-branch repos in dependency order (deps first).
# Optional trailing repo names restrict to that subset (default-branch repos in
# the subset are skipped with info; excluded feature-branch deps trigger a warning).
# No subset args = full-workspace scan (unchanged). Stop-on-first-failure.
merge_workspace() {
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}"
  local subset=("${@:5}")
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")

  # Names to consider: explicit subset, or every workspace git repo.
  local consider=() dir name
  if [[ ${#subset[@]} -gt 0 ]]; then
    consider=("${subset[@]}")
  else
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      should_skip_dir "$dir" && continue
      consider+=("$name")
    done
  fi

  # Keep only feature-branch repos; in subset mode, info-skip default-branch ones.
  local candidates=() br def
  for name in "${consider[@]}"; do
    dir="$workspace/$name"
    should_skip_dir "$dir" && continue
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    def=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$def" ]]; then
      candidates+=("$name")
    elif [[ ${#subset[@]} -gt 0 ]]; then
      log_info "$name: on default branch '$def' — nothing to merge, skipping" "branch"
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "no feature-branch repos to merge" "branch"; return 0
  fi

  if [[ ${#subset[@]} -gt 0 ]]; then
    warn_excluded_feature_deps "$workspace" "$graph_file" "${candidates[@]}"
  fi

  local ordered=() r
  while IFS= read -r r; do
    [[ -n "$r" ]] && ordered+=("$r")
  done < <(order_repos_by_deps "$graph_file" "${candidates[@]}")
  for r in "${ordered[@]}"; do
    merge_repo "$workspace/$r" "$strategy" "$dry_run" "$delete_branch" || return 1
  done
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors) — including pre-existing `merge_workspace` order + stop-on-first-failure tests.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): merge_workspace optional [repos...] subset"
```

---

## Task 5: Wire `branch pr` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` — `pr)` sub-dispatch (currently `bin/mra.sh:654-669`) and usage line (`bin/mra.sh:104`)
- Modify: `tests/test_pr_ops.sh` (append integration tests)

- [ ] **Step 1: Write the failing test** (append at end of `tests/test_pr_ops.sh`)

```bash
# --- branch pr dispatch: subset validation runs BEFORE gh-auth; unknown flag rejected ---
DP=$(mktemp -d); mkdir -p "$DP/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DP/.collab/dep-graph.json"
# missing repo -> abort with "not a git repo", and NOT a gh-auth error (ordering proof)
if out=$(MRA_WORKSPACE="$DP" bash "$SCRIPT_DIR/bin/mra.sh" branch pr ghost 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: branch pr with missing repo should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
case "$out" in *"gh authentication"*) echo "FAIL: must fail on subset validation before gh-auth: $out"; errors=$((errors+1)) ;; *) : ;; esac
# unknown flag -> "unknown option"
out=$(MRA_WORKSPACE="$DP" bash "$SCRIPT_DIR/bin/mra.sh" branch pr -x 2>&1) || true
case "$out" in *"unknown option"*) : ;; *) echo "FAIL: unknown flag should error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DP"
# usage line advertises [repos...]
grep -q 'branch pr .*\[repos\.\.\.\]' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise 'branch pr ... [repos...]'"; errors=$((errors+1)); }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — today `branch pr ghost` hits `*) unknown option: ghost` (positional repos not yet supported) and the usage grep finds no `[repos...]`.

- [ ] **Step 3: Replace the `pr)` sub-dispatch** in `bin/mra.sh` (the block starting `pr)` at line 654)

```bash
        pr)
          local base="" dry_run=false repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --base) if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "branch"; exit 1; fi; base="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch pr requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          pr_workspace "$workspace" "$base" "$dry_run" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
```

- [ ] **Step 4: Update the usage line** in `bin/mra.sh` (line 104)

Replace:

```
  branch pr [--base <ref>] [--dry-run]  Push feature branches and open PRs across repos (deps first)
```

with:

```
  branch pr [--base <ref>] [--dry-run] [repos...]  Push feature branches and open PRs across repos (deps first; repos... = subset)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_pr_ops.sh
git commit -m "feat(branch): branch pr [repos...] subset (validate before gh-auth) + usage"
```

---

## Task 6: Wire `branch merge` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` — `merge)` sub-dispatch (currently `bin/mra.sh:670-690`) and usage line (`bin/mra.sh:105`)
- Modify: `tests/test_pr_ops.sh` (append integration tests)

- [ ] **Step 1: Write the failing test** (append at end of `tests/test_pr_ops.sh`)

```bash
# --- branch merge dispatch: subset validation runs BEFORE gh-auth; strategy still checked ---
DM=$(mktemp -d); mkdir -p "$DM/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DM/.collab/dep-graph.json"
# missing repo -> abort with "not a git repo", NOT a gh-auth error
if out=$(MRA_WORKSPACE="$DM" bash "$SCRIPT_DIR/bin/mra.sh" branch merge ghost 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: branch merge with missing repo should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"not a git repo"*) : ;; *) echo "FAIL: expected 'not a git repo': $out"; errors=$((errors+1)) ;; esac
case "$out" in *"gh authentication"*) echo "FAIL: must fail on subset validation before gh-auth: $out"; errors=$((errors+1)) ;; *) : ;; esac
# invalid --strategy still rejected even with a repo arg
out=$(MRA_WORKSPACE="$DM" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --strategy bogus somerepo 2>&1) || true
case "$out" in *"merge|squash|rebase"*|*strategy*) : ;; *) echo "FAIL: invalid strategy should error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DM"
# usage line advertises [repos...]
grep -q 'branch merge .*\[repos\.\.\.\]' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise 'branch merge ... [repos...]'"; errors=$((errors+1)); }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `branch merge ghost` hits `*) unknown option: ghost` today, and the usage grep finds no `[repos...]`.

- [ ] **Step 3: Replace the `merge)` sub-dispatch** in `bin/mra.sh` (the block starting `merge)` at line 670)

```bash
        merge)
          local strategy="merge" dry_run=false delete_branch=false repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              --delete-branch) delete_branch=true; shift ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          case "$strategy" in
            merge|squash|rebase) ;;
            *) log_error "branch merge: --strategy must be merge|squash|rebase" "branch"; exit 1 ;;
          esac
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch merge requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          merge_workspace "$workspace" "$strategy" "$dry_run" "$delete_branch" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
```

- [ ] **Step 4: Update the usage line** in `bin/mra.sh` (line 105)

Replace:

```
  branch merge [--strategy S] [--dry-run] [--delete-branch]  Merge open PRs across repos (deps first; gated on mergeable+CI)
```

with:

```
  branch merge [--strategy S] [--dry-run] [--delete-branch] [repos...]  Merge open PRs across repos (deps first; gated on mergeable+CI; repos... = subset)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_pr_ops.sh
git commit -m "feat(branch): branch merge [repos...] subset (validate before gh-auth) + usage"
```

---

## Task 7: Full regression + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` (§17 status note) + re-render `.html`

- [ ] **Step 1: Run the full suite**

Run: `bash test.sh`
Expected: `shell tests: 44 passed, 0 failed` and `mcp-server : ok`. (No new suite file is added — Phase 9 tests live inside the existing `tests/test_pr_ops.sh`.)

- [ ] **Step 2: Flip the §17 status note** in the spec

Replace the `**Status:**` line under `## 17. Phase 9 …`:

```
**Status:** Approved (design) — 2026-06-05. Implementation scope for the next plan. One capability; no new subsystem. Reactivates §11.6.2.
```

with:

```
**Status:** Implemented — 2026-06-05. `branch pr`/`branch merge` accept `[repos…]`; `validate_repo_subset` + `warn_excluded_feature_deps` in `lib/pr-ops.sh`. Reactivated §11.6.2.
```

- [ ] **Step 3: Re-render the spec HTML**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md`
Expected: `✓ …-design.md -> …-design.html`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.html
git commit -m "docs(spec): mark Phase 9 (branch pr/merge subset) implemented"
```

---

## Self-Review Notes

- **Spec coverage:** §17.1 surface → Tasks 5/6 (dispatch + usage). §17.2 dispatch ordering / fail-fast → Task 1 (helper) + Tasks 5/6 (ordering proof tests). §17.2 candidate filter (default-branch skip) → Tasks 3/4. §17.2 dep warning → Task 2 + wired in Tasks 3/4. §17.3 architecture → all tasks. §17.4 error handling → Tasks 1/5/6. §17.5 testing items 1–8 → distributed across Tasks 3–6. §17.6 out-of-scope → respected (no sync/review changes, no auto-include, no CI polling).
- **No placeholders:** every code step shows full function bodies / exact replacement text.
- **Type/name consistency:** `validate_repo_subset workspace repos…` and `warn_excluded_feature_deps workspace graph_file subset…` used identically in helper definition (Tasks 1/2) and callers (Tasks 3/4/5/6). Note: the §17.3 spec sketched `warn_excluded_feature_deps graph_file subset… -- feature_repos…`; this plan uses the spec-sanctioned "equivalent signature" `workspace graph_file subset…` (lazy per-dep branch check — no full second scan), which the spec explicitly permits.
