# Project-Memory Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each `--add-dir` project's native `CLAUDE.md`/`AGENTS.md`/`.claude/rules/` load into the `claude` CLI mra launches, gated by a config flag, guarded against cross-project leakage, and locked by offline tests.

**Architecture:** A single `apply_project_memory_env()` helper exports `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (or unsets it) at the top of `main()`; every child `claude` process inherits it. The interactive launch adds `--setting-sources user,project` so it never pulls each repo's gitignored `CLAUDE.local.md`. PKB stays complementary by dropping its verbatim conventions copy when native loading is on.

**Tech Stack:** Bash, jq, the existing `tests/test_*.sh` harness run by `test.sh`.

## Global Constraints

- Verified against claude **2.1.186**: `--add-dir` auto-loads `.claude/skills/`; `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` is required for CLAUDE.md/AGENTS.md/`.claude/rules/`; `--setting-sources` excluding `local` drops add-dir `CLAUDE.local.md`.
- Commits: `<type>: <desc>` (zh-TW ok), **no** attribution footer (disabled globally).
- Coding style: immutability, many small focused files, comprehensive error handling, no hardcoded values.
- The flag governs **CLAUDE.md + AGENTS.md + .claude/rules ONLY** — not skills (already auto-load), not `settings.local.json`.
- **Hard gate:** `config.json` may default `loadProjectMemory: true` only once the interactive launch carries `--setting-sources user,project` (Task 4 lands before Task 5).
- Default ON semantics: only an explicit `"loadProjectMemory": false` disables; a missing key (jq `null`) means ON.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/project-memory.sh` (new) | The `apply_project_memory_env()` switch — the only env-mutating lib |
| `bin/mra.sh` | Source the lib; call the switch once at the top of `main()` |
| `lib/config.sh` | `config_handle` gains the `project-memory on/off` arm |
| `config.json` | Ships `loadProjectMemory: true` |
| `lib/launch.sh` | Interactive launch adds `--setting-sources user,project` |
| `lib/pkb.sh` | `pkb_build_context` + `_pkb_generate_conventions` drop duplicate rule content when native loading is on |
| `tests/test_project_memory.sh` (new) | Unit: flag→export/unset; config_handle; ordering guard |
| `tests/test_launch.sh` | Extend stub to capture env + assert `--setting-sources user,project` |
| `tests/test_pkb_context.sh` (new) | `pkb_build_context` omits verbatim conventions when flag on |
| `README.md` / `CHANGELOG.md` / `usage()` | Document the flag and its exact scope |

---

## Phase 1 — Loading + hard gate + tests + docs

### Task 1: `apply_project_memory_env` helper + unit test

**Files:**
- Create: `lib/project-memory.sh`
- Test: `tests/test_project_memory.sh`

**Interfaces:**
- Consumes: `config_get` (from `lib/config.sh`), `MRA_CONFIG`.
- Produces: `apply_project_memory_env()` — reads `loadProjectMemory`, exports `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` when not `false`, `unset`s it when `false`.

- [ ] **Step 1: Write the failing test** — create `tests/test_project_memory.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/project-memory.sh"

errors=0
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
MRA_CONFIG=$(mktemp)
write_config() { printf '%s\n' "$1" > "$MRA_CONFIG"; }
VAR=CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD

# Case 1: flag ON -> exported = 1
unset $VAR; write_config '{"loadProjectMemory": true}'; apply_project_memory_env
[[ "${!VAR:-unset}" == "1" ]] || fail "ON: expected =1, got ${!VAR:-unset}"

# Case 2: flag OFF -> unset (even if previously set)
export $VAR=1; write_config '{"loadProjectMemory": false}'; apply_project_memory_env
[[ -z "${!VAR+x}" ]] || fail "OFF: expected unset, got ${!VAR:-unset}"

# Case 3: key missing -> default ON
unset $VAR; write_config '{"autoScan": true}'; apply_project_memory_env
[[ "${!VAR:-unset}" == "1" ]] || fail "missing: expected default-ON =1, got ${!VAR:-unset}"

# Case 4: OFF must override a globally-exported var (mra authoritative)
export $VAR=1; write_config '{"loadProjectMemory": false}'; apply_project_memory_env
[[ -z "${!VAR+x}" ]] || fail "OFF-global: mra must unset a globally-exported var"

rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then echo "PASS: all project-memory tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_project_memory.sh`
Expected: FAIL — `lib/project-memory.sh` does not exist (source error).

