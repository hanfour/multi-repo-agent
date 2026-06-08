# CI-polling auto-merge (Phase 10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `--wait-ci [--ci-timeout <sec>]` to `mra branch merge` that polls each PR's CI checks until they finish, then merges.

**Architecture:** A new `wait_for_pr_checks` poll loop in `lib/ci.sh` drives off `gh pr checks`'s exit codes (`0`=green, `8`=pending→keep polling, other non-zero=stop). `merge_repo` gains one new param `ci_wait_timeout` (empty = current one-shot gate, unchanged; a positive integer = poll). `merge_workspace` threads it; the `merge)` dispatch parses the flags with order-independent post-parse validation.

**Tech Stack:** Bash (shell library + `bin/mra.sh` dispatch), custom PASS/FAIL test harness (`tests/test_*.sh`), `gh`/`git`/`jq`.

**Spec:** `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` §18.

---

## File Structure

- **`lib/ci.sh`** (modify) — add `CI_POLL_INTERVAL` constant + `wait_for_pr_checks` (first runtime function; previously only the workflow generator).
- **`lib/pr-ops.sh`** (modify) — `merge_repo` gains 5th param `ci_wait_timeout`; CI gate branches poll-vs-one-shot; dry-run preview gains a wait clause. `merge_workspace` gains `ci_wait_timeout` (5th param, subset shifts to `${@:6}`) and threads it through.
- **`bin/mra.sh`** (modify) — `merge)` dispatch parses `--wait-ci` / `--ci-timeout`, validates post-parse, threads `ci_wait_timeout`; usage line updated. `pr)` untouched.
- **`tests/test_ci.sh`** (create) — `wait_for_pr_checks` unit tests (auto-discovered by `test.sh`, suite count 44→45).
- **`tests/test_pr_ops.sh`** (modify) — source `ci.sh`; CI-gate tests (open-PR stub); merge_workspace signature/thread-through; dispatch tests; update 3 Phase 9 subset calls with the `""` slot.

Reference facts (read before starting):
- `gh pr checks` exit codes: `0` = all passed, `8` = pending (documented in `gh pr checks --help`), other non-zero = failed OR no-checks-reported. Current one-shot gate `lib/pr-ops.sh:173`: `if ! (cd … gh pr checks …); then … "CI not green — stopping"; return 1`.
- `merge_repo` signature today: `(repo_dir, strategy, dry_run, delete_branch)` (`lib/pr-ops.sh:143`). CI gate at 173-175; dry-run preview at 181-183.
- `merge_workspace` today: `(workspace, strategy, dry_run, delete_branch, [subset…])` with subset `${@:5}` (`lib/pr-ops.sh:194-196`); calls `merge_repo … || return 1` at 244.
- `merge)` dispatch: `bin/mra.sh:674-697`. Usage line: `bin/mra.sh:105`.
- A `(cd "$repo_dir" && gh …)` subshell isolates variable mutations — test stubs that count calls MUST use a **file-based** counter, not a shell var.
- `test.sh` auto-discovers `tests/test_*.sh` (line 32).

---

## Task 1: `wait_for_pr_checks` poll loop + `tests/test_ci.sh`

**Files:**
- Create: `tests/test_ci.sh`
- Modify: `lib/ci.sh` (add constant + function)

- [ ] **Step 1: Write the failing test** — create `tests/test_ci.sh` with this exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/ci.sh"

errors=0
D=$(mktemp -d)   # a dir for the (cd "$repo_dir" ...) subshell to cd into

# CI_POLL_INTERVAL constant is defined and numeric
if ! [[ "${CI_POLL_INTERVAL:-}" =~ ^[0-9]+$ ]]; then echo "FAIL: CI_POLL_INTERVAL should be a number (got '${CI_POLL_INTERVAL:-}')"; errors=$((errors+1)); fi

# --- 1. all checks pass on first poll -> 0 ---
gh() { return 0; }
if wait_for_pr_checks "$D" feat/x 5 1; then : ; else echo "FAIL: all-pass should return 0"; errors=$((errors+1)); fi

