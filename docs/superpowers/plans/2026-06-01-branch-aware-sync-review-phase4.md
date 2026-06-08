# Branch-aware Sync & Review — Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra review <repo> --range <R>` and `--head <ref>`, and unify diff acquisition so single-pass, debate, and persona paths all use `lib/review-diff.sh` (retiring spec §8.1.5).

**Architecture:** Generalize `review-diff.sh` with an additive `range` mode (`git diff "$range_expr"`). Introduce a single `(mode, range_expr)` decision point in `review.sh` and thread it to all three review paths (incrementally, behavior-preserving at each step). Finally add the `--head`/`--range` flags with mutual-exclusion gates and `git rev-list` validation that fails loud on an invalid ref/range and exits 0 with "no changes" on a valid-but-empty range.

**Tech Stack:** Bash, git CLI, existing `lib/review*.sh`, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Modify `lib/review-diff.sh`** — add `range` mode (additive; `working`/`base` unchanged).
- **Modify `lib/review.sh`** — `(mode, range_expr)` decision point; thread to single-pass, debate, persona; `--head`/`--range` parsing + gates + validation.
- **Modify `lib/review-prompt.sh`** — `build_review_prompt` consumes `(mode, range_expr)`.
- **Modify `lib/review-debate.sh`** — `run_debate_review` consumes `(mode, range_expr)`.
- **Modify `bin/mra.sh`** — `review)` dispatch recognizes `--head`/`--range`; usage.
- **Create `tests/test_review_diff.sh`** — range-mode unit test.
- **Create `tests/test_review_flags.sh`** — flag gates + validation (subprocess).

Task order: T1 review-diff range mode (additive, green) → T2 single-pass on range_expr (behavior-preserving) → T3 debate+persona on range_expr (behavior-preserving; retires §8.1.5) → T4 `--head`/`--range` flags + gates + validation (the user-facing feature). Each task keeps the full suite green.

---

## Task 1: Add `range` mode to `lib/review-diff.sh`

**Files:**
- Modify: `lib/review-diff.sh`
- Test: `tests/test_review_diff.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_diff.sh`:

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
printf 'a\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -m c1 &>/dev/null
A=$(git -C "$R" rev-parse HEAD)
printf 'b\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -m c2 &>/dev/null
B=$(git -C "$R" rev-parse HEAD)

# range mode: A..B contains c2's change
out=$(review_diff_text "$R" range "$A..$B")
case "$out" in *'+b'*) : ;; *) echo "FAIL: range A..B should contain c2 change (+b): $out"; errors=$((errors+1)) ;; esac
files=$(review_diff_files "$R" range "$A..$B")
case "$files" in *f.txt*) : ;; *) echo "FAIL: range changed-files should list f.txt: $files"; errors=$((errors+1)) ;; esac

# range mode: empty range yields empty output (no error)
out=$(review_diff_text "$R" range "$B..$B")
if [[ -n "$out" ]]; then echo "FAIL: empty range should yield empty diff: $out"; errors=$((errors+1)); fi

# working mode unchanged (regression)
printf 'c\n' >> "$R/f.txt"
out=$(review_diff_text "$R" working "")
case "$out" in *'+c'*) : ;; *) echo "FAIL: working mode should capture unstaged change: $out"; errors=$((errors+1)) ;; esac

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review-diff range/working tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_diff.sh`
Expected: FAIL — `range` mode is not yet handled (current `review_diff_text` treats any non-`working` mode as `base`, running `git diff "$range_expr...HEAD"` which is wrong for an explicit `A..B`).

- [ ] **Step 3: Add the `range` mode**

Replace the body of `lib/review-diff.sh` with (adds `range`; keeps `working` and `base`):

```bash
#!/usr/bin/env bash
# Single source of truth for review diff acquisition.
# mode "working": working tree vs HEAD (staged + unstaged tracked changes; untracked excluded).
# mode "range"  : an explicit git range expression (e.g. "base...HEAD", "base...ref", "A..B").
# mode "base"   : legacy — "<resolved_base>...HEAD" (kept for direct callers/tests).

review_diff_text() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff HEAD 2>/dev/null || echo ""
  elif [[ "$mode" == "range" ]]; then
    git -C "$project_dir" diff "$arg" 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff "${arg}...HEAD" 2>/dev/null || \
    git -C "$project_dir" diff "${arg}" HEAD 2>/dev/null || echo ""
  fi
}

