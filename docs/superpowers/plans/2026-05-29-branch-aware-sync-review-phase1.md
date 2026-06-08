# Branch-aware Sync & Review — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cross-repo branch lifecycle to `mra`: `branch new <name> [repos…]`, `branch switch <name>`, and `sync --push [--dry-run]`.

**Architecture:** A pure push decision engine (`branch_push_action`) joins `lib/branch.sh`. Mutating cross-repo branch ops live in a new `lib/branch-ops.sh` (keeping `lib/branch.sh` read-only/pure). Push lives in `lib/sync.sh` beside `safe_sync_repo`. `bin/mra.sh` restructures the `branch)` dispatch to support positional subcommands and adds `--push`/`--dry-run` to `sync)`. All per-repo work is isolated with a `failed` counter; any failure → non-zero exit.

**Tech Stack:** Bash, git CLI, existing `lib/colors.sh` log helpers, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Create `lib/branch-ops.sh`** — `validate_branch_name()`, `create_branch_in_repo()`, `create_branch_workspace()`, `switch_branch_in_repo()`, `switch_branch_workspace()`. The write side of branch ops.
- **Create `tests/test_branch_ops.sh`** — validation + create/switch behavior against multi-repo fixtures.
- **Modify `lib/branch.sh`** — add pure `branch_push_action()`.
- **Modify `lib/sync.sh`** — add `push_repo()` + `push_workspace()`.
- **Modify `bin/mra.sh`** — source `branch-ops.sh`; restructure `branch)` dispatch (status/new/switch); add `--push`/`--dry-run` to `sync)`; usage.
- **Modify `tests/test_branch.sh`** — `branch_push_action` cases.
- **Modify `tests/test_sync.sh`** — push behavior against bare-repo fixtures.

Dependency order: T1 validate → T2 push engine → T3 create → T4 switch → T5 push → T6 branch dispatch → T7 sync --push dispatch.

---

## Task 1: `validate_branch_name()` + `lib/branch-ops.sh` skeleton

**Files:**
- Create: `lib/branch-ops.sh`
- Test: `tests/test_branch_ops.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_branch_ops.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch-ops.sh"

errors=0

# valid names
for n in feat/x bugfix-123 release/v1.2.0; do
  if ! validate_branch_name "$n"; then echo "FAIL: '$n' should be valid"; ((errors++)); fi
done
# invalid: empty, leading dash, git-invalid
for n in "" "-foo" "--all" "feat/x..y" "feat~1" "feat^" "with space"; do
  if validate_branch_name "$n"; then echo "FAIL: '$n' should be INVALID"; ((errors++)); fi
done

if [[ $errors -eq 0 ]]; then
  echo "PASS: branch-ops validation tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch_ops.sh`
Expected: FAIL — `validate_branch_name: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/branch-ops.sh`:

```bash
#!/usr/bin/env bash
# Mutating cross-repo branch operations (create / switch).
# Read-only introspection lives in lib/branch.sh; this file is the write side.

# Validate a branch name. Returns 0 if valid, non-zero otherwise.
# Rejects: empty, leading dash (git option injection), and git-invalid ref names.
validate_branch_name() {
  local name="$1"
  [[ -z "$name" ]] && return 1
  case "$name" in -*) return 1 ;; esac
  git check-ref-format "refs/heads/$name" >/dev/null 2>&1 || return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/branch-ops.sh tests/test_branch_ops.sh
git commit -m "feat(branch): validate_branch_name + branch-ops.sh skeleton"
```

---

## Task 2: Push decision engine `branch_push_action()`