- [ ] **Step 3: Write minimal implementation** — create `lib/project-memory.sh`:

```bash
#!/usr/bin/env bash
# Project-memory loading switch.
#
# Controls whether each --add-dir project's NATIVE instruction files
# (CLAUDE.md, AGENTS.md, .claude/rules/) load into the claude CLI mra
# launches. Governed ONLY by those files — NOT skills (already auto-load
# via --add-dir) and NOT settings.local.json.
#
# Implemented with claude's CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
# env var, exported once at the top of main() so every child claude
# process (interactive launch, headless `claude -p`, pkb generators)
# inherits it. Depends on config_get (lib/config.sh).
apply_project_memory_env() {
  local enabled
  enabled=$(config_get "loadProjectMemory" 2>/dev/null)
  # Default ON: only an explicit "false" disables. A missing key (jq null),
  # "true", or empty all enable. unset (not skip) on OFF so an OFF config is
  # authoritative even over a var the user exported globally in their shell.
  if [[ "$enabled" == "false" ]]; then
    unset CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
  else
    export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_project_memory.sh`
Expected: `PASS: all project-memory tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/project-memory.sh tests/test_project_memory.sh
git commit -m "feat(launch): apply_project_memory_env 開關(CLAUDE.md/rules 原生載入)"
```

---

### Task 2: Wire into `main()` + ordering guard

**Files:**
- Modify: `bin/mra.sh` (source line near 13; call at top of `main()` line 150)
- Test: `tests/test_project_memory.sh` (append ordering case)

**Interfaces:**
- Consumes: `apply_project_memory_env` (Task 1).
- Produces: the env var is set/unset before any `case "$command"` dispatch, so every subcommand's child claude inherits it.

- [ ] **Step 1: Write the failing test** — append before the final summary block of `tests/test_project_memory.sh`:

```bash
# Case 5: ordering guard — the call must precede `case "$command"` dispatch
mra_main="$SCRIPT_DIR/bin/mra.sh"
call_line=$(grep -n '^[[:space:]]*apply_project_memory_env' "$mra_main" | head -1 | cut -d: -f1)
case_line=$(grep -n 'case "\$command" in' "$mra_main" | head -1 | cut -d: -f1)
[[ -n "$call_line" && -n "$case_line" && "$call_line" -lt "$case_line" ]] \
  || fail "ordering: call (line ${call_line:-none}) must precede case (line ${case_line:-none})"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_project_memory.sh`
Expected: FAIL — `ordering: call (line none) must precede case ...` (not wired yet).

- [ ] **Step 3: Implement** — two edits in `bin/mra.sh`:

After `source "$MRA_DIR/lib/config.sh"` (line 13) add:
```bash
source "$MRA_DIR/lib/project-memory.sh"
```

In `main()`, between `local command="${1:-}"` and the help check, add:
```bash
main() {
  local command="${1:-}"

  apply_project_memory_env

  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_project_memory.sh`