review_diff_files() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff --name-only HEAD 2>/dev/null || echo ""
  elif [[ "$mode" == "range" ]]; then
    git -C "$project_dir" diff --name-only "$arg" 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff --name-only "${arg}...HEAD" 2>/dev/null || \
    git -C "$project_dir" diff --name-only "${arg}" HEAD 2>/dev/null || echo ""
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_diff.sh`
Expected: PASS. Then `bash test.sh` — all green (existing `test_review_working.sh` base/working unit tests still pass since those modes are unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/review-diff.sh tests/test_review_diff.sh
git commit -m "feat(review): add range mode to review-diff (explicit git range)"
```

---

## Task 2: Single-pass review consumes `(mode, range_expr)`

Introduce the single `(mode, range_expr)` decision point in `review.sh` and route the strategy diff + single-pass prompt through `range` mode. Behavior-preserving: the default `range_expr` is `${resolved_base}...HEAD` (the current `base...HEAD`). `working` stays `mode=working`.

**Files:**
- Modify: `lib/review.sh`
- Modify: `lib/review-prompt.sh`
- Test: full suite (regression — base/working behavior unchanged)

- [ ] **Step 1: Replace the diff-mode block in `review.sh`**

In `lib/review.sh`, find the block (after the resolved_base block):

```bash
  # --- Resolve diff mode (working tree vs committed branch) ---
  local diff_mode="base"
  [[ "$working" == "true" ]] && diff_mode="working"

  # --- Auto-select strategy based on diff size ---
  local diff_for_strategy changed_files_for_strategy
  diff_for_strategy=$(review_diff_text "$project_dir" "$diff_mode" "$resolved_base")
  changed_files_for_strategy=$(review_diff_files "$project_dir" "$diff_mode" "$resolved_base")
```

Replace it with:

```bash
  # --- Resolve diff mode + range expression (single decision point) ---
  # Phase 4: default is the committed range base...HEAD; --working uses the working tree.
  # --range / --head (added in a later task) override range_expr.
  local mode="range" range_expr="${resolved_base}...HEAD"
  if [[ "$working" == "true" ]]; then mode="working"; range_expr=""; fi

  # --- Auto-select strategy based on diff size ---
  local diff_for_strategy changed_files_for_strategy
  diff_for_strategy=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  changed_files_for_strategy=$(review_diff_files "$project_dir" "$mode" "$range_expr")
```

- [ ] **Step 2: Update the single-pass `build_review_prompt` call in `review.sh`**

Find the single-pass call:

```bash
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$base_ref" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "$output_mode" "$diff_mode")
```

Replace its last line so it passes `"$mode" "$range_expr"` instead of `"$diff_mode"`:

```bash
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$base_ref" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "$output_mode" "$mode" "$range_expr")
```

- [ ] **Step 3: Update `build_review_prompt` in `review-prompt.sh`**

In `lib/review-prompt.sh`, change the `diff_mode` param (currently `local diff_mode="${11:-base}"`) to a `mode`+`range_expr` pair, and replace the base-resolution + diff block. Specifically:

Replace:
```bash
  local diff_mode="${11:-base}"
```
with:
```bash
  local mode="${11:-range}"
  local range_expr="${12:-}"
```

Then replace the base-resolution + diff block:
```bash
  # --- Resolve base ref (try local, then origin/) ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  # --- Get diff ---
  local diff
  diff=$(review_diff_text "$project_dir" "$diff_mode" "$resolved_base")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$diff_mode" "$resolved_base")
```
with (the base ref is already resolved by `review.sh` and baked into `range_expr`, so no re-resolution here):
```bash
  # --- Get diff (mode/range_expr resolved by review.sh) ---
  local diff
  diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")
```

(If `$base_ref` is referenced elsewhere in the prompt text below this block, leave those references — only the diff acquisition changes.)

- [ ] **Step 4: Run the full suite (regression)**

Run: `bash test.sh`
Expected: all green. Default review now uses `range` mode with `range_expr=${resolved_base}...HEAD` — equivalent to the previous `base` behavior (single `git diff base...HEAD`; the rarely-hit two-step fallback is dropped, consistent with prior phases). `--working` unchanged. `test_review_working.sh` / `test_review_personas.sh` / `test_review_safety.sh` stay green.

