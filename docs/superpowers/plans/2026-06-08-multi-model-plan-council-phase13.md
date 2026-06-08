# mra plan --dual (Phase 13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra plan --dual` — an opt-in council that runs each persona on both claude and codex, then synthesizes with explicit cross-model agree/disagree.

**Architecture:** A new `lib/model-provider.sh` provides `call_model <provider> <prompt> <model> <project_dir> <add_dirs> <max_turns>` (claude = existing flags incl. a parameterized `--max-turns`; codex = `codex exec -s read-only` with cwd = project dir; binary names env-overridable via `MRA_CLAUDE_BIN`/`MRA_CODEX_BIN`) plus `ensure_codex_available`. `run_plan_council` routes every expert AND synth call through `call_model`; a new `dual` param makes it run claude+codex per persona, tag blocks by provider, write a missing-side sentinel on a failed/empty call, and use an agree/disagree synth template. Default (`dual=false`) reproduces today's claude-only council byte-for-byte.

**Tech Stack:** Bash (`lib/model-provider.sh`, `lib/plan-council.sh`, `bin/mra.sh`), the `claude` and `codex` CLIs, custom PASS/FAIL harness (`tests/test_plan_council.sh`).

**Spec:** `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` §21.

---

## File Structure

- **`lib/model-provider.sh`** (create) — `call_model` + `ensure_codex_available`; the only place that knows how to invoke each CLI. Depends on `expand_add_dir_string` (`lib/args.sh`) and `log_error` (`lib/colors.sh`).
- **`bin/mra.sh`** (modify) — source `lib/model-provider.sh`; `plan)` dispatch parses `--dual`, preflights codex, threads `dual` into `run_plan_council`; usage updated.
- **`lib/plan-council.sh`** (modify) — `run_plan_council` gains a `dual` param; routes expert + synth calls through `call_model`; dual mode = 2 providers/persona + provider tags + missing-side sentinel + agree/disagree synth template. Non-dual path byte-unchanged.
- **`tests/test_plan_council.sh`** (modify) — source `args.sh` + `model-provider.sh`; add `call_model` / `ensure_codex_available` / dual `run_plan_council` / dispatch tests.

Reference facts (read before starting):
- `expand_add_dir_string <arrayvar> <string>` (`lib/args.sh:43`) expands an add-dir string into a bash array; `build_add_dir_string` (`lib/args.sh:12`) builds the string. plan-council currently does `expand_add_dir_string _ad_arr "$claude_add_dirs"` then passes `"${_ad_arr[@]}"`.
- `run_plan_council project project_dir task personas model add_dirs pkb_context lang_directive` (`lib/plan-council.sh:67`) — `$2` is the project dir (codex cwd). Currently each persona + the synth call `claude -p … --model "$model" … --setting-sources project`, experts with `--max-turns 6`, synth with `--max-turns 4`, both with `--disallowedTools Write,Edit,NotebookEdit`.
- Single caller: `bin/mra.sh:858` (under `plan)`), which parses `--model` (default `sonnet`), builds `add_dirs`/`pkb_context`/`lang_directive`.
- `tests/test_plan_council.sh` sources colors/personas/plan-council, uses `errors`, ends `if [[ $errors -eq 0 ]]; then echo "PASS: all plan-council tests passed"; else …; exit 1; fi`. Append before that block.
- `bin/mra.sh` runs `set -euo pipefail`; lib files don't set it themselves. The existing `"${_ad_arr[@]}"` empty-array expansion works under the runtime bash (5.x) — replicate verbatim (no guard) to stay byte-identical.

---

## Task 1: `lib/model-provider.sh` — `call_model` + `ensure_codex_available`

**Files:**
- Create: `lib/model-provider.sh`
- Modify: `bin/mra.sh` (source the new lib)
- Modify: `tests/test_plan_council.sh` (source `args.sh` + `model-provider.sh`; append tests)

- [ ] **Step 1: Add the source lines**

