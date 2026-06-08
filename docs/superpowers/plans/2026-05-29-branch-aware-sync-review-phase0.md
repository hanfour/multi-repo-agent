# Branch-aware Sync & Review — Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public `mra branch status`, a public `mra sync` with a `--safe` branch-aware fast-forward path, and a `mra review <repo> --working` mode that reviews uncommitted changes.

**Architecture:** A new `lib/branch.sh` holds a pure decision engine (`branch_sync_action`) and read-only repo introspection (`get_branch_state`). `lib/sync.sh` gains a `--safe` path that fetches, computes `BranchState`, and fast-forwards only when safe. A new `lib/review-diff.sh` extracts the duplicated diff-acquisition logic so `review.sh` and `review-prompt.sh` can share a `base`-vs-`working` mode. `bin/mra.sh` wires the new commands following existing dispatch conventions.

**Tech Stack:** Bash, git CLI, existing `lib/colors.sh` log helpers, plain-bash test scripts under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Create `lib/branch.sh`** — `branch_sync_action()`, `get_branch_state()`, `branch_state_get()`, `branch_row_needs_attention()`, `branch_format_row()`. Read-only introspection + pure decision logic.
- **Create `lib/review-diff.sh`** — `review_diff_text()`, `review_diff_files()`. Single source of truth for review diff acquisition (`base` vs `working`).
- **Create `tests/test_branch.sh`** — unit tests for the decision engine + state parsing.
- **Create `tests/test_review_working.sh`** — tests for working-tree diff acquisition + empty handling.
- **Modify `lib/sync.sh`** — add `safe_sync_repo()` and `safe_sync_workspace()`.
- **Modify `lib/review.sh`** — add `--working` flag, force single-pass, use `review-diff.sh`.
- **Modify `lib/review-prompt.sh`** — accept a diff-mode param, use `review-diff.sh`.
- **Modify `bin/mra.sh`** — source new libs; add `branch` and `sync` dispatch cases; add `--working` to `review`; update usage.
- **Modify `tests/test_sync.sh`** — add `safe_sync_repo` regression + safety tests.

Each task is independently committable. Tasks 1–4 deliver `branch status`; 5–6 deliver `sync --safe`; 7–9 deliver `review --working`.

---

## Task 1: Decision engine `branch_sync_action()`

**Files:**
- Create: `lib/branch.sh`
- Test: `tests/test_branch.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_branch.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/branch.sh"

errors=0

assert_action() { # ahead behind dirty upstream expected
  local got
  got=$(branch_sync_action "$1" "$2" "$3" "$4")
  if [[ "$got" != "$5" ]]; then
    echo "FAIL: branch_sync_action($1,$2,$3,$4) => '$got', expected '$5'"; ((errors++))
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

if [[ $errors -eq 0 ]]; then
  echo "PASS: branch_sync_action tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `lib/branch.sh` does not exist / `branch_sync_action: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/branch.sh`:

```bash
#!/usr/bin/env bash
# Branch-aware introspection and the pure sync decision engine.
# All functions are read-only: they never modify a working tree or branch.

