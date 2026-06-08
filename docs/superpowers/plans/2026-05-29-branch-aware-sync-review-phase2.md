# Branch-aware Sync & Review — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the cross-repo PR workflow to `mra`: `sync --review` (auto-review changed repos) and `branch pr [--base] [--dry-run]` (push + open PRs across repos in dependency order).

**Architecture:** A pure `review_targets` selector (new `lib/review-select.sh`) and a `sync_review_workspace` driver (in `lib/sync.sh`) deliver `sync --review`, reusing Phase 0 `safe_sync_repo` + `BranchState` and the existing `review_project` (terminal). A new `lib/pr-ops.sh` holds the pure `order_repos_by_deps` (Kahn best-effort) plus `pr_repo`/`pr_workspace`, reusing Phase 1 `push_repo` and `lib/deps.sh` relationships. `bin/mra.sh` adds `sync --review` and a `branch pr` subcommand with a `gh auth` preflight.

**Tech Stack:** Bash, git CLI, `gh` CLI (branch pr only), existing `lib/colors.sh`/`lib/deps.sh`/`lib/preflight.sh`, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Create `lib/review-select.sh`** — pure `review_targets(workspace, changed…)`.
- **Create `lib/pr-ops.sh`** — `order_repos_by_deps()`, `pr_repo()`, `pr_workspace()`.
- **Create `tests/test_review_select.sh`**, **`tests/test_pr_ops.sh`**.
- **Modify `lib/sync.sh`** — add `sync_review_workspace()`.
- **Modify `bin/mra.sh`** — source the two new libs; add `--review` to `sync)`; add `pr)` to `branch)`; `gh` preflight; usage.
- **Modify `tests/test_sync.sh`** — `sync_review_workspace` sync-detection (review call stubbed).

Reused as-is: `safe_sync_repo`, `push_repo`, `get_branch_state`, `branch_state_get`, `is_on_default_branch`, `get_default_branch`, `should_skip_dir` (sync.sh/branch.sh); `review_project` (review.sh, terminal mode); `get_project_deps`, `get_dep_graph_path` (deps.sh); `check_gh_auth` (preflight.sh). All are sourced by `bin/mra.sh` before use.

Dependency order: T1 review_targets → T2 sync_review_workspace → T3 wire sync --review → T4 order_repos_by_deps → T5 pr_repo → T6 pr_workspace → T7 wire branch pr.

---

## Task 1: `review_targets()` + `lib/review-select.sh`

**Files:**
- Create: `lib/review-select.sh`
- Test: `tests/test_review_select.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_select.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/review-select.sh"

errors=0
WS=$(mktemp -d)
for r in a b c; do
  mkdir -p "$WS/$r"
  git -C "$WS/$r" init -b main . &>/dev/null
  git -C "$WS/$r" config user.email t@t.t; git -C "$WS/$r" config user.name t
  git -C "$WS/$r" commit --allow-empty -m init &>/dev/null
done
# a: on a feature branch (off-default) -> selected via off-default
git -C "$WS/a" checkout -b feat/x &>/dev/null
# b: on main, passed as changed -> selected via changed
# c: on main, clean, not changed -> NOT selected

out=$(review_targets "$WS" b)
echo "$out" | grep -qx a || { echo "FAIL: 'a' (off-default) should be a target"; ((errors++)); }
echo "$out" | grep -qx b || { echo "FAIL: 'b' (changed) should be a target"; ((errors++)); }
if echo "$out" | grep -qx c; then echo "FAIL: 'c' (clean on-default, not changed) should NOT be a target"; ((errors++)); fi

# no changed args, only off-default selection
out2=$(review_targets "$WS")
echo "$out2" | grep -qx a || { echo "FAIL: 'a' should still be selected with no changed args"; ((errors++)); }
if echo "$out2" | grep -qx b; then echo "FAIL: 'b' should not be selected when not changed"; ((errors++)); fi
rm -rf "$WS"

if [[ $errors -eq 0 ]]; then
  echo "PASS: review-select tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_select.sh`