In `tests/test_plan_council.sh`, after `source "$SCRIPT_DIR/lib/plan-council.sh"`, add:
```bash
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/model-provider.sh"
```

In `bin/mra.sh`, alongside the other `source "$MRA_DIR/lib/*.sh"` lines (near where `args.sh` / `plan-council.sh` are sourced), add:
```bash
source "$MRA_DIR/lib/model-provider.sh"
```

- [ ] **Step 2: Write the failing tests** — append to `tests/test_plan_council.sh`, BEFORE the final summary block:

```bash
# --- model-provider: call_model dispatch + ensure_codex_available ---
MP_DIR=$(mktemp -d); MP_REC="$MP_DIR/rec"
# stub "claude": record flattened args, emit fixed output
cat > "$MP_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$MP_REC"
echo "<claude-output>"
STUB
# stub "codex": record flattened args + cwd, emit fixed output
cat > "$MP_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex: $* | cwd=$(pwd)" >> "$MP_REC"
echo "<codex-output>"
STUB
chmod +x "$MP_DIR/claude" "$MP_DIR/codex"
export MP_REC

# 1. call_model claude forwards -p / --disallowedTools / --model / --max-turns (param)
: > "$MP_REC"
out=$(MRA_CLAUDE_BIN="$MP_DIR/claude" call_model claude "PROMPT-A" sonnet "$MP_DIR" "" 6)
[[ "$out" == "<claude-output>" ]] || { echo "FAIL: call_model claude output: $out"; errors=$((errors+1)); }
rec=$(cat "$MP_REC")
case "$rec" in *"-p"*) : ;; *) echo "FAIL: claude missing -p: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--disallowedTools Write,Edit,NotebookEdit"*) : ;; *) echo "FAIL: claude missing disallowedTools: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--model sonnet"*) : ;; *) echo "FAIL: claude missing --model: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--max-turns 6"*) : ;; *) echo "FAIL: claude missing --max-turns 6: $rec"; errors=$((errors+1)) ;; esac
# max_turns is a real parameter (4 for the synthesizer)
: > "$MP_REC"
MRA_CLAUDE_BIN="$MP_DIR/claude" call_model claude "PROMPT-S" sonnet "$MP_DIR" "" 4 >/dev/null
case "$(cat "$MP_REC")" in *"--max-turns 4"*) : ;; *) echo "FAIL: claude should forward --max-turns 4: $(cat "$MP_REC")"; errors=$((errors+1)) ;; esac

# 2. call_model codex uses `exec -s read-only` and runs with cwd = project_dir
: > "$MP_REC"
out=$(MRA_CODEX_BIN="$MP_DIR/codex" call_model codex "PROMPT-B" sonnet "$MP_DIR" "" 6)
[[ "$out" == "<codex-output>" ]] || { echo "FAIL: call_model codex output: $out"; errors=$((errors+1)); }
rec=$(cat "$MP_REC")
case "$rec" in *"exec -s read-only"*) : ;; *) echo "FAIL: codex missing 'exec -s read-only': $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"cwd=$MP_DIR"*) : ;; *) echo "FAIL: codex cwd should be project_dir: $rec"; errors=$((errors+1)) ;; esac

# 3. unknown provider -> non-zero
if call_model bogus "P" sonnet "$MP_DIR" "" 6 >/dev/null 2>&1; then echo "FAIL: unknown provider should fail"; errors=$((errors+1)); fi

# 4. ensure_codex_available: present (stub) vs absent
if ! MRA_CODEX_BIN="$MP_DIR/codex" ensure_codex_available; then echo "FAIL: ensure_codex_available should pass with a real bin"; errors=$((errors+1)); fi
if MRA_CODEX_BIN="__nope_not_a_real_bin__" ensure_codex_available; then echo "FAIL: ensure_codex_available should fail when bin absent"; errors=$((errors+1)); fi
rm -rf "$MP_DIR"; unset MP_REC
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_plan_council.sh`
Expected: FAIL — `call_model: command not found` / `ensure_codex_available: command not found`.

