# `mra dev` Autonomous Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra dev <project> "<task>"` — a deterministic, fully-headless single-repo state machine that implements a task, runs debate+verifier review, fixes findings, opens a PR, runs the post-PR review loop, and reports — with a false-green firewall as the central safety property.

**Architecture:** A new `lib/dev.sh` state machine drives a write-enabled headless agent (`lib/dev-agent.sh`, reusing `agents/sub-agent.md` via `claude -p`) and the existing debate reviewer (`review_project`, forced `--strategy debate`). The review verdict is transported out-of-band via a result-file channel (`$MRA_REVIEW_RESULT_FILE`, parallel to the existing `SYNC_RESULT_FILE`) because `review_project`'s exit code is structurally `0` for every status. Every ambiguity resolves toward re-review/escalate, never `APPROVED`.

**Tech Stack:** Bash (sourced libs under `lib/`, dispatched from `bin/mra.sh`), `jq`, `git`, `gh`, `claude -p`. Tests are plain-bash assertion scripts under `tests/test_*.sh` (auto-discovered by `test.sh`; **bats is NOT installed**).

**Reference spec:** `docs/superpowers/specs/2026-06-26-mra-dev-loop-design.md` (decisions D1–D16, §10 critic fixes).

## Global Constraints

- Tests live in `tests/test_dev_*.sh`, plain bash, sourced helpers `ok`/`fail`/`assert_eq`, footer `if [[ $errors -eq 0 ]]; then echo "PASS: ..."; else echo "FAIL: $errors"; exit 1; fi`. **No `.bats`** — `test.sh` globs only `tests/test_*.sh`.
- Mock at the **`review_project` function boundary** for verdict tests, and stub `_dev_run_agent` / `_dev_review_one` for loop-transition tests (debate agents call **bare** `claude`, so `MRA_CLAUDE_BIN` does not intercept them).
- Verdict is read **only** from `$MRA_REVIEW_RESULT_FILE` status; **exit code is never the gate**. Missing/empty/unparseable ⇒ `REVIEW_INCOMPLETE`, never `APPROVED`.
- Force `--strategy debate` + force-export `MRA_REVIEW_VERIFY_APPROVE=1` on every loop-internal review. `MRA_REVIEW_ALLOW_APPROVE=1` only on the `--pr` post and only under `--auto-approve`.
- Under `set -euo pipefail` (bin/mra.sh:2): guard every `review_project` / `_dev_run_agent` / `jq` / `grep -c` call so a non-exceptional return-1 never aborts the loop mid-flight.
- Protocol/sentinel tokens stay English: `===MRA-DEV-DONE===` / `===MRA-DEV-BLOCKED: <reason>===`.
- Never `git add -A`; the agent self-commits surgically. `dev_project` owns branch creation (fork from `origin/<default>`), never `mra_commit`.
- Conventional commits; one logical change per commit. **Do not push** unless the operator asks.

## File Structure

| File | Responsibility |
|---|---|
| `lib/review.sh` (modify) | Add `_review_emit_verdict` + call it in the debate branch of `review_project` to write the canonical verdict JSON to `$MRA_REVIEW_RESULT_FILE`. |
| `lib/dev-agent.sh` (create) | `_dev_run_agent` (headless write-enabled `claude -p`), `_dev_parse_sentinel`, `_dev_slugify`. |
| `lib/dev.sh` (create) | `dev_project` state machine + `_dev_read_status`, `_dev_fingerprint`, `_dev_review_one`, `_dev_validate`, `_dev_escalate`, `_dev_report`. |
| `bin/mra.sh` (modify) | Source the two libs; add the `dev)` dispatch case + arg parser + usage line. |
| `tests/test_dev_verdict.sh` (create) | Result-file verdict channel + three-valued + false-green guards (stubs `review_project`). |
| `tests/test_dev_state_machine.sh` (create) | Pure helpers + loop transitions (stubs `_dev_run_agent`/`_dev_review_one`). |
| `tests/test_dev_cli.sh` (create) | Arg parsing, mutual-exclusion, `--dry-run`/`--no-pr` semantics. |

**Execution order:** Task 0 (de-risk) → 1 (verdict channel) → 2 (agent driver) → 3 (validate/branch/implement) → 4 (code-review loop) → 5 (PR + pr-review loop) → 6 (CLI) → 7 (escalation/report/teardown) → 8 (full suite + docs).

---

## Task 0: De-risk the write-enabled `claude -p` (spike — BLOCKS all later tasks)

This is an empirical verification, not a TDD task. The whole design rests on a non-interactive `claude -p` that can Write/Edit **and** `git commit` with no permission prompt and no TTY. Confirm the exact flags before building anything.

**Files:** none (scratch repo + notes recorded in the commit message of Task 2).

- [ ] **Step 1: Make a scratch repo**

```bash
SPIKE=$(mktemp -d); git -C "$SPIKE" init -q; git -C "$SPIKE" commit -q --allow-empty -m init
```

- [ ] **Step 2: Run the headless write+rename+commit probe**

```bash
claude -p 'Create a file hello.txt containing "hi". Then rename it to world.txt using git mv. Then stage and commit with message "spike: write+rename". Print ===MRA-DEV-DONE=== when finished.' \
  --allowedTools 'Edit,Write,Read,Grep,Glob,Bash(git:*)' \
  --setting-sources project \
  --add-dir "$SPIKE" \
  --max-turns 20 < /dev/null
```

Expected: no permission prompt, no hang; `git -C "$SPIKE" log --oneline` shows the spike commit; `git -C "$SPIKE" ls-files` shows `world.txt` (rename worked).

- [ ] **Step 3: Record the outcome**

Verify and write down (for Task 2): the exact working flag string; whether `Bash(git:*)` (with colon) was required (vs the non-matching `Bash(git*)`); and whether a file rename via `git mv` succeeded under the allowlist. If `git commit` could not be granted without `--dangerously-skip-permissions`, STOP and escalate — the design's commit model needs revisiting before proceeding.

- [ ] **Step 4: Decide allowlist breadth (critic gap §10-5)**

If the rename in Step 2 needed a non-git verb (e.g. plain `mv`/`mkdir`), record whether to broaden the default to `Bash(git:*),Bash(mkdir:*),Bash(mv:*)` or keep git-only with an `MRA_DEV_ALLOWED_TOOLS` override note. Carry the decision into Task 2.

```bash
rm -rf "$SPIKE"
```

---

## Task 1: Verdict-emission to the result-file channel (`lib/review.sh`)

**Files:**
- Modify: `lib/review.sh` (add `_review_emit_verdict`; call it in the debate branch of `review_project`, before `_render_review_json`)
- Test: `tests/test_dev_verdict.sh`