Expected: FAIL — `review_targets: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/review-select.sh`:

```bash
#!/usr/bin/env bash
# Pure selection of repos to auto-review after a sync.
# review_targets(workspace, changed...) = {changed} ∪ {repos with ahead>0 OR not on default branch}.
# Read-only; relies on get_branch_state / branch_state_get / is_on_default_branch / should_skip_dir.

review_targets() {
  local workspace="$1"; shift
  local seen=" " out=()
  # 1) repos sync changed this run (passed as args)
  local r
  for r in "$@"; do
    [[ -z "$r" ]] && continue
    if [[ "$seen" != *" $r "* ]]; then out+=("$r"); seen="$seen$r "; fi
  done
  # 2) repos with local work: ahead>0 or off-default
  local dir name state ahead on_default
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    state=$(get_branch_state "$dir")
    ahead=$(branch_state_get "$state" ahead)
    if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
    if [[ "$ahead" -gt 0 || "$on_default" != "true" ]]; then
      if [[ "$seen" != *" $name "* ]]; then out+=("$name"); seen="$seen$name "; fi
    fi
  done
  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_select.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/review-select.sh tests/test_review_select.sh
git commit -m "feat(review): review_targets selector (changed ∪ ahead ∪ off-default)"
```

---

## Task 2: `sync_review_workspace()` in `lib/sync.sh`

**Files:**
- Modify: `lib/sync.sh`
- Test: `tests/test_sync.sh`

`sync_review_workspace` runs `safe_sync_repo` per repo, records which HEADs moved, computes `review_targets`, and calls `review_project` (terminal) on each target. The test stubs `review_project` (defining a function of the same name in the test script overrides it) so no real Claude call happens — it asserts the right repos are selected/reviewed. The test must source `review-select.sh` and define the stub.

- [ ] **Step 1: Write the failing test**

In `tests/test_sync.sh`, add near the top (after the existing `source "$SCRIPT_DIR/lib/branch.sh"` line):

```bash
source "$SCRIPT_DIR/lib/review-select.sh"
```

Then append, immediately before the final `rm -rf "$TEST_DIR"`:

```bash
# --- sync_review_workspace: sync half + target selection (review stubbed) ---
SR_DIR=$(mktemp -d)
git -C "$SR_DIR" init -b main --bare up &>/dev/null
git clone "$SR_DIR/up" "$SR_DIR/a" &>/dev/null
git -C "$SR_DIR/a" config user.email t@t.t; git -C "$SR_DIR/a" config user.name t
git -C "$SR_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SR_DIR/a" push -u origin main &>/dev/null
# advance origin/main via a second clone, so repo a is behind -> safe_sync ff -> "changed"
git clone "$SR_DIR/up" "$SR_DIR/b" &>/dev/null
git -C "$SR_DIR/b" config user.email t@t.t; git -C "$SR_DIR/b" config user.name t
git -C "$SR_DIR/b" commit --allow-empty -m c2 &>/dev/null
git -C "$SR_DIR/b" push origin main &>/dev/null
# repo b stays on main and is up-to-date with its own clone (will not be 'changed' and is on-default => not a target)
git -C "$SR_DIR/b" fetch --quiet; git -C "$SR_DIR/b" pull --ff-only --quiet &>/dev/null || true

# stub review_project to avoid real Claude; record which repos were reviewed
REVIEW_LOG=$(mktemp)
review_project() { echo "$2" >> "$REVIEW_LOG"; return 0; }

sync_review_workspace "$SR_DIR" &>/dev/null
# repo a was behind -> fast-forwarded -> HEAD moved -> in 'changed' -> reviewed
if ! grep -qx a "$REVIEW_LOG"; then echo "FAIL: repo a (fast-forwarded) should be reviewed"; ((errors++)); fi
# repo b: on default branch, up-to-date, not changed -> NOT reviewed
if grep -qx b "$REVIEW_LOG"; then echo "FAIL: repo b (clean on-default) should NOT be reviewed"; ((errors++)); fi
rm -rf "$SR_DIR" "$REVIEW_LOG"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `sync_review_workspace: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/sync.sh`:

```bash
# Run a safe-sync across the workspace, then auto-review the changed repos.
# "changed" = repos whose HEAD moved during sync; review targets also include
# repos with local work (ahead>0 / off-default), via review_targets.
# Reviews run via review_project in terminal mode. Returns non-zero if any review failed.
sync_review_workspace() {
  local workspace="$1"
  local changed=() failed=0
  local dir name before after
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    before=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    safe_sync_repo "$dir" || true
    after=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    [[ -n "$before" && "$before" != "$after" ]] && changed+=("$name")
  done

  local targets=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && targets+=("$t")
  done < <(review_targets "$workspace" ${changed[@]+"${changed[@]}"})

  if [[ ${#targets[@]} -eq 0 ]]; then
    log_info "no repos to review" "sync"; return 0
  fi
  local repo
  for repo in "${targets[@]}"; do
    log_progress "reviewing $repo" "sync"
    if ! review_project "$workspace" "$repo"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: PASS (repo a fast-forwarded and reviewed; repo b not). Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): sync_review_workspace (safe-sync then auto-review changed repos)"
```

---

## Task 3: Wire `sync --review` dispatch

**Files:**
- Modify: `bin/mra.sh`

- [ ] **Step 1: Source `lib/review-select.sh`**

In `bin/mra.sh`, find `source "$MRA_DIR/lib/branch-ops.sh"` and add immediately after it:

```bash
source "$MRA_DIR/lib/review-select.sh"
```

- [ ] **Step 2: Replace the `sync)` dispatch case**

Find the existing `sync)` case and replace the WHOLE case with (adds `--review`; review is the top mode, then push, then safe, then default):

```bash
    sync)
      shift
      local safe=false push=false dry_run=false review=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --safe) safe=true; shift ;;
          --push) push=true; shift ;;
          --dry-run) dry_run=true; shift ;;
          --review) review=true; shift ;;
          *) log_error "unknown option: $1" "sync"; exit 1 ;;
        esac
      done
      local workspace; workspace=$(resolve_workspace)
      if [[ "$review" == "true" ]]; then
        sync_review_workspace "$workspace"
        exit $?
      elif [[ "$push" == "true" ]]; then
        push_workspace "$workspace" "$dry_run"
        exit $?
      elif [[ "$safe" == "true" ]]; then
        safe_sync_workspace "$workspace"
        exit $?
      else
        # Default: reproduce existing helper behavior as a public command.
        local graph_file git_org
        graph_file=$(get_dep_graph_path "$workspace")
        git_org=$(jq -r '.gitOrg' "$graph_file")
        sync_from_repos_json "$workspace" "$git_org"
        exit $?
      fi
      ;;
```

- [ ] **Step 3: Update usage text**

In the usage heredoc, replace the existing `sync [--safe] [--push] [--dry-run]` line with:

```
  sync [--safe] [--push] [--dry-run] [--review]  Clone/pull; --safe ff-only; --push pushes; --review auto-reviews changed repos
```

- [ ] **Step 4: Smoke test**

Run:

```bash
WS=$(mktemp -d)
git -C "$WS" init -b main --bare up &>/dev/null
git clone "$WS/up" "$WS/a" &>/dev/null
git -C "$WS/a" config user.email t@t.t; git -C "$WS/a" config user.name t
git -C "$WS/a" commit --allow-empty -m c1 &>/dev/null
git -C "$WS/a" push -u origin main &>/dev/null
# a on main, clean, up-to-date => no targets
MRA_WORKSPACE="$WS" bash bin/mra.sh sync --review; echo "review exit=$?"
rm -rf "$WS"
```

Expected: logs `no repos to review` and `review exit=0` (clean on-default repo, nothing changed → no targets, no Claude call).

- [ ] **Step 5: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(sync): wire mra sync --review dispatch + usage"
```

---

## Task 4: `order_repos_by_deps()` + `lib/pr-ops.sh`

**Files:**
- Create: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

