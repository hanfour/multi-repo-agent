# branch status --json (Phase 11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra branch status --json` — a machine-readable JSON array of every repo's branch state.

**Architecture:** A new pure `branch_state_json` in `lib/branch.sh` builds one JSON object per repo with `jq -n` (the JSON sibling of `branch_format_row`). The `branch status` dispatch in `bin/mra.sh` gains a `--json` flag that, in JSON mode, collects per-repo objects and emits a single array via `jq -s '.'`, keeps stdout JSON-only (fetch errors → stderr; no header/clean line), and emits `[]` for an empty workspace.

**Tech Stack:** Bash (`lib/branch.sh` + `bin/mra.sh` dispatch), `jq`, `git`, custom PASS/FAIL test harness in `tests/test_branch.sh`.

**Spec:** `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` §19.

---

## File Structure

- **`lib/branch.sh`** (modify) — add pure `branch_state_json state_block on_default needs_attention` (jq-built object). No change to `get_branch_state`, `branch_format_row`, `branch_row_needs_attention`, `branch_sync_action`, `branch_state_get`.
- **`bin/mra.sh`** (modify) — `branch status` dispatch gains `--json`; usage line updated.
- **`tests/test_branch.sh`** (modify) — append `branch_state_json` unit tests + `branch status --json` dispatch tests (the suite already exists; tests go before its final summary/exit block).

Reference facts (read before starting):
- `get_branch_state repo_dir` (`lib/branch.sh:41`) prints flat `KEY=VALUE` lines: `repo`, `branch`, `upstream`, `ahead`, `behind`, `dirty`, `sync_action` (ahead/behind/dirty always numeric, default 0).
- `branch_state_get state key` (`lib/branch.sh:34`) extracts one field.
- `branch_row_needs_attention ahead behind dirty on_default` (`lib/branch.sh:65`) → exit 0 (true) when any count > 0 OR `on_default != "true"`.
- `branch_format_row` (`lib/branch.sh:72`) is the text sibling — match its structure.
- The `branch status` dispatch is in `bin/mra.sh` under the `branch)` case, sub-case `status)`. It parses `--all`/`--fetch`, prints a table header, loops `"$workspace"/*/` (skips `.*` and `should_skip_dir`), optionally `git fetch`, computes state, and prints rows that need attention (or all with `--all`).
- `_log`/`log_*` (`lib/colors.sh`) write to **stdout** — so JSON mode must redirect fetch errors to stderr and skip the header/clean line.
- `resolve_workspace` honours `MRA_WORKSPACE=<dir>` (used by existing dispatch tests in `tests/test_pr_ops.sh`).
- `tests/test_branch.sh` sources only `lib/branch.sh`, uses an `errors` counter, and ends with `if [[ $errors -eq 0 ]]; then echo "PASS: branch_sync_action tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi`. Append new tests BEFORE that block.

---

## Task 1: `branch_state_json` pure function

**Files:**
- Modify: `tests/test_branch.sh` (append unit tests before the summary block)
- Modify: `lib/branch.sh` (add function)

- [ ] **Step 1: Write the failing test** — append to `tests/test_branch.sh`, BEFORE the final `if [[ $errors -eq 0 ]]` summary block:

```bash
# --- branch_state_json: jq-built object, correct types, injection-safe ---
STATE_A=$'repo=app\nbranch=feat/x\nupstream=origin/feat/x\nahead=2\nbehind=0\ndirty=1\nsync_action=ahead-only'
obj=$(branch_state_json "$STATE_A" false true)
printf '%s' "$obj" | jq -e . >/dev/null 2>&1 || { echo "FAIL: branch_state_json output is not valid JSON: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.repo')" == "app" ]] || { echo "FAIL: .repo wrong: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.branch')" == "feat/x" ]] || { echo "FAIL: .branch wrong: $obj"; errors=$((errors+1)); }
[[ "$(printf '%s' "$obj" | jq -r '.sync_action')" == "ahead-only" ]] || { echo "FAIL: .sync_action wrong: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '.ahead==2 and .behind==0 and .dirty==1' >/dev/null 2>&1 || { echo "FAIL: numeric fields wrong: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '(.ahead|type)=="number" and (.dirty|type)=="number"' >/dev/null 2>&1 || { echo "FAIL: ahead/dirty should be JSON numbers: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '(.on_default|type)=="boolean" and (.needs_attention|type)=="boolean"' >/dev/null 2>&1 || { echo "FAIL: on_default/needs_attention should be JSON booleans: $obj"; errors=$((errors+1)); }
printf '%s' "$obj" | jq -e '.on_default==false and .needs_attention==true' >/dev/null 2>&1 || { echo "FAIL: boolean values wrong: $obj"; errors=$((errors+1)); }

# injection-safety: a branch name with a double-quote stays valid JSON
STATE_Q=$'repo=app\nbranch=feat/q"x\nupstream=(none)\nahead=0\nbehind=0\ndirty=0\nsync_action=no-upstream'
objq=$(branch_state_json "$STATE_Q" true false)
printf '%s' "$objq" | jq -e . >/dev/null 2>&1 || { echo "FAIL: quote in branch name broke JSON: $objq"; errors=$((errors+1)); }
[[ "$(printf '%s' "$objq" | jq -r '.branch')" == 'feat/q"x' ]] || { echo "FAIL: quoted branch name not preserved: $objq"; errors=$((errors+1)); }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `branch_state_json: command not found` (function does not exist yet).

- [ ] **Step 3: Write the implementation** — add to `lib/branch.sh`, after `branch_format_row` (at the end of the file):

```bash
# Emit one BranchState block as a JSON object (jq-built; injection-safe).
# The JSON sibling of branch_format_row. Args: state_block on_default needs_attention
# on_default / needs_attention are the strings "true"/"false" (become JSON booleans).
branch_state_json() {
  local s="$1" on_default="$2" needs_attention="$3"
  jq -n \
    --arg repo "$(branch_state_get "$s" repo)" \
    --arg branch "$(branch_state_get "$s" branch)" \
    --arg upstream "$(branch_state_get "$s" upstream)" \
    --argjson ahead "$(branch_state_get "$s" ahead)" \
    --argjson behind "$(branch_state_get "$s" behind)" \
    --argjson dirty "$(branch_state_get "$s" dirty)" \
    --arg sync_action "$(branch_state_get "$s" sync_action)" \
    --argjson on_default "$on_default" \
    --argjson needs_attention "$needs_attention" \
    '{repo:$repo, branch:$branch, upstream:$upstream, ahead:$ahead, behind:$behind, dirty:$dirty, sync_action:$sync_action, on_default:$on_default, needs_attention:$needs_attention}'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: `PASS: branch_sync_action tests passed` (0 errors — the existing tests plus the new block).

- [ ] **Step 5: Commit**

```bash
git add lib/branch.sh tests/test_branch.sh
git commit -m "feat(branch): branch_state_json — JSON object sibling of branch_format_row"
```

---

## Task 2: `branch status --json` dispatch + usage

**Files:**
- Modify: `bin/mra.sh` — `branch status` sub-dispatch + the usage line for `branch status`
- Modify: `tests/test_branch.sh` (append dispatch tests before the summary block)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_branch.sh`, BEFORE the final summary block:

```bash
# --- branch status --json dispatch (real CLI via MRA_WORKSPACE) ---
# workspace: repo a on default branch (clean), repo b on a feature branch
WSJ=$(mktemp -d)
for r in a b; do
  git -C "$WSJ" init -b main "$r" &>/dev/null
  git -C "$WSJ/$r" config user.email t@t.t; git -C "$WSJ/$r" config user.name t
  git -C "$WSJ/$r" commit --allow-empty -m init &>/dev/null
done
git -C "$WSJ/b" checkout -b feat/x &>/dev/null

# 3. array of ALL repos (length 2, includes the needs_attention:false one)
out=$(MRA_WORKSPACE="$WSJ" bash "$SCRIPT_DIR/bin/mra.sh" branch status --json 2>/dev/null)
printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --json should output a JSON array: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq 'length')" == "2" ]] || { echo "FAIL: array should have 2 repos: $out"; errors=$((errors+1)); }
# 4. needs_attention correct: a (default, clean) false; b (feature branch) true
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="a") | .needs_attention')" == "false" ]] || { echo "FAIL: repo a needs_attention should be false: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="b") | .needs_attention')" == "true" ]] || { echo "FAIL: repo b needs_attention should be true: $out"; errors=$((errors+1)); }
[[ "$(printf '%s' "$out" | jq -r '.[] | select(.repo=="b") | .branch')" == "feat/x" ]] || { echo "FAIL: repo b branch should be feat/x: $out"; errors=$((errors+1)); }
# 5. stdout is clean: the whole thing parses as JSON (no header/log contamination)
printf '%s' "$out" | jq . >/dev/null 2>&1 || { echo "FAIL: --json stdout must be pure JSON: $out"; errors=$((errors+1)); }
case "$out" in *'[branch]'*|*REPO*BRANCH*) echo "FAIL: --json stdout must not contain table header / log tags: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WSJ"