**Interfaces:**
- Consumes: existing `extract_json`, `_repair_review_json` (review.sh), `$MRA_REVIEW_RESULT_FILE` (set by caller).
- Produces: `_review_emit_verdict "$review_json" "$project_dir"` — writes canonical `{status,comments,...}` (or `{"status":"REVIEW_INCOMPLETE","comments":[]}`) to `$MRA_REVIEW_RESULT_FILE` when set; no-op when unset. Debate path always writes the file before any `return 1`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_dev_verdict.sh`:

```bash
#!/usr/bin/env bash
# Verdict-channel tests: review.sh writes the canonical verdict to
# $MRA_REVIEW_RESULT_FILE; the dev loop trusts that file, NEVER the exit code.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

RF=$(mktemp); export MRA_REVIEW_RESULT_FILE="$RF"

# 1. A valid review_json is written verbatim (status readable).
_review_emit_verdict '{"status":"CHANGES_REQUESTED","comments":[{"path":"a.ts","line":5,"severity":"HIGH","body":"x"}]}' "/tmp"
assert_eq "valid json -> status readable" "CHANGES_REQUESTED" "$(jq -r .status "$RF")"

# 2. Empty/garbage that cannot be repaired -> synthetic REVIEW_INCOMPLETE (never APPROVED).
_review_emit_verdict 'not json at all {{{' "/tmp"
assert_eq "unparseable -> REVIEW_INCOMPLETE" "REVIEW_INCOMPLETE" "$(jq -r .status "$RF")"

# 3. APPROVED passes through (the loop, not this fn, applies the verifier gate).
_review_emit_verdict '{"status":"APPROVED","comments":[]}' "/tmp"
assert_eq "approved passes through" "APPROVED" "$(jq -r .status "$RF")"

# 4. Unset channel -> no-op, no crash, no file write.
RF2=$(mktemp); rm -f "$RF2"
( unset MRA_REVIEW_RESULT_FILE; _review_emit_verdict '{"status":"APPROVED"}' "/tmp" )
[[ ! -e "$RF2" ]] && ok "unset channel -> no-op" || fail "unset channel wrote a file"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-verdict tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_dev_verdict.sh`
Expected: FAIL — `_review_emit_verdict: command not found`.

- [ ] **Step 3: Implement `_review_emit_verdict` in `lib/review.sh`**

Add near the other `_review_*` helpers (e.g. after `_render_review_json`):

```bash
# Verdict transport for `mra dev`: write the canonical review JSON to
# $MRA_REVIEW_RESULT_FILE (if set), via extract -> repair -> validate. Anything
# unparseable-after-repair becomes a synthetic REVIEW_INCOMPLETE — NEVER coerced
# to APPROVED. Human/log output on stdout is left untouched (separate channel).
_review_emit_verdict() {
  local review_json="$1" project_dir="$2"
  [[ -z "${MRA_REVIEW_RESULT_FILE:-}" ]] && return 0
  local j
  j=$(extract_json "$review_json")
  if ! printf '%s' "$j" | jq . >/dev/null 2>&1; then
    j=$(extract_json "$(_repair_review_json "$j" "$project_dir")")
  fi
  if printf '%s' "$j" | jq -e 'has("status")' >/dev/null 2>&1; then
    printf '%s' "$j" > "$MRA_REVIEW_RESULT_FILE"
  else
    printf '{"status":"REVIEW_INCOMPLETE","comments":[]}' > "$MRA_REVIEW_RESULT_FILE"
  fi
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/test_dev_verdict.sh`
Expected: PASS (all 4).

- [ ] **Step 5: Wire emission into the debate branch of `review_project`**

In `lib/review.sh`, in the `if [[ "$strategy" == "debate" ]]` block, emit **before** `_render_review_json` so the file is always written even if rendering returns 1:

```bash
    _review_emit_verdict "$review_json" "$project_dir"
    _render_review_json "$review_json" "$output_mode" "$project_dir" "$pr_number" "debate" || return 1
```

- [ ] **Step 6: Run the full review suite (no regressions)**

Run: `bash tests/test_review_debate.sh && bash tests/test_review_json_repair.sh && bash tests/test_dev_verdict.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/review.sh tests/test_dev_verdict.sh
git commit -m "feat(review): emit canonical verdict to MRA_REVIEW_RESULT_FILE on debate path"
```

---

## Task 2: Headless write-agent driver (`lib/dev-agent.sh`)

**Files:**
- Create: `lib/dev-agent.sh`
- Test: `tests/test_dev_state_machine.sh` (pure-helper section)

**Interfaces:**
- Produces:
  - `_dev_slugify "<task>"` → echoes a lowercase `a-z0-9-` slug, ≤50 chars, trimmed.
  - `_dev_parse_sentinel "<agent output>"` → echoes `DONE` or `BLOCKED:<reason>`; absence of a sentinel ⇒ `BLOCKED:no sentinel` (fail-safe).
  - `_dev_run_agent "$dir" "$mode" "$input"` → dispatches `claude -p` (write-enabled) with `agents/sub-agent.md`; echoes raw agent output. `mode` ∈ `implement|fix`. Honors `${MRA_DEV_CLAUDE_BIN:-${MRA_CLAUDE_BIN:-claude}}`, `${MRA_DEV_ALLOWED_TOOLS:-...}`, `${MRA_DEV_IMPLEMENT_MAX_TURNS:-45}`, `${MRA_DEV_FIX_MAX_TURNS:-20}`. (Stubbed in loop tests.)

- [ ] **Step 1: Write the failing test (append to `tests/test_dev_state_machine.sh`)**

Create `tests/test_dev_state_machine.sh`:

```bash
#!/usr/bin/env bash
# Pure helpers + state-machine transitions for `mra dev`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev-agent.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- _dev_slugify ---
assert_eq "slugify lowercases + dashes"   "add-foo-bar"  "$(_dev_slugify 'Add Foo Bar!')"
assert_eq "slugify collapses separators"  "a-b"          "$(_dev_slugify '  a   ///  b  ')"

# --- _dev_parse_sentinel ---
assert_eq "DONE sentinel"        "DONE"               "$(_dev_parse_sentinel 'work done ===MRA-DEV-DONE===')"
assert_eq "BLOCKED carries reason" "BLOCKED:no docker" "$(_dev_parse_sentinel '===MRA-DEV-BLOCKED: no docker===')"
assert_eq "missing sentinel fail-safe" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'I analyzed but stopped')"
# DONE token must not be inferred from prose (false-green guard, mirrors review subsystem)
assert_eq "prose 'done' is not DONE" "BLOCKED:no sentinel" "$(_dev_parse_sentinel 'the task is done now')"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-state-machine tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_dev_state_machine.sh`
Expected: FAIL — `_dev_slugify: command not found`.

- [ ] **Step 3: Implement the pure helpers + driver in `lib/dev-agent.sh`**

```bash
#!/usr/bin/env bash
# Headless write-enabled implement/fix driver for `mra dev`.
# Unlike every other mra claude -p (read-only), this one can Write/Edit/Bash(git)
# so the agent implements and self-commits. Reuses agents/sub-agent.md.

_dev_slugify() {
  local s="$1"
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')
  s="${s#-}"; s="${s%-}"
  printf '%s' "${s:0:50}"
}

