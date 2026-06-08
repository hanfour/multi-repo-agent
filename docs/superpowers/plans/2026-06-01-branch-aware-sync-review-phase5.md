# Branch-aware Sync & Review — Phase 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five review-subsystem correctness fixes: mode-aware `is_api_change`, a `--working + --pr` guard, a mode-aware prompt preamble, eval PKB via `review_diff_files`, and removal of the legacy `base` diff mode.

**Architecture:** Thread the existing `(mode, range_expr)` pair into `is_api_change` (reordering `review.sh` so it is computed first). Add one mutual-exclusion gate. Make the review prompt opener mode-aware. Route eval's PKB diff through `review-diff.sh`. Drop the now-unused `base` mode. No new commands; default review behavior is unchanged.

**Tech Stack:** Bash, git CLI, existing `lib/review*.sh`/`lib/change-detector.sh`/`lib/eval.sh`, plain-bash tests under `tests/` auto-discovered by `test.sh`.

---

## File Structure

- **Modify `lib/change-detector.sh`** — `is_api_change` gains optional `(mode, range_expr)`; uses `review_diff_files`/`git diff <rev>`.
- **Modify `lib/review.sh`** — reorder so `(mode, range_expr)` is computed before `is_api_change`; pass it in; add `--working + --pr` gate.
- **Modify `lib/review-prompt.sh`** — mode-aware preamble.
- **Modify `lib/eval.sh`** — PKB `changed_files` via `review_diff_files`.
- **Modify `lib/review-diff.sh`** — drop `base` mode (working | range only).
- **Create `tests/test_change_detector.sh`**; extend `tests/test_review_flags.sh`, `tests/test_review_working.sh`.

Task order: T1 is_api_change mode-aware (the meaty reorder) → T2 `--working + --pr` gate → T3 preamble → T4 eval PKB → T5 remove base mode. Each keeps the suite green.

---

## Task 1: `is_api_change` mode-aware + `review.sh` reorder

**Files:**
- Modify: `lib/change-detector.sh`
- Modify: `lib/review.sh`
- Test: `tests/test_change_detector.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test_change_detector.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"            # get_default_branch
source "$SCRIPT_DIR/lib/review-diff.sh"     # review_diff_files
source "$SCRIPT_DIR/lib/change-detector.sh"

errors=0
T=$(mktemp -d)
git -C "$T" init -b main repo &>/dev/null
R="$T/repo"
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
mkdir -p "$R/config" "$R/app/models"
echo "x" > "$R/app/models/u.rb"; git -C "$R" add .; git -C "$R" commit -m base &>/dev/null
A=$(git -C "$R" rev-parse HEAD)
# work on a feature branch so the default branch (main) stays at A — mirrors real review usage
git -C "$R" checkout -b feat &>/dev/null
# B: an API-surface change (routes.rb) + a non-API change
printf 'Rails.routes\n' > "$R/config/routes.rb"
echo "y" >> "$R/app/models/u.rb"
git -C "$R" add .; git -C "$R" commit -m feat &>/dev/null
B=$(git -C "$R" rev-parse HEAD)
# C: a non-API-only change
echo "z" >> "$R/app/models/u.rb"; git -C "$R" add .; git -C "$R" commit -m chore &>/dev/null

# range A..B contains routes.rb -> high
res=$(is_api_change "$R" rails-api range "$A..$B")
case "$res" in high*) : ;; *) echo "FAIL: A..B (routes.rb) should be high, got: $res"; errors=$((errors+1)) ;; esac

# range B..HEAD is models-only -> low
res=$(is_api_change "$R" rails-api range "$B..$(git -C "$R" rev-parse HEAD)")
case "$res" in low|none) : ;; *) echo "FAIL: B..HEAD (models only) should be low/none, got: $res"; errors=$((errors+1)) ;; esac

# empty range -> none
res=$(is_api_change "$R" rails-api range "$B..$B")
case "$res" in none) : ;; *) echo "FAIL: empty range should be none, got: $res"; errors=$((errors+1)) ;; esac

# backward-compat: 2-arg call falls back to default_branch...HEAD (HEAD is C; main is A => routes.rb in range) -> high
res=$(is_api_change "$R" rails-api)
case "$res" in high*) : ;; *) echo "FAIL: 2-arg back-compat should see routes.rb (high), got: $res"; errors=$((errors+1)) ;; esac

rm -rf "$T"
if [[ $errors -eq 0 ]]; then
  echo "PASS: is_api_change mode-aware tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_change_detector.sh`