**Files:**
- Modify: `lib/branch.sh`
- Test: `tests/test_branch.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- branch_push_action (args: ahead behind upstream branch) ---
assert_push() { # ahead behind upstream branch expected
  local got
  got=$(branch_push_action "$1" "$2" "$3" "$4")
  if [[ "$got" != "$5" ]]; then
    echo "FAIL: branch_push_action($1,$2,$3,$4) => '$got', expected '$5'"; ((errors++))
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `branch_push_action: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/branch.sh`:

```bash
# Pure push decision engine, sibling to branch_sync_action. First matching rule wins.
# Args: ahead behind upstream branch  -> prints one action string.
# Does NOT consider dirty (uncommitted files don't affect pushing committed refs).
# `branch` distinguishes a real unpublished branch from a detached HEAD (both have upstream=(none)).
branch_push_action() {
  local ahead="$1" behind="$2" upstream="$3" branch="$4"
  if [[ "$branch" == "(detached)" ]]; then echo "skip-detached"; return; fi
  if [[ "$upstream" == "(none)" ]]; then echo "push-new"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then echo "up-to-date"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then echo "push"; return; fi
  if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then echo "skip-diverged"; return; fi
  echo "skip-behind"   # ahead==0 && behind>0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/branch.sh tests/test_branch.sh
git commit -m "feat(branch): branch_push_action push decision engine"
```

---

## Task 3: `create_branch_in_repo()` + `create_branch_workspace()`

**Files:**
- Modify: `lib/branch-ops.sh`
- Test: `tests/test_branch_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- create_branch_workspace across a multi-repo fixture ---
WS=$(mktemp -d)
for r in a b; do
  mkdir -p "$WS/$r"
  git -C "$WS/$r" init -b main . &>/dev/null
  git -C "$WS/$r" config user.email t@t.t; git -C "$WS/$r" config user.name t
  git -C "$WS/$r" commit --allow-empty -m init &>/dev/null
done
# repo b already has feat/x (should be switched, not fail)
git -C "$WS/b" branch feat/x &>/dev/null

create_branch_workspace "$WS" feat/x &>/dev/null
for r in a b; do
  cur=$(git -C "$WS/$r" rev-parse --abbrev-ref HEAD)
  if [[ "$cur" != "feat/x" ]]; then echo "FAIL: $r should be on feat/x, got $cur"; ((errors++)); fi
done

# invalid name => non-zero, no repo changed
git -C "$WS/a" checkout main &>/dev/null
before=$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)
if create_branch_workspace "$WS" "feat/x..y" &>/dev/null; then
  echo "FAIL: invalid name should make create_branch_workspace return non-zero"; ((errors++))
fi
after=$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)
if [[ "$before" != "$after" ]]; then echo "FAIL: invalid name must not change any branch"; ((errors++)); fi

# named-repo subset: only repo a
git -C "$WS/a" checkout main &>/dev/null
create_branch_workspace "$WS" feat/y a &>/dev/null
if [[ "$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)" != "feat/y" ]]; then
  echo "FAIL: repo a should be on feat/y"; ((errors++))
fi
if git -C "$WS/b" show-ref --verify --quiet refs/heads/feat/y; then
  echo "FAIL: repo b should NOT have feat/y (not in subset)"; ((errors++))
fi
rm -rf "$WS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch_ops.sh`
Expected: FAIL — `create_branch_workspace: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/branch-ops.sh`:

```bash
# Create+checkout a branch in one repo (base = current HEAD).
# If the branch already exists, switch to it and warn. Returns non-zero on failure.
create_branch_in_repo() {
  local repo_dir="$1" name="$2"
  local repo_name; repo_name=$(basename "$repo_dir")
  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$name"; then
    log_warn "$repo_name: branch '$name' already exists, switching" "branch"
    if git -C "$repo_dir" checkout "$name" >/dev/null 2>&1; then
      log_success "$repo_name: on '$name'" "branch"; return 0
    else
      log_error "$repo_name: cannot switch to '$name' (working tree?)" "branch"; return 1
    fi
  fi
  if git -C "$repo_dir" checkout -b "$name" >/dev/null 2>&1; then
    log_success "$repo_name: created '$name'" "branch"; return 0
  else
    log_error "$repo_name: failed to create '$name'" "branch"; return 1
  fi
}

# Create the branch across a repo set. Extra args = repo names; if none, all workspace git repos.
# Validates the name first (fail fast, no repo touched). Returns non-zero if any repo failed.
create_branch_workspace() {
  local workspace="$1" name="$2"; shift 2
  if ! validate_branch_name "$name"; then
    log_error "invalid branch name: '$name'" "branch"; return 1
  fi
  local failed=0
  local repos=("$@")
  if [[ ${#repos[@]} -eq 0 ]]; then
    for dir in "$workspace"/*/; do
      [[ ! -d "$dir" ]] && continue
      local b; b=$(basename "$dir")
      [[ "$b" == .* ]] && continue
      should_skip_dir "$dir" && continue
      if ! create_branch_in_repo "$dir" "$name"; then failed=$((failed+1)); fi
    done
  else
    for r in "${repos[@]}"; do
      local dir="$workspace/$r"
      if should_skip_dir "$dir"; then
        log_error "$r: not a git repo" "branch"; failed=$((failed+1)); continue
      fi
      if ! create_branch_in_repo "$dir" "$name"; then failed=$((failed+1)); fi
    done
  fi
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/branch-ops.sh tests/test_branch_ops.sh
git commit -m "feat(branch): create_branch_in_repo + create_branch_workspace"
```

