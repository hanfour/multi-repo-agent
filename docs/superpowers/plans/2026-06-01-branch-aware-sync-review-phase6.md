# Branch-aware Sync & Review — Phase 6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the cleanup backlog: fix the controller-detection grep no-op, remove a dead `action` lookup, make eval's `is_api_change` call explicit, close three test-coverage gaps, and add `set -euo pipefail` to the 13 test files that lack it.

**Architecture:** Small, independent fixes across `lib/change-detector.sh`, `lib/branch.sh`, `lib/eval.sh`, plus a test-coverage pass and a per-file strict-mode sweep over `tests/`. No new commands; the only behavior change is the intended controller-detection fix.

**Tech Stack:** Bash, git CLI, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Modify `lib/change-detector.sh`** — fix the controller grep so the `if` can be true.
- **Modify `lib/branch.sh`** — `branch_format_row` reads `sync_action` directly.
- **Modify `lib/eval.sh`** — explicit `is_api_change` mode/range args.
- **Modify `tests/test_change_detector.sh`, `tests/test_review_working.sh`** — coverage additions.
- **Modify 13 `tests/test_*.sh`** — add `set -euo pipefail`.

Task order: T1 controller fix (behavior) → T2 dead lookup → T3 eval consistency → T4 test gaps → T5 strict-mode sweep. Each keeps the suite green.

---

## Task 1: Fix controller-detection grep no-op

**Files:**
- Modify: `lib/change-detector.sh`
- Test: `tests/test_change_detector.sh`

- [ ] **Step 1: Write the failing test**

In `tests/test_change_detector.sh`, add immediately before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- controller change with a public method => high (controller-detection fix) ---
CT=$(mktemp -d)
git -C "$CT" init -b main repo &>/dev/null
CR="$CT/repo"
git -C "$CR" config user.email t@t.t; git -C "$CR" config user.name t
mkdir -p "$CR/app/controllers"
git -C "$CR" commit --allow-empty -m base &>/dev/null
CA=$(git -C "$CR" rev-parse HEAD)
git -C "$CR" checkout -b feat &>/dev/null
printf 'class UsersController\n  def index\n  end\nend\n' > "$CR/app/controllers/users_controller.rb"
git -C "$CR" add .; git -C "$CR" commit -m "add controller" &>/dev/null
CB=$(git -C "$CR" rev-parse HEAD)

res=$(is_api_change "$CR" rails-api range "$CA..$CB")
case "$res" in high*) : ;; *) echo "FAIL: controller w/ def index should be high, got: $res"; errors=$((errors+1)) ;; esac
rm -rf "$CT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_change_detector.sh`
Expected: FAIL — the controller `if` is a no-op today (`grep -qE … | grep -v …`), so only-controller changes return `low`, not `high`.

- [ ] **Step 3: Fix the grep**

In `lib/change-detector.sh`, find:

```bash
      if echo "$changed_files" | grep -qE "^app/controllers/" | grep -v "concerns/"; then
```

Replace with:

```bash
      if echo "$changed_files" | grep -E "^app/controllers/" | grep -qvE "concerns/"; then
```