# Echo "DONE" or "BLOCKED:<reason>". Explicit sentinel only — never infer from
# prose (the review subsystem abandoned regex-on-prose precisely to kill false greens).
_dev_parse_sentinel() {
  local out="$1" line
  line=$(printf '%s\n' "$out" | grep -oE '===MRA-DEV-DONE===|===MRA-DEV-BLOCKED:[^=]*===' | tail -1 || true)
  if [[ "$line" == *"MRA-DEV-DONE"* ]]; then
    printf 'DONE'
  elif [[ "$line" == *"MRA-DEV-BLOCKED:"* ]]; then
    local reason="${line#*MRA-DEV-BLOCKED:}"; reason="${reason%===}"
    reason=$(printf '%s' "$reason" | sed 's/^ *//;s/ *$//')
    printf 'BLOCKED:%s' "$reason"
  else
    printf 'BLOCKED:no sentinel'
  fi
}

# Dispatch the write-enabled agent. mode=implement|fix. Echoes raw output.
_dev_run_agent() {
  local dir="$1" mode="$2" input="$3"
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local bin="${MRA_DEV_CLAUDE_BIN:-${MRA_CLAUDE_BIN:-claude}}"
  local tools="${MRA_DEV_ALLOWED_TOOLS:-Edit,Write,Read,Grep,Glob,Bash(git:*)}"
  local turns; [[ "$mode" == implement ]] && turns="${MRA_DEV_IMPLEMENT_MAX_TURNS:-45}" || turns="${MRA_DEV_FIX_MAX_TURNS:-20}"
  local lang; lang=$(config_get "outputLanguage" 2>/dev/null); [[ "$lang" == "null" ]] && lang=""
  local verb; [[ "$mode" == implement ]] && verb="Implement this task" || verb="Fix EXACTLY these code-review findings"
  local prompt
  prompt=$(cat <<PROMPT
You are operating headlessly inside ONE repository on a branch that ALREADY EXISTS.
Do NOT create a branch. Do NOT run \`mra test\` or any test suite — there is NO test gate.
Ignore any test-driven-development or Docker test steps in your base instructions.
${verb}:

${input}

Make surgical changes only. Stage and commit your work yourself with git (never \`git add -A\`).
When finished and committed, print on its own line: ===MRA-DEV-DONE===
If you cannot proceed, print: ===MRA-DEV-BLOCKED: <one-line reason>===
${lang:+All prose output in ${lang}; keep the sentinel tokens in English.}
PROMPT
)
  "$bin" -p "$prompt" \
    --add-dir "$dir" \
    --append-system-prompt-file "$mra_dir/agents/sub-agent.md" \
    --allowedTools "$tools" \
    --setting-sources project \
    --max-turns "$turns" < /dev/null 2>&1 || true
}
```

> Note (critic gap §10-6): the prompt explicitly neutralizes sub-agent.md's TDD-first, Docker-test, DONE-after-tests, and branch-creation mandates.

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/test_dev_state_machine.sh`
Expected: PASS (slugify + sentinel cases).

- [ ] **Step 5: Commit**

```bash
git add lib/dev-agent.sh tests/test_dev_state_machine.sh
git commit -m "feat(dev): write-enabled headless agent driver + slug/sentinel helpers"
```

---

## Task 3: Verdict + review helpers (`lib/dev.sh`)

**Files:**
- Create: `lib/dev.sh` (helpers only this task)
- Test: `tests/test_dev_verdict.sh` (append)

**Interfaces:**
- Consumes: `$MRA_REVIEW_RESULT_FILE`; `review_project` (review.sh); `$DEV_AUTO_APPROVE` (global).
- Produces:
  - `_dev_read_status "$rf"` → echoes `.status`, or `REVIEW_INCOMPLETE` if empty/missing/unparseable.
  - `_dev_fingerprint "$rf"` → echoes sorted `path:line:severity,` of `.comments[]` (empty string if none).
  - `_dev_review_one "$workspace" "$project" "$mode" "$base" "$pr_n"` (`mode`∈`code|pr`) → forces debate + `VERIFY_APPROVE=1` (+`PR_CONTEXT=0` and conditional `ALLOW_APPROVE=1` on `pr`), calls `review_project … 1>&2 || true`, echoes `STATUS|FINGERPRINT`.

- [ ] **Step 1: Write the failing tests (append to `tests/test_dev_verdict.sh`, before the footer)**

```bash
# --- _dev_read_status / _dev_fingerprint (source dev.sh) ---
source "$SCRIPT_DIR/lib/dev.sh"

printf '{"status":"APPROVED","comments":[]}' > "$RF"
assert_eq "read_status approved" "APPROVED" "$(_dev_read_status "$RF")"
: > "$RF"
assert_eq "read_status empty -> INCOMPLETE" "REVIEW_INCOMPLETE" "$(_dev_read_status "$RF")"
printf 'garbage' > "$RF"
assert_eq "read_status garbage -> INCOMPLETE" "REVIEW_INCOMPLETE" "$(_dev_read_status "$RF")"

printf '%s' '{"status":"CHANGES_REQUESTED","comments":[{"path":"b.ts","line":9,"severity":"HIGH","body":"y"},{"path":"a.ts","line":2,"severity":"LOW","body":"x"}]}' > "$RF"
assert_eq "fingerprint sorted" "a.ts:2:LOW,b.ts:9:HIGH," "$(_dev_fingerprint "$RF")"

# --- _dev_review_one reads ONLY the file, never the exit code (false-green firewall) ---
# Stub review_project: writes CHANGES_REQUESTED to RF but RETURNS 1 (the malformed-path
# return) — the loop must still see CHANGES_REQUESTED, not abort, under set -e.
review_project() { printf '%s' '{"status":"CHANGES_REQUESTED","comments":[]}' > "$MRA_REVIEW_RESULT_FILE"; return 1; }
out=$(DEV_AUTO_APPROVE=false _dev_review_one ws proj code main "")
assert_eq "review_one trusts file not exit code" "CHANGES_REQUESTED" "${out%%|*}"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_dev_verdict.sh`
Expected: FAIL — `_dev_read_status: command not found`.

- [ ] **Step 3: Implement helpers in `lib/dev.sh`**

```bash
#!/usr/bin/env bash
# Deterministic implement -> review -> fix -> PR loop for `mra dev`.
# Verdict comes ONLY from $MRA_REVIEW_RESULT_FILE; exit code is never the gate.

_dev_read_status() {
  local rf="$1" st
  st=$(jq -r '.status // empty' "$rf" 2>/dev/null || true)
  [[ -n "$st" ]] && printf '%s' "$st" || printf 'REVIEW_INCOMPLETE'
}

_dev_fingerprint() {
  local rf="$1"
  jq -r '(.comments // [])[] | "\(.path):\(.line):\(.severity)"' "$rf" 2>/dev/null \
    | sort | tr '\n' ',' || true
}

# Run one debate review; emit verdict to RF; echo "STATUS|FINGERPRINT".
# mode=code (local base...HEAD) | pr (post to GitHub PR + verdict).
_dev_review_one() {
  local workspace="$1" project="$2" mode="$3" base="$4" pr_n="$5"
  : > "$MRA_REVIEW_RESULT_FILE"
  local -a rargs=(--strategy debate --base "$base")
  local pr_ctx="" allow=""
  if [[ "$mode" == pr ]]; then
    rargs+=(--pr "$pr_n"); pr_ctx=0
    [[ "${DEV_AUTO_APPROVE:-false}" == true ]] && allow=1
  fi
  # set -e firewall (§10-1): || true so review_project's documented return-1
  # (malformed-JSON path) can never abort the loop before we read the file.
  MRA_REVIEW_VERIFY_APPROVE=1 MRA_REVIEW_PR_CONTEXT="$pr_ctx" MRA_REVIEW_ALLOW_APPROVE="$allow" \
    review_project "$workspace" "$project" "${rargs[@]}" 1>&2 || true
  printf '%s|%s' "$(_dev_read_status "$MRA_REVIEW_RESULT_FILE")" "$(_dev_fingerprint "$MRA_REVIEW_RESULT_FILE")"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_dev_verdict.sh`
Expected: PASS (all verdict + review_one cases).

- [ ] **Step 5: Commit**

```bash
git add lib/dev.sh tests/test_dev_verdict.sh
git commit -m "feat(dev): result-file verdict + fingerprint + review_one helpers"
```

---

## Task 4: State machine — validate, branch, implement, code-review loop (`lib/dev.sh`)

**Files:**
- Modify: `lib/dev.sh` (add `_dev_validate`, `_dev_progress`, `_dev_escalate`, `_dev_report`, `dev_project`)
- Test: `tests/test_dev_state_machine.sh` (append loop-transition section)

**Interfaces:**
- Consumes: `_dev_run_agent`/`_dev_parse_sentinel` (Task 2); `_dev_review_one` (Task 3); `resolve_project_dir`, `pkb_exists`/`pkb_generate`, `mra_log`, `notify_escalation` (existing libs); globals `DEV_BASE DEV_MAX_ROUNDS DEV_RETRY_CAP DEV_GLOBAL_CAP DEV_NO_PR DEV_AUTO_APPROVE DEV_RESUME DEV_DRY_RUN`.
- Produces: `dev_project "$workspace" "$project" "$task"` → runs steps 0–3; on success echoes `DEV_RESULT status=APPROVED stage=code rounds=<n>` and returns 0; on any escalation echoes `DEV_RESULT status=ESCALATED stage=<s> reason=<r>` and returns 2. `_dev_progress "$dir" "$base"` → returns 0 iff HEAD moved and `base...HEAD` non-empty (stubbable).

- [ ] **Step 1: Write the failing loop tests (append to `tests/test_dev_state_machine.sh`, before footer)**

```bash
# --- loop transitions (source dev.sh; stub side-effects) ---
source "$SCRIPT_DIR/lib/dev.sh"
export MRA_REVIEW_RESULT_FILE="$(mktemp)"
DEV_BASE="origin/main"; DEV_MAX_ROUNDS=3; DEV_RETRY_CAP=2; DEV_GLOBAL_CAP=12
DEV_NO_PR=true; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false

# Stub all side-effecting / external calls.
resolve_project_dir() { printf '/fake/%s' "$2"; }
_dev_ensure_pkb() { return 0; }
mra_log()     { :; }
notify_escalation() { :; }
_dev_validate(){ return 0; }
_dev_branch()  { return 0; }
_dev_progress(){ return 0; }            # implement/fix always "made progress"
_dev_run_agent(){ printf '===MRA-DEV-DONE==='; }

# Scripted review verdicts: pop one per _dev_review_one call.
REVIEWS=(); RI=0
_dev_review_one() { local v="${REVIEWS[$RI]}"; RI=$((RI+1)); printf '%s' "$v"; }

run_dev() { RI=0; dev_project ws proj "do a thing"; }

# 1. First review APPROVED -> success, 0 rounds.
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "approved-first succeeds" "0" "$rc"
[[ "$out" == *"status=APPROVED"* ]] && ok "reports APPROVED" || fail "missing APPROVED: $out"

# 2. CHANGES_REQUESTED then APPROVED -> success after 1 fix round.
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "APPROVED|"); out=$(run_dev); rc=$?
assert_eq "changes->approved succeeds" "0" "$rc"

# 3. CHANGES_REQUESTED forever with max-rounds 2 -> ESCALATED, rc 2, no infinite loop.
DEV_MAX_ROUNDS=2
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "CHANGES_REQUESTED|b:2:HIGH," "CHANGES_REQUESTED|c:3:HIGH,")
out=$(run_dev); rc=$?
assert_eq "round cap escalates" "2" "$rc"
[[ "$out" == *"status=ESCALATED"* ]] && ok "reports ESCALATED" || fail "missing ESCALATED: $out"
DEV_MAX_ROUNDS=3

# 4. Identical fingerprint twice -> no-progress escalate (before burning rounds).
REVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "CHANGES_REQUESTED|a:1:HIGH,"); out=$(run_dev); rc=$?
assert_eq "no-progress escalates" "2" "$rc"
[[ "$out" == *"no progress"* ]] && ok "reports no-progress reason" || fail "missing no-progress: $out"