---

## Task 4: `switch_branch_in_repo()` + `switch_branch_workspace()`

**Files:**
- Modify: `lib/branch-ops.sh`
- Test: `tests/test_branch_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- switch_branch_workspace: switch where branch exists, leave others untouched ---
WS2=$(mktemp -d)
for r in a b; do
  mkdir -p "$WS2/$r"
  git -C "$WS2/$r" init -b main . &>/dev/null
  git -C "$WS2/$r" config user.email t@t.t; git -C "$WS2/$r" config user.name t
  git -C "$WS2/$r" commit --allow-empty -m init &>/dev/null
done
# only repo a has feat/x; both currently on main
git -C "$WS2/a" branch feat/x &>/dev/null

switch_branch_workspace "$WS2" feat/x &>/dev/null
if [[ "$(git -C "$WS2/a" rev-parse --abbrev-ref HEAD)" != "feat/x" ]]; then
  echo "FAIL: repo a should switch to feat/x"; ((errors++))
fi
if [[ "$(git -C "$WS2/b" rev-parse --abbrev-ref HEAD)" != "main" ]]; then
  echo "FAIL: repo b (no feat/x) should remain on main"; ((errors++))
fi

# invalid name => non-zero
if switch_branch_workspace "$WS2" "-foo" &>/dev/null; then
  echo "FAIL: invalid name should make switch_branch_workspace return non-zero"; ((errors++))
fi
rm -rf "$WS2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch_ops.sh`
Expected: FAIL — `switch_branch_workspace: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/branch-ops.sh`:

```bash
# Switch one repo to an EXISTING branch. Missing branch or a dirty/conflict
# checkout failure are non-fatal skips (warn, return 0) — never -f, never discard.
switch_branch_in_repo() {
  local repo_dir="$1" name="$2"
  local repo_name; repo_name=$(basename "$repo_dir")
  if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$name"; then
    log_warn "$repo_name: no branch '$name' — skipping" "branch"; return 0
  fi
  if git -C "$repo_dir" checkout "$name" >/dev/null 2>&1; then
    log_success "$repo_name: on '$name'" "branch"; return 0
  fi
  log_warn "$repo_name: cannot switch to '$name' (dirty/conflict) — skipping" "branch"; return 0
}

# Switch every workspace git repo that has the branch. Validates name first.
# Returns non-zero only on an invalid name (per-repo skips are expected, not failures).
switch_branch_workspace() {
  local workspace="$1" name="$2"
  if ! validate_branch_name "$name"; then
    log_error "invalid branch name: '$name'" "branch"; return 1
  fi
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local b; b=$(basename "$dir")
    [[ "$b" == .* ]] && continue
    should_skip_dir "$dir" && continue
    switch_branch_in_repo "$dir" "$name"
  done
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/branch-ops.sh tests/test_branch_ops.sh
git commit -m "feat(branch): switch_branch_in_repo + switch_branch_workspace"
```

---

## Task 5: `push_repo()` + `push_workspace()`

**Files:**
- Modify: `lib/sync.sh`
- Test: `tests/test_sync.sh`

`tests/test_sync.sh` already sources `lib/branch.sh` (Phase 0 Task 5), so `branch_push_action`/`get_branch_state` are available.

- [ ] **Step 1: Write the failing test**

In `tests/test_sync.sh`, append immediately before the final `rm -rf "$TEST_DIR"`:

```bash
# --- push_repo: pushes a local-ahead branch to the bare remote ---
PUSH_DIR=$(mktemp -d)
git -C "$PUSH_DIR" init -b main --bare up &>/dev/null
git clone "$PUSH_DIR/up" "$PUSH_DIR/a" &>/dev/null
git -C "$PUSH_DIR/a" config user.email t@t.t; git -C "$PUSH_DIR/a" config user.name t
git -C "$PUSH_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PUSH_DIR/a" push -u origin main &>/dev/null
git -C "$PUSH_DIR/a" commit --allow-empty -m c2 &>/dev/null   # now ahead by 1
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" false &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" == "$after" ]]; then echo "FAIL: push_repo should advance the bare remote"; ((errors++)); fi

# --- push_repo dry-run: does NOT advance the remote even when ahead ---
git -C "$PUSH_DIR/a" commit --allow-empty -m c3 &>/dev/null   # ahead again
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" true &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: dry-run push must NOT advance the remote"; ((errors++)); fi

# --- push_repo: new branch with no upstream gets pushed with -u ---
git -C "$PUSH_DIR/a" checkout -b feat/new &>/dev/null
git -C "$PUSH_DIR/a" commit --allow-empty -m f1 &>/dev/null
push_repo "$PUSH_DIR/a" false &>/dev/null
if ! git -C "$PUSH_DIR/a" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' &>/dev/null; then
  echo "FAIL: push_repo push-new should set upstream"; ((errors++))
fi

# --- push_repo: behind branch is NOT pushed ---
git clone "$PUSH_DIR/up" "$PUSH_DIR/b" &>/dev/null
git -C "$PUSH_DIR/b" config user.email t@t.t; git -C "$PUSH_DIR/b" config user.name t
git -C "$PUSH_DIR/b" commit --allow-empty -m adv &>/dev/null
git -C "$PUSH_DIR/b" push origin main &>/dev/null   # advance remote main
git -C "$PUSH_DIR/a" checkout main &>/dev/null
git -C "$PUSH_DIR/a" fetch --quiet
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" false &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: behind branch must not be pushed"; ((errors++)); fi
rm -rf "$PUSH_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `push_repo: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/sync.sh`:

```bash
# Push one repo per the push decision engine. dry_run="true" previews only.
# Never force-pushes. Returns non-zero on push failure.
push_repo() {
  local repo_dir="$1" dry_run="${2:-false}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0
  git -C "$repo_dir" fetch --quiet 2>/dev/null || true

  local state branch upstream ahead behind dirty action
  state=$(get_branch_state "$repo_dir")
  branch=$(branch_state_get "$state" branch)
  upstream=$(branch_state_get "$state" upstream)
  ahead=$(branch_state_get "$state" ahead)
  behind=$(branch_state_get "$state" behind)
  dirty=$(branch_state_get "$state" dirty)
  action=$(branch_push_action "$ahead" "$behind" "$upstream" "$branch")

  local dirty_note=""
  [[ "$dirty" -gt 0 ]] && dirty_note=" ($dirty uncommitted files remain local)"

  case "$action" in
    push-new)
      if [[ "$dry_run" == "true" ]]; then
        log_info "$repo_name: would push -u origin $branch (new branch)$dirty_note" "sync"; return 0
      fi
      if git -C "$repo_dir" push -u origin "$branch" >/dev/null 2>&1; then
        log_success "$repo_name: pushed new branch '$branch'$dirty_note" "sync"; return 0
      else
        log_error "$repo_name: push -u failed" "sync"; return 1
      fi
      ;;
    push)
      if [[ "$dry_run" == "true" ]]; then
        log_info "$repo_name: would push $branch ($ahead ahead)$dirty_note" "sync"; return 0
      fi
      if git -C "$repo_dir" push >/dev/null 2>&1; then
        log_success "$repo_name: pushed$dirty_note" "sync"; return 0
      else
        log_error "$repo_name: push failed" "sync"; return 1
      fi
      ;;
    up-to-date)
      log_success "$repo_name: up-to-date (nothing to push)" "sync"; return 0 ;;
    skip-detached)
      log_warn "$repo_name: detached HEAD — skipping (check out a branch first)" "sync"; return 0 ;;
    skip-diverged)
      log_warn "$repo_name: diverged — skipping (pull/reconcile first, never force)" "sync"; return 0 ;;
    skip-behind)
      log_warn "$repo_name: behind upstream — skipping (pull first)" "sync"; return 0 ;;
    *)
      log_warn "$repo_name: unknown push state '$action' — skipping" "sync"; return 0 ;;
  esac
}