- [ ] **Step 4: Write the implementation** — create `lib/model-provider.sh`:

```bash
#!/usr/bin/env bash
# Model provider abstraction for mra: dispatch one prompt to claude or codex.
# Depends on: expand_add_dir_string (lib/args.sh), log_error (lib/colors.sh).
# Binary names are env-overridable (MRA_CLAUDE_BIN / MRA_CODEX_BIN) for tests.

# Run one prompt against a provider, printing the model's response to stdout.
# Args: provider prompt model project_dir add_dirs max_turns
#   claude -> existing council invocation (edit tools disabled; --max-turns parameterized
#             so experts use 6 and the synthesizer uses 4).
#   codex  -> `codex exec -s read-only` (read-only sandbox), cwd = project_dir so it sees the repo.
#             (codex has no turn limit; max_turns applies to the claude branch only.)
call_model() {
  local provider="$1" prompt="$2" model="$3" project_dir="$4" add_dirs="$5" max_turns="${6:-6}"
  case "$provider" in
    claude)
      local _ad=()
      expand_add_dir_string _ad "$add_dirs"
      "${MRA_CLAUDE_BIN:-claude}" -p "$prompt" \
        "${_ad[@]}" \
        --model "$model" \
        --max-turns "$max_turns" \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project"
      ;;
    codex)
      ( cd "$project_dir" && "${MRA_CODEX_BIN:-codex}" exec -s read-only "$prompt" )
      ;;
    *)
      log_error "call_model: unknown provider '$provider'" "plan"; return 2
      ;;
  esac
}

# Preflight gate for `mra plan --dual`: is the codex CLI available?
ensure_codex_available() {
  command -v "${MRA_CODEX_BIN:-codex}" >/dev/null 2>&1
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_plan_council.sh`
Expected: `PASS: all plan-council tests passed` (0 errors).

- [ ] **Step 6: Commit**

```bash
git add lib/model-provider.sh bin/mra.sh tests/test_plan_council.sh
git commit -m "feat(plan): model-provider abstraction (call_model claude|codex + ensure_codex_available)"
```

---

## Task 2: `run_plan_council` dual mode

**Files:**
- Modify: `tests/test_plan_council.sh` (append dual tests)
- Modify: `lib/plan-council.sh` (replace the whole `run_plan_council` function)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_plan_council.sh`, BEFORE the summary block:

```bash
# --- run_plan_council dual mode (stub both bins) ---
RC_DIR=$(mktemp -d); RC_REC="$RC_DIR/rec"; RC_PROJ="$RC_DIR/proj"; mkdir -p "$RC_PROJ"
cat > "$RC_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$RC_REC"
echo "<claude-output>"
STUB
cat > "$RC_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex: $*" >> "$RC_REC"
echo "<codex-output>"
STUB
cat > "$RC_DIR/codex-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$RC_DIR/claude" "$RC_DIR/codex" "$RC_DIR/codex-fail"
export RC_REC

# 5. dual=true, 1 persona -> claude(expert,6) + codex(expert) + claude(synth,4) all ran; tags present; synth output returned
: > "$RC_REC"
out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" true)
case "$out" in *"<claude-output>"*) : ;; *) echo "FAIL: dual run should return synth (claude) output: $out"; errors=$((errors+1)) ;; esac
rec=$(cat "$RC_REC")
case "$rec" in *"--max-turns 6"*) : ;; *) echo "FAIL: dual missing expert claude --max-turns 6: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"exec -s read-only"*) : ;; *) echo "FAIL: dual missing codex expert call: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--max-turns 4"*) : ;; *) echo "FAIL: dual missing synth claude --max-turns 4: $rec"; errors=$((errors+1)) ;; esac
# the synth prompt (recorded in the claude synth call) carries the [claude]/[codex] tags
case "$rec" in *"[claude]"*) : ;; *) echo "FAIL: synth input missing [claude] tag: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"[codex]"*) : ;; *) echo "FAIL: synth input missing [codex] tag: $rec"; errors=$((errors+1)) ;; esac