Kahn best-effort ordering WITHIN the to-PR set: a repo is "ready" when all of its in-set dependencies are already ordered (dependencies before consumers). If a round makes no progress (cycle / missing data), the remaining repos are appended in their given order with a logged note.

- [ ] **Step 1: Write the failing test**

Create `tests/test_pr_ops.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/pr-ops.sh"

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
  echo "FAIL: dependency 'b' should be ordered before consumer 'a' (got: $(echo $ordered | tr '\n' ' '))"; ((errors++))
fi
# all three present
for r in a b c; do echo "$ordered" | grep -qx "$r" || { echo "FAIL: $r missing from order"; ((errors++)); }; done

# unrelated subset (only c) -> just c, no error
ordered2=$(order_repos_by_deps "$GF" c)
if [[ "$(echo "$ordered2" | tr -d '[:space:]')" != "c" ]]; then echo "FAIL: single repo should order to itself"; ((errors++)); fi
rm -f "$GF"

if [[ $errors -eq 0 ]]; then
  echo "PASS: pr-ops ordering tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `order_repos_by_deps: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/pr-ops.sh`:

```bash
#!/usr/bin/env bash
# Cross-repo PR operations (writes / gh). Pure ordering + per-repo PR + workspace driver.

# Order the given repos dependency-first (Kahn best-effort) within the set.
# Args: graph_file repo...  -> prints ordered repo names, one per line.
order_repos_by_deps() {
  local graph_file="$1"; shift
  local allset=" $* "
  local remaining=("$@") ordered=() ordered_str=" "
  while [[ ${#remaining[@]} -gt 0 ]]; do
    local ready=() notready=() r dep blocked
    for r in "${remaining[@]}"; do
      blocked=false
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        # blocked if an in-set dependency is not yet ordered
        if [[ "$allset" == *" $dep "* && "$ordered_str" != *" $dep "* ]]; then
          blocked=true; break
        fi
      done < <(get_project_deps "$r" "$graph_file")
      if [[ "$blocked" == "true" ]]; then notready+=("$r"); else ready+=("$r"); fi
    done
    if [[ ${#ready[@]} -eq 0 ]]; then
      log_warn "branch pr: cannot fully order by deps (cycle?), using given order for: ${remaining[*]}" "branch"
      for r in "${remaining[@]}"; do ordered+=("$r"); done
      break
    fi
    for r in $(printf '%s\n' "${ready[@]}" | sort); do
      ordered+=("$r"); ordered_str="$ordered_str$r "
    done
    remaining=(${notready[@]+"${notready[@]}"})
  done
  [[ ${#ordered[@]} -gt 0 ]] && printf '%s\n' "${ordered[@]}"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr): order_repos_by_deps (Kahn best-effort, deps before consumers)"
```

---

## Task 5: `pr_repo()`

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

`pr_repo` is gated by local checks that need no `gh`: skip detached/on-base, skip when the branch has no commits vs base (eligibility), and `--dry-run` previews. The actual push + `gh pr create` path is only reached for an eligible feature branch in non-dry-run mode (not exercised in tests — needs a real GitHub remote). After push it verifies the branch is fully published (`origin/<branch>` matches local) before opening a PR, so a `behind`/`diverged` push-skip never produces a PR.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- pr_repo: dry-run previews, never pushes; skip rules ---
PR_DIR=$(mktemp -d)
git -C "$PR_DIR" init -b main --bare up &>/dev/null
git clone "$PR_DIR/up" "$PR_DIR/a" &>/dev/null
git -C "$PR_DIR/a" config user.email t@t.t; git -C "$PR_DIR/a" config user.name t
git -C "$PR_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PR_DIR/a" push -u origin main &>/dev/null

# on default branch (main) => skip, no push
out=$(pr_repo "$PR_DIR/a" "" false 2>&1) || true
case "$out" in *base*|*skip*|*on*) : ;; *) echo "FAIL: default-branch repo should be skipped: $out"; ((errors++)) ;; esac

# feature branch with a commit, dry-run => would-open, no remote ref created
git -C "$PR_DIR/a" checkout -b feat/x &>/dev/null
git -C "$PR_DIR/a" commit --allow-empty -m work &>/dev/null
before=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/x' || true)
out=$(pr_repo "$PR_DIR/a" "" true 2>&1) || true
case "$out" in *would*) : ;; *) echo "FAIL: dry-run should print would-open: $out"; ((errors++)) ;; esac
after=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/x' || true)
if [[ "$before" != "$after" ]]; then echo "FAIL: dry-run must not push feat/x to remote"; ((errors++)); fi

# feature branch with NO commits vs base => eligibility skip, no push
git -C "$PR_DIR/a" checkout -b feat/empty main &>/dev/null
out=$(pr_repo "$PR_DIR/a" "main" true 2>&1) || true
case "$out" in *nothing*|*no commits*) : ;; *) echo "FAIL: empty branch should skip (eligibility): $out"; ((errors++)) ;; esac
ref_empty=$(git -C "$PR_DIR/up" for-each-ref --format='%(refname)' | grep -c 'feat/empty' || true)
if [[ "$ref_empty" != "0" ]]; then echo "FAIL: empty branch must not be pushed"; ((errors++)); fi
rm -rf "$PR_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `pr_repo: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/pr-ops.sh`:

```bash
# Open a PR for one repo. base="" -> repo's default branch. dry_run="true" -> preview only.
# Skips detached/on-base/no-commits-vs-base. Pushes via push_repo (never force), then
# verifies the branch is fully published before opening. Existing PR -> report URL (not a failure).
pr_repo() {
  local repo_dir="$1" base="$2" dry_run="${3:-false}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0

  local branch; branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  local base_ref="$base"
  if [[ -z "$base_ref" ]]; then base_ref=$(get_default_branch "$repo_dir"); fi

  if [[ "$branch" == "(detached)" ]]; then
    log_warn "$repo_name: detached HEAD — skipping" "branch"; return 0
  fi
  if [[ "$branch" == "$base_ref" ]]; then
    log_warn "$repo_name: on base branch '$base_ref' — skipping" "branch"; return 0
  fi

  local count
  count=$(git -C "$repo_dir" rev-list --count "${base_ref}..${branch}" 2>/dev/null || echo 0)
  if [[ "${count:-0}" -eq 0 ]]; then
    log_info "$repo_name: no commits vs $base_ref — nothing to PR, skipping" "branch"; return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "$repo_name: would open PR: $branch → $base_ref" "branch"; return 0
  fi

  if ! push_repo "$repo_dir" false; then
    log_error "$repo_name: push failed — not opening PR" "branch"; return 1
  fi
  # verify branch fully published (guards against behind/diverged push-skip)
  local lref rref
  lref=$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || echo "L")
  rref=$(git -C "$repo_dir" rev-parse "origin/$branch" 2>/dev/null || echo "R")
  if [[ "$lref" != "$rref" ]]; then
    log_warn "$repo_name: branch not fully published (behind/diverged) — skipping PR" "branch"; return 0
  fi

  local existing
  existing=$(cd "$repo_dir" && gh pr view "$branch" --json url --jq '.url' 2>/dev/null || echo "")
  if [[ -n "$existing" ]]; then
    log_success "$repo_name: PR already exists: $existing" "branch"; return 0
  fi
  local url
  if url=$(cd "$repo_dir" && gh pr create --base "$base_ref" --head "$branch" --fill 2>/dev/null); then
    log_success "$repo_name: opened PR: $url" "branch"; return 0
  fi
  log_error "$repo_name: gh pr create failed" "branch"; return 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (default-branch skip; dry-run prints would-open and does not push; empty branch eligibility-skips). Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr): pr_repo (eligibility, push, publish-verify, gh pr create, dry-run)"
```

---

## Task 6: `pr_workspace()`

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
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
case "$out" in *would*open*) : ;; *) echo "FAIL: pr_workspace dry-run should preview feature-branch repo a: $out"; ((errors++)) ;; esac
if echo "$out" | grep -q 'b:.*would open'; then echo "FAIL: repo b (on main) should not be PR'd"; ((errors++)); fi

# all on default branch -> info, no would-open
git -C "$PW_DIR/a" checkout main &>/dev/null
out2=$(pr_workspace "$PW_DIR" "" true 2>&1) || true
if echo "$out2" | grep -q 'would open'; then echo "FAIL: no feature-branch repos should yield no PRs: $out2"; ((errors++)); fi
rm -rf "$PW_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `pr_workspace: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/pr-ops.sh`:

```bash
# Open PRs across all feature-branch repos in dependency order. Returns non-zero if any failed.
pr_workspace() {
  local workspace="$1" base="$2" dry_run="${3:-false}"
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
    log_info "no feature-branch repos to PR" "branch"; return 0
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
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr): pr_workspace (collect feature-branch repos, order, drive pr_repo)"
```

---

## Task 7: Wire `branch pr` dispatch

**Files:**
- Modify: `bin/mra.sh`

- [ ] **Step 1: Source `lib/pr-ops.sh`**

In `bin/mra.sh`, find `source "$MRA_DIR/lib/review-select.sh"` and add immediately after it:

```bash
source "$MRA_DIR/lib/pr-ops.sh"
```

- [ ] **Step 2: Add the `pr)` arm to the `branch)` dispatch**

In the `branch)` case's inner `case "$sub" in`, add a `pr)` arm immediately before the `*)` (default) arm:

```bash
        pr)
          local base="" dry_run=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --base) if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "branch"; exit 1; fi; base="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          if ! check_gh_auth; then
            log_error "branch pr requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          local workspace; workspace=$(resolve_workspace)
          pr_workspace "$workspace" "$base" "$dry_run"
          exit $?
          ;;
```

Also update the `*)` usage line in that inner case to mention `pr`:

```bash
        *)
          log_error "usage: mra branch status|new|switch|pr ..." "branch"; exit 1 ;;