- [ ] **Step 5: Smoke test default + working review reach the right diff path**

Run:

```bash
WS=$(mktemp -d); mkdir -p "$WS/.collab"; echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main repo &>/dev/null
git -C "$WS/repo" config user.email t@t.t; git -C "$WS/repo" config user.name t
echo a > "$WS/repo/f.txt"; git -C "$WS/repo" add f.txt; git -C "$WS/repo" commit -m init &>/dev/null
MRA_WORKSPACE="$WS" bash bin/mra.sh review repo --working; echo "working exit=$?"
rm -rf "$WS"
```

Expected: `no uncommitted changes to review` + `working exit=0` (working mode still early-returns on a clean tree).

- [ ] **Step 6: Commit**

```bash
git add lib/review.sh lib/review-prompt.sh
git commit -m "refactor(review): single-pass consumes (mode, range_expr) via review-diff"
```

---

## Task 3: Debate + persona consume `(mode, range_expr)` (retires §8.1.5)

Migrate the debate path (`run_debate_review`) and the persona block to `review_diff_text(project_dir, mode, range_expr)`, eliminating their inline `git diff base...HEAD`. Behavior-preserving by default. After this task all four diff sites use `review-diff.sh`.

**Files:**
- Modify: `lib/review-debate.sh`
- Modify: `lib/review.sh`
- Test: full suite (regression)

- [ ] **Step 1: `run_debate_review` accepts `(mode, range_expr)`**

In `lib/review-debate.sh`, add two trailing params after `pkb_context` (currently `${13}`):

```bash
  local pkb_context="${13:-}"
  local mode="${14:-range}"
  local range_expr="${15:-}"
```

Then replace the base-resolution + inline diff block:
```bash
  # --- Resolve base ref ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

  local diff
  diff=$(git -C "$project_dir" diff "${resolved_base}...HEAD" 2>/dev/null || \
         git -C "$project_dir" diff "${resolved_base}" HEAD 2>/dev/null || \
         echo "(diff unavailable)")

  local changed_files
  changed_files=$(git -C "$project_dir" diff --name-only "${resolved_base}...HEAD" 2>/dev/null || \
                  git -C "$project_dir" diff --name-only "${resolved_base}" HEAD 2>/dev/null || \
                  echo "")
```
with:
```bash
  # --- Get diff (mode/range_expr resolved by review.sh) ---
  local diff
  diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
  [[ -z "$diff" ]] && diff="(diff unavailable)"
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")
```

