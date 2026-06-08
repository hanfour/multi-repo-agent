# Branch-aware Sync & Review — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the existing `mra` branch/sync/PR surface: mutually-exclusive sync mode flags, repo-name path-traversal guard, `branch pr` base/eligibility polish, a diverged-push integration fixture, and a repo-wide test-harness fix.

**Architecture:** No new commands. Targeted fixes retiring the spec §9.7 and §10.8 follow-ups: a new pure `validate_repo_name` in `lib/branch-ops.sh`; base-aware candidate filtering + unresolved-base handling in `lib/pr-ops.sh`; mutual-exclusion gates in the `bin/mra.sh` `sync)` dispatch; plus test-only additions and a mechanical `((errors++))` → `errors=$((errors+1))` sweep.

**Tech Stack:** Bash, git CLI, existing `lib/*`, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Modify `lib/branch-ops.sh`** — add pure `validate_repo_name()`; call it in `create_branch_workspace` for listed repos.
- **Modify `lib/pr-ops.sh`** — `pr_workspace` candidate filter uses the resolved base; `pr_repo` warns on an unresolvable base.
- **Modify `bin/mra.sh`** — `sync)` dispatch gains mutual-exclusion + `--dry-run`-requires-`--push` gates.
- **Create `tests/test_sync_flags.sh`** — flag-discipline subprocess tests.
- **Modify `tests/test_branch_ops.sh`, `tests/test_pr_ops.sh`, `tests/test_sync.sh`** — new assertions.
- **Sweep all `tests/test_*.sh`** — `((errors++))` → `errors=$((errors+1))`.

Task order: T1 sweep first (so later test additions land in already-consistent files), then T2 sync flags, T3 validate_repo_name, T4 pr-ops base, T5 diverged fixture. Tasks are independent except all run against a green suite.

---

## Task 1: Repo-wide `((errors++))` → `errors=$((errors+1))` sweep

Under `set -euo pipefail`, `((errors++))` returns exit 1 when `errors` is 0, aborting a test on its FIRST failing assertion instead of accumulating all failures. This mechanical sweep fixes every test file. Behavior on the green path is identical (the suite stays green); on failure it now counts all failures.

**Files:**
- Modify: every `tests/test_*.sh` containing `((errors++))`

- [ ] **Step 1: Confirm the current occurrences**

Run: `grep -rl '((errors++))' tests/ | wc -l`
Expected: a non-zero count (≈40 files).

- [ ] **Step 2: Apply the portable sweep**

Run (portable across GNU/BSD sed; BRE treats `(` `)` `+` as literal, and the replacement has no special chars):

```bash
for f in tests/test_*.sh; do
  if grep -q '((errors++))' "$f"; then
    sed -i.bak 's/((errors++))/errors=$((errors+1))/g' "$f" && rm -f "$f.bak"
  fi
done
```

- [ ] **Step 3: Verify no residual occurrences**

Run: `grep -rn '((errors' tests/ || echo "clean"`
Expected: `clean` (no `((errors...` patterns remain).

- [ ] **Step 4: Run the full suite to confirm green (behavior unchanged)**

Run: `bash test.sh`
Expected: all green — same pass counts as before (the change only affects failure accumulation).

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: replace ((errors++)) with errors=\$((errors+1)) for set -e failure accumulation"
```

---

## Task 2: sync flag discipline (mutual exclusion + `--dry-run` requires `--push`)

**Files:**
- Modify: `bin/mra.sh` (`sync)` dispatch)
- Test: `tests/test_sync_flags.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test_sync_flags.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

# A clean, empty workspace (no repos) so a valid single-mode/default run exits 0 quickly.
WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"

# run sync with the given flags; capture output in $out and exit code in $rc.
# The `if out=$(...)` form suspends set -e so a non-zero exit does not abort the test.
run() {
  if out=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync "$@" 2>&1); then rc=0; else rc=$?; fi
}

# conflicting modes -> exit 1 + message
run --safe --push
if [[ $rc -eq 0 ]]; then echo "FAIL: --safe --push should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"choose only one"*) : ;; *) echo "FAIL: expected 'choose only one', got: $out"; errors=$((errors+1)) ;; esac

run --review --push
if [[ $rc -eq 0 ]]; then echo "FAIL: --review --push should exit non-zero"; errors=$((errors+1)); fi

# --dry-run without --push -> exit 1 + message
run --dry-run
if [[ $rc -eq 0 ]]; then echo "FAIL: --dry-run without --push should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"only applies to --push"*) : ;; *) echo "FAIL: expected 'only applies to --push', got: $out"; errors=$((errors+1)) ;; esac

# valid combo: --push --dry-run on empty workspace -> exit 0
run --push --dry-run
if [[ $rc -ne 0 ]]; then echo "FAIL: --push --dry-run should exit 0 on empty workspace, got rc=$rc: $out"; errors=$((errors+1)); fi