Expected: FAIL — `is_api_change` ignores params 3/4 and always diffs `default_branch...HEAD`, so the `B..B` (empty) and `B..C` (models-only) range cases return the wrong verdict.

- [ ] **Step 3: Rewrite `is_api_change` in `lib/change-detector.sh`**

Replace the whole `is_api_change()` function with:

```bash
is_api_change() {
  local project_dir="$1"
  local project_type="$2"
  local mode="${3:-range}"
  local range_expr="${4:-}"

  local default_branch
  default_branch=$(get_default_branch "$project_dir" 2>/dev/null || echo "main")
  # Back-compat: no explicit range in range mode → default to "<default_branch>...HEAD".
  if [[ "$mode" != "working" && -z "$range_expr" ]]; then
    range_expr="${default_branch}...HEAD"
  fi
  # Revision arg for content (pathspec) diffs: HEAD for working, else the range expression.
  local diff_rev="$range_expr"
  [[ "$mode" == "working" ]] && diff_rev="HEAD"

  # Get list of changed files (mode-aware, via the single diff source of truth)
  local changed_files
  changed_files=$(review_diff_files "$project_dir" "$mode" "$range_expr")

  if [[ -z "$changed_files" ]]; then
    echo "none"
    return 0
  fi

  local high_confidence=false
  local reasons=()

  case "$project_type" in
    rails-api)
      if echo "$changed_files" | grep -q "^config/routes.rb$"; then
        high_confidence=true; reasons+=("routes.rb changed")
      fi
      if echo "$changed_files" | grep -qE "^app/controllers/" | grep -v "concerns/"; then
        local ctrl_diff
        ctrl_diff=$(git -C "$project_dir" diff "$diff_rev" -- "app/controllers/" 2>/dev/null)
        if echo "$ctrl_diff" | grep -qE "^\+.*def (index|show|create|update|destroy|search)"; then
          high_confidence=true; reasons+=("controller public method changed")
        elif echo "$ctrl_diff" | grep -qE "^\+.*(get|post|put|patch|delete) "; then
          high_confidence=true; reasons+=("route definition in controller")
        fi
      fi
      if echo "$changed_files" | grep -qE "^app/serializers/"; then
        high_confidence=true; reasons+=("serializer changed")
      fi
      if echo "$changed_files" | grep -q "^db/schema.rb$"; then
        local schema_diff
        schema_diff=$(git -C "$project_dir" diff "$diff_rev" -- "db/schema.rb" 2>/dev/null)
        if echo "$schema_diff" | grep -qE "^\+.*t\.(string|integer|text|boolean|datetime|decimal|float|json|jsonb|references)"; then
          high_confidence=true; reasons+=("schema column added/changed")
        fi
      fi
      ;;

    node-backend|node-frontend|nextjs)
      if echo "$changed_files" | grep -qE "^src/routes/"; then
        high_confidence=true; reasons+=("route files changed")
      fi
      if echo "$changed_files" | grep -q "openapi.yaml\|openapi.json"; then
        high_confidence=true; reasons+=("OpenAPI spec changed")
      fi
      if echo "$changed_files" | grep -qE "^src/(types|interfaces)/"; then
        high_confidence=true; reasons+=("type/interface definitions changed")
      fi
      if echo "$changed_files" | grep -qE "^src/validation/"; then
        high_confidence=true; reasons+=("validation rules changed")
      fi
      ;;
  esac

  # Common triggers (any project type)
  if echo "$changed_files" | grep -q "^\.env\.example$\|^env\.example$"; then
    local env_diff
    env_diff=$(git -C "$project_dir" diff "$diff_rev" -- ".env.example" "env.example" 2>/dev/null)
    if echo "$env_diff" | grep -qE "^\+.*(KEY|TOKEN|SECRET|HEADER|AUTH)"; then
      high_confidence=true; reasons+=("new required env var (auth/key)")
    fi
  fi
  if echo "$changed_files" | grep -qE "docker-compose.*\.(yml|yaml)$"; then
    high_confidence=true; reasons+=("docker-compose changed")
  fi

  if [[ "$high_confidence" == "true" ]]; then
    echo "high|${reasons[*]}"
  else
    echo "low"
  fi
}
```