# Pure decision engine. First matching rule wins (see spec §4.2).
# Args: ahead behind dirty upstream  -> prints one action string.
branch_sync_action() {
  local ahead="$1" behind="$2" dirty="$3" upstream="$4"
  if [[ "$upstream" == "(none)" ]]; then echo "no-upstream"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then echo "up-to-date"; return; fi
  if [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then echo "ahead-only"; return; fi
  if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then echo "diverged"; return; fi
  # Remaining: behind>0 and ahead==0
  if [[ "$dirty" -gt 0 ]]; then echo "dirty-skip"; return; fi
  echo "fast-forward"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: PASS — `PASS: branch_sync_action tests passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/branch.sh tests/test_branch.sh
git commit -m "feat(branch): pure branch_sync_action decision engine"
```

---

## Task 2: `get_branch_state()` + `branch_state_get()`

**Files:**
- Modify: `lib/branch.sh`
- Test: `tests/test_branch.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch.sh`, just before the final `if [[ $errors -eq 0 ]]` block:

```bash
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
  echo "FAIL: expected branch=main, got: $state"; ((errors++))
fi
if [[ "$(branch_state_get "$state" upstream)" != "origin/main" ]]; then
  echo "FAIL: expected upstream=origin/main, got: $state"; ((errors++))
fi
if [[ "$(branch_state_get "$state" sync_action)" != "up-to-date" ]]; then
  echo "FAIL: expected sync_action=up-to-date, got: $state"; ((errors++))
fi

# Detached HEAD => branch=(detached), upstream=(none) => no-upstream
sha=$(git -C "$TEST_DIR/repo" rev-parse HEAD)
git -C "$TEST_DIR/repo" checkout "$sha" &>/dev/null
state=$(get_branch_state "$TEST_DIR/repo")
if [[ "$(branch_state_get "$state" branch)" != "(detached)" ]]; then
  echo "FAIL: expected branch=(detached), got: $state"; ((errors++))
fi
if [[ "$(branch_state_get "$state" sync_action)" != "no-upstream" ]]; then
  echo "FAIL: expected sync_action=no-upstream for detached, got: $state"; ((errors++))
fi
rm -rf "$TEST_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `get_branch_state: command not found` / `branch_state_get: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/branch.sh`:

```bash
# Read one KEY=VALUE field out of a state block.
# Args: state_block key
branch_state_get() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# Compute a read-only BranchState snapshot for a repo.
# Does NOT fetch — reads local refs only (callers fetch when they want fresh counts).
# Prints flat KEY=VALUE lines (see spec §4.1).
get_branch_state() {
  local repo_dir="$1"
  local repo branch upstream ahead behind dirty action counts
  repo=$(basename "$repo_dir")
  branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "(none)")
  if [[ "$upstream" == "(none)" ]]; then
    ahead=0; behind=0
  else
    counts=$(git -C "$repo_dir" rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || printf '0\t0')
    behind=$(printf '%s' "$counts" | cut -f1)
    ahead=$(printf '%s' "$counts" | cut -f2)
    [[ -z "$behind" ]] && behind=0
    [[ -z "$ahead" ]] && ahead=0
  fi
  # dirty = tracked staged + unstaged (untracked excluded; out of scope, spec §4.3)
  dirty=$(git -C "$repo_dir" status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true)
  action=$(branch_sync_action "$ahead" "$behind" "$dirty" "$upstream")
  printf 'repo=%s\nbranch=%s\nupstream=%s\nahead=%s\nbehind=%s\ndirty=%s\nsync_action=%s\n' \
    "$repo" "$branch" "$upstream" "$ahead" "$behind" "$dirty" "$action"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/branch.sh tests/test_branch.sh
git commit -m "feat(branch): get_branch_state read-only snapshot + branch_state_get"
```

---

## Task 3: Attention filter + row formatter

**Files:**
- Modify: `lib/branch.sh`
- Test: `tests/test_branch.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch.sh`, just before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- branch_row_needs_attention (args: ahead behind dirty on_default) ---
if branch_row_needs_attention 0 0 0 true; then
  echo "FAIL: clean+on-default should NOT need attention"; ((errors++))
fi
if ! branch_row_needs_attention 1 0 0 true; then
  echo "FAIL: ahead>0 should need attention"; ((errors++))
fi
if ! branch_row_needs_attention 0 0 0 false; then
  echo "FAIL: off-default should need attention"; ((errors++))
fi
if ! branch_row_needs_attention 0 0 2 true; then
  echo "FAIL: dirty>0 should need attention"; ((errors++))
fi

# --- branch_format_row produces one line containing the key fields ---
row=$(branch_format_row "repo=api"$'\n'"branch=feat/x"$'\n'"upstream=origin/feat/x"$'\n'"ahead=2"$'\n'"behind=1"$'\n'"dirty=0"$'\n'"sync_action=diverged")
case "$row" in
  *api*feat/x*diverged*) : ;;
  *) echo "FAIL: row missing fields: $row"; ((errors++)) ;;
esac
if [[ "$(printf '%s' "$row" | wc -l | tr -d ' ')" != "0" ]]; then
  echo "FAIL: row should be a single line (no trailing newline)"; ((errors++))
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `branch_row_needs_attention: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/branch.sh`:

```bash
# True (exit 0) if a repo's row should show by default in `branch status`.
# Args: ahead behind dirty on_default("true"/"false")
branch_row_needs_attention() {
  local ahead="$1" behind="$2" dirty="$3" on_default="$4"
  [[ "$ahead" -gt 0 || "$behind" -gt 0 || "$dirty" -gt 0 || "$on_default" != "true" ]]
}

# Format one BranchState block as a single aligned table row (no trailing newline).
# Args: state_block
branch_format_row() {
  local s="$1" repo branch upstream ahead behind dirty action
  repo=$(branch_state_get "$s" repo)
  branch=$(branch_state_get "$s" branch)
  upstream=$(branch_state_get "$s" upstream)
  ahead=$(branch_state_get "$s" ahead)
  behind=$(branch_state_get "$s" behind)
  dirty=$(branch_state_get "$s" dirty)
  action=$(branch_state_get "$s" action 2>/dev/null)
  [[ -z "$action" ]] && action=$(branch_state_get "$s" sync_action)
  printf '%-20s %-24s +%-3s -%-3s ~%-3s %s' \
    "$repo" "$branch" "$ahead" "$behind" "$dirty" "$action"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/branch.sh tests/test_branch.sh
git commit -m "feat(branch): attention filter + row formatter"
```

---

## Task 4: Wire `mra branch status`

**Files:**
- Modify: `bin/mra.sh` (source line near line 16; usage block; new dispatch case)
- Test: manual smoke (no Claude/network needed)

- [ ] **Step 1: Source the new lib**

In `bin/mra.sh`, find the existing `source "$MRA_DIR/lib/sync.sh"` (line ~16) and add immediately after it:

```bash
source "$MRA_DIR/lib/branch.sh"
```

- [ ] **Step 2: Add the dispatch case**

In `bin/mra.sh`, add a new case in the main dispatch `case` block (place it alongside other top-level commands, e.g. just before the `review)` case):

```bash
    branch)
      shift
      local sub="${1:-}"; shift || true
      local show_all=false do_fetch=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --all) show_all=true; shift ;;
          --fetch) do_fetch=true; shift ;;
          *) log_error "unknown option: $1" "branch"; exit 1 ;;
        esac
      done
      case "$sub" in
        status)
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
        *)
          log_error "usage: mra branch status [--all] [--fetch]" "branch"; exit 1 ;;
      esac
      ;;