# 6. dual=false (default) -> ONLY claude; codex never called; expert(6)+synth(4) present
: > "$RC_REC"
out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" false)
rec=$(cat "$RC_REC")
if printf '%s' "$rec" | grep -q 'codex:'; then echo "FAIL: non-dual must NOT call codex: $rec"; errors=$((errors+1)); fi
case "$rec" in *"--max-turns 6"*) : ;; *) echo "FAIL: non-dual missing expert --max-turns 6: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--max-turns 4"*) : ;; *) echo "FAIL: non-dual missing synth --max-turns 4: $rec"; errors=$((errors+1)) ;; esac
if printf '%s' "$rec" | grep -q '\[codex\]'; then echo "FAIL: non-dual synth input must not carry provider tags: $rec"; errors=$((errors+1)); fi

# 7. dual=true with a FAILING codex -> council still produces output (exit 0), sentinel reaches synth input
: > "$RC_REC"
if out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex-fail" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" true); then rc=0; else rc=$?; fi
[[ $rc -eq 0 ]] || { echo "FAIL: failing codex should not break the council (rc=$rc)"; errors=$((errors+1)); }
case "$out" in *"<claude-output>"*) : ;; *) echo "FAIL: council should still return synth output on codex failure: $out"; errors=$((errors+1)) ;; esac
case "$(cat "$RC_REC")" in *"no response"*) : ;; *) echo "FAIL: missing-side sentinel should reach synth input: $(cat "$RC_REC")"; errors=$((errors+1)) ;; esac
rm -rf "$RC_DIR"; unset RC_REC
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_plan_council.sh`
Expected: FAIL — `run_plan_council` does not accept a 9th `dual` arg yet, never calls codex, and has no sentinel/tagged synth input.

- [ ] **Step 3: Write the implementation** — replace the ENTIRE `run_plan_council` function in `lib/plan-council.sh` with:

```bash
run_plan_council() {
  local project="$1" project_dir="$2" task="$3" personas="$4" model="$5"
  local claude_add_dirs="$6" pkb_context="${7:-}" lang_directive="${8:-}" dual="${9:-false}"

  local providers=("claude")
  [[ "$dual" == "true" ]] && providers=("claude" "codex")

  local expert_count; expert_count=$(echo "$personas" | wc -w | tr -d ' ')
  log_progress >&2 "[plan] convening council of $expert_count experts$([[ "$dual" == "true" ]] && echo ' ×2 models')..." "plan"

  local pids=() result_files=() err_files=() persona_names=() provider_names=()
  local p prov
  for p in $personas; do
    for prov in "${providers[@]}"; do
      local f err
      f=$(mktemp); err=$(mktemp)
      result_files+=("$f"); err_files+=("$err")
      persona_names+=("$p"); provider_names+=("$prov")
      (
        local prompt
        prompt=$(build_plan_prompt "$p" "$task" "$pkb_context" "$lang_directive")
        call_model "$prov" "$prompt" "$model" "$project_dir" "$claude_add_dirs" 6
      ) > "$f" 2> "$err" &
      pids+=("$!")
    done
  done

  local i pid rc
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    if ! wait "$pid"; then
      rc=$?
      log_warn >&2 "[plan] ${persona_names[$i]} [${provider_names[$i]}] failed (rc=$rc) — stderr: ${err_files[$i]}" "plan"
    fi
  done

  local all=""
  for i in "${!result_files[@]}"; do
    local tag content
    if [[ "$dual" == "true" ]]; then
      tag="### ${persona_names[$i]} [${provider_names[$i]}]"
    else
      tag="### ${persona_names[$i]}"
    fi
    content="$(cat "${result_files[$i]}")"
    if [[ "$dual" == "true" && -z "${content//[[:space:]]/}" ]]; then
      content="(no response — ${provider_names[$i]} call failed or returned empty)"
    fi
    all+="$tag"$'\n\n'"$content"$'\n\n---\n\n'
    rm -f "${result_files[$i]}"
  done
  local e
  for e in "${err_files[@]}"; do
    [[ -s "$e" ]] || rm -f "$e"
  done

  log_progress >&2 "[plan] synthesizing unified plan..." "plan"
  local synth_template
  if [[ "$dual" == "true" ]]; then
    synth_template=$(cat <<'TEMPLATE'
You are the council synthesizer. Below are independent plans for the same task, each from a domain expert as seen by TWO models (claude and codex). Blocks are tagged "### <persona> [claude]" / "### <persona> [codex]". A block reading "(no response — ...)" means that model did not return for that persona.

## Task
%TASK%

## Expert Perspectives (per persona × model)
%EXPERTS%

## Your Job
For each persona, COMPARE the claude and codex perspectives:
1. Where BOTH models agree → list under "High-confidence (both models agree)".
2. Where they DISAGREE, only one model raised it, or one is "(no response)" → list under "Model Disagreements" showing both sides. DO NOT pick a winner — leave it for a human to decide.
3. Then produce the consolidated plan, keeping every CRITICAL concern from either model with attribution.

%LANG%

## Output Format

# Unified Plan: <task>

## High-confidence (both models agree)
- [persona] <concern>

## ⚠ Model Disagreements (human decides)
- [persona] claude: <position> │ codex: <position>

## Consolidated Files
- `path` — <why, which expert/model raised it>

## Risks (sorted)
- [CRITICAL] [persona/model] <risk + mitigation>
- [HIGH] [persona/model] <risk + mitigation>

## Required Tests
- <test>

## Execution Steps
1. <step>
2. <step>
TEMPLATE
)
  else
    synth_template=$(cat <<'TEMPLATE'
You are the council synthesizer. Below are independent plans from N domain experts for the same task.

## Task
%TASK%

## Expert Perspectives
%EXPERTS%

## Your Job
Produce ONE unified implementation plan that:
1. Keeps every CRITICAL concern raised by any expert.
2. Merges overlapping files-to-touch into one consolidated list.
3. Orders risks by severity, keeping expert attribution (e.g. "[security-auditor] ...").
4. Lists required tests deduped across experts.
5. Ends with a numbered step-by-step TODO list ready for execution.

%LANG%

## Output Format

# Unified Plan: <task>

## Consolidated Files
- `path` — <why, which expert raised it>

## Risks (sorted)
- [CRITICAL] [expert] <risk>
- [HIGH] [expert] <risk>

## Required Tests
- <test>

## Execution Steps
1. <step>
2. <step>
TEMPLATE
)
  fi

  # Safe substitution via bash parameter expansion (no command evaluation)
  local synth_prompt="$synth_template"
  synth_prompt="${synth_prompt//%TASK%/$task}"
  synth_prompt="${synth_prompt//%EXPERTS%/$all}"
  synth_prompt="${synth_prompt//%LANG%/$lang_directive}"

  local synth_out; synth_out=$(mktemp)
  local synth_err; synth_err=$(mktemp)
  rc=0
  call_model claude "$synth_prompt" "$model" "$project_dir" "$claude_add_dirs" 4 \
    >"$synth_out" 2>"$synth_err" || rc=$?

  if [[ $rc -ne 0 ]]; then
    log_warn >&2 "[plan] synthesizer failed (rc=$rc) — stderr: $synth_err" "plan"
    rm -f "$synth_out"
    return $rc
  fi

  if [[ ! -s "$synth_out" ]]; then
    log_warn >&2 "[plan] synthesizer returned empty output — see stderr: $synth_err" "plan"
    rm -f "$synth_out"
    return 1
  fi

  cat "$synth_out"
  rm -f "$synth_out"
  [[ -s "$synth_err" ]] || rm -f "$synth_err"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_plan_council.sh`
Expected: `PASS: all plan-council tests passed` (0 errors) — including the existing non-dual tests (the `default_plan_personas` / `build_plan_prompt` tests are untouched).

- [ ] **Step 5: Commit**

```bash
git add lib/plan-council.sh tests/test_plan_council.sh
git commit -m "feat(plan): run_plan_council --dual (claude+codex per persona, agree/disagree synth)"
```

---

## Task 3: `mra plan --dual` dispatch + preflight + usage

**Files:**
- Modify: `bin/mra.sh` — the `plan)` dispatch + usage lines
- Modify: `tests/test_plan_council.sh` (append dispatch tests)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_plan_council.sh`, BEFORE the summary block:

```bash
# --- mra plan --dual dispatch (real CLI via MRA_WORKSPACE) ---
PD_WS=$(mktemp -d); mkdir -p "$PD_WS/.collab" "$PD_WS/app"
echo '{"gitOrg":"x","projects":{"app":{"deps":{},"consumedBy":[]}}}' > "$PD_WS/.collab/dep-graph.json"
git -C "$PD_WS/app" init -b main &>/dev/null
git -C "$PD_WS/app" config user.email t@t.t; git -C "$PD_WS/app" config user.name t
git -C "$PD_WS/app" commit --allow-empty -m init &>/dev/null
# 8. --dual with codex absent -> preflight error, non-zero, council not convened
if out=$(MRA_WORKSPACE="$PD_WS" MRA_CODEX_BIN="__nope_not_real__" bash "$SCRIPT_DIR/bin/mra.sh" plan app "do a thing" --dual 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: --dual without codex should exit non-zero"; errors=$((errors+1)); }
case "$out" in *codex*) : ;; *) echo "FAIL: preflight error should mention codex: $out"; errors=$((errors+1)) ;; esac
case "$out" in *"convening council"*) echo "FAIL: council must NOT convene when codex absent: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$PD_WS"
# 9. usage advertises --dual
grep -q 'plan .*--dual' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise plan --dual"; errors=$((errors+1)); }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_plan_council.sh`
Expected: FAIL — `--dual` is an unknown option today (`-*) unknown option`), so it errors with "unknown option" (not the codex preflight message), and usage has no `--dual`.