(Only the changed-file source and the 3 content-diff `git diff` revisions changed — from `"$default_branch"...HEAD` to `review_diff_files`/`"$diff_rev"`. All the `grep` trigger logic is byte-identical to before.)

- [ ] **Step 4: Reorder `review.sh` so `(mode, range_expr)` is computed before `is_api_change`, and pass it in**

In `lib/review.sh`, replace the contiguous region that currently begins at `  # --- Detect API change ---` and ends at the close of the explicit-range validation `fi` (the block ending `  fi` right after the `rev-list` check). The CURRENT text is:

```bash
  # --- Detect API change ---
  local has_api_change="false"
  if [[ -d "$project_dir/.git" ]]; then
    local change_result
    change_result=$(is_api_change "$project_dir" "$project_type" 2>/dev/null || echo "low")
    [[ "${change_result%%|*}" == "high" ]] && has_api_change="true"
  fi

  # --- Output language ---
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""

  # --- Determine output mode ---
  local output_mode="terminal"
  [[ -n "$pr_number" ]] && output_mode="inline"

  # --- Resolve base ref for git operations ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

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

Replace that ENTIRE region with (resolved_base + mode/range_expr/validation moved up; Detect API change now passes `"$mode" "$range_expr"`; output language/mode kept after):

```bash
  # --- Resolve base ref for git operations ---
  local resolved_base="$base_ref"
  if [[ -d "$project_dir/.git" ]]; then
    if ! git -C "$project_dir" rev-parse --verify "$base_ref" &>/dev/null; then
      if git -C "$project_dir" rev-parse --verify "origin/$base_ref" &>/dev/null; then
        resolved_base="origin/$base_ref"
      fi
    fi
  fi

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

  # --- Detect API change (mode-aware) ---
  local has_api_change="false"
  if [[ -d "$project_dir/.git" ]]; then
    local change_result
    change_result=$(is_api_change "$project_dir" "$project_type" "$mode" "$range_expr" 2>/dev/null || echo "low")
    [[ "${change_result%%|*}" == "high" ]] && has_api_change="true"
  fi

  # --- Output language ---
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""

  # --- Determine output mode ---
  local output_mode="terminal"
  [[ -n "$pr_number" ]] && output_mode="inline"