# --- 2. pending,pending,pass across polls -> 0 (proves re-poll); pending uses gh exit 8 ---
CNT=$(mktemp); echo 0 > "$CNT"
gh() { local n; n=$(<"$CNT"); n=$((n+1)); echo "$n" > "$CNT"; case $n in 1|2) return 8 ;; *) return 0 ;; esac; }
if wait_for_pr_checks "$D" feat/x 10 0; then : ; else echo "FAIL: pending-then-pass should return 0"; errors=$((errors+1)); fi
n_final=$(<"$CNT"); if [[ "$n_final" -lt 3 ]]; then echo "FAIL: should have polled at least 3 times (got $n_final)"; errors=$((errors+1)); fi
rm -f "$CNT"

# --- 3. a failed check (exit 1, not 8) -> 1 immediately (fail-fast) ---
gh() { return 1; }
if wait_for_pr_checks "$D" feat/x 60 1; then echo "FAIL: failed check should return non-zero"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 1 ]] || { echo "FAIL: failed check should return 1 (got $rc)"; errors=$((errors+1)); }; fi

# --- 4. always pending (exit 8) + tiny timeout -> 2 (timed out) ---
gh() { return 8; }
if wait_for_pr_checks "$D" feat/x 1 1; then echo "FAIL: timeout should return non-zero"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 2 ]] || { echo "FAIL: timeout should return 2 (got $rc)"; errors=$((errors+1)); }; fi

# --- 5. no checks reported (gh exits non-zero, non-8 e.g. 1) -> 1 (NOT silently green) ---
gh() { return 1; }
if wait_for_pr_checks "$D" feat/x 5 1; then echo "FAIL: no-checks (non-zero) must NOT be green"; errors=$((errors+1)); else rc=$?; [[ "$rc" -eq 1 ]] || { echo "FAIL: no-checks should return 1 (got $rc)"; errors=$((errors+1)); }; fi

unset -f gh
rm -rf "$D"

if [[ "$errors" -eq 0 ]]; then echo "PASS: ci poll tests passed"; else echo "=== ci: $errors failed ==="; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_ci.sh`
Expected: FAIL — `wait_for_pr_checks: command not found` and/or the `CI_POLL_INTERVAL` assertion fails (neither exists yet).

- [ ] **Step 3: Write the implementation** — add to `lib/ci.sh`, immediately after the header comment lines (before `generate_ci_workflow`):

```bash
# Seconds between gh pr checks polls while CI is pending (overridable for tests).
CI_POLL_INTERVAL="${CI_POLL_INTERVAL:-30}"

# Poll a PR's CI checks until they finish, by inspecting `gh pr checks` exit codes.
# Args: repo_dir branch timeout_sec [interval_sec]
# Exit codes used: 0 = all passed; 8 = pending (keep waiting); any other non-zero
# = not green (a failed check OR "no checks reported" — both stop, matching the
# one-shot gate in merge_repo).
# Returns: 0 green | 1 not green (failed/no-checks) | 2 timed out.
wait_for_pr_checks() {
  local repo_dir="$1" branch="$2" timeout_sec="$3" interval_sec="${4:-$CI_POLL_INTERVAL}"
  local start=$SECONDS rc
  while true; do
    (cd "$repo_dir" && gh pr checks "$branch" >/dev/null 2>&1); rc=$?
    case "$rc" in
      0) return 0 ;;   # all checks passed
      8) ;;            # pending — fall through to timeout check, then sleep
      *) return 1 ;;   # failed / no-checks / other -> not green
    esac
    if (( SECONDS - start >= timeout_sec )); then
      return 2
    fi
    sleep "$interval_sec"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_ci.sh`
Expected: `PASS: ci poll tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/ci.sh tests/test_ci.sh
git commit -m "feat(ci): wait_for_pr_checks — poll gh pr checks exit codes (0/8/other)"
```

---

## Task 2: `merge_repo` gains `ci_wait_timeout` (poll-vs-one-shot CI gate)

**Files:**
- Modify: `tests/test_pr_ops.sh` (add `source ci.sh`; append CI-gate tests)
- Modify: `lib/pr-ops.sh` (replace the whole `merge_repo` function)

- [ ] **Step 1: Add the ci.sh source line** — in `tests/test_pr_ops.sh`, after the existing `source "$SCRIPT_DIR/lib/pr-ops.sh"` line (near the top, ~line 10), add:

```bash
source "$SCRIPT_DIR/lib/ci.sh"
```

- [ ] **Step 2: Write the failing tests** — append at the END of `tests/test_pr_ops.sh`, BEFORE the final summary/exit block. These stub `gh pr view` to report an OPEN+MERGEABLE PR so execution actually reaches the CI gate:

```bash
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
merge_repo "$CGR" merge false "" "" &>/dev/null
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