Expected: `PASS: all project-memory tests passed`

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh tests/test_project_memory.sh
git commit -m "feat(launch): main() 入口套用 project-memory 開關 + ordering guard"
```

---

### Task 3: `config_handle` CLI arm (`mra config project-memory on/off`)

**Files:**
- Modify: `lib/config.sh` (`config_handle`, insert before the `*)` arm at line 63)
- Test: `tests/test_project_memory.sh` (append config_handle case)

**Interfaces:**
- Consumes: `config_set` (lib/config.sh).
- Produces: `config_handle project-memory on|off` writes `loadProjectMemory: true|false`.

- [ ] **Step 1: Write the failing test** — append before the final summary block of `tests/test_project_memory.sh`:

```bash
# Case 6: config_handle project-memory on/off flips loadProjectMemory
write_config '{}'
config_handle project-memory off >/dev/null 2>&1
[[ "$(config_get loadProjectMemory)" == "false" ]] || fail "config_handle off -> false"
config_handle project-memory on  >/dev/null 2>&1
[[ "$(config_get loadProjectMemory)" == "true" ]]  || fail "config_handle on -> true"
config_handle project-memory bogus >/dev/null 2>&1 && fail "config_handle bogus should return non-zero"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_project_memory.sh`
Expected: FAIL — `unknown config key: project-memory` (arm not added).

- [ ] **Step 3: Implement** — in `lib/config.sh`, insert this arm immediately before the `*) log_error "unknown config key: $key" ...` line:

```bash
    project-memory)
      if [[ "$value" == "on" || "$value" == "off" ]]; then
        config_set "loadProjectMemory" "$( [[ "$value" == "on" ]] && echo true || echo false )"
        log_success "loadProjectMemory $value" "config"
      else log_error "invalid value: $value (use on/off)" "config"; return 1; fi ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_project_memory.sh`
Expected: `PASS: all project-memory tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/config.sh tests/test_project_memory.sh
git commit -m "feat(config): mra config project-memory on/off"
```

---

### Task 4: Interactive launch guard (`--setting-sources user,project`)

**Files:**
- Modify: `lib/launch.sh` (in `launch_claude`, right after the `--add-dir` args are collected, ~line 29)
- Test: `tests/test_launch.sh` (add a positive assertion)

**Interfaces:**
- Consumes: none new.
- Produces: every interactive launch passes `--setting-sources user,project` — keeps the operator's user-scope settings.json/permissions while excluding `local` scope, so each repo's gitignored `CLAUDE.local.md` is never pulled into the shared orchestrator context.

> **Why `user,project` and not bare `project`:** both exclude `local` (the leak vector), but bare `project` also drops the operator's `~/.claude/settings.json` (their global allowedTools/hooks) from the interactive session — a permissions regression. `user,project` excludes only `local`. Headless calls keep their existing bare `project` (they are ephemeral and already audited). This refines spec D4.

- [ ] **Step 1: Write the failing test** — in `tests/test_launch.sh`, add after the Case 1 assertions:

```bash
# --- Case 1b: interactive launch must restrict setting-sources to user,project ---
grep -qx -- '--setting-sources' "$CAPTURE" || fail "case1b: --setting-sources missing"
grep -qx -- 'user,project'      "$CAPTURE" || fail "case1b: expected setting-sources value user,project"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_launch.sh`
Expected: FAIL — `case1b: --setting-sources missing`.

- [ ] **Step 3: Implement** — in `lib/launch.sh`, immediately after the `while IFS= read -r -d '' arg; do claude_args+=("$arg"); done < <(build_add_dir_args ...)` block, add:

```bash
  # Restrict settings to user+project scope so the orchestrator keeps the
  # operator's global settings.json but never loads each --add-dir repo's
  # gitignored CLAUDE.local.md (local scope) when project-memory is on.
  claude_args+=(--setting-sources user,project)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_launch.sh`
Expected: `PASS: all launch tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/launch.sh tests/test_launch.sh
git commit -m "fix(launch): 互動 launch 加 --setting-sources user,project(排除跨專案 CLAUDE.local.md)"
```

---

### Task 5: Default the flag ON + env-inheritance integration test

**Files:**
- Modify: `config.json` (add `"loadProjectMemory": true`)
- Test: `tests/test_launch.sh` (capture env in the stub; ON→ENV:1, OFF→ENV:unset)

**Interfaces:**
- Consumes: `apply_project_memory_env` (Task 1), `launch_claude` (existing).
- Produces: proof that a launched child claude inherits the exported env var end-to-end.

- [ ] **Step 1: Write the failing test** — two edits in `tests/test_launch.sh`.

(a) Extend the `claude()` stub to also record the env var (append one line; keep existing argv capture intact):
```bash
claude() {
  : > "$CAPTURE"
  printf '%s\n' "$@" >> "$CAPTURE"
  printf 'ENV:%s\n' "${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD:-unset}" >> "$CAPTURE"
}
```

(b) Add an integration block at the end (before the summary). It sources the switch, drives it with a temp config, then launches:
```bash
# --- Case 3: child claude inherits the project-memory env var ---
source "$SCRIPT_DIR/lib/project-memory.sh"
PM_CONFIG=$(mktemp)
config_get() { jq -r ".$1" "$PM_CONFIG"; }   # real read against the temp config

