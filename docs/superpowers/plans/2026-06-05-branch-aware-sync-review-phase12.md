# sync --json (Phase 12) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra sync --json` for the default / `--safe` / `--push` modes — a per-repo `{repo, action, ok}` JSON array.

**Architecture:** A shared per-repo result model: a new pure `sync_result_json` (jq object, sibling of `branch_state_json`) and a `_sync_record` sink that appends `repo<TAB>action<TAB>ok` to the file named by `SYNC_RESULT_FILE` only when that env var is set (text mode = unset = no-op, unchanged). Each per-repo worker (`sync_repo`, `safe_sync_repo`, `push_repo`) calls `_sync_record` at each outcome alongside its existing `log_*`. The `sync` dispatch's `--json` mode sets up `SYNC_RESULT_FILE`, runs the chosen workspace fn with stdout→stderr (human logs to stderr), then emits the JSON array from the records.

**Tech Stack:** Bash (`lib/sync.sh` + `bin/mra.sh` dispatch), `jq`, `git`, custom PASS/FAIL test harness (`tests/test_sync.sh`, `tests/test_sync_flags.sh`).

**Spec:** `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` §20.

---

## File Structure

- **`lib/sync.sh`** (modify) — add pure `sync_result_json repo action ok` + `_sync_record repo action ok` sink; instrument the three workers `sync_repo` / `safe_sync_repo` / `push_repo` (add `_sync_record` at each outcome; human `log_*` preserved). Workspace drivers (`safe_sync_workspace`/`push_workspace`) unchanged.
- **`lib/repos.sh`** — unchanged (`sync_from_repos_json` records via `sync_repo` at the worker layer).
- **`bin/mra.sh`** (modify) — `sync` dispatch gains `--json` (reject `--review --json`; JSON mode sets `SYNC_RESULT_FILE`, runs workspace fn stdout→stderr, emits array, exits non-zero if any `ok=false`); usage line updated.
- **`tests/test_sync.sh`** (modify) — unit tests for `sync_result_json` + `_sync_record` + worker recording.
- **`tests/test_sync_flags.sh`** (modify) — `sync --json` dispatch tests (real CLI).

Reference facts (read before starting):
- Workers live in `lib/sync.sh`: `sync_repo` (default, ~line 41), `safe_sync_repo` (~96), `push_repo` (~152). Each does git side-effects, calls `log_*` (stdout), returns 0/1.
- `should_skip_dir` early-returns (not a git repo) are NOT recorded (consistent with text mode where they never appear).
- `_log`/`log_*` (`lib/colors.sh`) write to **stdout**.
- The `sync` dispatch is in `bin/mra.sh` (`sync)` case): parses `--safe`/`--push`/`--dry-run`/`--review`, enforces mode mutual-exclusion + "`--dry-run` only with `--push`", then calls `sync_review_workspace` / `push_workspace` / `safe_sync_workspace` / `sync_from_repos_json` (default).
- `resolve_workspace` honours `MRA_WORKSPACE`.
- `tests/test_sync.sh` sources colors/sync/branch/review-select, uses `errors`, ends `if [[ $errors -eq 0 ]]; then echo "PASS: all sync tests passed"; else …; exit 1; fi`. Append before that block.
- `tests/test_sync_flags.sh` has a `run() { if out=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync "$@" 2>&1); then rc=0; else rc=$?; fi; }` helper and a shared empty `$WS`; ends `if [[ $errors -eq 0 ]]; then echo "PASS: sync flag discipline tests passed"; …; fi`. Note `run()` merges stderr into `$out` (`2>&1`) — for JSON stdout/stderr-separation tests, do NOT use `run`; invoke the CLI directly capturing stdout and stderr separately.

---

## Task 1: `sync_result_json` + `_sync_record` shared helpers

**Files:**
- Modify: `tests/test_sync.sh` (append unit tests before the summary block)
- Modify: `lib/sync.sh` (add two functions)

- [ ] **Step 1: Write the failing test** — append to `tests/test_sync.sh`, BEFORE the final `if [[ $errors -eq 0 ]]` summary block:

```bash
# --- sync_result_json: jq object, correct types, injection-safe ---
o=$(sync_result_json app pulled true)
printf '%s' "$o" | jq -e . >/dev/null 2>&1 || { echo "FAIL: sync_result_json not valid JSON: $o"; errors=$((errors+1)); }
[[ "$(printf '%s' "$o" | jq -r '.repo')" == "app" ]] || { echo "FAIL: .repo wrong: $o"; errors=$((errors+1)); }
[[ "$(printf '%s' "$o" | jq -r '.action')" == "pulled" ]] || { echo "FAIL: .action wrong: $o"; errors=$((errors+1)); }
printf '%s' "$o" | jq -e '.ok==true and (.ok|type)=="boolean"' >/dev/null 2>&1 || { echo "FAIL: .ok should be boolean true: $o"; errors=$((errors+1)); }
of=$(sync_result_json x clone-failed false)
printf '%s' "$of" | jq -e '.ok==false' >/dev/null 2>&1 || { echo "FAIL: .ok should be false: $of"; errors=$((errors+1)); }
# injection-safety: a repo name with a double-quote stays valid JSON
oq=$(sync_result_json 'a"b' pulled true)
printf '%s' "$oq" | jq -e . >/dev/null 2>&1 || { echo "FAIL: quote in repo broke JSON: $oq"; errors=$((errors+1)); }
[[ "$(printf '%s' "$oq" | jq -r '.repo')" == 'a"b' ]] || { echo "FAIL: quoted repo not preserved: $oq"; errors=$((errors+1)); }
# guard: non-boolean ok rejected (non-zero, no JSON)
if sync_result_json app pulled notabool >/dev/null 2>&1; then echo "FAIL: sync_result_json should reject non-boolean ok"; errors=$((errors+1)); fi

# --- _sync_record: file sink, no-op when SYNC_RESULT_FILE unset ---
unset SYNC_RESULT_FILE 2>/dev/null || true
_sync_record app pulled true   # must be a no-op, no error, no file
RF=$(mktemp); rm -f "$RF"      # a path that does not exist yet
SYNC_RESULT_FILE="$RF" _sync_record app pulled true
SYNC_RESULT_FILE="$RF" _sync_record lib up-to-date true
[[ -f "$RF" ]] || { echo "FAIL: _sync_record should create the sink file"; errors=$((errors+1)); }
[[ "$(wc -l < "$RF" | tr -d ' ')" == "2" ]] || { echo "FAIL: _sync_record should append one line per call: $(cat "$RF")"; errors=$((errors+1)); }
[[ "$(head -1 "$RF")" == $'app\tpulled\ttrue' ]] || { echo "FAIL: _sync_record line format wrong: $(head -1 "$RF")"; errors=$((errors+1)); }
rm -f "$RF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `sync_result_json: command not found` / `_sync_record: command not found`.

- [ ] **Step 3: Write the implementation** — add to `lib/sync.sh`, at the END of the file:

```bash
# Emit one per-repo sync result as a JSON object (jq-built; injection-safe).
# Sibling of branch_state_json. Args: repo action ok
#   - ok MUST be the string "true" or "false" (passed via --argjson to become a JSON boolean).
sync_result_json() {
  local repo="$1" action="$2" ok="$3"
  [[ "$ok" == "true" || "$ok" == "false" ]] \
    || { echo "sync_result_json: ok must be 'true' or 'false', got: '$ok'" >&2; return 1; }
  jq -n --arg repo "$repo" --arg action "$action" --argjson ok "$ok" \
    '{repo:$repo, action:$action, ok:$ok}'
}