# Push every git repo in a workspace. Returns non-zero if any push failed.
push_workspace() {
  local workspace="$1" dry_run="${2:-false}"
  local failed=0
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    if ! push_repo "$dir" "$dry_run"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): push_repo/push_workspace (decision-engine driven, dry-run, never force)"
```

---

## Task 6: Wire `branch new` / `branch switch` dispatch

`bin/mra.sh` is `set -euo pipefail` — use `x=$((x+1))` never `((x++))`. The current `branch)` case parses flags BEFORE switching on the subcommand, which breaks positional args for `new`/`switch`. This task restructures so each subcommand parses its own args (the `status` body is unchanged, only moved inside its arm).

**Files:**
- Modify: `bin/mra.sh`
- Test: manual smoke + full suite

- [ ] **Step 1: Source `lib/branch-ops.sh`**

In `bin/mra.sh`, find `source "$MRA_DIR/lib/branch.sh"` and add immediately after it:

```bash
source "$MRA_DIR/lib/branch-ops.sh"
```

- [ ] **Step 2: Replace the entire `branch)` dispatch case**

Find the existing `branch)` case (it begins with `    branch)` and ends at its matching `      ;;` — it currently parses `--all`/`--fetch` then `case "$sub" in status) ... *) ... esac`). Replace the WHOLE case with:

```bash
    branch)
      shift
      local sub="${1:-}"; shift || true
      case "$sub" in
        status)
          local show_all=false do_fetch=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --all) show_all=true; shift ;;
              --fetch) do_fetch=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          local shown=0 failed=0
          printf '%-20s %-24s %-5s%-5s%-5s %s\n' "REPO" "BRANCH" "AHEAD" "BEHIND" "DIRTY" "ACTION"
          for dir in "$workspace"/*/; do
            [[ ! -d "$dir" ]] && continue
            local name; name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            should_skip_dir "$dir" && continue
            if [[ "$do_fetch" == "true" ]]; then
              if ! git -C "$dir" fetch --quiet 2>/dev/null; then
                log_error "$name: fetch failed" "branch"; failed=$((failed+1))
              fi
            fi
            local state on_default ahead behind dirty
            state=$(get_branch_state "$dir")
            ahead=$(branch_state_get "$state" ahead)
            behind=$(branch_state_get "$state" behind)
            dirty=$(branch_state_get "$state" dirty)
            if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
            if [[ "$show_all" == "true" ]] || branch_row_needs_attention "$ahead" "$behind" "$dirty" "$on_default"; then
              branch_format_row "$state"; printf '\n'; shown=$((shown+1))
            fi
          done
          if [[ "$shown" -eq 0 && "$show_all" == "false" ]]; then
            log_success "all repos clean and up to date" "branch"
          fi
          [[ "$failed" -gt 0 ]] && exit 1
          exit 0
          ;;
        new)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch new <name> [repos...]" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          create_branch_workspace "$workspace" "$bname" "$@"
          exit $?
          ;;
        switch)
          local bname="${1:-}"; shift || true
          if [[ -z "$bname" ]]; then log_error "usage: mra branch switch <name>" "branch"; exit 1; fi
          local workspace; workspace=$(resolve_workspace)
          switch_branch_workspace "$workspace" "$bname"
          exit $?
          ;;
        *)
          log_error "usage: mra branch status|new|switch ..." "branch"; exit 1 ;;
      esac
      ;;
```

- [ ] **Step 3: Update usage text**

In the usage heredoc, replace the existing `branch status ...` line with:

```
  branch status [--all] [--fetch]  Cross-repo branch overview (default: repos needing attention)
  branch new <name> [repos...]  Create+checkout a branch across repos
  branch switch <name>          Switch repos that have <name> to it
```

- [ ] **Step 4: Smoke test `new` and `switch`**

Run:

```bash
WS=$(mktemp -d)
for r in a b; do
  mkdir -p "$WS/$r"
  ( cd "$WS/$r" && git init -b main . &>/dev/null && git -c user.email=t@t.t -c user.name=t commit --allow-empty -m init &>/dev/null )
done
MRA_WORKSPACE="$WS" bash bin/mra.sh branch new feat/x; echo "new exit=$?"
for r in a b; do echo "$r: $(git -C "$WS/$r" rev-parse --abbrev-ref HEAD)"; done
( cd "$WS/a" && git checkout main &>/dev/null )
MRA_WORKSPACE="$WS" bash bin/mra.sh branch switch feat/x; echo "switch exit=$?"
echo "a now: $(git -C "$WS/a" rev-parse --abbrev-ref HEAD)"
MRA_WORKSPACE="$WS" bash bin/mra.sh branch new "-bad"; echo "invalid exit=$? (expect non-zero)"
rm -rf "$WS"
```

Expected: `new exit=0`, both repos on `feat/x`; after switching a back, `switch exit=0` and `a now: feat/x`; `invalid exit=1` (leading-dash rejected). `branch status` still works unchanged.

- [ ] **Step 5: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(branch): wire mra branch new/switch dispatch + usage"
```

---

## Task 7: Wire `sync --push [--dry-run]` dispatch

**Files:**
- Modify: `bin/mra.sh`
- Test: manual smoke + full suite

- [ ] **Step 1: Replace the `sync)` dispatch case**

Find the existing `sync)` case and replace the WHOLE case with (adds `--push`/`--dry-run`; push takes precedence over safe; default path unchanged):

```bash
    sync)
      shift
      local safe=false push=false dry_run=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --safe) safe=true; shift ;;
          --push) push=true; shift ;;
          --dry-run) dry_run=true; shift ;;
          *) log_error "unknown option: $1" "sync"; exit 1 ;;
        esac
      done
      local workspace; workspace=$(resolve_workspace)
      if [[ "$push" == "true" ]]; then
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

- [ ] **Step 2: Update usage text**

In the usage heredoc, replace the existing `sync [--safe]` line with:

```
  sync [--safe] [--push] [--dry-run]  Clone/pull; --safe ff-only; --push pushes per decision engine
```

- [ ] **Step 3: Smoke test `--push` and `--push --dry-run`**

Run:

```bash
WS=$(mktemp -d)
git -C "$WS" init -b main --bare up &>/dev/null
git clone "$WS/up" "$WS/a" &>/dev/null
git -C "$WS/a" config user.email t@t.t; git -C "$WS/a" config user.name t
git -C "$WS/a" commit --allow-empty -m c1 &>/dev/null
git -C "$WS/a" push -u origin main &>/dev/null
git -C "$WS/a" commit --allow-empty -m c2 &>/dev/null   # ahead by 1
before=$(git -C "$WS/up" rev-parse main)
MRA_WORKSPACE="$WS" bash bin/mra.sh sync --push --dry-run; echo "dry exit=$?"
mid=$(git -C "$WS/up" rev-parse main)
[[ "$before" == "$mid" ]] && echo "OK: dry-run did not push" || echo "BAD: dry-run pushed"
MRA_WORKSPACE="$WS" bash bin/mra.sh sync --push; echo "push exit=$?"
after=$(git -C "$WS/up" rev-parse main)
[[ "$mid" != "$after" ]] && echo "OK: real push advanced remote" || echo "BAD: push did nothing"
rm -rf "$WS"
```

Expected: `dry exit=0`, `OK: dry-run did not push`; `push exit=0`, `OK: real push advanced remote`. (The bare `up` dir is skipped by `should_skip_dir` since it has no working `.git` subdir layout it iterates — confirm no error.)

- [ ] **Step 4: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(sync): wire mra sync --push [--dry-run] dispatch + usage"
```

---

## Done — Phase 1 complete

After Task 7 the lifecycle journey works end to end: `mra branch new feat/x` → commit → `mra sync --push --dry-run` → `mra sync --push`. Deferred to Phase 2 (spec §8 / §8.1): `review --range`/`--head`, the five §8.1 follow-ups, `sync --review`, `branch pr`.

> **Historical note:** the phase numbering of deferred items above reflects this plan's authoring moment and was later re-assigned across Phases 2–5. The authoritative, current phase map is **spec §8** (this plan and its commits are unchanged / already merged).