# 5. REVIEW_INCOMPLETE beyond retry cap -> escalate, NEVER approved.
DEV_RETRY_CAP=1
REVIEWS=("REVIEW_INCOMPLETE|" "REVIEW_INCOMPLETE|"); out=$(run_dev); rc=$?
assert_eq "incomplete escalates, never approves" "2" "$rc"
DEV_RETRY_CAP=2

# 6. Implement BLOCKED -> escalate before any review.
_dev_run_agent(){ printf '===MRA-DEV-BLOCKED: no creds==='; }
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "implement BLOCKED escalates" "2" "$rc"
[[ "$out" == *"no creds"* ]] && ok "carries BLOCKED reason" || fail "missing reason: $out"
_dev_run_agent(){ printf '===MRA-DEV-DONE==='; }

# 7. Implement empty diff -> escalate before review.
_dev_progress(){ return 1; }
REVIEWS=("APPROVED|"); out=$(run_dev); rc=$?
assert_eq "empty diff escalates" "2" "$rc"
_dev_progress(){ return 0; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_dev_state_machine.sh`
Expected: FAIL — `dev_project: command not found`.

- [ ] **Step 3: Implement `dev_project` (+ helpers) in `lib/dev.sh`**

```bash
_dev_progress() { # HEAD moved AND base...HEAD non-empty
  local dir="$1" base="$2"
  [[ -n "$(git -C "$dir" rev-list "$base"..HEAD 2>/dev/null)" ]] || return 1
  [[ -n "$(git -C "$dir" diff "$base"...HEAD 2>/dev/null)" ]] || return 1
}

_dev_escalate() { # workspace project stage reason  -> echoes DEV_RESULT, returns 2
  local workspace="$1" project="$2" stage="$3" reason="$4"
  mra_log "$workspace" "$project" "ESCALATED [$stage]: $reason" >/dev/null 2>&1 || true
  notify_escalation "$workspace" "$project" "$reason" >/dev/null 2>&1 || true
  log_error "[escalate] $project ($stage): $reason" "dev"
  printf 'DEV_RESULT status=ESCALATED stage=%s reason=%s\n' "$stage" "$reason"
  return 2
}

_dev_report() { # stage code_rounds  -> echoes DEV_RESULT, returns 0
  log_success "$2 review round(s); branch ready" "dev"
  printf 'DEV_RESULT status=APPROVED stage=%s rounds=%s\n' "$1" "$2"
  return 0
}

dev_project() {
  local workspace="$1" project="$2" task="$3"
  local dir base slug v fp
  dir=$(resolve_project_dir "$workspace" "$project") || { log_error "unknown project: $project" "dev"; return 1; }
  base="${DEV_BASE:-origin/$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@origin/@@' || echo main)}"
  _dev_validate "$dir" "$base" || return 1
  slug=$(_dev_slugify "$task")
  [[ "${DEV_DRY_RUN:-false}" == true ]] && { log_info "[dry-run] would work on mra/$slug from $base" "dev"; return 0; }

  # 1 BRANCH (dev owns it; fork from base, not current HEAD)
  _dev_branch "$dir" "$slug" "$base" || return 1

  # 2 IMPLEMENT
  local out st
  out=$(_dev_run_agent "$dir" implement "$task")
  st=$(_dev_parse_sentinel "$out")
  [[ "$st" == BLOCKED:* ]] && { _dev_escalate "$workspace" "$project" implement "${st#BLOCKED:}"; return 2; }
  _dev_progress "$dir" "$base" || { _dev_escalate "$workspace" "$project" implement "no diff produced"; return 2; }
  _dev_ensure_pkb "$dir" "$project"   # build-if-missing before first review (D14)

  # 3 CODE-REVIEW LOOP (three-valued; bounded)
  local round=0 retry=0 prev_fp="" global=0
  while :; do
    global=$((global+1)); [[ "$global" -gt "${DEV_GLOBAL_CAP:-12}" ]] && { _dev_escalate "$workspace" "$project" code "global review ceiling"; return 2; }
    IFS='|' read -r v fp <<<"$(_dev_review_one "$workspace" "$project" code "$base" "")"
    case "$v" in
      APPROVED) break ;;
      COMMENT|REVIEW_INCOMPLETE)
        retry=$((retry+1)); [[ "$retry" -gt "${DEV_RETRY_CAP:-2}" ]] && { _dev_escalate "$workspace" "$project" code "review never completed"; return 2; }
        continue ;;
      CHANGES_REQUESTED)
        [[ -n "$prev_fp" && "$fp" == "$prev_fp" ]] && { _dev_escalate "$workspace" "$project" code "no progress: identical findings"; return 2; }
        out=$(_dev_run_agent "$dir" fix "$(jq -r '(.comments//[])[]|"- [\(.severity)] \(.path):\(.line) — \(.body)"' "$MRA_REVIEW_RESULT_FILE" 2>/dev/null || true)")
        st=$(_dev_parse_sentinel "$out")
        [[ "$st" == BLOCKED:* ]] && { _dev_escalate "$workspace" "$project" fix "${st#BLOCKED:}"; return 2; }
        _dev_progress "$dir" "$base" || { _dev_escalate "$workspace" "$project" fix "fix produced no diff"; return 2; }
        prev_fp="$fp"; round=$((round+1))
        [[ "$round" -ge "${DEV_MAX_ROUNDS:-3}" ]] && { _dev_escalate "$workspace" "$project" code "code-review cap"; return 2; }
        continue ;;
      *) _dev_escalate "$workspace" "$project" code "unknown verdict: $v"; return 2 ;;
    esac
  done

  # PR + pr-review loop inserted in Task 5. For now, stop at local APPROVED.
  if [[ "${DEV_NO_PR:-false}" == true ]]; then _dev_report code "$round"; return 0; fi
  _dev_report code "$round"; return 0
}
```

Add minimal `_dev_validate` / `_dev_branch` (real side-effects; stubbed in tests):

```bash
_dev_validate() {
  local dir="$1" base="$2"
  [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && { log_error "working tree not clean: $dir" "dev"; return 1; }
  local cur protected; cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  for protected in main master develop production; do
    [[ "$cur" == "$protected" ]] && { log_error "refusing to run on protected branch: $cur" "dev"; return 1; }
  done
  return 0
}

_dev_branch() {
  local dir="$1" slug="$2" base="$3"
  git -C "$dir" fetch --quiet origin 2>/dev/null || true
  if git -C "$dir" show-ref --verify --quiet "refs/heads/mra/$slug" && [[ "${DEV_RESUME:-false}" != true ]]; then
    log_error "branch mra/$slug exists; pass --resume" "dev"; return 1
  fi
  git -C "$dir" checkout -B "mra/$slug" "$base" >/dev/null 2>&1 || { log_error "cannot create mra/$slug from $base" "dev"; return 1; }
}

# Build-if-missing PKB before the first review (D14). Uses the real pkb helpers
# (pkb_exists / pkb_generate, as called by `mra analyze`). Non-fatal on failure —
# a missing PKB just risks REVIEW_INCOMPLETE, which the loop already handles.
_dev_ensure_pkb() {
  local dir="$1" project="$2"
  pkb_exists "$dir" 2>/dev/null && return 0
  pkb_generate "$project" "$dir" "${DEV_MODEL:-sonnet}" "" >/dev/null 2>&1 || true
}
```

> Note: the protected-branch check is intentionally on the *current* branch (you must not be sitting on `main` when you start); `_dev_branch` then forks the new branch from `origin/<default>`, never from the stale current HEAD (D12).

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_dev_state_machine.sh`
Expected: PASS (all 7 transition cases + earlier helper cases).

- [ ] **Step 5: Commit**

```bash
git add lib/dev.sh tests/test_dev_state_machine.sh
git commit -m "feat(dev): dev_project state machine — validate, branch, implement, code-review loop"
```

---

## Task 5: PR creation + pr-review loop (`lib/dev.sh`)

**Files:**
- Modify: `lib/dev.sh` (replace the dev_project tail; add `_dev_push`, `_dev_pr_open`, `_dev_pr_dismiss_prior`, `_dev_pr_loop`)
- Test: `tests/test_dev_state_machine.sh` (append pr-review section)

**Interfaces:**
- Consumes: `mra_pr_create` (workflow.sh), `gh`, `git`; the code-review loop body (extract a reusable `_dev_fix_round`).
- Produces:
  - `_dev_push "$dir" "$slug"` → `git push -u origin mra/<slug>` (stubbable).
  - `_dev_pr_open "$dir" "$slug" "$title" "$body"` → echoes the PR number (existing → `gh pr view`, else `mra_pr_create`).
  - `_dev_pr_dismiss_prior "$dir" "$pr_n"` → dismisses/replaces the bot's prior MRA review so exactly one pinned review persists (§10-3).
  - `_dev_pr_loop "$workspace" "$project" "$dir" "$base" "$pr_n"` → pr-review loop; returns 0 on APPROVED, 2 on escalate.

- [ ] **Step 1: Write the failing pr-review tests (append to `tests/test_dev_state_machine.sh`, before footer)**

```bash
# --- pr-review loop ---
DEV_NO_PR=false
_dev_push() { PUSHES=$((PUSHES+1)); return 0; }
_dev_pr_open() { printf '42'; }
_dev_pr_dismiss_prior() { :; }
PREVIEWS=(); PRI=0
# reuse _dev_review_one stub but with a separate script for pr mode via mode arg
_dev_review_one() { local m="$3"; if [[ "$m" == pr ]]; then local v="${PREVIEWS[$PRI]}"; PRI=$((PRI+1)); printf '%s' "$v"; else printf 'APPROVED|'; fi; }
run_pr() { RI=0; PRI=0; PUSHES=0; dev_project ws proj "thing"; }

# 8. PR review approved first time -> success; pushed at least once before review.
PREVIEWS=("APPROVED|"); out=$(run_pr); rc=$?
assert_eq "pr-review approved succeeds" "0" "$rc"
[[ "$PUSHES" -ge 1 ]] && ok "pushed before pr review" || fail "no push before pr review"

# 9. PR review CHANGES then APPROVED -> push happens at top of EACH iteration (>=2).
PREVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "APPROVED|"); out=$(run_pr); rc=$?
assert_eq "pr changes->approved succeeds" "0" "$rc"
[[ "$PUSHES" -ge 2 ]] && ok "push at top of each pr iteration" || fail "expected >=2 pushes got $PUSHES"

# 10. PR review never clean within cap -> ESCALATED.
DEV_MAX_ROUNDS=1
PREVIEWS=("CHANGES_REQUESTED|a:1:HIGH," "CHANGES_REQUESTED|b:2:HIGH,"); out=$(run_pr); rc=$?
assert_eq "pr cap escalates" "2" "$rc"
DEV_MAX_ROUNDS=3
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_dev_state_machine.sh`
Expected: FAIL — pr-review cases fail (no PR loop yet; `dev_project` returns at the code-review report).

- [ ] **Step 3: Replace the dev_project tail and add the PR helpers**

In `dev.sh`, replace:

```bash
  # PR + pr-review loop inserted in Task 5. For now, stop at local APPROVED.
  if [[ "${DEV_NO_PR:-false}" == true ]]; then _dev_report code "$round"; return 0; fi
  _dev_report code "$round"; return 0
}
```

with:

```bash
  # 4 PR
  if [[ "${DEV_NO_PR:-false}" == true ]]; then _dev_report code "$round"; return 0; fi
  _dev_push "$dir" "$slug" || { _dev_escalate "$workspace" "$project" pr "push failed"; return 2; }
  local pr_n; pr_n=$(_dev_pr_open "$dir" "$slug" "mra: ${task:0:60}" "$(_dev_pr_body "$task")")
  [[ -z "$pr_n" ]] && { _dev_escalate "$workspace" "$project" pr "could not open PR"; return 2; }

  # 5 PR-REVIEW LOOP
  _dev_pr_loop "$workspace" "$project" "$dir" "$base" "$pr_n" || return 2
  _dev_report pr "$round"; return 0
}

_dev_push() { git -C "$1" push -u origin "mra/$2" >/dev/null 2>&1; }

_dev_pr_body() { printf '## Summary\n\n%s\n\n## Test Plan\n- [ ] review findings addressed by mra dev loop\n' "$1"; }

_dev_pr_open() { # dir slug title body -> echo PR number
  local dir="$1" slug="$2" title="$3" body="$4" n
  n=$( (cd "$dir" && gh pr view "mra/$slug" --json number -q .number) 2>/dev/null || true)
  if [[ -z "$n" ]]; then
    mra_pr_create "$dir" "$title" "$body" >/dev/null 2>&1 || true
    n=$( (cd "$dir" && gh pr view "mra/$slug" --json number -q .number) 2>/dev/null || true)
  fi
  printf '%s' "$n"
}

# Single pinned review (§10-3): dismiss the bot's prior MRA reviews so the PR
# carries exactly one evolving review instead of N stacked ones.
_dev_pr_dismiss_prior() {
  local dir="$1" pr_n="$2"
  ( cd "$dir" && gh pr view "$pr_n" --json reviews \
      -q '.reviews[] | select(.author.login=="'"${MRA_BOT_LOGIN:-github-actions[bot]}"'") | .id' 2>/dev/null \
    | while read -r rid; do gh api -X PUT "repos/{owner}/{repo}/pulls/$pr_n/reviews/$rid/dismissals" -f message="superseded by mra dev" >/dev/null 2>&1 || true; done ) || true
}

_dev_pr_loop() {
  local workspace="$1" project="$2" dir="$3" base="$4" pr_n="$5"
  local round=0 retry=0 prev_fp="" v fp out st global=0
  while :; do
    global=$((global+1)); [[ "$global" -gt "${DEV_GLOBAL_CAP:-12}" ]] && { _dev_escalate "$workspace" "$project" pr "global review ceiling"; return 2; }
    _dev_push "$dir" "$(basename "$(git -C "$dir" symbolic-ref --short HEAD)")" >/dev/null 2>&1 || _dev_push "$dir" "${prev_fp:-x}" || true
    _dev_pr_dismiss_prior "$dir" "$pr_n"
    IFS='|' read -r v fp <<<"$(_dev_review_one "$workspace" "$project" pr "$base" "$pr_n")"
    case "$v" in
      APPROVED) return 0 ;;
      COMMENT|REVIEW_INCOMPLETE)
        retry=$((retry+1)); [[ "$retry" -gt "${DEV_RETRY_CAP:-2}" ]] && { _dev_escalate "$workspace" "$project" pr "pr-review never completed"; return 2; }
        continue ;;
      CHANGES_REQUESTED)
        [[ -n "$prev_fp" && "$fp" == "$prev_fp" ]] && { _dev_escalate "$workspace" "$project" pr "no progress"; return 2; }
        out=$(_dev_run_agent "$dir" fix "$(jq -r '(.comments//[])[]|"- [\(.severity)] \(.path):\(.line) — \(.body)"' "$MRA_REVIEW_RESULT_FILE" 2>/dev/null || true)")
        st=$(_dev_parse_sentinel "$out")
        { [[ "$st" == BLOCKED:* ]] || ! _dev_progress "$dir" "$base"; } && { _dev_escalate "$workspace" "$project" pr "fix blocked or empty"; return 2; }
        prev_fp="$fp"; round=$((round+1))
        [[ "$round" -ge "${DEV_MAX_ROUNDS:-3}" ]] && { _dev_escalate "$workspace" "$project" pr "pr-review cap"; return 2; }
        continue ;;  # next iteration's top-of-loop push + --pr review IS the re-confirm (§10-2)
      *) _dev_escalate "$workspace" "$project" pr "unknown verdict: $v"; return 2 ;;
    esac
  done
}
```

> The push at the top of every iteration (D11) keeps the GitHub head current so `post_inline_review`'s hunk filter matches; `_dev_pr_dismiss_prior` before each post enforces the single pinned review (§10-3). For the test, `_dev_push` is stubbed to count; in production the basename-derived slug push is the real invariant — simplify the production line to `_dev_push "$dir" "$slug"` by passing `slug` into `_dev_pr_loop` if you prefer (keep the stub seam).

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_dev_state_machine.sh`
Expected: PASS (cases 8–10 + all earlier).

- [ ] **Step 5: Commit**

```bash
git add lib/dev.sh tests/test_dev_state_machine.sh
git commit -m "feat(dev): PR creation + pr-review loop with top-of-loop push and single pinned review"
```

---

## Task 6: CLI dispatch + flag parsing (`bin/mra.sh`)

**Files:**
- Modify: `bin/mra.sh` (source the two libs near the other `source` lines ~6–63; add the `dev)` case after `plan)`; add a usage line)
- Test: `tests/test_dev_cli.sh`

**Interfaces:**
- Consumes: `resolve_workspace`, `resolve_project_dir`, `validate_project_name`, `check_gh_auth` (existing), `dev_project` (Task 4/5).
- Produces: `mra dev <project> "<task>" [--base R] [--model M] [--max-rounds N] [--no-pr] [--auto-approve] [--resume] [--dry-run]`. A parser-only helper `_dev_parse_args "$@"` (defined in `lib/dev.sh`) sets the `DEV_*` globals + `DEV_PROJECT`/`DEV_TASK`; returns non-zero with a usage error on bad input. (Tested directly; bin/mra.sh just calls it then `dev_project`.)

- [ ] **Step 1: Write the failing CLI tests**

Create `tests/test_dev_cli.sh`:

```bash
#!/usr/bin/env bash
# Arg-parsing + terminal-semantics for `mra dev` (parser tested directly).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