# Record one per-repo sync outcome to the SYNC_RESULT_FILE sink, when set.
# No-op (and side-effect-free) when SYNC_RESULT_FILE is unset — keeps text mode unchanged.
# A file sink (not a shell var) is used so records survive subshell boundaries.
# Args: repo action ok
_sync_record() {
  [[ -n "${SYNC_RESULT_FILE:-}" ]] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SYNC_RESULT_FILE"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: `PASS: all sync tests passed` (0 errors).

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): sync_result_json + _sync_record (shared per-repo result model)"
```

---

## Task 2: instrument `safe_sync_repo` (--safe worker)

**Files:**
- Modify: `tests/test_sync.sh` (append worker test)
- Modify: `lib/sync.sh` (replace `safe_sync_repo`)

- [ ] **Step 1: Write the failing test** — append to `tests/test_sync.sh`, BEFORE the summary block:

```bash
# --- safe_sync_repo records its outcome to the SYNC_RESULT_FILE sink ---
# up-to-date fixture: clone a bare origin, commit+push, so local == origin/main
SS=$(mktemp -d)
git init -b main --bare "$SS/up.git" &>/dev/null
git clone "$SS/up.git" "$SS/a" &>/dev/null
git -C "$SS/a" config user.email t@t.t; git -C "$SS/a" config user.name t
git -C "$SS/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SS/a" push -u origin main &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" safe_sync_repo "$SS/a" >/dev/null 2>&1 || true
grep -qx $'a\tup-to-date\ttrue' "$RF" || { echo "FAIL: safe_sync_repo should record 'up-to-date true': $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SS" "$RF"
# fetch-failure fixture: a repo with a bad origin
FF=$(mktemp -d)
git -C "$FF" init -b main a &>/dev/null
git -C "$FF/a" config user.email t@t.t; git -C "$FF/a" config user.name t
git -C "$FF/a" commit --allow-empty -m c1 &>/dev/null
git -C "$FF/a" remote add origin /nonexistent/x.git
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" safe_sync_repo "$FF/a" >/dev/null 2>&1 || true
grep -qx $'a\tfetch-failed\tfalse' "$RF" || { echo "FAIL: safe_sync_repo should record 'fetch-failed false': $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$FF" "$RF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `safe_sync_repo` does not record yet, so `$RF` is empty and the `grep -qx` assertions fail.

- [ ] **Step 3: Write the implementation** — replace the ENTIRE `safe_sync_repo` function in `lib/sync.sh` with:

```bash
safe_sync_repo() {
  local repo_dir="$1"
  local repo_name; repo_name=$(basename "$repo_dir")

  if should_skip_dir "$repo_dir"; then
    return 0
  fi

  if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
    log_error "$repo_name: fetch failed" "sync"
    _sync_record "$repo_name" fetch-failed false
    return 1
  fi

  local state action
  state=$(get_branch_state "$repo_dir")
  action=$(branch_state_get "$state" sync_action)

  case "$action" in
    fast-forward)
      log_progress "$repo_name: fast-forward" "sync"
      if git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null; then
        log_success "$repo_name: ok" "sync"; _sync_record "$repo_name" pulled true; return 0
      else
        log_error "$repo_name: ff-only pull failed" "sync"; _sync_record "$repo_name" ff-failed false; return 1
      fi
      ;;
    up-to-date|ahead-only)
      log_success "$repo_name: $action (no pull needed)" "sync"; _sync_record "$repo_name" "$action" true; return 0 ;;
    diverged)
      log_warn "$repo_name: diverged (ahead & behind) — skipping, resolve manually" "sync"; _sync_record "$repo_name" diverged true; return 0 ;;
    dirty-skip)
      log_warn "$repo_name: behind but working tree dirty — skipping" "sync"; _sync_record "$repo_name" dirty-skip true; return 0 ;;
    no-upstream)
      log_warn "$repo_name: no upstream branch set — skipping" "sync"; _sync_record "$repo_name" no-upstream true; return 0 ;;
    *)
      log_warn "$repo_name: unknown state '$action' — skipping" "sync"; _sync_record "$repo_name" unknown true; return 0 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: `PASS: all sync tests passed` (0 errors) — including the existing `safe_sync_repo` text tests (human `log_*` lines unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): record safe_sync_repo outcomes via _sync_record"
```

---

## Task 3: instrument `push_repo` (--push worker)

**Files:**
- Modify: `tests/test_sync.sh` (append worker test)
- Modify: `lib/sync.sh` (replace `push_repo`)

- [ ] **Step 1: Write the failing test** — append to `tests/test_sync.sh`, BEFORE the summary block:

```bash
# --- push_repo records its outcome (dry-run, no real push) ---
PP=$(mktemp -d)
git init -b main --bare "$PP/up.git" &>/dev/null
git clone "$PP/up.git" "$PP/a" &>/dev/null
git -C "$PP/a" config user.email t@t.t; git -C "$PP/a" config user.name t
git -C "$PP/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PP/a" push -u origin main &>/dev/null
# feature branch with no upstream + a commit -> push-new -> dry-run -> would-push-new
git -C "$PP/a" checkout -b feat/x &>/dev/null
git -C "$PP/a" commit --allow-empty -m work &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" push_repo "$PP/a" true >/dev/null 2>&1 || true
grep -qE $'^a\twould-push(-new)?\ttrue$' "$RF" || { echo "FAIL: push_repo dry-run should record would-push*: $(cat "$RF")"; errors=$((errors+1)); }
# back on default branch, up-to-date with origin -> up-to-date
git -C "$PP/a" checkout main &>/dev/null
: > "$RF"
SYNC_RESULT_FILE="$RF" push_repo "$PP/a" true >/dev/null 2>&1 || true
grep -qx $'a\tup-to-date\ttrue' "$RF" || { echo "FAIL: push_repo should record up-to-date: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$PP" "$RF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `push_repo` does not record yet; `$RF` empty.

- [ ] **Step 3: Write the implementation** — replace the ENTIRE `push_repo` function in `lib/sync.sh` with:

```bash
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
        log_info "$repo_name: would push -u origin $branch (new branch)$dirty_note" "sync"; _sync_record "$repo_name" would-push-new true; return 0
      fi
      if git -C "$repo_dir" push -u origin "$branch" >/dev/null 2>&1; then
        log_success "$repo_name: pushed new branch '$branch'$dirty_note" "sync"; _sync_record "$repo_name" pushed-new true; return 0
      else
        log_error "$repo_name: push -u failed" "sync"; _sync_record "$repo_name" push-new-failed false; return 1
      fi
      ;;
    push)
      if [[ "$dry_run" == "true" ]]; then
        log_info "$repo_name: would push $branch ($ahead ahead)$dirty_note" "sync"; _sync_record "$repo_name" would-push true; return 0
      fi
      if git -C "$repo_dir" push >/dev/null 2>&1; then
        log_success "$repo_name: pushed$dirty_note" "sync"; _sync_record "$repo_name" pushed true; return 0
      else
        log_error "$repo_name: push failed" "sync"; _sync_record "$repo_name" push-failed false; return 1
      fi
      ;;
    up-to-date)
      log_success "$repo_name: up-to-date (nothing to push)" "sync"; _sync_record "$repo_name" up-to-date true; return 0 ;;
    skip-detached)
      log_warn "$repo_name: detached HEAD — skipping (check out a branch first)" "sync"; _sync_record "$repo_name" skip-detached true; return 0 ;;
    skip-diverged)
      log_warn "$repo_name: diverged — skipping (pull/reconcile first, never force)" "sync"; _sync_record "$repo_name" skip-diverged true; return 0 ;;
    skip-behind)
      log_warn "$repo_name: behind upstream — skipping (pull first)" "sync"; _sync_record "$repo_name" skip-behind true; return 0 ;;
    *)
      log_warn "$repo_name: unknown push state '$action' — skipping" "sync"; _sync_record "$repo_name" unknown true; return 0 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: `PASS: all sync tests passed` (0 errors) — including the existing `push_repo` text tests.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): record push_repo outcomes via _sync_record"