(Leave the `base_ref` param 4 in place — it may still be referenced in the debate prompt text. `review-debate.sh` can call `review_diff_text` because `bin/mra.sh` sources `lib/review-diff.sh` before `lib/review-debate.sh`; the existing `test_review_personas.sh`/`test_review_safety.sh` don't exercise the diff, so no test sourcing change is needed.)

- [ ] **Step 2: Pass `(mode, range_expr)` from review.sh's debate call**

In `lib/review.sh`, find the `run_debate_review` call and append `"$mode" "$range_expr"` as the last two args:

```bash
    review_json=$(run_debate_review \
      "$project" "$project_dir" "$graph_file" "$base_ref" \
      "$project_type" "$consumers" "$deps" "$has_api_change" \
      "$output_language" "$model" "$claude_add_dirs_str" "$claude_focused_dirs_str" \
      "$pkb_context" "$mode" "$range_expr")
```

- [ ] **Step 3: Migrate the persona block in review.sh to `review_diff_text`**

In `lib/review.sh`, replace the persona block's base-resolution + inline diff:
```bash
    # Resolve base + diff (same as debate path does internally)
    local resolved_base_p="$base_ref"
    if [[ -d "$project_dir/.git" ]]; then
      if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
        if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
          resolved_base_p="origin/$base_ref"
        fi
      fi
    fi
    local persona_diff persona_changed
    persona_diff=$(git -C "$project_dir" diff "${resolved_base_p}...HEAD" 2>/dev/null || \
                   git -C "$project_dir" diff "${resolved_base_p}" HEAD 2>/dev/null || \
                   echo "(diff unavailable)")
    persona_changed=$(git -C "$project_dir" diff --name-only "${resolved_base_p}...HEAD" 2>/dev/null || \
                      git -C "$project_dir" diff --name-only "${resolved_base_p}" HEAD 2>/dev/null || \
                      echo "")
```
with:
```bash
    # diff via review-diff.sh (mode/range_expr resolved above)
    local persona_diff persona_changed
    persona_diff=$(review_diff_text "$project_dir" "$mode" "$range_expr")
    [[ -z "$persona_diff" ]] && persona_diff="(diff unavailable)"
    persona_changed=$(review_diff_files "$project_dir" "$mode" "$range_expr")
```

- [ ] **Step 4: Run the full suite (regression)**

Run: `bash test.sh`
Expected: all green. Debate and persona now use `review-diff.sh` with the same default `range_expr=${resolved_base}...HEAD`. `test_review_personas.sh` / `test_review_safety.sh` unchanged.

- [ ] **Step 5: Confirm no remaining inline diff sites + no other callers broke**

Run: `grep -rn 'diff "\${resolved_base' lib/ || echo "no inline base diffs remain"`
Expected: `no inline base diffs remain` (all four sites now route through `review-diff.sh`).
Run: `grep -rn 'run_debate_review\|build_review_prompt' lib/ bin/ | grep -v 'review-debate.sh:\|review-prompt.sh:'`
Expected: only the call sites in `lib/review.sh` (confirms signatures changed safely).

- [ ] **Step 6: Commit**

```bash
git add lib/review-debate.sh lib/review.sh
git commit -m "refactor(review): debate + persona consume (mode, range_expr); retire §8.1.5 inline diffs"
```

---

## Task 4: `--head` / `--range` flags + gates + validation

**Files:**
- Modify: `lib/review.sh`
- Modify: `bin/mra.sh`
- Test: `tests/test_review_flags.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_flags.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"
git -C "$WS" init -b main repo &>/dev/null
git -C "$WS/repo" config user.email t@t.t; git -C "$WS/repo" config user.name t
git -C "$WS/repo" commit --allow-empty -m c1 &>/dev/null

# capture exit + output without aborting under set -e
run() { if out=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" review repo "$@" 2>&1); then rc=0; else rc=$?; fi; }

# mutual exclusion -> non-zero
run --range c1..HEAD --head HEAD
if [[ $rc -eq 0 ]]; then echo "FAIL: --range + --head should be rejected"; errors=$((errors+1)); fi
case "$out" in *"mutually exclusive"*) : ;; *) echo "FAIL: expected 'mutually exclusive': $out"; errors=$((errors+1)) ;; esac

run --range HEAD~0..HEAD --pr 1
if [[ $rc -eq 0 ]]; then echo "FAIL: --range + --pr should be rejected"; errors=$((errors+1)); fi

run --head HEAD --working
if [[ $rc -eq 0 ]]; then echo "FAIL: --head + --working should be rejected"; errors=$((errors+1)); fi

# invalid range -> non-zero + 'invalid'
run --range maim..HEAD
if [[ $rc -eq 0 ]]; then echo "FAIL: invalid range should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *invalid*) : ;; *) echo "FAIL: expected 'invalid' message: $out"; errors=$((errors+1)) ;; esac

# valid but empty range -> exit 0 + 'no changes'
run --range HEAD..HEAD
if [[ $rc -ne 0 ]]; then echo "FAIL: empty range should exit 0, got rc=$rc: $out"; errors=$((errors+1)); fi
case "$out" in *"no changes"*) : ;; *) echo "FAIL: expected 'no changes': $out"; errors=$((errors+1)) ;; esac

rm -rf "$WS"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review flag gates + range validation passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_flags.sh`
Expected: FAIL — `--range`/`--head` are currently unknown options (or mis-parsed), and there is no validation.

- [ ] **Step 3: Parse `--range`/`--head` in `review.sh`**

In `lib/review.sh`, add `range_arg=""` and `head_arg=""` to the `review_project` locals line:

```bash
  local project="" pr_number="" base_ref="" model="sonnet" debate=true force_strategy="" working=false range_arg="" head_arg=""
```

In the option `while` loop, add two cases before the `-*)` catch-all:

```bash
      --range)
        if [[ $# -lt 2 ]]; then log_error "--range requires a range (e.g. A..B)" "review"; return 1; fi
        range_arg="$2"; shift 2 ;;
      --head)
        if [[ $# -lt 2 ]]; then log_error "--head requires a ref" "review"; return 1; fi
        head_arg="$2"; shift 2 ;;
```

- [ ] **Step 4: Add mutual-exclusion gates**

In `lib/review.sh`, after the existing `if [[ "$working" == "true" ]]; then ... fi` guard block (the one rejecting `--working + --personas`/`--strategy debate`), add:

```bash
  if [[ -n "$range_arg" && -n "$head_arg" ]]; then
    log_error "review: --range and --head are mutually exclusive" "review"; return 1
  fi
  if [[ ( -n "$range_arg" || -n "$head_arg" ) && -n "$pr_number" ]]; then
    log_error "review: --range/--head cannot be combined with --pr" "review"; return 1
  fi
  if [[ ( -n "$range_arg" || -n "$head_arg" ) && "$working" == "true" ]]; then
    log_error "review: --range/--head cannot be combined with --working" "review"; return 1
  fi
```

- [ ] **Step 5: Extend the mode/range_expr decision + add validation**

In `lib/review.sh`, replace the Task-2 block:

```bash
  # --- Resolve diff mode + range expression (single decision point) ---
  # Phase 4: default is the committed range base...HEAD; --working uses the working tree.
  # --range / --head (added in a later task) override range_expr.
  local mode="range" range_expr="${resolved_base}...HEAD"
  if [[ "$working" == "true" ]]; then mode="working"; range_expr=""; fi
```

with:

```bash
  # --- Resolve diff mode + range expression (single decision point) ---
  local mode="range" range_expr="${resolved_base}...HEAD" explicit_range=false
  if [[ "$working" == "true" ]]; then
    mode="working"; range_expr=""
  elif [[ -n "$range_arg" ]]; then
    mode="range"; range_expr="$range_arg"; explicit_range=true
  elif [[ -n "$head_arg" ]]; then
    mode="range"; range_expr="${resolved_base}...${head_arg}"; explicit_range=true
  fi
  # An explicit --range/--head must resolve; a typo fails loud (never a silent empty review).
  if [[ "$explicit_range" == "true" ]]; then
    if ! git -C "$project_dir" rev-list "$range_expr" -- >/dev/null 2>&1; then
      log_error "review: invalid range/ref '$range_expr'" "review"; return 1
    fi
  fi
```

Then find the existing working empty-diff early-return:

```bash
  if [[ "$working" == "true" && "$changed_count" -eq 0 ]]; then
    log_info "no uncommitted changes to review" "review"
    return 0
  fi
```

and add, immediately after it, the explicit-range empty early-return:

```bash
  if [[ "$explicit_range" == "true" && "$changed_count" -eq 0 ]]; then
    log_info "review: no changes in '$range_expr' — nothing to review" "review"
    return 0
  fi
```

- [ ] **Step 6: Recognize `--range`/`--head` in the `bin/mra.sh` review dispatch**

In `bin/mra.sh`'s `review)` case, the `has_project` detection loop marks value-taking flags so their values aren't mistaken for the project. Find:

```bash
          --pr|--base|--model|--strategy) skip_next=true ;;
```

and change it to:

```bash
          --pr|--base|--model|--strategy|--range|--head) skip_next=true ;;
```

(The outer collection loop already forwards unknown flags to `review_args`, so `review_project` receives `--range`/`--head`.)

- [ ] **Step 7: Update usage text**

In the usage heredoc, change the `review` line to document the new flags:

```
  review <project> [--pr N] [--working] [--range A..B] [--head <ref>] [--no-debate]  Code review
```

- [ ] **Step 8: Run the tests**

Run: `bash tests/test_review_flags.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 9: Commit**

```bash
git add lib/review.sh bin/mra.sh tests/test_review_flags.sh
git commit -m "feat(review): --range/--head with mutual-exclusion gates and rev-list validation"
```

---

## Done — Phase 4 complete

After Task 4, `mra review <repo> --range A..B` and `--head <ref>` work across light/standard/debate/persona (all four paths consume `(mode, range_expr)` via `review-diff.sh`, retiring §8.1.5). An invalid range/ref fails loud (exit 1); a valid-but-empty range exits 0 with "no changes"; `--range`/`--head` are mutually exclusive with each other and with `--pr`/`--working`. Default `base...HEAD` review is byte-for-byte unchanged. Deferred to Phase 5 (spec §12.8): §8.1.1–§8.1.4, `is_api_change` range/working-awareness, §11.6.