```

- [ ] **Step 3: Update usage text**

In the usage heredoc (the `Commands:` list, near the `review` line), add:

```
  branch status [--all] [--fetch]  Cross-repo branch overview (default: repos needing attention)
```

- [ ] **Step 4: Smoke test against a temp workspace**

Run:

```bash
WS=$(mktemp -d)
git -C "$WS" -c init.defaultBranch=main init a-repo 2>/dev/null; mkdir -p "$WS/a-repo"
( cd "$WS/a-repo" && git init -b main . &>/dev/null && git commit --allow-empty -m init &>/dev/null && git checkout -b feat/x &>/dev/null )
MRA_WORKSPACE="$WS" bash bin/mra.sh branch status
MRA_WORKSPACE="$WS" bash bin/mra.sh branch status --all
rm -rf "$WS"
```

Expected: a header row; `a-repo` shown (it is on a non-default branch → needs attention) with `branch feat/x` and `no-upstream`. Both invocations exit 0.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `bash test.sh`
Expected: all green (new `tests/test_branch.sh` included via glob).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(branch): mra branch status command (--all/--fetch)"
```

---

## Task 5: `safe_sync_repo()` in `lib/sync.sh`

**Files:**
- Modify: `lib/sync.sh` (append functions; it already sources nothing — `branch.sh` is sourced by `bin/mra.sh` before `sync.sh` uses it, so for standalone tests we source it explicitly)
- Test: `tests/test_sync.sh`