printf '{"loadProjectMemory": true}\n' > "$PM_CONFIG"; apply_project_memory_env
launch_claude "$TEST_DIR/workspace" "/no/such/graph" "proj-a" >/dev/null 2>&1
grep -qx -- 'ENV:1' "$CAPTURE" || fail "case3: child must see ENV:1 when flag ON"

printf '{"loadProjectMemory": false}\n' > "$PM_CONFIG"; apply_project_memory_env
launch_claude "$TEST_DIR/workspace" "/no/such/graph" "proj-a" >/dev/null 2>&1
grep -qx -- 'ENV:unset' "$CAPTURE" || fail "case3: child must see ENV:unset when flag OFF"
rm -f "$PM_CONFIG"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_launch.sh`
Expected: FAIL — `case3: child must see ENV:1 when flag ON` (stub not yet capturing env / no integration).
Note: if Step 1(a) is applied first, the failure is the `ENV:1` assertion, not a syntax error.

- [ ] **Step 3: Implement** — add the default to `config.json`:

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "outputLanguage": "繁體中文台灣用語",
  "loadProjectMemory": true,
  "aliases": {},
  "subAgentWorkflow": {
    "reviewLoopMax": 3,
    "autoCommit": true,
    "autoPR": true
  }
}
```

- [ ] **Step 4: Run full suite to verify nothing regressed**

Run: `bash tests/test_launch.sh && bash tests/test_project_memory.sh && bash tests/test_config.sh`
Expected: all three print `PASS`.

- [ ] **Step 5: Commit**

```bash
git add config.json tests/test_launch.sh
git commit -m "feat(launch): 預設啟用 loadProjectMemory + env 繼承回歸測試"
```

---

### Task 6: Documentation (scope statement everywhere)

**Files:**
- Modify: `bin/mra.sh` (`usage()` — config section near line 72)
- Modify: `README.md` (config section)
- Modify: `CHANGELOG.md` (top entry)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `usage()`** — in `bin/mra.sh`, under the config help, add a line after `config <key> <value>`:

```
  config project-memory on|off  Load each project's CLAUDE.md/AGENTS.md/.claude/rules (default on)
```

- [ ] **Step 2: Update `README.md`** — add to the configuration section:

```markdown
### Project memory

`mra config project-memory on|off` (default **on**) controls whether each loaded
project's native **CLAUDE.md**, **AGENTS.md**, and **.claude/rules/** load into
the `claude` session mra launches. It does **not** affect Agent Skills
(`.claude/skills/`, already auto-loaded via `--add-dir`) or `settings.local.json`.
The interactive orchestrator uses `--setting-sources user,project`, so a repo's
gitignored `CLAUDE.local.md` is never pulled into the shared cross-repo context.
```

- [ ] **Step 3: Update `CHANGELOG.md`** — add the top entry:

```markdown
- feat(launch): load each project's CLAUDE.md/AGENTS.md/.claude/rules natively
  (`mra config project-memory on|off`, default on); interactive launch now scopes
  settings to `user,project` to avoid cross-project CLAUDE.local.md leakage.
```

- [ ] **Step 4: Verify the full suite still passes**

Run: `bash test.sh`
Expected: green summary, no failures.

- [ ] **Step 5: Commit**

```bash
git add bin/mra.sh README.md CHANGELOG.md
git commit -m "docs: 說明 mra config project-memory 與精確載入範圍"
```

---

## Phase 2 — PKB de-duplication (splittable into a follow-up PR)

> Mitigates the token redundancy this feature introduces. Phase 1 ships working on its own; if Phase 2 is deferred, note the overlap in the PR.

### Task 7: `pkb_build_context` drops verbatim conventions when native loading is on

**Files:**
- Modify: `lib/pkb.sh` (`pkb_build_context`, near line 320 + guards at 354-359 and 417-424)
- Test: `tests/test_pkb_context.sh` (new)

**Interfaces:**
- Consumes: `config_get loadProjectMemory`, `pkb_dir`, `pkb_exists`.
- Produces: `pkb_build_context` omits the verbatim "Full Conventions" block and the verbatim fallback when `loadProjectMemory != false`; tagged essentials + sitemap/architecture/api/modules/tunnels still load.

- [ ] **Step 1: Write the failing test** — create `tests/test_pkb_context.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pkb.sh"

errors=0
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

PROJ=$(mktemp -d)
PKB="$PROJ/.mra/pkb"; mkdir -p "$PKB/modules"
echo '{"version":2,"lastUpdated":"2026-01-01T00:00:00Z"}' > "$PKB/meta.json"
printf '**proj** | app | Node.js\nDemo\n' > "$PKB/identity.md"
# conventions.md has NO tagged lines -> exercises the verbatim fallback path
printf 'VERBATIM_CONVENTIONS_MARKER full text here\n' > "$PKB/conventions.md"

MRA_CONFIG=$(mktemp)

# flag ON -> verbatim conventions must be suppressed
printf '{"loadProjectMemory": true}\n' > "$MRA_CONFIG"
out=$(pkb_build_context "$PROJ" "" "full")
echo "$out" | grep -q 'VERBATIM_CONVENTIONS_MARKER' && fail "ON: verbatim conventions must be suppressed"
echo "$out" | grep -q 'proj' || fail "ON: identity (non-conventions context) must still load"

# flag OFF -> verbatim conventions present (legacy behaviour)
printf '{"loadProjectMemory": false}\n' > "$MRA_CONFIG"
out=$(pkb_build_context "$PROJ" "" "full")
echo "$out" | grep -q 'VERBATIM_CONVENTIONS_MARKER' || fail "OFF: verbatim conventions must load"

rm -rf "$PROJ"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then echo "PASS: all pkb_context tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pkb_context.sh`
Expected: FAIL — `ON: verbatim conventions must be suppressed` (no flag awareness yet).

- [ ] **Step 3: Implement** — in `lib/pkb.sh`, near the top of `pkb_build_context` (after the `pkb_exists` guard returns), add:

```bash
  local native_memory=false
  [[ "$(config_get loadProjectMemory 2>/dev/null)" != "false" ]] && native_memory=true
```

Then wrap the L1 verbatim fallback (the `else` branch, ~lines 354-359 — the `## Conventions\n$(cat "$conventions_file")` block) so it only runs when not native:
```bash
    elif [[ "$native_memory" == false ]]; then
      # Fallback: load full conventions if no tags found (pre-v2 PKB)
      context="${context}
## Conventions
$(cat "$conventions_file")
"
    fi
```

