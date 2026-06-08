# Branch-aware Sync & Review — Phase 8 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Final polish — add `branch merge --delete-branch` (opt-in), make `integration-test.sh`'s `is_api_change` call explicit, add a concerns-only negative test, and align `merge_repo`'s skip log levels with `pr_repo`.

**Architecture:** Thread a `delete_branch` flag through `merge_repo`/`merge_workspace`/dispatch (default off; appends `--delete-branch` to `gh pr merge`). Two one-line consistency fixes and one test addition. No new subsystem.

**Tech Stack:** Bash, git CLI, `gh` CLI, existing `lib/pr-ops.sh`/`lib/integration-test.sh`, plain-bash tests under `tests/`.

---

## File Structure

- **Modify `lib/pr-ops.sh`** — `merge_repo` gains `delete_branch` (4th param) + uses it in `gh pr merge` and the dry-run preview; the two skip logs become `log_warn`; `merge_workspace` gains `delete_branch` (4th param) and passes it through.
- **Modify `bin/mra.sh`** — `branch merge` dispatch parses `--delete-branch` and passes it to `merge_workspace`; usage updated.
- **Modify `lib/integration-test.sh`** — explicit `is_api_change` mode/range.
- **Modify `tests/test_pr_ops.sh`, `tests/test_change_detector.sh`** — passthrough/skip tests + concerns-only negative test.

Task order: T1 lib plumbing (`merge_repo` + `merge_workspace`) → T2 dispatch flag → T3 integration-test consistency → T4 concerns-only test.

---

## Task 1: Thread `delete_branch` through `merge_repo`/`merge_workspace` + align skip logs

**Files:**
- Modify: `lib/pr-ops.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- merge_repo accepts delete_branch param without breaking the skip path ---
DB_DIR=$(mktemp -d)
git -C "$DB_DIR" init -b main repo &>/dev/null
DBR="$DB_DIR/repo"
git -C "$DBR" config user.email t@t.t; git -C "$DBR" config user.name t
git -C "$DBR" commit --allow-empty -m c1 &>/dev/null
git -C "$DBR" checkout -b feat/x &>/dev/null
git -C "$DBR" commit --allow-empty -m work &>/dev/null
out=$(merge_repo "$DBR" merge false true 2>&1); rc=$?   # delete_branch=true, no PR => skip
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
merge_repo() { echo "delete=$4" >> "$DBW_LOG"; return 0; }   # record 4th arg (delete_branch)
merge_workspace "$DBW_DIR" merge true true &>/dev/null
case "$(cat "$DBW_LOG")" in *"delete=true"*) : ;; *) echo "FAIL: merge_workspace should pass delete_branch=true to merge_repo: $(cat "$DBW_LOG")"; errors=$((errors+1)) ;; esac
unset -f merge_repo
rm -rf "$DBW_DIR" "$DBW_LOG"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `merge_workspace` ignores a 4th arg today (the stub records `delete=` empty, not `delete=true`).

- [ ] **Step 3: Update `merge_repo` in `lib/pr-ops.sh`**

(a) Change the signature line:
```bash
  local repo_dir="$1" strategy="${2:-merge}" dry_run="${3:-false}"
```
to:
```bash
  local repo_dir="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}"
```

(b) Change the two skip logs from `log_info` to `log_warn`:
```bash
    log_info "$repo_name: detached HEAD — skipping" "branch"; return 0
```
→
```bash
    log_warn "$repo_name: detached HEAD — skipping" "branch"; return 0
```
and
```bash
    log_info "$repo_name: on default branch '$def' — skipping" "branch"; return 0
```
→
```bash
    log_warn "$repo_name: on default branch '$def' — skipping" "branch"; return 0
```

(c) Replace the dry-run + merge block (the part from `if [[ "$dry_run" == "true" ]]; then ... fi` through the `gh pr merge` `if`) with:
```bash
  local del_note=""
  local merge_args=(--"$strategy")
  if [[ "$delete_branch" == "true" ]]; then del_note=" (+delete-branch)"; merge_args+=(--delete-branch); fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "$repo_name: would merge PR #$number ($strategy)$del_note" "branch"; return 0
  fi
  if (cd "$repo_dir" && gh pr merge "$branch" "${merge_args[@]}" >/dev/null 2>&1); then
    log_success "$repo_name: merged PR #$number ($strategy)$del_note" "branch"; return 0
  fi
  log_error "$repo_name: gh pr merge failed for PR #$number" "branch"; return 1
```

- [ ] **Step 4: Update `merge_workspace` in `lib/pr-ops.sh`**

(a) Change its signature:
```bash
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}"
```
to:
```bash
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}"
```

(b) Change the merge_repo call:
```bash
    merge_repo "$workspace/$r" "$strategy" "$dry_run" || return 1
```
to:
```bash
    merge_repo "$workspace/$r" "$strategy" "$dry_run" "$delete_branch" || return 1
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS. Then `bash test.sh` — all green (the existing merge_repo default-branch skip test still passes; its message text is unchanged by the log-level swap).