reset() { DEV_PROJECT=""; DEV_TASK=""; DEV_BASE=""; DEV_MODEL=""; DEV_MAX_ROUNDS=""; DEV_NO_PR=false; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false; }

# 1. project + multi-word task accumulate; defaults applied.
reset; _dev_parse_args api add a new field; rc=$?
assert_eq "parse ok rc" "0" "$rc"
assert_eq "project parsed" "api" "$DEV_PROJECT"
assert_eq "task accumulated" "add a new field" "$DEV_TASK"
assert_eq "default model sonnet" "sonnet" "$DEV_MODEL"
assert_eq "default max-rounds 3" "3" "$DEV_MAX_ROUNDS"

# 2. flags parsed.
reset; _dev_parse_args api "do x" --base develop --model opus --max-rounds 5 --no-pr --auto-approve --resume --dry-run
assert_eq "base" "develop" "$DEV_BASE"
assert_eq "model" "opus" "$DEV_MODEL"
assert_eq "max-rounds" "5" "$DEV_MAX_ROUNDS"
assert_eq "no-pr" "true" "$DEV_NO_PR"
assert_eq "auto-approve" "true" "$DEV_AUTO_APPROVE"
assert_eq "resume" "true" "$DEV_RESUME"
assert_eq "dry-run" "true" "$DEV_DRY_RUN"