# single mode --review on empty workspace -> not rejected by discipline gate (exit 0)
run --review
if [[ $rc -ne 0 ]]; then echo "FAIL: single --review should not be rejected, got rc=$rc: $out"; errors=$((errors+1)); fi

rm -rf "$WS"
if [[ $errors -eq 0 ]]; then
  echo "PASS: sync flag discipline tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

Note: `out`/`rc` are set by the `run` helper as globals (no `local`), so the assertions after each call can read them.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync_flags.sh`
Expected: FAIL — conflicting flags currently do NOT exit non-zero (`--review` silently wins; `--dry-run` is silently ignored).

- [ ] **Step 3: Add the discipline gates in `bin/mra.sh`**

In the `sync)` case, immediately AFTER the option-parsing `while` loop and BEFORE `local workspace; workspace=$(resolve_workspace)`, insert:

```bash
      # mode flags are mutually exclusive
      local mode_count=0
      [[ "$safe" == "true" ]] && mode_count=$((mode_count+1))
      [[ "$push" == "true" ]] && mode_count=$((mode_count+1))
      [[ "$review" == "true" ]] && mode_count=$((mode_count+1))
      if [[ "$mode_count" -gt 1 ]]; then
        log_error "sync: choose only one of --safe / --push / --review" "sync"; exit 1
      fi
      if [[ "$dry_run" == "true" && "$push" != "true" ]]; then
        log_error "sync: --dry-run only applies to --push" "sync"; exit 1
      fi
```

(The `[[ ... ]] && mode_count=...` lines are set-e-safe: a false `[[ ]]` on the LHS of `&&` does not trigger `set -e`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync_flags.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh tests/test_sync_flags.sh
git commit -m "fix(sync): mutually-exclusive mode flags; --dry-run requires --push"
```

---

## Task 3: `validate_repo_name()` + `branch new` path-traversal guard

**Files:**
- Modify: `lib/branch-ops.sh`
- Test: `tests/test_branch_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_branch_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- validate_repo_name: only flat names allowed ---
for n in api my-repo repo123; do
  if ! validate_repo_name "$n"; then echo "FAIL: '$n' should be a valid repo name"; errors=$((errors+1)); fi
done
for n in "a/b" "." ".." "-foo" "../x"; do
  if validate_repo_name "$n"; then echo "FAIL: '$n' should be an INVALID repo name"; errors=$((errors+1)); fi
done

# --- create_branch_workspace rejects a traversal repo name without touching the filesystem ---
WSV=$(mktemp -d)
mkdir -p "$WSV/api"
git -C "$WSV/api" init -b main . &>/dev/null
git -C "$WSV/api" config user.email t@t.t; git -C "$WSV/api" config user.name t
git -C "$WSV/api" commit --allow-empty -m init &>/dev/null
if create_branch_workspace "$WSV" feat/x "../evil" &>/dev/null; then
  echo "FAIL: create_branch_workspace should return non-zero when a repo name is invalid"; errors=$((errors+1))
fi
if [[ -e "$WSV/../evil" ]]; then echo "FAIL: traversal name must not create anything outside the workspace"; errors=$((errors+1)); fi
rm -rf "$WSV"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch_ops.sh`
Expected: FAIL — `validate_repo_name: command not found`.

- [ ] **Step 3: Add `validate_repo_name` and call it in `create_branch_workspace`**

In `lib/branch-ops.sh`, add this function (e.g. right after `validate_branch_name`):

```bash
# Validate a repo NAME (a flat directory under the workspace). Returns non-zero if invalid.
# Rejects: empty, contains '/', equals '.' or '..', or begins with '-' (path traversal / option injection).
validate_repo_name() {
  local name="$1"
  [[ -z "$name" ]] && return 1
  case "$name" in
    -*) return 1 ;;
    .|..) return 1 ;;
    */*) return 1 ;;
  esac
  return 0
}
```

Then, in `create_branch_workspace`'s named-repos loop (the `else` branch), add a validation guard as the FIRST statement inside `for r in "${repos[@]}"; do` — before `local dir="$workspace/$r"`:

```bash
    for r in "${repos[@]}"; do
      if ! validate_repo_name "$r"; then
        log_error "invalid repo name: '$r'" "branch"; failed=$((failed+1)); continue
      fi
      local dir="$workspace/$r"
      if should_skip_dir "$dir"; then
        log_error "$r: not a git repo" "branch"; failed=$((failed+1)); continue
      fi
      if ! create_branch_in_repo "$dir" "$name"; then failed=$((failed+1)); fi
    done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/branch-ops.sh tests/test_branch_ops.sh
git commit -m "fix(branch): validate_repo_name guards branch new against path traversal"
```

---