```

---

## Task 4: instrument `sync_repo` (default worker)

**Files:**
- Modify: `tests/test_sync.sh` (append worker test)
- Modify: `lib/sync.sh` (replace `sync_repo`)

- [ ] **Step 1: Write the failing test** — append to `tests/test_sync.sh`, BEFORE the summary block:

```bash
# --- sync_repo records its outcome ---
# clone fixture: a missing dir cloned from a local bare origin -> cloned
SD=$(mktemp -d); mkdir -p "$SD/origin" "$SD/ws"
git init -b main --bare "$SD/origin/a.git" &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" sync_repo "$SD/ws/a" "$SD/origin" >/dev/null 2>&1 || true
grep -qx $'a\tcloned\ttrue' "$RF" || { echo "FAIL: sync_repo should record cloned: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SD" "$RF"
# feature-branch fixture -> skipped-branch
SB=$(mktemp -d)
git -C "$SB" init -b main a &>/dev/null
git -C "$SB/a" config user.email t@t.t; git -C "$SB/a" config user.name t
git -C "$SB/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SB/a" checkout -b feat/x &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" sync_repo "$SB/a" "ignored-org" >/dev/null 2>&1 || true
grep -qx $'a\tskipped-branch\ttrue' "$RF" || { echo "FAIL: sync_repo should record skipped-branch: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SB" "$RF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync.sh`
Expected: FAIL — `sync_repo` does not record yet; `$RF` empty.

- [ ] **Step 3: Write the implementation** — replace the ENTIRE `sync_repo` function in `lib/sync.sh` with:

```bash
sync_repo() {
  local repo_dir="$1" git_org="$2"
  local repo_name
  repo_name=$(basename "$repo_dir")

  if [[ ! -d "$repo_dir" ]]; then
    # Clone
    local clone_url="${git_org}/${repo_name}.git"
    log_progress "$repo_name: git clone" "sync"
    if git clone "$clone_url" "$repo_dir" &>/dev/null 2>&1; then
      log_success "$repo_name: cloned" "sync"
      _sync_record "$repo_name" cloned true
      return 0
    else
      log_error "$repo_name: clone failed ($clone_url)" "sync"
      _sync_record "$repo_name" clone-failed false
      return 1
    fi
  fi

  if should_skip_dir "$repo_dir"; then
    return 0
  fi

  if ! is_on_default_branch "$repo_dir"; then
    local branch
    branch=$(get_current_branch "$repo_dir")
    log_warn "$repo_name: on branch '$branch', skipping sync" "sync"
    _sync_record "$repo_name" skipped-branch true
    return 0
  fi

  log_progress "$repo_name: git pull" "sync"
  if git -C "$repo_dir" fetch --quiet 2>/dev/null && git -C "$repo_dir" pull --quiet 2>/dev/null; then
    log_success "$repo_name: ok" "sync"
    _sync_record "$repo_name" pulled true
    return 0
  else
    log_error "$repo_name: sync failed" "sync"
    _sync_record "$repo_name" sync-failed false
    return 1
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sync.sh`
Expected: `PASS: all sync tests passed` (0 errors) — including existing `sync_repo` text tests.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/test_sync.sh
git commit -m "feat(sync): record sync_repo outcomes via _sync_record"
```

---

## Task 5: `sync --json` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` — the `sync)` dispatch block + the `sync` usage line
- Modify: `tests/test_sync_flags.sh` (append dispatch tests before the summary block)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_sync_flags.sh`, BEFORE the final summary block. Do NOT use the `run()` helper (it merges stderr into `$out`); invoke the CLI directly, capturing stdout and stderr separately:

```bash
# --- sync --json dispatch ---
# 9/12. default mode --json on the empty $WS -> [] (valid array; exercises default-mode JSON dispatch)
jout=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync --json 2>/dev/null)
[[ "$(printf '%s' "$jout" | jq -c '.')" == "[]" ]] || { echo "FAIL: empty workspace --json should be []: $jout"; errors=$((errors+1)); }

# 10. --safe --json over a populated workspace -> array, clean stdout, logs on stderr
WJ=$(mktemp -d)
for r in a b; do
  git -C "$WJ" init -b main "$r" &>/dev/null
  git -C "$WJ/$r" config user.email t@t.t; git -C "$WJ/$r" config user.name t
  git -C "$WJ/$r" commit --allow-empty -m init &>/dev/null
done
git -C "$WJ/b" checkout -b feat/x &>/dev/null
EJ=$(mktemp)
jout=$(MRA_WORKSPACE="$WJ" bash "$SCRIPT_DIR/bin/mra.sh" sync --safe --json 2>"$EJ")
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --safe --json should be a JSON array: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq 'length')" == "2" ]] || { echo "FAIL: array should have 2 repos: $jout"; errors=$((errors+1)); }
printf '%s' "$jout" | jq -e 'all(.[]; has("repo") and has("action") and has("ok"))' >/dev/null 2>&1 || { echo "FAIL: each object needs repo/action/ok: $jout"; errors=$((errors+1)); }
printf '%s' "$jout" | jq . >/dev/null 2>&1 || { echo "FAIL: --safe --json stdout must be pure JSON: $jout"; errors=$((errors+1)); }
case "$jout" in *'[sync]'*) echo "FAIL: stdout must not contain the [sync] log tag: $jout"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WJ" "$EJ"