# 3. missing task -> nonzero.
reset; _dev_parse_args api >/dev/null 2>&1; assert_eq "missing task fails" "1" "$?"
# 4. missing project+task -> nonzero.
reset; _dev_parse_args >/dev/null 2>&1; assert_eq "missing all fails" "1" "$?"
# 5. non-positive max-rounds rejected.
reset; _dev_parse_args api "x" --max-rounds 0 >/dev/null 2>&1; assert_eq "max-rounds 0 rejected" "1" "$?"
reset; _dev_parse_args api "x" --max-rounds abc >/dev/null 2>&1; assert_eq "max-rounds abc rejected" "1" "$?"
# 6. --base requires a value.
reset; _dev_parse_args api "x" --base >/dev/null 2>&1; assert_eq "base arity checked" "1" "$?"
# 7. unknown flag rejected.
reset; _dev_parse_args api "x" --frobnicate >/dev/null 2>&1; assert_eq "unknown flag rejected" "1" "$?"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-cli tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_dev_cli.sh`
Expected: FAIL — `_dev_parse_args: command not found`.

- [ ] **Step 3: Implement `_dev_parse_args` in `lib/dev.sh`**

```bash
_dev_parse_args() {
  DEV_PROJECT=""; DEV_TASK=""; DEV_BASE="${DEV_BASE:-}"; DEV_MODEL="sonnet"; DEV_MAX_ROUNDS="3"
  DEV_NO_PR=false; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)       [[ $# -lt 2 ]] && { log_error "--base requires a value" "dev"; return 1; }; DEV_BASE="$2"; shift 2 ;;
      --model)      [[ $# -lt 2 ]] && { log_error "--model requires a value" "dev"; return 1; }; DEV_MODEL="$2"; shift 2 ;;
      --max-rounds) [[ $# -lt 2 ]] && { log_error "--max-rounds requires a value" "dev"; return 1; }
                    [[ "$2" =~ ^[1-9][0-9]*$ ]] || { log_error "--max-rounds must be a positive integer" "dev"; return 1; }
                    DEV_MAX_ROUNDS="$2"; shift 2 ;;
      --no-pr)        DEV_NO_PR=true; shift ;;
      --auto-approve) DEV_AUTO_APPROVE=true; shift ;;
      --resume)       DEV_RESUME=true; shift ;;
      --dry-run)      DEV_DRY_RUN=true; shift ;;
      -*) log_error "unknown option: $1" "dev"; return 1 ;;
      *)  if [[ -z "$DEV_PROJECT" ]]; then DEV_PROJECT="$1"; else DEV_TASK+="${DEV_TASK:+ }$1"; fi; shift ;;
    esac
  done
  [[ -z "$DEV_PROJECT" || -z "$DEV_TASK" ]] && { log_error "usage: mra dev <project> \"<task>\" [--base R] [--model M] [--max-rounds N] [--no-pr] [--auto-approve] [--resume] [--dry-run]" "dev"; return 1; }
  return 0
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_dev_cli.sh`
Expected: PASS (all 7 groups).

- [ ] **Step 5: Wire the dispatch case into `bin/mra.sh`**

Add to the `source` block (near line 26):

```bash
source "$MRA_DIR/lib/dev-agent.sh"
source "$MRA_DIR/lib/dev.sh"
```

Add the case after the `plan)` case closes:

```bash
    dev)
      shift
      _dev_parse_args "$@" || exit 1
      local workspace; workspace=$(resolve_workspace)
      validate_project_name "$DEV_PROJECT" || exit 1
      [[ "$DEV_NO_PR" == true ]] || check_gh_auth || exit 1
      dev_project "$workspace" "$DEV_PROJECT" "$DEV_TASK"
      ;;