- [ ] **Step 3: Edit the `plan)` dispatch** in `bin/mra.sh`. (a) Add `plan_dual=false` to the locals line:

```bash
      local plan_project="" plan_task="" plan_model="sonnet" plan_dual=false
```

(b) Add a `--dual` case to the arg loop, just before the `-*)` unknown-option case:

```bash
          --dual) plan_dual=true; shift ;;
```

(c) After the `project_dir` existence check (`[[ ! -d "$project_dir" ]] && { … exit 1; }`) and BEFORE the `pkb_build_context` line, add the preflight:

```bash
      if [[ "$plan_dual" == "true" ]] && ! ensure_codex_available; then
        log_error "mra plan --dual requires the codex CLI (not found on PATH)" "plan"; exit 1
      fi
```

(d) Pass `dual` as the 9th arg to `run_plan_council` (the call at the end of `plan)`):

```bash
      run_plan_council "$plan_project" "$project_dir" "$plan_task" \
        "$(default_plan_personas)" "$plan_model" "$add_dirs" "$pkb_context" "$lang_directive" "$plan_dual"
```

- [ ] **Step 4: Update the usage lines** in `bin/mra.sh`. (a) The dispatch usage-error string:

```
log_error "usage: mra plan <project> \"<task>\" [--model <model>]" "plan"; exit 1
```
→ append `[--dual]`:
```
log_error "usage: mra plan <project> \"<task>\" [--model <model>] [--dual]" "plan"; exit 1
```

(b) The top-level help line for `plan`:
```
  plan <project> "<task>" [--model M]  Multi-expert implementation plan
```
→
```
  plan <project> "<task>" [--model M] [--dual]  Multi-expert plan; --dual = claude+codex council
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_plan_council.sh`
Expected: `PASS: all plan-council tests passed` (0 errors).