# 11. --review --json -> error, non-zero, no JSON
if jout=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync --review --json 2>/dev/null); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: --review --json should exit non-zero"; errors=$((errors+1)); }
if printf '%s' "$jout" | jq -e . >/dev/null 2>&1; then echo "FAIL: --review --json should produce no JSON on stdout: $jout"; errors=$((errors+1)); fi

# 13. failure path: a repo whose --safe fetch fails -> non-zero exit, stdout still a JSON array with ok:false
WF=$(mktemp -d)
git -C "$WF" init -b main a &>/dev/null
git -C "$WF/a" config user.email t@t.t; git -C "$WF/a" config user.name t
git -C "$WF/a" commit --allow-empty -m init &>/dev/null
git -C "$WF/a" remote add origin /nonexistent/x.git
EF=$(mktemp)
if jout=$(MRA_WORKSPACE="$WF" bash "$SCRIPT_DIR/bin/mra.sh" sync --safe --json 2>"$EF"); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: fetch-failure --safe --json should exit non-zero"; errors=$((errors+1)); }
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: stdout should still be a JSON array on failure: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq -r '.[] | select(.repo=="a") | .ok')" == "false" ]] || { echo "FAIL: failed repo should have ok:false: $jout"; errors=$((errors+1)); }
grep -q 'fetch failed' "$EF" || { echo "FAIL: fetch-failure message should be on stderr: $(cat "$EF")"; errors=$((errors+1)); }
rm -rf "$WF" "$EF"