unset -f gh wait_for_pr_checks
source "$SCRIPT_DIR/lib/ci.sh"   # restore real wait_for_pr_checks
rm -rf "$CG_DIR" "$CG_LOG"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `merge_repo` ignores a 5th arg today, so the poll path (test 7) calls the one-shot gate (no `WAIT_CALLED`), and the dry-run preview (test 8) has no wait clause.

- [ ] **Step 4: Write the implementation** — replace the ENTIRE `merge_repo` function in `lib/pr-ops.sh` with:

```bash
merge_repo() {
  local repo_dir="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}" ci_wait_timeout="${5:-}"
  local repo_name; repo_name=$(basename "$repo_dir")
  should_skip_dir "$repo_dir" && return 0

  local branch; branch=$(git -C "$repo_dir" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
  if [[ "$branch" == "(detached)" ]]; then
    log_warn "$repo_name: detached HEAD — skipping" "branch"; return 0
  fi
  local def; def=$(get_default_branch "$repo_dir")
  if [[ "$branch" == "$def" ]]; then
    log_warn "$repo_name: on default branch '$def' — skipping" "branch"; return 0
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

  # CI gate: poll when ci_wait_timeout is set (and not dry-run), else the one-shot
  # check (unchanged). Dry-run with a wait skips polling — it is previewed below.
  if [[ -n "$ci_wait_timeout" ]]; then
    if [[ "$dry_run" != "true" ]]; then
      local crc=0
      wait_for_pr_checks "$repo_dir" "$branch" "$ci_wait_timeout" || crc=$?
      if [[ "$crc" -eq 2 ]]; then
        log_error "$repo_name: PR #$number CI did not finish within ${ci_wait_timeout}s — stopping" "branch"; return 1
      elif [[ "$crc" -ne 0 ]]; then
        log_error "$repo_name: PR #$number CI not green — stopping" "branch"; return 1
      fi
    fi
  else
    if ! (cd "$repo_dir" && gh pr checks "$branch" >/dev/null 2>&1); then
      log_error "$repo_name: PR #$number CI not green — stopping" "branch"; return 1
    fi
  fi

  local del_note=""
  local merge_args=(--"$strategy")
  if [[ "$delete_branch" == "true" ]]; then del_note=" (+delete-branch)"; merge_args+=(--delete-branch); fi

  if [[ "$dry_run" == "true" ]]; then
    if [[ -n "$ci_wait_timeout" ]]; then
      log_info "$repo_name: would wait for CI (timeout ${ci_wait_timeout}s) then merge PR #$number ($strategy)$del_note" "branch"
    else
      log_info "$repo_name: would merge PR #$number ($strategy)$del_note" "branch"
    fi
    return 0
  fi
  if (cd "$repo_dir" && gh pr merge "$branch" "${merge_args[@]}" >/dev/null 2>&1); then
    log_success "$repo_name: merged PR #$number ($strategy)$del_note" "branch"; return 0
  fi
  log_error "$repo_name: gh pr merge failed for PR #$number" "branch"; return 1
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors) — including the pre-existing `merge_repo` skip-path / delete_branch tests (the 4-arg call sites still work; `ci_wait_timeout` defaults to `""` = one-shot gate, unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): merge_repo --wait-ci gate via ci_wait_timeout param"
```

---

## Task 3: `merge_workspace` threads `ci_wait_timeout` (subset shifts to `${@:6}`)

**Files:**
- Modify: `lib/pr-ops.sh` (`merge_workspace` signature + the `merge_repo` call; update doc comment)
- Modify: `tests/test_pr_ops.sh` (update 3 Phase 9 subset calls with the `""` slot; append thread-through test)

- [ ] **Step 1: Update the 3 Phase 9 subset call sites first** — in `tests/test_pr_ops.sh`, the Phase 9 subset tests call `merge_workspace` with the subset as the 5th arg. With the new signature the 5th arg is `ci_wait_timeout`, so insert an empty `""` before the repo names. Make these three exact replacements:

`merge_workspace "$MS_DIR" merge true false a &>/dev/null`
→ `merge_workspace "$MS_DIR" merge true false "" a &>/dev/null`

`out=$(merge_workspace "$MS_DIR" merge true false a b 2>&1) || true`
→ `out=$(merge_workspace "$MS_DIR" merge true false "" a b 2>&1) || true`

`out=$(merge_workspace "$MH_DIR" merge true false a 2>&1) || true`
→ `out=$(merge_workspace "$MH_DIR" merge true false "" a 2>&1) || true`

(The non-subset calls `merge_workspace "$MW_DIR" merge true` and `merge_workspace "$DBW_DIR" merge true true` need NO change — they never reach the 5th positional, so `ci_wait_timeout` defaults to `""`.)

- [ ] **Step 2: Write the failing test** — append at the END of `tests/test_pr_ops.sh`, BEFORE the final summary/exit block:

```bash
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — current `merge_workspace` treats the 5th arg as the start of the subset (so `120` would be a repo name, not threaded as `ci_wait_timeout`), and `merge_repo`'s `$5` is empty → no `ci=120`.

- [ ] **Step 4: Write the implementation** — in `lib/pr-ops.sh`, change the `merge_workspace` signature lines (currently `local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}"` then `local subset=("${@:5}")`) to:

```bash
  local workspace="$1" strategy="${2:-merge}" dry_run="${3:-false}" delete_branch="${4:-false}" ci_wait_timeout="${5:-}"
  local subset=("${@:6}")
```

And change the `merge_repo` call line (currently `merge_repo "$workspace/$r" "$strategy" "$dry_run" "$delete_branch" || return 1`) to:

```bash
    merge_repo "$workspace/$r" "$strategy" "$dry_run" "$delete_branch" "$ci_wait_timeout" || return 1
```

Also update the `merge_workspace` doc comment (the block above the function) to add a line:

```bash
# A non-empty ci_wait_timeout (5th arg) is threaded to merge_repo to poll CI.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors) — including the updated Phase 9 subset tests and the pre-existing order / stop-on-first-failure / delete_branch-threading tests.

- [ ] **Step 6: Commit**

```bash
git add lib/pr-ops.sh tests/test_pr_ops.sh
git commit -m "feat(pr-ops): merge_workspace threads ci_wait_timeout (subset -> \${@:6})"
```

---

## Task 4: Wire `branch merge --wait-ci [--ci-timeout]` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` — the `merge)` sub-dispatch + usage line (`bin/mra.sh:105`)
- Modify: `tests/test_pr_ops.sh` (append dispatch integration tests)