And guard the L3 "Full Conventions" block (~lines 417-424) likewise:
```bash
    # Full conventions (not just tagged lines) — skip when claude loads
    # CLAUDE.md/rules natively to avoid a verbatim second copy.
    if [[ -f "$conventions_file" && "$native_memory" == false ]]; then
      context="${context}
## Full Conventions
$(cat "$conventions_file")
"
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pkb_context.sh`
Expected: `PASS: all pkb_context tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/pkb.sh tests/test_pkb_context.sh
git commit -m "perf(pkb): native 載入啟用時略過 PKB 逐字 conventions(去三重冗餘)"
```

---

### Task 8 (optional, deferrable): stop PKB generators re-reading auto-loaded files

**Files:**
- Modify: `lib/pkb.sh` (`_pkb_generate_conventions`, the prompt's "Read config files" line ~609)
- Test: `tests/test_pkb_context.sh` (append a unit on the sources-suffix helper)

**Interfaces:**
- Consumes: `config_get loadProjectMemory`.
- Produces: `_pkb_conventions_sources_suffix()` → returns `", CLAUDE.md, AGENTS.md, .claude/rules/"` when native loading is OFF, else `""`. Used to build the generator prompt so generators don't re-read files already in context.

- [ ] **Step 1: Write the failing test** — append before the summary block of `tests/test_pkb_context.sh`:

```bash
# Sources-suffix helper: omit CLAUDE.md/rules from the read list when native loading is on
printf '{"loadProjectMemory": true}\n'  > "$MRA_CONFIG"
[[ -z "$(_pkb_conventions_sources_suffix)" ]] || fail "suffix: ON must be empty"
printf '{"loadProjectMemory": false}\n' > "$MRA_CONFIG"
[[ "$(_pkb_conventions_sources_suffix)" == *"CLAUDE.md"* ]] || fail "suffix: OFF must list CLAUDE.md"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pkb_context.sh`
Expected: FAIL — `_pkb_conventions_sources_suffix: command not found`.

- [ ] **Step 3: Implement** — in `lib/pkb.sh`, add the helper above `_pkb_generate_conventions`:

```bash
# When project-memory native loading is on, claude already has CLAUDE.md /
# AGENTS.md / .claude/rules in context, so the conventions generator should
# not be told to re-read them (avoids double-feeding + echoing auto-loaded text).
_pkb_conventions_sources_suffix() {
  [[ "$(config_get loadProjectMemory 2>/dev/null)" == "false" ]] \
    && echo ", CLAUDE.md, AGENTS.md, .claude/rules/" || echo ""
}
```

Then in `_pkb_generate_conventions`, change the prompt's read line from the hardcoded list to use the suffix. Replace:
```
1. Read config files: .eslintrc*, tsconfig*, prettier*, .editorconfig, CLAUDE.md, AGENTS.md, .claude/rules/.
```
with a computed value built before the heredoc:
```bash
  local sources_suffix; sources_suffix=$(_pkb_conventions_sources_suffix)
```
and in the prompt body:
```
1. Read config files: .eslintrc*, tsconfig*, prettier*, .editorconfig${sources_suffix}.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pkb_context.sh`
Expected: `PASS: all pkb_context tests passed`

- [ ] **Step 5: Commit**

```bash
git add lib/pkb.sh tests/test_pkb_context.sh
git commit -m "perf(pkb): native 載入啟用時 conventions 產生器不重讀 CLAUDE.md/rules"
```

---

## Self-Review

- **Spec coverage:** D1→Tasks 3/6; D2→Tasks 7/8; D3→Tasks 1/2; D4→Tasks 4/5 (hard gate ordered: 4 before 5); D5→Tasks 1/2/5. Risks 1-6 all mapped. ✅
- **Deviation from spec:** Task 4 uses `--setting-sources user,project` (not bare `project`) to avoid dropping the operator's user-scope settings from the interactive session while still excluding `local`/`CLAUDE.local.md`. Spec D4 + risk 1 updated to match.
- **Placeholder scan:** none — every code/test step is concrete.
- **Type/name consistency:** `apply_project_memory_env`, `loadProjectMemory`, `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`, `_pkb_conventions_sources_suffix` used consistently across tasks.