```

(The `--- Auto-select strategy ---` block that follows is unchanged and still references `$mode`/`$range_expr`, which are now in scope above it.)

- [ ] **Step 5: Run tests**

Run: `bash tests/test_change_detector.sh` — Expected: PASS.
Run: `bash test.sh` — Expected: all green (default review's `is_api_change` now passes `mode=range`, `range_expr=${resolved_base}...HEAD`; for the default base this matches the old `default_branch...HEAD` heuristic closely enough — the suite confirms no regression).

- [ ] **Step 6: Commit**

```bash
git add lib/change-detector.sh lib/review.sh tests/test_change_detector.sh
git commit -m "fix(review): is_api_change is mode/range-aware (consumer context matches reviewed diff)"
```

---

## Task 2: `--working + --pr` guard

**Files:**
- Modify: `lib/review.sh`
- Test: `tests/test_review_flags.sh` (extend)

- [ ] **Step 1: Write the failing test**

In `tests/test_review_flags.sh`, add immediately before the final `if [[ $errors -eq 0 ]]` block:

```bash
# --working + --pr is incoherent (working-tree changes have no PR line mapping)
run --working --pr 1
if [[ $rc -eq 0 ]]; then echo "FAIL: --working + --pr should be rejected"; errors=$((errors+1)); fi
case "$out" in *working*) : ;; *) echo "FAIL: expected message mentioning --working: $out"; errors=$((errors+1)) ;; esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_flags.sh`
Expected: FAIL — `--working --pr` is currently allowed (no guard).

- [ ] **Step 3: Add the guard**

In `lib/review.sh`, inside the existing `if [[ "$working" == "true" ]]; then ... fi` guard block (which already rejects `--working + --personas` and `--working + --strategy debate`), add one more check before `debate=false`:

```bash
    if [[ -n "$pr_number" ]]; then
      log_error "review: --working cannot be combined with --pr (working-tree changes have no PR line mapping)" "review"
      return 1
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_flags.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/review.sh tests/test_review_flags.sh
git commit -m "fix(review): reject --working + --pr (incoherent combination)"
```

---

## Task 3: Mode-aware prompt preamble

**Files:**
- Modify: `lib/review-prompt.sh`
- Test: `tests/test_review_working.sh` (extend)

- [ ] **Step 1: Write the failing test**

In `tests/test_review_working.sh`, add before the final `if [[ $errors -eq 0 ]]` block (the test already sources what it needs; if not, ensure it sources `lib/colors.sh`, `lib/review-diff.sh`, `lib/review-prompt.sh`):

```bash
# --- mode-aware prompt preamble ---
PRE_DIR=$(mktemp -d); git -C "$PRE_DIR" init -b main repo &>/dev/null
PR="$PRE_DIR/repo"
git -C "$PR" config user.email t@t.t; git -C "$PR" config user.name t
echo a > "$PR/f.txt"; git -C "$PR" add f.txt; git -C "$PR" commit -m c1 &>/dev/null
echo b >> "$PR/f.txt"

# working mode: preamble mentions working tree, not "pull request"
p=$(build_review_prompt repo "$PR" "" main unknown "" "" false "" terminal working "")
case "$p" in *"uncommitted working-tree"*) : ;; *) echo "FAIL: working preamble should mention working tree"; errors=$((errors+1)) ;; esac
case "$p" in *"pull request"*) echo "FAIL: working preamble should NOT say 'pull request'"; errors=$((errors+1)) ;; *) : ;; esac

# default (base...HEAD) keeps 'pull request'
p=$(build_review_prompt repo "$PR" "" main unknown "" "" false "" terminal range "main...HEAD")
case "$p" in *"pull request"*) : ;; *) echo "FAIL: default preamble should say 'pull request'"; errors=$((errors+1)) ;; esac
rm -rf "$PRE_DIR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_working.sh`
Expected: FAIL — the preamble is always "You are reviewing a pull request …" regardless of mode.

- [ ] **Step 3: Make the preamble mode-aware**

In `lib/review-prompt.sh`, just before the `# --- Assemble prompt ---` `cat <<PROMPT` heredoc, add a `review_subject` computation:

```bash
  # Mode-aware opening line
  local review_subject="a pull request"
  if [[ "$mode" == "working" ]]; then
    review_subject="the uncommitted working-tree changes"
  elif [[ "$mode" == "range" && -n "$range_expr" && "$range_expr" != *"...HEAD" ]]; then
    review_subject="the changes in '${range_expr}'"
  fi
```

Then change the heredoc's first line from:
```
You are reviewing a pull request for the project "${project}" (type: ${project_type}).
```
to:
```
You are reviewing ${review_subject} for the project "${project}" (type: ${project_type}).
```