- [ ] **Step 1: Write the failing test**

In `tests/test_sync.sh`, add `source "$SCRIPT_DIR/lib/branch.sh"` right after the existing `source "$SCRIPT_DIR/lib/sync.sh"` line. Then append, just before the final `rm -rf "$TEST_DIR"`:

```bash
# --- safe_sync_repo: fast-forward a behind, clean feature branch ---
SAFE_DIR=$(mktemp -d)
git -C "$SAFE_DIR" init -b main --bare up &>/dev/null
git clone "$SAFE_DIR/up" "$SAFE_DIR/a" &>/dev/null
git -C "$SAFE_DIR/a" config user.email t@t.t; git -C "$SAFE_DIR/a" config user.name t
git -C "$SAFE_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SAFE_DIR/a" push -u origin main &>/dev/null
# second clone advances origin/main
git clone "$SAFE_DIR/up" "$SAFE_DIR/b" &>/dev/null
git -C "$SAFE_DIR/b" config user.email t@t.t; git -C "$SAFE_DIR/b" config user.name t
git -C "$SAFE_DIR/b" commit --allow-empty -m c2 &>/dev/null
git -C "$SAFE_DIR/b" push origin main &>/dev/null
# repo "a" is now behind by 1, clean => should fast-forward
before=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
safe_sync_repo "$SAFE_DIR/a" &>/dev/null
after=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
if [[ "$before" == "$after" ]]; then
  echo "FAIL: safe_sync_repo should fast-forward a behind/clean repo"; ((errors++))
fi

# --- safe_sync_repo: must NOT touch a dirty working tree ---
echo "dirty" > "$SAFE_DIR/a/file.txt"; git -C "$SAFE_DIR/a" add file.txt
git -C "$SAFE_DIR/b" commit --allow-empty -m c3 &>/dev/null
git -C "$SAFE_DIR/b" push origin main &>/dev/null
git -C "$SAFE_DIR/a" fetch --quiet
before=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
safe_sync_repo "$SAFE_DIR/a" &>/dev/null || true
after=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
if [[ "$before" != "$after" ]]; then
  echo "FAIL: safe_sync_repo must NOT move HEAD when working tree is dirty"; ((errors++))
fi
rm -rf "$SAFE_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `safe_sync_repo: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/sync.sh`:

```bash
# Branch-aware safe sync for one repo: fetch, then fast-forward ONLY when safe.
# Never merges/rebases, never touches a dirty or diverged tree. Returns non-zero on pull failure.
safe_sync_repo() {
  local repo_dir="$1"
  local repo_name; repo_name=$(basename "$repo_dir")

  if should_skip_dir "$repo_dir"; then
    return 0
  fi

  if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
    log_error "$repo_name: fetch failed" "sync"
    return 1
  fi

  local state action
  state=$(get_branch_state "$repo_dir")
  action=$(branch_state_get "$state" sync_action)

  case "$action" in
    fast-forward)
      log_progress "$repo_name: fast-forward" "sync"
      if git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null; then
        log_success "$repo_name: ok" "sync"; return 0
      else
        log_error "$repo_name: ff-only pull failed" "sync"; return 1
      fi
      ;;
    up-to-date|ahead-only)
      log_success "$repo_name: $action (no pull needed)" "sync"; return 0 ;;
    diverged)
      log_warn "$repo_name: diverged (ahead & behind) — skipping, resolve manually" "sync"; return 0 ;;
    dirty-skip)
      log_warn "$repo_name: behind but working tree dirty — skipping" "sync"; return 0 ;;
    no-upstream)
      log_warn "$repo_name: no upstream branch set — skipping" "sync"; return 0 ;;
    *)
      log_warn "$repo_name: unknown state '$action' — skipping" "sync"; return 0 ;;
  esac
}

