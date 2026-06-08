# Branch-aware Sync & Review — Phase 7 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra branch merge [--strategy merge|squash|rebase] [--dry-run]` — merge each repo's open PR in dependency order, gated on mergeability + CI, stopping on the first failure.

**Architecture:** Two new functions in `lib/pr-ops.sh` (`merge_repo`, `merge_workspace`) sibling to `pr_repo`/`pr_workspace`, reusing `order_repos_by_deps`/`get_default_branch`/`should_skip_dir`. `bin/mra.sh` gains a `branch merge` subcommand with `gh` preflight + strategy validation. Merge state comes live from `gh` (no local fetch); merges happen on GitHub (no local writes).

**Tech Stack:** Bash, git CLI, `gh` CLI, `jq`, existing `lib/pr-ops.sh`/`lib/preflight.sh`, plain-bash tests under `tests/`.

---

## File Structure

- **Modify `lib/pr-ops.sh`** — add `merge_repo()` and `merge_workspace()`.
- **Modify `bin/mra.sh`** — `branch merge` dispatch (`--strategy`/`--dry-run`, gh preflight, strategy validation) + usage.
- **Modify `tests/test_pr_ops.sh`** — merge_repo skip paths, merge_workspace collect+order (stub), `--strategy` validation (subprocess).

Task order: T1 `merge_repo` (+ skip tests) → T2 `merge_workspace` (+ order test) → T3 dispatch (+ validation test).

---

## Task 1: `merge_repo()`

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

`merge_repo` does local skips first (no `gh` needed), then queries the PR via `gh` and gates on mergeable + CI. Tests cover the skip paths (default-branch; feature-branch with no GitHub PR → `gh pr view` fails → "no open PR" skip); the gating + actual `gh pr merge` paths need a real GitHub PR and are not exercised (per existing `pr_repo` convention).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately before the final `if [[ $errors -eq 0 ]]` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `merge_repo: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/pr-ops.sh`:

```bash
# Merge one repo's open PR (for its current feature branch), gated on mergeable + CI.
# strategy: merge|squash|rebase. dry_run="true" previews only.
# Returns 0 on success/skip; non-zero when a PR exists but cannot merge or the merge fails (stop signal).
merge_repo() {
  local repo_dir="$1" strategy="${2:-merge}" dry_run="${3:-false}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0

  local branch; branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  if [[ "$branch" == "(detached)" ]]; then
    log_info "$repo_name: detached HEAD — skipping" "branch"; return 0
  fi
  local def; def=$(get_default_branch "$repo_dir")
  if [[ "$branch" == "$def" ]]; then
    log_info "$repo_name: on default branch '$def' — skipping" "branch"; return 0
  fi

  local pr_json
  pr_json=$(cd "$repo_dir" && gh pr view "$branch" --json number,state,mergeable 2>/dev/null || echo "")
  if [[ -z "$pr_json" ]]; then
    log_info "$repo_name: no open PR for '$branch' — skipping" "branch"; return 0
  fi
  local state number mergeable
  state=$(printf '%s' "$pr_json" | jq -r '.state' 2>/dev/null)
  number=$(printf '%s' "$pr_json" | jq -r '.number' 2>/dev/null)
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable' 2>/dev/null)

  if [[ "$state" != "OPEN" ]]; then
    log_info "$repo_name: PR #$number not open ($state) — skipping" "branch"; return 0
  fi
  if [[ "$mergeable" != "MERGEABLE" ]]; then
    log_error "$repo_name: PR #$number not mergeable ($mergeable) — stopping" "branch"; return 1
  fi
  if ! (cd "$repo_dir" && gh pr checks "$branch" >/dev/null 2>&1); then
    log_error "$repo_name: PR #$number CI not green — stopping" "branch"; return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "$repo_name: would merge PR #$number ($strategy)" "branch"; return 0
  fi
  if (cd "$repo_dir" && gh pr merge "$branch" --"$strategy" >/dev/null 2>&1); then
    log_success "$repo_name: merged PR #$number ($strategy)" "branch"; return 0
  fi
  log_error "$repo_name: gh pr merge failed for PR #$number" "branch"; return 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (default-branch skip; no-PR skip returns 0; dry-run no-PR skip). Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(merge): merge_repo (gated PR merge, skip/stop semantics)"
```

---

## Task 2: `merge_workspace()`

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately before the final `if [[ $errors -eq 0 ]]` block:

```bash
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
  git -C "$MW_DIR/$r" checkout -b feat/x &>/dev/null   # both on a feature branch
done

# stub merge_repo to record call order (avoids any gh)
MERGE_LOG=$(mktemp)
merge_repo() { echo "$(basename "$1")" >> "$MERGE_LOG"; return 0; }

merge_workspace "$MW_DIR" merge true &>/dev/null
# both collected, and b (dependency) before a (consumer)
pa=$(grep -nx a "$MERGE_LOG" | cut -d: -f1); pb=$(grep -nx b "$MERGE_LOG" | cut -d: -f1)
if [[ -z "$pa" || -z "$pb" || "$pb" -ge "$pa" ]]; then
  echo "FAIL: merge order should be b before a (got: $(tr '\n' ' ' < "$MERGE_LOG"))"; errors=$((errors+1))
fi

# all on default branch => no candidates
git -C "$MW_DIR/a" checkout main &>/dev/null; git -C "$MW_DIR/b" checkout main &>/dev/null
out=$(merge_workspace "$MW_DIR" merge true 2>&1) || true
case "$out" in *"no feature-branch repos"*) : ;; *) echo "FAIL: all-on-main should report no candidates: $out"; errors=$((errors+1)) ;; esac
rm -rf "$MW_DIR" "$MERGE_LOG"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `merge_workspace: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/pr-ops.sh`:

```bash
# Merge open PRs across feature-branch repos in dependency order (deps first).
# Stop-on-first-failure: a repo whose PR cannot merge (or whose merge fails) halts the batch.
merge_workspace() {
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}"
  local graph_file; graph_file=$(get_dep_graph_path "$workspace")
  local candidates=() dir name br def
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    def=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$def" ]]; then candidates+=("$name"); fi
  done
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "no feature-branch repos to merge" "branch"; return 0
  fi
  local ordered=() r
  while IFS= read -r r; do
    [[ -n "$r" ]] && ordered+=("$r")
  done < <(order_repos_by_deps "$graph_file" "${candidates[@]}")
  for r in "${ordered[@]}"; do
    merge_repo "$workspace/$r" "$strategy" "$dry_run" || return 1
  done
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (b before a; all-on-main → no candidates). Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(merge): merge_workspace (deps-ordered, stop-on-first-failure)"
```

---

## Task 3: Wire `branch merge` dispatch

**Files:**
- Modify: `bin/mra.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- branch merge dispatch: invalid --strategy rejected (before gh/workspace) ---
DSP=$(mktemp -d); mkdir -p "$DSP/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$DSP/.collab/dep-graph.json"
if out=$(MRA_WORKSPACE="$DSP" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --strategy bogus 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -eq 0 ]]; then echo "FAIL: invalid --strategy should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"merge|squash|rebase"*|*strategy*) : ;; *) echo "FAIL: expected strategy error: $out"; errors=$((errors+1)) ;; esac
rm -rf "$DSP"
```

(NOTE: `test_pr_ops.sh` defines `SCRIPT_DIR` at the top — it is in scope here.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `branch merge` is an unknown subcommand today (hits the `*)` usage error, but the message won't mention strategy; or it errors differently). The assertion on the strategy message fails.

- [ ] **Step 3: Add the `merge)` arm to the `branch)` dispatch**

In `bin/mra.sh`, in the `branch)` case's inner `case "$sub" in`, add a `merge)` arm immediately before the `*)` (default) arm:

```bash
        merge)
          local strategy="merge" dry_run=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          case "$strategy" in
            merge|squash|rebase) ;;
            *) log_error "branch merge: --strategy must be merge|squash|rebase" "branch"; exit 1 ;;
          esac
          if ! check_gh_auth; then
            log_error "branch merge requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          local workspace; workspace=$(resolve_workspace)
          merge_workspace "$workspace" "$strategy" "$dry_run"
          exit $?
          ;;
```

(Strategy validation runs BEFORE the `gh` preflight so an invalid strategy is rejected regardless of `gh` auth — this is what the test exercises.)

Also update the inner-case `*)` usage line to list `merge`:

```bash
        *)
          log_error "usage: mra branch status|new|switch|pr|merge ..." "branch"; exit 1 ;;
```

- [ ] **Step 4: Update usage text**

In the usage heredoc, add after the `branch pr` line:

```
  branch merge [--strategy S] [--dry-run]  Merge open PRs across repos (deps first; gated on mergeable+CI)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (invalid strategy → non-zero + message). Then `bash test.sh` — all green.

- [ ] **Step 6: Smoke test (gh-dependent — outcome depends on auth)**

Run:
```bash
WS=$(mktemp -d); mkdir -p "$WS/.collab"; echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main a &>/dev/null
git -C "$WS/a" config user.email t@t.t; git -C "$WS/a" config user.name t
git -C "$WS/a" commit --allow-empty -m init &>/dev/null
git -C "$WS/a" checkout -b feat/x &>/dev/null
git -C "$WS/a" commit --allow-empty -m work &>/dev/null
MRA_WORKSPACE="$WS" bash bin/mra.sh branch merge --dry-run; echo "exit=$?"
rm -rf "$WS"
```
Expected: either (gh authenticated) `a: no open PR for 'feat/x' — skipping` then exit 0 (the local fixture has no GitHub PR), OR (gh not authenticated) the gh-auth error + exit 1. Both prove the wiring (validation → preflight → merge_workspace → merge_repo no-PR skip).

- [ ] **Step 7: Commit**

```bash
git add bin/mra.sh tests/test_pr_ops.sh
git commit -m "feat(merge): wire mra branch merge dispatch (gh preflight, --strategy/--dry-run) + usage"
```

---

## Done — Phase 7 complete

After Task 3, `mra branch merge` merges each repo's open PR in dependency order, gated on mergeability + CI (`gh pr checks`), stopping on the first PR that can't merge; `--strategy merge|squash|rebase` and `--dry-run` are supported; skips (no PR / default branch / detached) don't halt. Out of scope (spec §15.8): conflict auto-resolution, CI polling, branch auto-deletion, merge queues.