# 6. empty workspace -> []
WSE=$(mktemp -d)
out=$(MRA_WORKSPACE="$WSE" bash "$SCRIPT_DIR/bin/mra.sh" branch status --json 2>/dev/null)
[[ "$(printf '%s' "$out" | jq -c '.')" == "[]" ]] || { echo "FAIL: empty workspace should yield []: $out"; errors=$((errors+1)); }
rm -rf "$WSE"

# 7. text mode (no --json) regression: still prints a table row for the feature-branch repo
WST=$(mktemp -d)
git -C "$WST" init -b main b &>/dev/null
git -C "$WST/b" config user.email t@t.t; git -C "$WST/b" config user.name t
git -C "$WST/b" commit --allow-empty -m init &>/dev/null
git -C "$WST/b" checkout -b feat/x &>/dev/null
out=$(MRA_WORKSPACE="$WST" bash "$SCRIPT_DIR/bin/mra.sh" branch status 2>/dev/null)
case "$out" in *REPO*BRANCH*) : ;; *) echo "FAIL: text mode should print the table header: $out"; errors=$((errors+1)) ;; esac
case "$out" in *feat/x*) : ;; *) echo "FAIL: text mode should show the feature branch row: $out"; errors=$((errors+1)) ;; esac
rm -rf "$WST"

# 8. failure-path stdout discipline: a repo whose fetch fails, with --fetch --json
WSF=$(mktemp -d)
git -C "$WSF" init -b main c &>/dev/null
git -C "$WSF/c" config user.email t@t.t; git -C "$WSF/c" config user.name t
git -C "$WSF/c" commit --allow-empty -m init &>/dev/null
git -C "$WSF/c" remote add origin /nonexistent/repo/path.git   # fetch will fail
ERRF=$(mktemp)
if out=$(MRA_WORKSPACE="$WSF" bash "$SCRIPT_DIR/bin/mra.sh" branch status --fetch --json 2>"$ERRF"); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: fetch-failure run should exit non-zero"; errors=$((errors+1)); }
printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: stdout should still be a JSON array despite fetch failure: $out"; errors=$((errors+1)); }
grep -q 'fetch failed' "$ERRF" || { echo "FAIL: fetch failure message should be on stderr: $(cat "$ERRF")"; errors=$((errors+1)); }
case "$out" in *'[branch]'*) echo "FAIL: stdout must not contain the [branch] log tag: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WSF" "$ERRF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_branch.sh`
Expected: FAIL — `--json` is an unknown option today (`*) log_error "unknown option"`), so the CLI exits non-zero with a log line on stdout and no JSON; the array/`[]`/stderr assertions fail.

- [ ] **Step 3: Replace the `status)` sub-dispatch** in `bin/mra.sh` (the block under `branch)` beginning `status)`) with:

```bash
        status)
          local show_all=false do_fetch=false json=false
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --all) show_all=true; shift ;;
              --fetch) do_fetch=true; shift ;;
              --json) json=true; shift ;;
              *) log_error "unknown option: $1" "branch"; exit 1 ;;
            esac
          done
          local workspace; workspace=$(resolve_workspace)
          local shown=0 failed=0
          local json_objs=()
          [[ "$json" == "false" ]] && printf '%-20s %-24s %-5s%-5s%-5s %s\n' "REPO" "BRANCH" "AHEAD" "BEHIND" "DIRTY" "ACTION"
          for dir in "$workspace"/*/; do
            [[ ! -d "$dir" ]] && continue
            local name; name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            should_skip_dir "$dir" && continue
            if [[ "$do_fetch" == "true" ]]; then
              if ! git -C "$dir" fetch --quiet 2>/dev/null; then
                if [[ "$json" == "true" ]]; then
                  log_error "$name: fetch failed" "branch" >&2
                else
                  log_error "$name: fetch failed" "branch"
                fi
                failed=$((failed+1))
              fi
            fi
            local state on_default ahead behind dirty needs_attention
            state=$(get_branch_state "$dir")
            ahead=$(branch_state_get "$state" ahead)
            behind=$(branch_state_get "$state" behind)
            dirty=$(branch_state_get "$state" dirty)
            if is_on_default_branch "$dir"; then on_default=true; else on_default=false; fi
            if branch_row_needs_attention "$ahead" "$behind" "$dirty" "$on_default"; then needs_attention=true; else needs_attention=false; fi
            if [[ "$json" == "true" ]]; then
              json_objs+=("$(branch_state_json "$state" "$on_default" "$needs_attention")")
            elif [[ "$show_all" == "true" || "$needs_attention" == "true" ]]; then
              branch_format_row "$state"; printf '\n'; shown=$((shown+1))
            fi
          done
          if [[ "$json" == "true" ]]; then
            if [[ ${#json_objs[@]} -eq 0 ]]; then
              printf '[]\n'
            else
              printf '%s\n' "${json_objs[@]}" | jq -s '.'
            fi
            [[ "$failed" -gt 0 ]] && exit 1
            exit 0
          fi
          if [[ "$shown" -eq 0 && "$show_all" == "false" ]]; then
            log_success "all repos clean and up to date" "branch"
          fi
          [[ "$failed" -gt 0 ]] && exit 1
          exit 0
          ;;
```