# Safe-sync every git repo in a workspace. Returns non-zero if any repo failed.
safe_sync_workspace() {
  local workspace="$1"
  local failed=0
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    if ! safe_sync_repo "$dir"; then failed=$((failed+1)); fi
  done
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: PASS — both new assertions hold (ff moved HEAD; dirty did not).

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): safe_sync_repo/safe_sync_workspace (ff-only, dirty/diverged-safe)"
```

---

## Task 6: Wire public `mra sync` (default + `--safe`)

**Files:**
- Modify: `bin/mra.sh` (new dispatch case; usage block)
- Test: manual smoke + full suite

- [ ] **Step 1: Add the dispatch case**

In `bin/mra.sh`, add a new case in the main dispatch block (e.g. just before the `branch)` case):

```bash
    sync)
      shift
      local safe=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --safe) safe=true; shift ;;
          *) log_error "unknown option: $1" "sync"; exit 1 ;;
        esac
      done
      local workspace; workspace=$(resolve_workspace)
      if [[ "$safe" == "true" ]]; then
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

In the usage heredoc, add near the `branch status` line:

```
  sync [--safe]                 Clone/pull repos; --safe fast-forwards feature branches
```

- [ ] **Step 3: Smoke test `--safe` against a temp workspace**

Run:

```bash
WS=$(mktemp -d)
git -C "$WS" init -b main --bare up &>/dev/null
git clone "$WS/up" "$WS/a" &>/dev/null
git -C "$WS/a" config user.email t@t.t; git -C "$WS/a" config user.name t
git -C "$WS/a" commit --allow-empty -m c1 &>/dev/null
git -C "$WS/a" push -u origin main &>/dev/null
git clone "$WS/up" "$WS/b" &>/dev/null
git -C "$WS/b" config user.email t@t.t; git -C "$WS/b" config user.name t
git -C "$WS/b" commit --allow-empty -m c2 &>/dev/null
git -C "$WS/b" push origin main &>/dev/null
before=$(git -C "$WS/a" rev-parse HEAD)
MRA_WORKSPACE="$WS" bash bin/mra.sh sync --safe
after=$(git -C "$WS/a" rev-parse HEAD)
[[ "$before" != "$after" ]] && echo "OK: a fast-forwarded" || echo "BAD: a not updated"
rm -rf "$WS"
```

Expected: prints `OK: a fast-forwarded`; the bare `up` and clone `b` are skipped/up-to-date as appropriate.

- [ ] **Step 4: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(sync): public mra sync command with --safe path"
```

---

## Task 7: Extract `lib/review-diff.sh` (DRY)

The review diff is currently recomputed inline in 4 places (`review.sh` strategy block, `review-prompt.sh`, `review-debate.sh`, persona path). Phase 0 introduces a single source of truth and switches the two single-pass call sites to it. Debate/persona keep their inline logic (untouched) because `--working` forces single-pass.

**Files:**
- Create: `lib/review-diff.sh`
- Test: `tests/test_review_working.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_working.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/review-diff.sh"

errors=0
TEST_DIR=$(mktemp -d)
git -C "$TEST_DIR" init -b main repo &>/dev/null
R="$TEST_DIR/repo"
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'line1\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -m init &>/dev/null

# Working tree: clean => empty diff
out=$(review_diff_text "$R" working "")
if [[ -n "$out" ]]; then echo "FAIL: clean tree should yield empty working diff"; ((errors++)); fi