```

Add a usage help line near the other command help (bin/mra.sh ~65–123):

```bash
  dev <project> "<task>" [--base R] [--max-rounds N] [--no-pr] [--auto-approve] [--resume] [--dry-run]
                                Autonomous implement->review->fix->PR loop (headless)
```

- [ ] **Step 6: Smoke-test dispatch (dry-run, no mutation)**

Run: `bash bin/mra.sh dev some-project "noop" --dry-run` (expect a `[dry-run] would work on mra/noop …` line and exit 0, assuming the project resolves; otherwise an `unknown project` error — both prove the case is wired).

- [ ] **Step 7: Commit**

```bash
git add bin/mra.sh lib/dev.sh tests/test_dev_cli.sh
git commit -m "feat(dev): mra dev CLI dispatch + flag parser"
```

---

## Task 7: Teardown — background-job reaping + RF cleanup (`lib/dev.sh`)

**Files:**
- Modify: `lib/dev.sh` (add `_dev_teardown`; call it from `_dev_escalate` and `_dev_report`)
- Test: `tests/test_dev_state_machine.sh` (append)

**Interfaces:**
- Produces: `_dev_teardown` → waits/kills background `_review_pkb_auto_update &` jobs and removes/unsets `$MRA_REVIEW_RESULT_FILE`. Called on **every** terminal path so a mid-loop death never orphans the PKB jobs review.sh spawns (D13).

- [ ] **Step 1: Write the failing test (append before footer in `tests/test_dev_state_machine.sh`)**

```bash
# --- teardown runs on every terminal path ---
TEARDOWN_RAN=0
_dev_teardown() { TEARDOWN_RAN=$((TEARDOWN_RAN+1)); }   # observe; real impl tested by smoke
# success path
DEV_NO_PR=true; REVIEWS=("APPROVED|"); RI=0; TEARDOWN_RAN=0; dev_project ws proj "x" >/dev/null; assert_eq "teardown on success" "1" "$TEARDOWN_RAN"
# escalate path
REVIEWS=("REVIEW_INCOMPLETE|" "REVIEW_INCOMPLETE|" "REVIEW_INCOMPLETE|"); DEV_RETRY_CAP=1; RI=0; TEARDOWN_RAN=0; dev_project ws proj "x" >/dev/null; assert_eq "teardown on escalate" "1" "$TEARDOWN_RAN"
DEV_RETRY_CAP=2
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_dev_state_machine.sh`
Expected: FAIL — teardown count is `0` (not yet called from `_dev_report`/`_dev_escalate`).

- [ ] **Step 3: Implement `_dev_teardown` and call it on terminal paths**

Add to `lib/dev.sh`:

```bash
# Reap background _review_pkb_auto_update jobs review.sh spawns, and drop the
# verdict channel — called on EVERY terminal path so a mid-loop death (or normal
# exit) never orphans them.
_dev_teardown() {
  local p
  for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "${MRA_REVIEW_RESULT_FILE:-}" && -e "$MRA_REVIEW_RESULT_FILE" ]] && rm -f "$MRA_REVIEW_RESULT_FILE"
  unset MRA_REVIEW_RESULT_FILE
}
```

In `_dev_escalate`, add `_dev_teardown` just before `return 2`; in `_dev_report`, add `_dev_teardown` just before `return 0`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_dev_state_machine.sh`
Expected: PASS (teardown counted on both paths + all prior cases).