(Note: the only changes from the current block are the `json` flag + its `--json` case, computing `needs_attention` into a variable, the JSON-mode fetch-error `>&2` redirect, the `[[ "$json" == "false" ]]` header guard, the `json_objs` collection, and the JSON-emit block. The text path is otherwise identical.)

- [ ] **Step 4: Update the usage line** in `bin/mra.sh`. Find:

```
  branch status [--all] [--fetch]  Cross-repo branch overview (default: repos needing attention)
```

Replace with:

```
  branch status [--all] [--fetch] [--json]  Cross-repo branch overview (default: repos needing attention; --json: machine-readable array of all repos)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_branch.sh`
Expected: `PASS: branch_sync_action tests passed` (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_branch.sh
git commit -m "feat(branch): branch status --json (all repos, stdout JSON-only) + usage"
```

---

## Task 3: Full regression + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` (§19 status) + re-render `.html`

- [ ] **Step 1: Run the full suite**

Run: `bash test.sh`
Expected: `shell tests: 45 passed, 0 failed` and `mcp-server : ok`. (No new suite — Phase 11 tests live in the existing `tests/test_branch.sh`.) If anything fails, STOP and report BLOCKED with the output.

- [ ] **Step 2: Flip the §19 status note** in the spec. Find the `**Status:**` line directly under `## 19. Phase 11 — `:

```
**Status:** Approved (design) — 2026-06-05. Implementation scope for the next plan. One read-only output mode; no change to existing behaviour.
```

Replace with:

```
**Status:** Implemented — 2026-06-05. `branch status --json` emits an all-repos JSON array via the new pure `branch_state_json` in `lib/branch.sh`; JSON-mode stdout stays JSON-only (fetch errors → stderr).
```

- [ ] **Step 3: Re-render the spec HTML**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md`
Expected: `✓ …-design.md -> …-design.html`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.html
git commit -m "docs(spec): mark Phase 11 (branch status --json) implemented"
```

---

## Self-Review Notes

- **Spec coverage:** §19.1 surface (`--json`, all-repos, `--all` redundant) → Task 2. §19.2 output shape (string/number/boolean fields, `needs_attention`, `[]`) → Task 1 (object) + Task 2 (array + empty). §19.3 stdout discipline (no header/clean line, fetch error → stderr) → Task 2 + test 8. §19.4 architecture (`branch_state_json` pure; dispatch collects + `jq -s`) → Tasks 1/2. §19.5 error handling → Task 2 + test 8. §19.6 tests 1–2 → Task 1; 3–8 → Task 2. §19.7 out-of-scope respected (only `branch status`, no field selection, text format unchanged).
- **No placeholders:** every code step shows full function body / exact replacement text / runnable test code.
- **Type/name consistency:** `branch_state_json state_block on_default needs_attention` is defined in Task 1 and called identically in Task 2's dispatch. Field names (`repo/branch/upstream/ahead/behind/dirty/sync_action/on_default/needs_attention`) match between the function, the spec §19.2, and the test assertions. `on_default`/`needs_attention` are the strings `"true"`/`"false"` everywhere (so `--argjson` yields JSON booleans).
- **stdout discipline:** test 8 is the load-bearing failure-path test — it captures stdout/stderr separately, asserts non-zero exit, JSON-still-on-stdout, error-on-stderr, and no `[branch]` tag on stdout, locking §19.3's mid-emit contract.