- [ ] **Step 6: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(merge): --delete-branch passthrough (merge_repo/merge_workspace) + align skip log levels"
```

---

## Task 2: Wire `branch merge --delete-branch` dispatch

**Files:**
- Modify: `bin/mra.sh`
- Test: `tests/test_pr_ops.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_pr_ops.sh`, before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- branch merge --delete-branch is accepted and threaded (no-PR fixture => skip, exit 0) ---
DBD=$(mktemp -d); mkdir -p "$DBD/.collab"; echo '{"gitOrg":"x","projects":{"a":{"deps":{},"consumedBy":[]}}}' > "$DBD/.collab/dep-graph.json"
git -C "$DBD" init -b main a &>/dev/null
git -C "$DBD/a" config user.email t@t.t; git -C "$DBD/a" config user.name t
git -C "$DBD/a" commit --allow-empty -m init &>/dev/null
git -C "$DBD/a" checkout -b feat/x &>/dev/null
git -C "$DBD/a" commit --allow-empty -m work &>/dev/null
if out=$(MRA_WORKSPACE="$DBD" bash "$SCRIPT_DIR/bin/mra.sh" branch merge --delete-branch --dry-run 2>&1); then rc=0; else rc=$?; fi
# gh authenticated => no-PR skip + exit 0; gh unauth => auth error + exit 1. Accept either, but --delete-branch must NOT be "unknown option".
case "$out" in *"unknown option"*) echo "FAIL: --delete-branch should be a recognized flag: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$DBD"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `--delete-branch` is currently an unknown option in the `merge)` arm (`*) log_error "unknown option"`).

- [ ] **Step 3: Add `--delete-branch` to the `merge)` dispatch**

In `bin/mra.sh`'s `merge)` arm, add `delete_branch=false` to the locals and a `--delete-branch` case, then pass it to `merge_workspace`. Specifically:

Change:
```bash
          local strategy="merge" dry_run=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
```
to:
```bash
          local strategy="merge" dry_run=false delete_branch=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              --delete-branch) delete_branch=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
```
And change:
```bash
          merge_workspace "$workspace" "$strategy" "$dry_run"
```
to:
```bash
          merge_workspace "$workspace" "$strategy" "$dry_run" "$delete_branch"
```

- [ ] **Step 4: Update usage text**

In the usage heredoc, change the `branch merge` line to document `--delete-branch`:
```
  branch merge [--strategy S] [--dry-run] [--delete-branch]  Merge open PRs across repos (deps first; gated on mergeable+CI)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (`--delete-branch` accepted, not "unknown option"). Then `bash test.sh` — all green.

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_pr_ops.sh
git commit -m "feat(merge): wire branch merge --delete-branch (opt-in) + usage"
```

---

## Task 3: `integration-test.sh` `is_api_change` consistency

**Files:**
- Modify: `lib/integration-test.sh`

- [ ] **Step 1: Make the change**

In `lib/integration-test.sh` (~line 125), find:
```bash
  change_level=$(is_api_change "$project_dir" "$project_type")
```
Replace with:
```bash
  change_level=$(is_api_change "$project_dir" "$project_type" range "$(get_default_branch "$project_dir")...HEAD")
```

(`get_default_branch` is available at runtime — `integration-test.sh` is sourced into `bin/mra.sh` alongside `sync.sh`. This is behavior-equivalent to the prior 2-arg back-compat default, just explicit and consistent with `review.sh`/`eval.sh`.)

- [ ] **Step 2: Verify syntax + call shape**

Run: `bash -n lib/integration-test.sh` — Expected: no output.
Run: `grep -n 'is_api_change' lib/integration-test.sh` — Expected: the call now has 4 args including `range "$(get_default_branch ...)...HEAD"`.

- [ ] **Step 3: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add lib/integration-test.sh
git commit -m "fix(integration-test): pass explicit mode/range to is_api_change (consistency)"
```

---

## Task 4: Concerns-only negative test

**Files:**
- Modify: `tests/test_change_detector.sh`

- [ ] **Step 1: Write the test**

Append to `tests/test_change_detector.sh`, before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- concerns-only controller change is NOT high (locks the grep -qvE concerns/ exclusion) ---
CC=$(mktemp -d)
git -C "$CC" init -b main repo &>/dev/null
CCR="$CC/repo"
git -C "$CCR" config user.email t@t.t; git -C "$CCR" config user.name t
mkdir -p "$CCR/app/controllers/concerns"
git -C "$CCR" commit --allow-empty -m base &>/dev/null
CCA=$(git -C "$CCR" rev-parse HEAD)
git -C "$CCR" checkout -b feat &>/dev/null
printf 'module Auth\n  def authenticate\n  end\nend\n' > "$CCR/app/controllers/concerns/auth_concern.rb"
git -C "$CCR" add .; git -C "$CCR" commit -m "add concern" &>/dev/null
CCB=$(git -C "$CCR" rev-parse HEAD)
res=$(is_api_change "$CCR" rails-api range "$CCA..$CCB")
case "$res" in high*) echo "FAIL: concerns-only change should NOT be high, got: $res"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$CC"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_change_detector.sh`
Expected: PASS — a change only under `app/controllers/concerns/` does NOT match `^config/routes.rb$`/serializer/schema, and the controller rule's `grep -qvE "concerns/"` excludes it, so the verdict is `low` (not `high`). (If it FAILS as `high`, the exclusion logic is broken — report it.)

- [ ] **Step 3: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tests/test_change_detector.sh
git commit -m "test(review): concerns-only controller change is not high (lock exclusion)"
```

---

## Done — Phase 8 complete

After Task 4: `mra branch merge --delete-branch` opt-in deletes merged branches; `integration-test.sh` calls `is_api_change` explicitly; the concerns-only exclusion is locked by a negative test; and `merge_repo`'s skip logs match `pr_repo`'s `log_warn` convention. The actionable backlog for branch-aware sync & review is now cleared (spec §16.5).