- [ ] **Step 1: Write the failing tests** — append at the END of `tests/test_pr_ops.sh`, BEFORE the final summary/exit block:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_ops.sh`
Expected: FAIL — `--wait-ci`/`--ci-timeout` are unknown options today (`branch merge --ci-timeout 60` hits `-*) unknown option`), and usage has no `--wait-ci`.

- [ ] **Step 3: Replace the `merge)` sub-dispatch** in `bin/mra.sh` with:

```bash
        merge)
          local strategy="merge" dry_run=false delete_branch=false wait_ci=false ci_timeout="" repos=()
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --strategy) if [[ $# -lt 2 ]]; then log_error "--strategy requires merge|squash|rebase" "branch"; exit 1; fi; strategy="$2"; shift 2 ;;
              --dry-run) dry_run=true; shift ;;
              --delete-branch) delete_branch=true; shift ;;
              --wait-ci) wait_ci=true; shift ;;
              --ci-timeout) if [[ $# -lt 2 ]]; then log_error "--ci-timeout requires a positive integer (seconds)" "branch"; exit 1; fi; ci_timeout="$2"; shift 2 ;;
              -*) log_error "unknown option: $1" "branch"; exit 1 ;;
              *) repos+=("$1"); shift ;;
            esac
          done
          case "$strategy" in
            merge|squash|rebase) ;;
            *) log_error "branch merge: --strategy must be merge|squash|rebase" "branch"; exit 1 ;;
          esac
          # Validate CI flags post-parse (order-independent), before any side effect.
          if [[ -n "$ci_timeout" && "$wait_ci" != "true" ]]; then
            log_error "--ci-timeout requires --wait-ci" "branch"; exit 1
          fi
          if [[ -n "$ci_timeout" && ! "$ci_timeout" =~ ^[1-9][0-9]*$ ]]; then
            log_error "--ci-timeout must be a positive integer (seconds): '$ci_timeout'" "branch"; exit 1
          fi
          local ci_wait_timeout=""
          if [[ "$wait_ci" == "true" ]]; then ci_wait_timeout="${ci_timeout:-1800}"; fi
          local workspace; workspace=$(resolve_workspace)
          if [[ ${#repos[@]} -gt 0 ]]; then
            if ! validate_repo_subset "$workspace" "${repos[@]}"; then exit 1; fi
          fi
          if ! check_gh_auth; then
            log_error "branch merge requires gh authentication (run: gh auth login)" "branch"; exit 1
          fi
          merge_workspace "$workspace" "$strategy" "$dry_run" "$delete_branch" "$ci_wait_timeout" ${repos[@]+"${repos[@]}"}
          exit $?
          ;;
```

- [ ] **Step 4: Update the usage line** in `bin/mra.sh`. Find:

```
  branch merge [--strategy S] [--dry-run] [--delete-branch] [repos...]  Merge open PRs across repos (deps first; gated on mergeable+CI; repos... = subset)
```

Replace with:

```
  branch merge [--strategy S] [--dry-run] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [repos...]  Merge open PRs across repos (deps first; mergeable+CI gated; --wait-ci polls CI; repos... = subset)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_ops.sh`
Expected: PASS (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_pr_ops.sh
git commit -m "feat(branch): branch merge --wait-ci [--ci-timeout] dispatch + usage"
```

---

## Task 5: Full regression + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` (§18 status) + re-render `.html`

- [ ] **Step 1: Run the full suite**

Run: `bash test.sh`
Expected: `shell tests: 45 passed, 0 failed` (the new `tests/test_ci.sh` brings the count from 44 to 45) and `mcp-server : ok`. If anything fails, STOP and report BLOCKED with the output.

- [ ] **Step 2: Flip the §18 status note** in the spec. Find the `**Status:**` line directly under `## 18. Phase 10 …`:

```
**Status:** Approved (design) — 2026-06-05. Implementation scope for the next plan. One opt-in capability; first real use of `lib/ci.sh` at merge time.
```

Replace it with:

```
**Status:** Implemented — 2026-06-05. `branch merge --wait-ci [--ci-timeout <sec>]` polls CI via `wait_for_pr_checks` in `lib/ci.sh` (exit-code driven); `ci_wait_timeout` threaded through `merge_workspace`/`merge_repo`.
```

- [ ] **Step 3: Re-render the spec HTML**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md`
Expected: `✓ …-design.md -> …-design.html`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.html
git commit -m "docs(spec): mark Phase 10 (CI-polling auto-merge) implemented"
```

---

## Self-Review Notes

- **Spec coverage:** §18.1 surface → Task 4 (dispatch + usage). §18.2 poll behaviour (0/8/other, timeout, fail-fast, no-checks=stop) → Task 1 (`wait_for_pr_checks`) + Task 2 (gate mapping). §18.2 dry-run-no-poll → Task 2. §18.3 `wait_for_pr_checks` in ci.sh → Task 1; single `ci_wait_timeout` param + signatures → Tasks 2/3; dispatch threading → Task 4; Phase 9 `""` knock-on → Task 3 Step 1. §18.4 error handling (post-parse, before side effects) → Task 4. §18.5 tests 1–5 → Task 1; 6–8 → Task 2; 9 → Task 3; 10–13 → Task 4; regression → Task 5. §18.6 out-of-scope respected (no `branch pr` wait, no configurable interval, no retry, mergeable unchanged).
- **No placeholders:** every code step shows full function bodies / exact replacement text.
- **Type/name consistency:** `wait_for_pr_checks repo_dir branch timeout_sec [interval_sec]` and the `ci_wait_timeout` param name are used identically across Tasks 1–4. `merge_repo` 5th param and `merge_workspace` 5th param both named `ci_wait_timeout`; dispatch builds `ci_wait_timeout` from `wait_ci`/`ci_timeout`. Return-code contract (0/1/2) consistent between Task 1 definition and Task 2 mapping.
- **Subshell-counter pitfall:** Task 1 test uses a file-based counter (the `(cd … gh …)` subshell would lose a shell-var counter) — called out in the plan header and applied in the test.