- [ ] **Step 5: Commit**

```bash
git add lib/dev.sh tests/test_dev_state_machine.sh
git commit -m "feat(dev): teardown reaps background PKB jobs + clears verdict channel on every exit"
```

---

## Task 8: Full suite green + docs + HTML render

**Files:**
- Modify: `README.md` (command reference table — add the `dev` row under "AI & Development")
- Modify: `CHANGELOG.md` (add an entry)
- Test: the whole `tests/` suite via `test.sh`

- [ ] **Step 1: Run the full shell suite**

Run: `bash test.sh`
Expected: `tests/test_dev_verdict.sh`, `tests/test_dev_state_machine.sh`, `tests/test_dev_cli.sh` all green; no regressions in existing tests. Summary line `shell tests: N passed, 0 failed`.

- [ ] **Step 2: Add the README command-reference row**

Under the **AI & Development** table in `README.md`, add:

```markdown
| `mra dev <project> "<task>" [--no-pr] [--auto-approve] [--resume] [--dry-run]` | Autonomous headless implement→review→fix→PR loop (single repo; debate+verifier gate) |
```

- [ ] **Step 3: Add a CHANGELOG entry**

Add under the top (unreleased/next) section of `CHANGELOG.md`:

```markdown
### Added
- `mra dev <project> "<task>"` — deterministic, fully-headless implement→review→fix→PR loop. Forces the debate+verifier review as the gate; transports the verdict via `$MRA_REVIEW_RESULT_FILE` (exit code is never trusted); three-valued APPROVED/CHANGES_REQUESTED/REVIEW_INCOMPLETE switch bounded by round/retry/global caps + a no-progress fingerprint. Default posts a COMMENT review (binding GitHub APPROVE is opt-in via `--auto-approve`). Env knobs: `MRA_DEV_IMPLEMENT_MAX_TURNS`, `MRA_DEV_FIX_MAX_TURNS`, `MRA_DEV_MAX_REVIEWS`, `MRA_DEV_ALLOWED_TOOLS`, `MRA_DEV_CLAUDE_BIN`. Cost accounting deferred.
```

- [ ] **Step 4: Re-render the design spec HTML (house rule)**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-06-26-mra-dev-loop-design.md`
Expected: `✓ … -> ….html`.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md docs/superpowers/specs/2026-06-26-mra-dev-loop-design.html
git commit -m "docs(dev): document mra dev in README + CHANGELOG"
```

- [ ] **Step 6: Final verification**

Run: `bash test.sh`
Expected: all shell tests pass (`0 failed`). Report the summary line verbatim as the completion evidence.

---

## Backlog (explicitly deferred, not in this plan)

- Cross-repo orchestration (dependency ordering, consumer integration tests, multi-PR chaining).
- Test-suite gate (`mra test` as a pass condition).
- Cost accounting / `--output-format json` token reporting (`record_usage` has zero callers today).
- Per-phase `claude -p` watchdog timeout → `BLOCKED` (the wall-clock ceiling bounds the whole run but not a single hung agent).
- Orchestrator-style per-round PR posting with a true distinct pr-reviewer persona (v1 keeps a single pinned review).
- `slugify` collision UX for genuinely different tasks mapping to the same `mra/<slug>`.