```

- [ ] **Step 3: Update usage text**

In the usage heredoc, add after the `branch switch <name>` line:

```
  branch pr [--base <ref>] [--dry-run]  Push feature branches and open PRs across repos (deps first)
```

- [ ] **Step 4: Smoke test (`--dry-run`, no gh writes)**

Run (note: `check_gh_auth` must pass for the command to proceed; if `gh` is not authenticated in this environment, the command will correctly exit 1 with the auth message — that itself verifies the preflight. If `gh` IS authenticated, the dry-run proceeds and performs no writes):

```bash
WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main a &>/dev/null
git -C "$WS/a" config user.email t@t.t; git -C "$WS/a" config user.name t
git -C "$WS/a" commit --allow-empty -m init &>/dev/null
git -C "$WS/a" checkout -b feat/x &>/dev/null
git -C "$WS/a" commit --allow-empty -m work &>/dev/null
MRA_WORKSPACE="$WS" bash bin/mra.sh branch pr --dry-run; echo "exit=$?"
rm -rf "$WS"
```

Expected: either `would open PR: feat/x → main` with `exit=0` (gh authenticated), OR the gh-auth error with `exit=1` (gh not authenticated) — both are correct outcomes proving the wiring (preflight + dispatch).

- [ ] **Step 5: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(pr): wire mra branch pr dispatch (gh preflight, --base/--dry-run) + usage"
```

---

## Done — Phase 2 complete

After Task 7 the workflow journey works end to end: `mra branch new feat/x` → commit → `mra sync --review` (auto-review changed repos) → `mra branch pr` (push + open PRs deps-first). Deferred to Phase 3 (spec §10.7 / §8.1 / §9.7): `review --range`/`--head`, the §8.1 review follow-ups, the §9.7 hardening follow-ups.

> **Historical note:** the phase numbering of deferred items above reflects this plan's authoring moment and was later re-assigned (Phase 3 = §9.7/§10.8 hardening; `review --range`/`--head` → Phase 4; §8.1.1–4 → Phase 5). The authoritative, current phase map is **spec §8** (this plan and its commits are unchanged / already merged).