- [ ] **Step 6: Commit**

```bash
git add bin/mra.sh tests/test_plan_council.sh
git commit -m "feat(plan): mra plan --dual flag + codex preflight + usage"
```

---

## Task 4: Full regression + spec status

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md` (§21 status) + re-render `.html`

- [ ] **Step 1: Run the full suite**

Run: `bash test.sh`
Expected: `shell tests: 45 passed, 0 failed` and `mcp-server : ok`. (No new suite — Phase 13 tests live in `tests/test_plan_council.sh`.) If anything fails, STOP and report BLOCKED with the output.

- [ ] **Step 2: Flip the §21 status note** in the spec. Find the `**Status:**` line directly under `## 21. Phase 13 — `:

```
**Status:** Approved (design) — 2026-06-08. Implementation scope for the next plan. First multi-MODEL capability: the existing plan-council (claude personas) gains a `--dual` mode that runs each persona on claude AND codex and surfaces cross-model agreement/disagreement. First engine of a broader multi-model push; review-debate / personas / eval are out of scope here.
```

Replace with:

```
**Status:** Implemented — 2026-06-08. `mra plan --dual` runs each persona on claude AND codex via the new `lib/model-provider.sh` (`call_model` + `ensure_codex_available`); `run_plan_council` tags blocks by provider, writes a missing-side sentinel on a failed/empty call, and synthesizes with an agree/disagree template. Non-dual path unchanged; codex side runs `codex exec -s read-only`.
```

- [ ] **Step 3: Re-render the spec HTML**

Run: `python3 docs/superpowers/render-html.py docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md`
Expected: `✓ …-design.md -> …-design.html`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.md docs/superpowers/specs/2026-05-29-branch-aware-sync-review-design.html
git commit -m "docs(spec): mark Phase 13 (mra plan --dual) implemented"
```

---

## Self-Review Notes

- **Spec coverage:** §21.1 surface (`--dual`, `--model` claude-only, preflight) → Task 3. §21.2 safety (claude edit-tools-off / codex read-only) → Task 1 (`call_model`). §21.3 provider abstraction (call_model signature incl. `max_turns`, `MRA_*_BIN`, ensure_codex_available, fail/empty non-fatal) → Task 1. §21.4 dual flow + tags + missing-side sentinel + agree/disagree synth → Task 2. §21.5 architecture → Tasks 1–3. §21.6 error handling (preflight, single-call fail, synth fail) → Tasks 1–3. §21.7 tests 1–4 → Task 1; 5–7 → Task 2; 8–9 → Task 3; regression → Task 4. §21.8 out-of-scope respected (plan-council only; no `--codex-model`; synth does not adjudicate).
- **No placeholders:** every code step shows the full function body / exact edit / runnable test.
- **Type/name consistency:** `call_model provider prompt model project_dir add_dirs max_turns` and `ensure_codex_available` are defined in Task 1 and used identically in Tasks 2–3. `run_plan_council`'s 9th param `dual` (default `false`) is added in Task 2 and passed by the dispatch in Task 3. `MRA_CLAUDE_BIN`/`MRA_CODEX_BIN` seams and the `(no response — … )` sentinel string are consistent between impl and tests.
- **Non-dual byte-equivalence:** Task 2 keeps the non-dual tag (`### persona`, no provider), the original synth template verbatim, and no sentinel — so non-dual `$all` and synth prompt are identical to today; expert (max-turns 6) and synth (max-turns 4) go through `call_model` which reproduces the exact claude invocation. Test 6 is the regression guard (codex never called; both max-turns present; no provider tags).
- **Hermetic tests:** claude/codex are stubbed via `MRA_*_BIN` pointing at temp scripts that record args/cwd to a file (subshell-safe); the real CLIs are never called. Dispatch test 8 simulates codex-absent with `MRA_CODEX_BIN=__nope_not_real__`.