# Modify a tracked file (unstaged) => working diff captures it
printf 'line2\n' >> "$R/f.txt"
out=$(review_diff_text "$R" working "")
case "$out" in *line2*) : ;; *) echo "FAIL: working diff missing unstaged change"; ((errors++)) ;; esac
files=$(review_diff_files "$R" working "")
case "$files" in *f.txt*) : ;; *) echo "FAIL: working changed-files missing f.txt"; ((errors++)) ;; esac

# Staged change also captured (git diff HEAD covers staged + unstaged)
git -C "$R" add f.txt
out=$(review_diff_text "$R" working "")
case "$out" in *line2*) : ;; *) echo "FAIL: working diff missing staged change"; ((errors++)) ;; esac

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review-diff working-mode tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_working.sh`
Expected: FAIL — `review_diff_text: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/review-diff.sh`:

```bash
#!/usr/bin/env bash
# Single source of truth for review diff acquisition.
# mode "working": working tree vs HEAD (staged + unstaged tracked changes; untracked excluded).
# mode "base"  : resolved_base...HEAD (committed branch changes).

review_diff_text() {
  local project_dir="$1" mode="$2" resolved_base="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff "${resolved_base}...HEAD" 2>/dev/null || \
    git -C "$project_dir" diff "${resolved_base}" HEAD 2>/dev/null || echo ""
  fi
}