# 14. --push --dry-run --json -> array, would-push*, clean stdout, log on stderr
WP=$(mktemp -d)
git -C "$WP" init -b main --bare up.git &>/dev/null
git clone "$WP/up.git" "$WP/a" &>/dev/null
git -C "$WP/a" config user.email t@t.t; git -C "$WP/a" config user.name t
git -C "$WP/a" commit --allow-empty -m c1 &>/dev/null
git -C "$WP/a" push -u origin main &>/dev/null
git -C "$WP/a" checkout -b feat/x &>/dev/null
git -C "$WP/a" commit --allow-empty -m work &>/dev/null
EP=$(mktemp)
jout=$(MRA_WORKSPACE="$WP" bash "$SCRIPT_DIR/bin/mra.sh" sync --push --dry-run --json 2>"$EP")
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --push --dry-run --json should be a JSON array: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq -r '.[] | select(.repo=="a") | .action')" =~ ^(would-push|would-push-new|up-to-date)$ ]] || { echo "FAIL: push dry-run action should be would-push*/up-to-date: $jout"; errors=$((errors+1)); }
case "$jout" in *'[sync]'*) echo "FAIL: --push --json stdout must not contain [sync] tag: $jout"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WP" "$EP"
```

(Note: the `WP/up.git` bare lives inside the workspace dir; `branch status`-style loops skip non-repo dirs, but the `--bare up.git` dir IS a git dir. To keep it out of the workspace scan, create the bare OUTSIDE: use `git init -b main --bare "$WP/../up_$$.git"`? Simpler — put the clone target as the only workspace entry: create the bare in a sibling temp. Implement as: `BARE=$(mktemp -d)/up.git; git init -b main --bare "$BARE"; git clone "$BARE" "$WP/a"`. Adjust the fixture so only `a` is under `$WP`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_sync_flags.sh`
Expected: FAIL — `--json` is an unknown option today (`*) log_error "unknown option"`), so every `--json` invocation errors out with no JSON.

- [ ] **Step 3: Replace the `sync)` dispatch block** in `bin/mra.sh` with:

```bash
    sync)
      shift
      local safe=false push=false dry_run=false review=false json=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --safe) safe=true; shift ;;
          --push) push=true; shift ;;
          --dry-run) dry_run=true; shift ;;
          --review) review=true; shift ;;
          --json) json=true; shift ;;
          *) log_error "unknown option: $1" "sync"; exit 1 ;;
        esac
      done
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
      if [[ "$json" == "true" && "$review" == "true" ]]; then
        log_error "sync: --review does not support --json" "sync"; exit 1
      fi
      local workspace; workspace=$(resolve_workspace)
      if [[ "$json" == "true" ]]; then
        local rf; rf=$(mktemp)
        export SYNC_RESULT_FILE="$rf"
        local jrc=0
        if [[ "$push" == "true" ]]; then
          push_workspace "$workspace" "$dry_run" 1>&2 || jrc=$?
        elif [[ "$safe" == "true" ]]; then
          safe_sync_workspace "$workspace" 1>&2 || jrc=$?
        else
          local graph_file git_org
          graph_file=$(get_dep_graph_path "$workspace")
          git_org=$(jq -r '.gitOrg' "$graph_file")
          sync_from_repos_json "$workspace" "$git_org" 1>&2 || jrc=$?
        fi
        unset SYNC_RESULT_FILE
        local json_objs=() repo action okv
        while IFS=$'\t' read -r repo action okv; do
          [[ -z "$repo" ]] && continue
          json_objs+=("$(sync_result_json "$repo" "$action" "$okv")")
        done < "$rf"
        rm -f "$rf"
        if [[ ${#json_objs[@]} -eq 0 ]]; then
          printf '[]\n'
        else
          printf '%s\n' "${json_objs[@]}" | jq -s '.'
        fi
        exit "$jrc"
      fi
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

- [ ] **Step 4: Update the usage line** in `bin/mra.sh`. Find:

```
  sync [--safe] [--push] [--dry-run] [--review]  Clone/pull; --safe ff-only; --push pushes; --review auto-reviews changed repos