(First `grep -E` lists changed controller files; `grep -qv concerns/` succeeds if any is not under `concerns/`. The inner content-diff gate that follows — `ctrl_diff` grepped for `def index|show|...` or route verbs — is unchanged, so `high` still requires a real public-method/route addition.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_change_detector.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/change-detector.sh tests/test_change_detector.sh
git commit -m "fix(review): controller-detection grep no-op (rails-api controller changes now detected)"
```

---

## Task 2: Remove dead `action` lookup in `branch_format_row`

**Files:**
- Modify: `lib/branch.sh`
- Test: `tests/test_branch.sh` (regression — existing `branch_format_row` test stays green)

- [ ] **Step 1: Make the change**

In `lib/branch.sh`, in `branch_format_row`, find:

```bash
  action=$(branch_state_get "$s" action 2>/dev/null)
  [[ -z "$action" ]] && action=$(branch_state_get "$s" sync_action)
```

Replace with:

```bash
  action=$(branch_state_get "$s" sync_action)
```

(`get_branch_state` always emits `sync_action=`; the `action` key never exists, so the first lookup was always empty.)

- [ ] **Step 2: Run the existing regression test**

Run: `bash tests/test_branch.sh`
Expected: PASS — the existing `branch_format_row` assertion (which passes a block containing `sync_action=diverged` and expects `diverged` in the row) still holds.

- [ ] **Step 3: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add lib/branch.sh
git commit -m "refactor(branch): branch_format_row reads sync_action directly (drop dead action lookup)"
```

---

## Task 3: eval `is_api_change` consistency

**Files:**
- Modify: `lib/eval.sh`

- [ ] **Step 1: Make the change**

In `lib/eval.sh` (~line 199), find:

```bash
    change_result=$(is_api_change "$project_dir" "$project_type" 2>/dev/null || echo "low")
```

Replace with:

```bash
    change_result=$(is_api_change "$project_dir" "$project_type" range "${resolved_base}...HEAD" 2>/dev/null || echo "low")
```

(`resolved_base` is already in scope, set earlier in the same function. This is behavior-equivalent to the prior 2-arg back-compat default but explicit, matching `review.sh`.)

- [ ] **Step 2: Verify syntax + the call shape**

Run: `bash -n lib/eval.sh` — Expected: no output.
Run: `grep -n 'is_api_change' lib/eval.sh` — Expected: the call now has 4 args (`"$project_dir" "$project_type" range "${resolved_base}...HEAD"`).

- [ ] **Step 3: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add lib/eval.sh
git commit -m "fix(eval): pass explicit mode/range to is_api_change (consistency with review)"
```

---

## Task 4: Close test-coverage gaps

**Files:**
- Modify: `tests/test_change_detector.sh` (is_api_change working mode)
- Modify: `tests/test_review_working.sh` (explicit `--range` preamble)

- [ ] **Step 1: Write the failing tests**

(a) In `tests/test_change_detector.sh`, add before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --- is_api_change working mode: uncommitted routes.rb => high ---
WK=$(mktemp -d)
git -C "$WK" init -b main repo &>/dev/null
WR="$WK/repo"
git -C "$WR" config user.email t@t.t; git -C "$WR" config user.name t
mkdir -p "$WR/config"
git -C "$WR" commit --allow-empty -m base &>/dev/null
printf 'Rails.routes\n' > "$WR/config/routes.rb"   # uncommitted (working tree)
res=$(is_api_change "$WR" rails-api working "")
case "$res" in high*) : ;; *) echo "FAIL: working-mode uncommitted routes.rb should be high, got: $res"; errors=$((errors+1)) ;; esac
rm -rf "$WK"
```

(b) In `tests/test_review_working.sh`, add before the final `if [[ $errors -eq 0 ]]` block. This block creates its OWN fixture (the earlier preamble block's `$PRE_DIR` has already been `rm -rf`'d, so do not rely on it):

```bash
# --- explicit --range preamble wording ---
RG_DIR=$(mktemp -d); git -C "$RG_DIR" init -b main repo &>/dev/null
RGR="$RG_DIR/repo"
git -C "$RGR" config user.email t@t.t; git -C "$RGR" config user.name t
git -C "$RGR" commit --allow-empty -m c1 &>/dev/null
p=$(build_review_prompt repo "$RGR" "" main unknown "" "" false "" terminal range "aaa..bbb")
case "$p" in *"changes in 'aaa..bbb'"*) : ;; *) echo "FAIL: explicit range preamble should name the range"; errors=$((errors+1)) ;; esac
case "$p" in *"pull request"*) echo "FAIL: explicit range preamble should NOT say 'pull request'"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$RG_DIR"
```

- [ ] **Step 2: Run tests to verify they fail (or are absent)**

Run: `bash tests/test_change_detector.sh` and `bash tests/test_review_working.sh`
Expected: the working-mode case requires `is_api_change` to read `git diff HEAD` (it does, via Phase 5) — this should PASS already and serves as a coverage lock. The explicit-range preamble case should PASS already (Phase 4/5 logic) — also a coverage lock. (If either FAILS, it reveals a real gap to fix in the corresponding lib.)

- [ ] **Step 3: Confirm green**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tests/test_change_detector.sh tests/test_review_working.sh
git commit -m "test(review): cover is_api_change working mode + explicit --range preamble"
```

---

## Task 5: `set -euo pipefail` sweep over 13 test files

Add strict mode to the 13 test files that lack it, ONE AT A TIME, running each after the change. `set -u`/`set -e` may surface a latent unbound variable or a previously-ignored non-zero exit; fix each minimally without changing assertions.

**Files (all under `tests/`):** `test_db_safety.sh`, `test_docker_trust.sh`, `test_doctor_security.sh`, `test_install_alias.sh`, `test_lint_profile.sh`, `test_project_path.sh`, `test_review_safety.sh`, `test_scan_rebuild.sh`, `test_scanners.sh`, `test_security_log.sh`, `test_snapshot.sh`, `test_url_policy.sh`, `test_validate.sh`.

- [ ] **Step 1: Confirm the list**

Run:
```bash
for f in tests/test_*.sh; do head -3 "$f" | grep -q 'set -euo pipefail' || echo "$f"; done
```
Expected: exactly the 13 files listed above.

- [ ] **Step 2: For each file — add strict mode, run, fix if needed**

For each file `F` in the list, do:
1. Insert `set -euo pipefail` on the line immediately AFTER the `#!/usr/bin/env bash` shebang (if a file has no shebang, add `set -euo pipefail` as the first line). Example for one file:
```bash
F=tests/test_validate.sh
# add after shebang (line 1)
sed -i.bak '1a set -euo pipefail' "$F" && rm -f "$F.bak"
```
   (If the file already has other `set -` lines just below the shebang, place `set -euo pipefail` adjacent to them instead of duplicating; inspect first with `head -5 "$F"`.)
2. Run `bash "$F"`.
3. If it PASSES, move to the next file.
4. If it FAILS due to strict mode, diagnose and apply the MINIMAL fix WITHOUT changing any assertion:
   - **Unbound variable** (`F: line N: VAR: unbound variable`): change the reference to `${VAR:-}` (or initialize the var earlier with a sensible default).
   - **A command whose non-zero exit now aborts** (a probe/cleanup that was expected to sometimes fail): append `|| true` to that specific command.
   - Re-run `bash "$F"` until green.
   - Report any fix that was more than a `${var:-}` / `|| true` (it may indicate a real latent bug).

- [ ] **Step 3: Verify all 13 now have strict mode and the suite is green**

Run:
```bash
for f in tests/test_*.sh; do head -5 "$f" | grep -q 'set -euo pipefail' || echo "MISSING: $f"; done
```
Expected: no `MISSING:` output.
Run: `bash test.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: add set -euo pipefail to the remaining 13 test files (+ minimal strict-mode fixes)"
```

---

## Done — Phase 6 complete

After Task 5 the cleanup backlog is cleared: the rails-api controller-detection trigger fires correctly, `branch_format_row` has no dead lookup, eval's `is_api_change` is explicit, the is_api_change working-mode and explicit-range preamble paths have test locks, and every `tests/test_*.sh` runs under `set -euo pipefail`. Deferred to Phase 7 (spec §14.5): auto-merge / PR-merge orchestration (its own brainstorm), §11.6.2.