## Task 4: `branch pr` base-aware candidate + unresolved-base warning

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, immediately BEFORE the final `if [[ $errors -eq 0 ]]` block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — currently an unresolvable base is treated as "0 commits → nothing to PR" (no "not found" message), and a repo on a non-default `--base` ref is still collected as a candidate (since the filter compares against the default branch, not the base).

- [ ] **Step 3: Update `pr_workspace` candidate filter (base-aware)**

In `lib/pr-ops.sh`, in `pr_workspace`, replace the candidate-collection loop body. The current body computes `def=$(get_default_branch "$dir")` and tests `"$br" != "$def"`. Replace the per-repo branch/exclusion logic so it excludes the RESOLVED base:

```bash
  for dir in "$workspace"/*/; do
    [[ ! -d "$dir" ]] && continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    should_skip_dir "$dir" && continue
    br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
    local base_ref="$base"
    [[ -z "$base_ref" ]] && base_ref=$(get_default_branch "$dir")
    if [[ "$br" != "(detached)" && "$br" != "$base_ref" ]]; then candidates+=("$name"); fi
  done
```

(Declare `base_ref` in the loop; `def` is no longer needed. Keep the surrounding `candidates`/`local ... dir name br` declarations — adjust the outer `local` list to drop `def` if present.)

- [ ] **Step 4: Add the unresolved-base guard in `pr_repo`**

In `lib/pr-ops.sh`, in `pr_repo`, AFTER the on-base check (`if [[ "$branch" == "$base_ref" ]]; ...`) and BEFORE the eligibility `count=` line, insert:

```bash
  if ! git -C "$repo_dir" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 \
     && ! git -C "$repo_dir" rev-parse --verify --quiet "origin/$base_ref" >/dev/null 2>&1; then
    log_warn "$repo_name: base '$base_ref' not found — skipping" "branch"; return 0
  fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 6: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "fix(pr): base-aware candidate filter + warn on unresolvable base"
```

---

## Task 5: Diverged-push integration fixture

**Files:**
- Modify: `tests/test_sync.sh` (test-only)

- [ ] **Step 1: Write the test**

In `tests/test_sync.sh`, append immediately before the final `rm -rf "$TEST_DIR"`:

```bash
# --- push_repo: a diverged branch is NOT pushed (integration) ---
DV_DIR=$(mktemp -d)
git -C "$DV_DIR" init -b main --bare up &>/dev/null
git clone "$DV_DIR/up" "$DV_DIR/a" &>/dev/null
git -C "$DV_DIR/a" config user.email t@t.t; git -C "$DV_DIR/a" config user.name t
git -C "$DV_DIR/a" commit --allow-empty -m base &>/dev/null
git -C "$DV_DIR/a" push -u origin main &>/dev/null
# second clone advances origin/main
git clone "$DV_DIR/up" "$DV_DIR/b" &>/dev/null
git -C "$DV_DIR/b" config user.email t@t.t; git -C "$DV_DIR/b" config user.name t
git -C "$DV_DIR/b" commit --allow-empty -m bcommit &>/dev/null
git -C "$DV_DIR/b" push origin main &>/dev/null
# a commits locally too => ahead AND behind => diverged
git -C "$DV_DIR/a" commit --allow-empty -m acommit &>/dev/null
git -C "$DV_DIR/a" fetch --quiet
before=$(git -C "$DV_DIR/up" rev-parse main)
push_repo "$DV_DIR/a" false &>/dev/null || true
after=$(git -C "$DV_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: diverged branch must not advance the remote"; errors=$((errors+1)); fi
rm -rf "$DV_DIR"
```

- [ ] **Step 2: Run test to verify it passes (behavior already correct from Phase 1)**

Run: `bash tests/test_sync.sh`
Expected: PASS — `push_repo` already classifies this as `skip-diverged` and does not push; this test adds the missing integration-level evidence. (If it FAILS, that is a real Phase 1 regression to investigate, not a test bug.)

- [ ] **Step 3: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tests/test_sync.sh
git commit -m "test(sync): diverged-push integration fixture (remote ref unchanged)"
```

---

## Done — Phase 3 complete

After Task 5 the §9.7 and §10.8 follow-ups are retired: sync mode flags are mutually exclusive with clear errors, `--dry-run` requires `--push`, `branch new` rejects path-traversal repo names, `branch pr` excludes repos on the base ref and warns on an unresolvable base, the diverged-push guard has integration coverage, and the test harness accumulates failures. Deferred to Phase 4 (spec §11.5): `review --range`/`--head` and the §8.1 review follow-ups.

> **Historical note:** Phase 4 (spec §12) is `review --range`/`--head` + diff-acquisition unification (retires §8.1.5); the remaining §8.1.1–§8.1.4 follow-ups moved to Phase 5. The authoritative, current phase map is **spec §8** (this plan and its commits are unchanged / already merged).