```

Replace with:

```
  sync [--safe] [--push] [--dry-run] [--review] [--json]  Clone/pull; --safe ff-only; --push pushes; --review auto-reviews; --json per-repo {repo,action,ok} array (not with --review)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_sync_flags.sh` then `bash tests/test_sync.sh`
Expected: both PASS (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_sync_flags.sh
git commit -m "feat(sync): sync --json dispatch (default/--safe/--push, stdout JSON-only) + usage"
```

---

## Task 6: Full regression + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` (§20 status) + re-render `.html`

- [ ] **Step 1: Run the full suite**

Run: `bash test.sh`
Expected: `shell tests: 45 passed, 0 failed` and `mcp-server : ok`. (No new suite — Phase 12 tests live in `tests/test_sync.sh` / `tests/test_sync_flags.sh`.) If anything fails, STOP and report BLOCKED with the output.

- [ ] **Step 2: Flip the §20 status note** in the spec. Find the `**Status:**` line directly under `## 20. Phase 12 — `:

```
**Status:** Approved (design) — 2026-06-05. Implementation scope for the next plan. Machine-readable sync output across the three sync-outcome modes, via a shared per-repo result model. `--review --json` is explicitly out of scope (freeform LLM output).
```

Replace with:

```
**Status:** Implemented — 2026-06-05. `sync --json` (default/`--safe`/`--push`) emits a per-repo `{repo, action, ok}` array via `sync_result_json` + the `SYNC_RESULT_FILE` sink in `lib/sync.sh`; JSON-mode stdout stays JSON-only (worker logs → stderr). `--review --json` rejected.
```

- [ ] **Step 3: Re-render the spec HTML**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md`
Expected: `✓ …-design.md -> …-design.html`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.html
git commit -m "docs(spec): mark Phase 12 (sync --json) implemented"
```

---

## Self-Review Notes

- **Spec coverage:** §20.1 surface (`--json` composes with default/--safe/--push; `--review --json` rejected) → Task 5. §20.2 result model (`{repo,action,ok}`, ok rule, skip-dir not recorded) → Task 1 (`sync_result_json`) + Tasks 2–4 (workers). §20.3 per-mode action vocab → Task 2 (--safe), Task 3 (--push), Task 4 (default). §20.4 mechanism (`_sync_record` sink, stdout→stderr) → Task 1 + Task 5. §20.5 architecture → all tasks. §20.6 error/consumer contract (review rejected, ok:false → non-zero, stdout JSON-only, stderr carries logs) → Task 5 + tests 11/13. §20.7 tests 1–5 → Task 1; 6 → Task 2; 7 → Task 3; 8 → Task 4; 9–15 → Task 5; regression → Task 6. §20.8 out-of-scope respected.
- **No placeholders:** every code step shows the full function body / exact replacement / runnable test.
- **Type/name consistency:** `sync_result_json repo action ok` and `_sync_record repo action ok` are defined in Task 1 and used identically in Tasks 2–5. The action strings in Tasks 2–4 exactly match the §20.3 vocab and the dispatch reads them back via `IFS=$'\t'`. `ok` is the string `true`/`false` throughout (workers pass literals; `sync_result_json` validates + `--argjson`).
- **stdout discipline:** Task 5 runs each workspace fn with `1>&2`, so worker `log_*` (stdout) lands on stderr; the only stdout writers in JSON mode are `printf '[]\n'` and `jq -s '.'`. Tests 10/14 assert no `[sync]` tag on stdout; test 13 asserts stderr carries the failure. The empty-array guard mirrors Phase 11.
- **Text mode unchanged:** `_sync_record` is a no-op when `SYNC_RESULT_FILE` is unset; the workers' human `log_*` lines are byte-identical, so existing `test_sync.sh`/`test_sync_flags.sh` text assertions keep passing (verified by Step 4 of each worker task + Task 6 regression).