review_diff_files() {
  local project_dir="$1" mode="$2" resolved_base="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff --name-only HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff --name-only "${resolved_base}...HEAD" 2>/dev/null || \
    git -C "$project_dir" diff --name-only "${resolved_base}" HEAD 2>/dev/null || echo ""
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_working.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/review-diff.sh tests/test_review_working.sh
git commit -m "feat(review): extract review-diff.sh (base/working diff acquisition)"
```

---

## Task 8: Wire `--working` into the single-pass review path

**Files:**
- Modify: `bin/mra.sh` (source `review-diff.sh`)
- Modify: `lib/review.sh` (arg parse + force single-pass + working diff + empty handling)
- Modify: `lib/review-prompt.sh` (accept diff-mode param, use `review-diff.sh`)
- Test: `bash test.sh` (regression) + reuse `tests/test_review_working.sh`

- [ ] **Step 1: Source `review-diff.sh` before the review libs**

In `bin/mra.sh`, immediately before `source "$MRA_DIR/lib/review-prompt.sh"` (line ~48), add:

```bash
source "$MRA_DIR/lib/review-diff.sh"
```

- [ ] **Step 2: Parse `--working` and force single-pass in `review.sh`**

In `lib/review.sh`, in the `while [[ $# -gt 0 ]]` option loop (near line 92), add a case before the `-*)` catch-all:

```bash
      --working)
        working=true; shift ;;
```

Add `working=false` to the locals declared at the top of `review_project` (the line declaring `project="" pr_number=""...`):

```bash
  local project="" pr_number="" base_ref="" model="sonnet" debate=true force_strategy="" working=false
```

After the option loop and the `[[ -z "$project" ]]` check, add validation + single-pass forcing:

```bash
  if [[ "$working" == "true" ]]; then
    if [[ "${MRA_REVIEW_PERSONAS:-false}" == "true" ]]; then
      log_error "--working cannot be combined with --personas (Phase 0: single-pass only)" "review"
      return 1
    fi
    if [[ "$force_strategy" == "debate" ]]; then
      log_error "--working cannot be combined with --strategy debate (Phase 0: single-pass only)" "review"
      return 1
    fi
    debate=false   # force light/standard single-pass
  fi
```

- [ ] **Step 3: Compute the diff via `review-diff.sh` with mode**

In `lib/review.sh`, replace the strategy diff block (currently lines ~175–180, the `diff_for_strategy=...` and `changed_files_for_strategy=...` assignments) with:

```bash
  # --- Resolve diff mode (working tree vs committed branch) ---
  local diff_mode="base"
  [[ "$working" == "true" ]] && diff_mode="working"

  local diff_for_strategy changed_files_for_strategy
  diff_for_strategy=$(review_diff_text "$project_dir" "$diff_mode" "$resolved_base")
  changed_files_for_strategy=$(review_diff_files "$project_dir" "$diff_mode" "$resolved_base")
```

Then immediately after the `changed_count` computation block, add the empty-working-diff guard:

```bash
  if [[ "$working" == "true" && "$changed_count" -eq 0 ]]; then
    log_info "no uncommitted changes to review" "review"
    return 0
  fi
```

- [ ] **Step 4: Pass `diff_mode` to the single-pass prompt builder**

In `lib/review.sh`, find the single-pass `build_review_prompt` call (near line 313) and append `"$diff_mode"` as the final argument:

```bash
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$base_ref" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "$output_mode" "$diff_mode")
```

In `lib/review-prompt.sh`, add the param to `build_review_prompt` locals (after the `output_mode` local, ~line 18):

```bash
  local diff_mode="${11:-base}"
```

Then replace its diff acquisition block (the `diff=$(git ... )` and `changed_files=$(git ...)` blocks, ~lines 31–44) with:

```bash
  local diff
  diff=$(review_diff_text "$project_dir" "$diff_mode" "$resolved_base")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$diff_mode" "$resolved_base")
```

- [ ] **Step 5: Run the full suite (regression — base mode must be unchanged)**

Run: `bash test.sh`
Expected: all green. `tests/test_review_personas.sh`, `tests/test_review_safety.sh`, and `tests/test_review_working.sh` all pass — base-mode behavior is byte-for-byte equivalent (same git commands, now behind a helper).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh lib/review.sh lib/review-prompt.sh
git commit -m "feat(review): --working single-pass mode via shared review-diff helper"
```

---

## Task 9: Wire `--working` flag in `mra.sh` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` (review dispatch passthrough + usage)
- Test: manual smoke

- [ ] **Step 1: Pass `--working` through the review dispatch**

In `bin/mra.sh`'s `review)` case, the existing loop already forwards unknown flags into `review_args` via the `*)` arm — but it currently only special-cases `--personas`. Confirm `--working` falls through to `review_args` (it does, via `*) review_args+=("$1")`). No change needed unless the `has_project` scan misclassifies it. Update the `has_project` detection loop to treat `--working` as a non-project flag by adding it to the `--no-debate) ;;` arm:

```bash
          --no-debate|--working) ;;
```

- [ ] **Step 2: Update usage text**

In the usage heredoc, change the `review` line to document `--working`:

```
  review <project> [--pr N] [--working] [--no-debate]  Code review (--working: uncommitted changes)
```

- [ ] **Step 3: Smoke test**

Run:

```bash
WS=$(mktemp -d); mkdir -p "$WS/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main repo &>/dev/null
git -C "$WS/repo" config user.email t@t.t; git -C "$WS/repo" config user.name t
echo a > "$WS/repo/f.txt"; git -C "$WS/repo" add f.txt; git -C "$WS/repo" commit -m init &>/dev/null
# clean tree => should report "no uncommitted changes" and exit 0 (no Claude call)
MRA_WORKSPACE="$WS" bash bin/mra.sh review repo --working; echo "exit=$?"
rm -rf "$WS"
```

Expected: logs `no uncommitted changes to review` and `exit=0`. (With changes present it would proceed to invoke Claude — not exercised in this smoke test.)

- [ ] **Step 4: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(review): wire mra review --working flag + usage"
```

---

## Done — Phase 0 complete

After Task 9, the journey works end to end: `mra branch status` → `mra sync --safe` → `mra review <repo> --working`. Phases 1–2 (push, branch new/switch, range/head review, auto-review-after-sync, PR chaining) are deferred per spec §8 and reuse `BranchState` + `branch_sync_action`.