(The `*"...HEAD"` guard keeps the default `base...HEAD` and `--head` (`base...ref`) cases on the "pull request" wording; only an explicit non-`...HEAD` `--range` like `A..B` gets the range wording. `--working` gets the working wording.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_working.sh`
Expected: PASS. Then `bash test.sh` — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/review-prompt.sh tests/test_review_working.sh
git commit -m "fix(review): mode-aware prompt preamble (working/range vs pull request)"
```

---

## Task 4: eval PKB changed-files via `review_diff_files`

**Files:**
- Modify: `lib/eval.sh`
- Test: `bash test.sh` (regression) + grep verification

- [ ] **Step 1: Make the change**

In `lib/eval.sh`, find (around line 218):

```bash
    changed_files=$(git -C "$project_dir" diff --name-only "${resolved_base}...HEAD" 2>/dev/null || echo "")
```

Replace with:

```bash
    changed_files=$(review_diff_files "$project_dir" range "${resolved_base}...HEAD")
```

- [ ] **Step 2: Verify the rewiring + syntax**

Run: `bash -n lib/eval.sh` — Expected: no output (syntax OK).
Run: `grep -n 'diff --name-only' lib/eval.sh || echo "no raw name-only diffs remain in eval.sh"` — Expected: `no raw name-only diffs remain in eval.sh`.

- [ ] **Step 3: Functional check (review_diff_files range produces the same file list)**

Run:
```bash
cd /Users/hanfourhuang/multi-repo-agent
source lib/review-diff.sh
T=$(mktemp -d); git -C "$T" init -b main r &>/dev/null
git -C "$T/r" config user.email t@t.t; git -C "$T/r" config user.name t
echo a > "$T/r/f.txt"; git -C "$T/r" add f.txt; git -C "$T/r" commit -m c1 &>/dev/null
echo b >> "$T/r/f.txt"; git -C "$T/r" add f.txt; git -C "$T/r" commit -m c2 &>/dev/null
out=$(review_diff_files "$T/r" range "HEAD~1...HEAD")
case "$out" in *f.txt*) echo "OK: range name-only lists f.txt" ;; *) echo "BAD: $out" ;; esac
rm -rf "$T"
```
Expected: `OK: range name-only lists f.txt`.

- [ ] **Step 4: Run the full suite**

Run: `bash test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/eval.sh
git commit -m "fix(eval): PKB changed-files via review_diff_files (single diff source)"
```

---

## Task 5: Remove legacy `base` mode from `review-diff.sh`

After Phase 4 + Task 1/4, no caller uses `base` mode (all use `working` or `range`). Collapse the `base` else-branch into the `range` else-branch (anything not `working` is treated as a raw range expression). No test changes: `tests/test_review_working.sh` and `tests/test_review_diff.sh` only exercise `working`/`range`.

**Files:**
- Modify: `lib/review-diff.sh`
- Test: `bash test.sh` (regression)

- [ ] **Step 1: Confirm no production caller uses `base` mode**

Run: `grep -rn 'review_diff_text\|review_diff_files' lib/ | grep -iE '"base"| base ' || echo "no base-mode callers"`
Expected: `no base-mode callers`.

- [ ] **Step 2: Simplify `review-diff.sh`**

Replace the body of `lib/review-diff.sh` with (working | range only; the `else` is now the range branch):

```bash
#!/usr/bin/env bash
# Single source of truth for review diff acquisition.
# mode "working": working tree vs HEAD (staged + unstaged tracked changes; untracked excluded).
# mode "range"  : an explicit git range expression (e.g. "base...HEAD", "base...ref", "A..B").
#                 Any mode other than "working" is treated as a range expression.

review_diff_text() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff "$arg" 2>/dev/null || echo ""
  fi
}

review_diff_files() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff --name-only HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff --name-only "$arg" 2>/dev/null || echo ""
  fi
}
```

- [ ] **Step 3: Run the suite**

Run: `bash tests/test_review_diff.sh` — Expected: PASS (range + working).
Run: `bash test.sh` — Expected: all green (`test_review_working.sh`, `test_change_detector.sh`, `test_review_personas.sh`, `test_review_safety.sh`, `test_review_flags.sh` all green).

- [ ] **Step 4: Commit**

```bash
git add lib/review-diff.sh
git commit -m "refactor(review): drop unused legacy base mode (working | range only)"
```

---

## Done — Phase 5 complete

After Task 5: `is_api_change` matches the actual reviewed diff under `--range`/`--head`/`--working`; `--working + --pr` is rejected; the review prompt preamble reflects the mode; eval's PKB diff routes through `review-diff.sh`; and the dead `base` mode is gone. Default review behavior is unchanged. Deferred to Phase 6 (spec §13.5): §8.1.4 (`branch_format_row` dead `action` lookup), §11.6.1 (13 test files lacking `set -euo pipefail`), §11.6.2, auto-merge.
