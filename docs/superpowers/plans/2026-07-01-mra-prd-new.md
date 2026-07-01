# `mra prd --new` Greenfield Planner + Scaffold Apply — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mra prd --new <name>` (greenfield interactive planner that brainstorms architecture from scratch, proposes a repo split, and writes a PRD + specs + task plan + a `<REQ>-scaffold.json`) and `mra prd-scaffold --req <ID> [--confirm] [--dry-run]` (operator-run, TTY-gated apply that `gh repo create`s the planned repos + seeds + registers them in the dep-graph).

**Architecture:** A **plan/apply split** reusing the brownfield `mra prd` machinery byte-for-byte. `mra prd --new` forks early in the `prd)` dispatch to `prd_launch_new` (launches an interactive Claude with `agents/prd-agent-new.md`, zero `--add-dir`, no PKB) and creates nothing. `mra prd-scaffold` mirrors `mra prd-issues`' gated/ungated/pure three-way skeleton: its create path requires an interactive TTY (`[ -t 0 ]`), pins per-repo `GH_TOKEN` via `ghAccounts`, keeps an immutable ledger with `gh repo view` pre-check (abort-not-adopt), and registers repos into the dep-graph with **atomic additive pure-jq** (never `mra scan`).

**Tech Stack:** Bash (sourced libs, dispatched from `bin/mra.sh`), `jq`, `git`, `gh`, interactive `claude`. Tests are plain-bash under `tests/test_*.sh` (auto-discovered by `test.sh`; **bats is NOT installed**).

**Reference spec:** `docs/superpowers/specs/2026-07-01-mra-prd-new-design.md` (decisions D1–D15, §15 critic gaps).

## Global Constraints

- The brownfield `mra prd` path (`prd_launch`, `agents/prd-agent.md`, `mra prd-issues`) must stay **byte-for-byte** — greenfield forks BEFORE reaching it.
- **Scaffold create path requires `[ -t 0 ]` (interactive TTY) AND `--confirm` AND not `--dry-run`** (byte-identical to `prd-issues.sh:197-206`). Any non-TTY caller / missing `--confirm` / `--dry-run` → print plan, create nothing, return 0.
- **Per-repo account pinning:** org = the workspace `gitOrg`; `GH_TOKEN=$(_prd_account_token <bare-org>)` (via `ghAccounts`); abort loud on missing mapping/unresolvable token BEFORE any create. `GH_TOKEN` pinned on every `gh` AND `git push`.
- **Dep-graph registration is additive pure-jq and ATOMIC:** every write goes `jq … "$f" > "$tmp" && mv "$tmp" "$f"` — NEVER `jq … "$f" > "$f"` (truncates before read → destroys the curated graph). NEVER call `build_dep_graph`/`mra scan`.
- **Name validation:** `validate_repo_name` (`branch-ops.sh:17`: rejects empty/`-*`/`.`/`..`/`*/*`) AND `_MRA_ID_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'` (`validate.sh:20`), before any create/mkdir.
- Default repo `--private`; `visibility:"public"` requires explicit plan opt-in; PII/secret scan on names+org+description before any create.
- Tests mock `gh` and `git` as bash **functions** (helpers call bare `gh`/`git`). The interactive `claude` launch is not run in CI. Plain-bash, no `.bats`.
- Conventional commits; one logical change per commit. **Do not push** unless the operator asks.

## File Structure

| File | Responsibility |
|---|---|
| `agents/prd-agent-new.md` (create) | Greenfield interactive system prompt: from-scratch FE/BE/data brainstorm; propose repo split + stack; emit PRD + specs + `<REQ>-tasks.json` + `<REQ>-scaffold.json`; create nothing; end with the prd-scaffold→prd-issues instruction. |
| `lib/prd.sh` (modify) | Add `prd_launch_new` sibling; brownfield `prd_launch`/`_prd_alloc_req_id` unchanged. |
| `lib/launch.sh` (modify) | Guard the unguarded `"${projects[@]}"` expansions with `${projects[@]+"${projects[@]}"}` (greenfield = first empty-array caller). |
| `bin/mra.sh` (modify) | `prd)` loop: guarded `--new)` arm + early fork; `source lib/prd-scaffold.sh`; `prd-scaffold)` case; usage. |
| `lib/prd-scaffold.sh` (create) | Gated `mra_prd_scaffold` + validate/PII/resolve-org/print-plan + ungated `_scaffold_create_all` + pure `_scaffold_register`/`_scaffold_write_scope`. |
| `tests/test_prd.sh` (create) | The `bin/mra.sh` `prd) --new` dispatch fork. |
| `tests/test_prd_scaffold.sh` (create) | The scaffold apply seam (gh+git shims). |
| `tests/test_launch.sh` (modify) | A zero-project `_launch_interactive` case (empty-array guard). |
| `test.sh` (modify), `README.md` (modify) | Register new tests; document the greenfield flow. |

**Execution order:** 1 (prompt) → 2 (prd_launch_new + launch guards) → 3 (dispatch fork) → 4 (test_prd.sh) → 5 (validate/PII/org/print) → 6 (register/scope, pure) → 7 (create worker) → 8 (gated entry) → 9 (prd-scaffold dispatch) → 10 (test_prd_scaffold.sh) → 11 (docs + smoke).

---

## Task 1: `agents/prd-agent-new.md` (greenfield system prompt)

**Files:** Create `agents/prd-agent-new.md`. No automated test (a prompt is reviewed, not executed).

- [ ] **Step 1: Write `agents/prd-agent-new.md`**

```markdown
# mra prd --new — Greenfield Product Planner

You run an **interactive** planning session for a **brand-new** project. There is NO existing
code, no repos, and no PKB — you invent the architecture with the human, then write documents,
a task plan, and a scaffold plan. **You never create repos or issues.**

## Given to you (from the launcher)
- `MRA_PRD_REQ_ID` — the requirement id (e.g. REQ-2026-0001). Use it verbatim.
- `MRA_PRD_NEW_NAME` — the project name the human chose.
- The absolute workspace root; output language directive (if present).

## Method — one question at a time
1. **Intent & scope.** Purpose, users, success criteria.
2. **Propose the repo split + stack.** Based on the above, propose the repos this needs (e.g.
   `<name>-api` (service), `<name>-ui` (web)) and the tech stack, and their dependency edges
   (e.g. ui → api). Present it and let the human confirm/adjust BEFORE writing anything.
3. **Frontend architecture.** Components, routes, state.
4. **Backend architecture.** API contracts, services, auth.
5. **Data architecture.** Schema/models, migrations, ownership.

## Produce (write under <workspace>/.collab/ ONLY)
- **PRD**: `.collab/requirements/<MRA_PRD_REQ_ID>.md` — Problem / Goals / Users / Frontend /
  Backend / Data architecture / Cross-repo impact (derive edges from the repo split you proposed) /
  Task decomposition / Open questions.
- **Per-repo specs**: `.collab/specs/<MRA_PRD_REQ_ID>-<repo>.md` (one per repo in your split).
- **Task Plan JSON**: `.collab/requirements/<MRA_PRD_REQ_ID>-tasks.json`:
  `{ "requirement_id": "<MRA_PRD_REQ_ID>", "title": "...", "tasks": [ {"id","project","title","tier","dependencies","complexity","acceptance_criteria"} ] }`.
  Every `project` MUST be one of the repo names in your scaffold plan.
- **Scaffold Plan JSON**: `.collab/requirements/<MRA_PRD_REQ_ID>-scaffold.json`:
  `{ "requirement_id": "<MRA_PRD_REQ_ID>", "repos": [ {"name","org","visibility","type","description","deps":["<other repo names>"]} ] }`.
  `visibility` defaults to `"private"`. `type` is one of the mra project types (service/web/node-backend/rails-api/…).
- After writing each `.md`, render it: `mra prd-render "<abs .md path>"` (via Bash).

## Hard rules
- Repo names must be simple slugs (letters/digits, `.`/`-`/`_`, ≤64 chars) — no `/`, no leading `-`.
- **NEVER** put secrets, credentials, real personal data, or internal hostnames in any artifact
  (repo names, descriptions, and specs may become public/outward-facing).
- **NEVER** create repos or issues. When the plan is ready, STOP and tell the human to run, in
  their own terminal:
  > `mra prd-scaffold --req <MRA_PRD_REQ_ID> --confirm`   (create the repos)
  > then `mra prd-issues --req <MRA_PRD_REQ_ID> --confirm`   (open the issues)
- Do not write outside `.collab/`; do not commit or push.
```

- [ ] **Step 2: Commit**

```bash
git add agents/prd-agent-new.md
git commit -m "feat(prd): greenfield prd-agent-new system prompt (propose repo split, create nothing)"
```

---

## Task 2: `prd_launch_new` + launch empty-array guards (`lib/prd.sh`, `lib/launch.sh`)

**Files:**
- Modify: `lib/prd.sh` (add `prd_launch_new`), `lib/launch.sh` (guard empty-array expansions)
- Test: `tests/test_launch.sh` (append a zero-project case)

**Interfaces:**
- Consumes: `_prd_alloc_req_id`, `_launch_interactive`.
- Produces: `prd_launch_new "$workspace" "$graph_file" "$new_name"` → allocates the REQ, exports `MRA_PRD_REQ_ID`/`MRA_PRD_MODE=new`/`MRA_PRD_NEW_NAME`, launches `_launch_interactive` with `agents/prd-agent-new.md` and **no** project args, writes **no** scope sidecar.

- [ ] **Step 1: Add the zero-project regression test to `tests/test_launch.sh` (before its footer)**

```bash
# --- greenfield: _launch_interactive with ZERO projects (empty-array safe) ---
SHIM3=$(mktemp -d); export SHIM_OUT3=$(mktemp)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$SHIM_OUT3"\n' > "$SHIM3/claude"; chmod +x "$SHIM3/claude"
WS3=$(mktemp -d); printf '{}' > "$WS3/g.json"
config_get() { echo ""; }; display_deps() { :; }
( MRA_CLAUDE_BIN="$SHIM3/claude" _launch_interactive "$WS3" "$WS3/g.json" "$SHIM3/none.md" "frag" ) 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "zero-project launch does not crash (empty-array safe)" || fail "zero-project launch crashed rc=$rc"
grep -q -- '--append-system-prompt' "$SHIM_OUT3" && ok "zero-project still emits prompt" || fail "no prompt with zero projects"
[[ "$(grep -cx -- '--add-dir' "$SHIM_OUT3")" == "0" ]] && ok "zero --add-dir" || fail "expected 0 --add-dir"
rm -rf "$SHIM3" "$WS3" "$SHIM_OUT3"
```

- [ ] **Step 2: Run — it should FAIL on bash that treats unset `"${projects[@]}"` as an error, or pass on 5.x**

Run: `bash tests/test_launch.sh`
Expected: the new case may pass on bash 5.x but the guard is still required for bash 3.2 portability; if it passes, proceed to add the guard anyway (Step 3) so the behavior is version-independent. (To force the failure locally: `set -u; a=(); echo "${a[@]}"` errors on bash 3.2.)

- [ ] **Step 3: Guard the empty-array expansions in `lib/launch.sh`**

Find every `"${projects[@]}"` in `lib/launch.sh` and replace with the codebase's own guard idiom (as used in `pr-ops.sh:31,67`):

```bash
# before:  build_add_dir_args "$workspace" "${projects[@]}"
# after:   build_add_dir_args "$workspace" ${projects[@]+"${projects[@]}"}
```

Apply the same `${projects[@]+"${projects[@]}"}` wrap to each `"${projects[@]}"` occurrence (the `build_add_dir_args` call, the `display_deps` loop, and any others). No-op on a non-empty array; safe on an empty one under `set -u`.

- [ ] **Step 4: Implement `prd_launch_new` in `lib/prd.sh`**

```bash
# Greenfield sibling of prd_launch: no existing repos/PKB, no scope sidecar.
prd_launch_new() {
  local workspace="$1" graph_file="$2" new_name="$3"
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local req; req=$(_prd_alloc_req_id "$workspace") || return 1
  # Bare org the scaffold apply will require every repo to belong to (org==gitOrg).
  # Compute it authoritatively and hand it to the agent so it can't guess wrong.
  local bare_org; bare_org=$(jq -r '.gitOrg // ""' "$graph_file" 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+).*#\1#')
  export MRA_PRD_REQ_ID="$req"
  export MRA_PRD_MODE=new
  export MRA_PRD_NEW_NAME="$new_name"
  export MRA_PRD_ORG="$bare_org"
  local frags="## mra prd --new session
You are planning a BRAND-NEW project '${new_name}' (${req}). Workspace root: ${workspace}.
No existing repos or PKB — invent the architecture; propose a repo split + stack for the human to confirm.
All new repos belong to the GitHub org: ${bare_org}. Use MRA_PRD_ORG='${bare_org}' verbatim for every repo's 'org' field.
Write ALL artifacts under ${workspace}/.collab/ only. Render each .md via: mra prd-render \"<abs .md>\".
You do NOT create repos or issues. When ready, STOP and tell the operator to run in their own terminal:
  mra prd-scaffold --req ${req} --confirm
  mra prd-issues   --req ${req} --confirm"
  [[ -n "${MRA_PRD_CLAUDE_BIN:-}" ]] && export MRA_CLAUDE_BIN="$MRA_PRD_CLAUDE_BIN"
  # No trailing project args -> zero --add-dir, zero PKB. No scope sidecar (written by scaffold apply).
  ( cd "$workspace" && _launch_interactive "$workspace" "$graph_file" "$mra_dir/agents/prd-agent-new.md" "$frags" )
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test_launch.sh`
Expected: PASS (zero-project case + all prior launch cases).

- [ ] **Step 6: Commit**

```bash
git add lib/prd.sh lib/launch.sh tests/test_launch.sh
git commit -m "feat(prd): prd_launch_new greenfield launcher; guard empty-array launch expansions"
```

---

## Task 3: `bin/mra.sh` `--new` arm + early greenfield fork

**Files:**
- Modify: `bin/mra.sh` (the `prd)` case)
- Test: covered by Task 4 (`tests/test_prd.sh`)

**Interfaces:**
- Consumes: `validate_repo_name` (branch-ops.sh), `_MRA_ID_REGEX` (validate.sh — confirm it's sourced; if not, `source "$MRA_DIR/lib/validate.sh"` near the other sources), `prd_launch_new` (Task 2), the existing `list_all_projects`/`validate_repo_subset`/`prd_launch`.

- [ ] **Step 1: Add the guarded `--new)` arm + fork to the `prd)` case**

In `bin/mra.sh`, the `prd)` case currently declares `local prd_projects=()` and parses flags. Add a `new_name` local and the guarded arm ABOVE the `-*)` catch, then fork after the loop:

```bash
    prd)
      shift
      local workspace; workspace=$(resolve_workspace)
      local graph_file="$workspace/.collab/dep-graph.json"
      local prd_projects=() new_name=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --new)
            [[ -n "${2:-}" && "$2" != -* ]] || { log_error "usage: mra prd --new <name>" "prd"; exit 1; }
            new_name="$2"; shift 2 ;;
          --no-sync) shift ;;   # accepted no-op (existing)
          -*) log_error "unknown option: $1" "prd"; exit 1 ;;
          *) prd_projects+=("$1"); shift ;;
        esac
      done
      if [[ -n "$new_name" ]]; then
        [[ "${#prd_projects[@]}" -eq 0 ]] || { log_error "prd --new takes no positional projects" "prd"; exit 1; }
        validate_repo_name "$new_name" || { log_error "invalid project name: $new_name" "prd"; exit 1; }
        [[ "$new_name" =~ $_MRA_ID_REGEX ]] || { log_error "name must match $_MRA_ID_REGEX" "prd"; exit 1; }
        prd_launch_new "$workspace" "$graph_file" "$new_name"
      else
        if [[ "${#prd_projects[@]}" -eq 0 ]]; then
          while IFS= read -r p; do prd_projects+=("$p"); done < <(list_all_projects "$graph_file")
        else
          validate_repo_subset "$workspace" "${prd_projects[@]}" || exit 1
        fi
        prd_launch "$workspace" "$graph_file" "${prd_projects[@]}"
      fi
      ;;
```

> Confirm `_MRA_ID_REGEX` is in scope: `grep -n 'source.*validate.sh' bin/mra.sh`. If absent, add `source "$MRA_DIR/lib/validate.sh"` in the source block.

- [ ] **Step 2: Smoke it**

Run: `bash bin/mra.sh prd --new billing --no-sync` from a temp workspace via `MRA_WORKSPACE` — expect a clean usage error only if the name is bad; otherwise it will try to launch (use an `MRA_CLAUDE_BIN` stub in Task 4's test). Bad-name form: `bash bin/mra.sh prd --new -bad` → usage error, exit 1.

- [ ] **Step 3: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(prd): mra prd --new arm + early greenfield fork (bypass validate_repo_subset)"
```

---

## Task 4: `tests/test_prd.sh` — the `--new` dispatch fork

**Files:**
- Create: `tests/test_prd.sh`
- Modify: `test.sh` (register it)

**Interfaces:** exercises `bin/mra.sh prd --new` end-to-end with stubs.

- [ ] **Step 1: Write `tests/test_prd.sh`**

```bash
#!/usr/bin/env bash
# The bin/mra.sh `prd) --new` greenfield dispatch fork.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

MRA="$SCRIPT_DIR/bin/mra.sh"
WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"; printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS/.collab/dep-graph.json"
# a claude stub that records the injected system prompt
SHIM=$(mktemp -d); export SHIM_OUT=$(mktemp)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$SHIM_OUT"\n' > "$SHIM/claude"; chmod +x "$SHIM/claude"

run() { ( cd "$WS" && MRA_WORKSPACE="$WS" MRA_CLAUDE_BIN="$SHIM/claude" bash "$MRA" "$@" </dev/null ) 2>&1; }

# 1. --new <name> forks to greenfield: launched prompt contains the greenfield markers
: > "$SHIM_OUT"; rc_out=$(run prd --new billing); rc=$?
grep -q 'BRAND-NEW project' "$SHIM_OUT" && ok "--new forks to greenfield prompt" || fail "greenfield prompt not launched: $rc_out"
grep -q 'mra prd-scaffold' "$SHIM_OUT" && ok "greenfield instructs prd-scaffold" || fail "no scaffold handoff in prompt"
[[ "$(grep -cx -- '--add-dir' "$SHIM_OUT")" == "0" ]] && ok "greenfield loads zero repos" || fail "greenfield added --add-dir"

# 2. --new with a flag value is rejected (never captured as a repo name)
out=$(run prd --new --no-sync); rc=$?
[[ "$rc" -ne 0 ]] && ok "--new --no-sync rejected" || fail "--new captured a flag as name"

# 3. --new with a bad slug rejected
out=$(run prd --new -bad); [[ "$?" -ne 0 ]] && ok "--new -bad rejected" || fail "bad slug accepted"

# 4. --new with a stray positional rejected
out=$(run prd --new billing extra); [[ "$?" -ne 0 ]] && ok "--new + stray positional rejected" || fail "stray positional accepted"

# 5. greenfield does NOT reach list_all_projects/validate_repo_subset:
#    the dep-graph has zero projects; if the brownfield branch ran with no args it would
#    launch orchestrator/prd with 0 projects — assert the greenfield prompt ran instead (covered by #1).
rm -rf "$WS" "$SHIM" "$SHIM_OUT"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd dispatch tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run to verify it fails, then register + pass**

Run: `bash tests/test_prd.sh` — should FAIL first if the fork isn't wired (it is, after Task 3, so it should PASS). Then add `tests/test_prd.sh` to `test.sh` if the runner uses an explicit list (it globs `tests/test_*.sh`, so no edit needed — confirm with `grep -n 'test_\*' test.sh`).

- [ ] **Step 3: Run the full dev-adjacent suite**

Run: `bash tests/test_prd.sh && bash tests/test_prd_cli.sh && bash tests/test_launch.sh`
Expected: all PASS (brownfield prd unaffected).

- [ ] **Step 4: Commit**

```bash
git add tests/test_prd.sh
git commit -m "test(prd): mra prd --new dispatch fork (greenfield, flag-not-name, bad-slug, stray-positional)"
```

---

## Task 5: `lib/prd-scaffold.sh` — validate + PII + resolve-org + print-plan

**Files:**
- Create: `lib/prd-scaffold.sh`
- Test: `tests/test_prd_scaffold.sh`

**Interfaces:**
- Consumes: `validate_repo_name` (branch-ops.sh), `_MRA_ID_REGEX` (validate.sh), `jq`.
- Produces:
  - `_scaffold_resolve_org "$gitorg"` → echoes the bare org (`git@github.com:onead` → `onead`).
  - `_scaffold_validate_plan "$scaffold_json" "$tasks_json" "$req" "$bare_org"` → returns 1 (naming the bad field) if `requirement_id != req`, any repo lacks `name/org/visibility/type`, a `name` fails `validate_repo_name`/`_MRA_ID_REGEX`, `org != bare_org`, `visibility ∉ {private,public}`, or (if tasks.json exists) any `task.project ⊄ repos.name`.
  - `_scaffold_scan_pii "$scaffold_json"` → returns 1 if names/org/description hit PII/secret patterns.
  - `_scaffold_print_plan "$scaffold_json" "$bare_org"` → prints the "will create" list to stderr.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_prd_scaffold.sh`:

```bash
#!/usr/bin/env bash
# mra prd-scaffold apply: validate / PII / org / gate / create / register.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/branch-ops.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/prd-issues.sh"   # _prd_account_token
source "$SCRIPT_DIR/lib/prd-scaffold.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"
printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS/.collab/dep-graph.json"
mk() { cat > "$WS/.collab/requirements/$1"; }

assert_eq "resolve bare org (ssh)" "acme" "$(_scaffold_resolve_org 'git@github.com:acme')"
assert_eq "resolve bare org (https)" "acme" "$(_scaffold_resolve_org 'https://github.com/acme')"

mk REQ-2026-0001-scaffold.json <<'JSON'
{"requirement_id":"REQ-2026-0001","repos":[
 {"name":"billing-api","org":"acme","visibility":"private","type":"service","description":"api","deps":[]},
 {"name":"billing-ui","org":"acme","visibility":"private","type":"web","description":"ui","deps":["billing-api"]}]}
JSON
mk REQ-2026-0001-tasks.json <<'JSON'
{"requirement_id":"REQ-2026-0001","tasks":[{"id":"t1","project":"billing-api","title":"x","tier":1,"dependencies":[],"acceptance_criteria":["a"]}]}
JSON
SJ="$WS/.collab/requirements/REQ-2026-0001-scaffold.json"; TJ="$WS/.collab/requirements/REQ-2026-0001-tasks.json"

_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-0001 acme; assert_eq "valid plan ok" "0" "$?"
_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-9999 acme >/dev/null 2>&1; assert_eq "req mismatch aborts" "1" "$?"
_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-0001 other >/dev/null 2>&1; assert_eq "org != gitOrg aborts" "1" "$?"
# bad slug
mk bad-scaffold.json <<'JSON'
{"requirement_id":"R","repos":[{"name":"-bad","org":"acme","visibility":"private","type":"service"}]}
JSON
_scaffold_validate_plan "$WS/.collab/requirements/bad-scaffold.json" "" R acme >/dev/null 2>&1; assert_eq "bad slug aborts" "1" "$?"
# task project not in repos
mk tj2.json <<'JSON'
{"requirement_id":"REQ-2026-0001","tasks":[{"id":"t1","project":"nope","title":"x","tier":1,"dependencies":[],"acceptance_criteria":["a"]}]}
JSON
_scaffold_validate_plan "$SJ" "$WS/.collab/requirements/tj2.json" REQ-2026-0001 acme >/dev/null 2>&1; assert_eq "task project not in repos aborts" "1" "$?"
# PII
mk pii-scaffold.json <<'JSON'
{"requirement_id":"R","repos":[{"name":"api","org":"acme","visibility":"private","type":"service","description":"contact john@acme.com"}]}
JSON
_scaffold_scan_pii "$WS/.collab/requirements/pii-scaffold.json" >/dev/null 2>&1; assert_eq "PII in description aborts" "1" "$?"
_scaffold_scan_pii "$SJ"; assert_eq "clean plan passes PII" "0" "$?"

# (gate + create + register cases appended in Tasks 6-8)
rm -rf "$WS"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-scaffold tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_prd_scaffold.sh`
Expected: FAIL — `_scaffold_resolve_org: command not found`.

- [ ] **Step 3: Implement the header + these four functions in `lib/prd-scaffold.sh`**

```bash
#!/usr/bin/env bash
# `mra prd-scaffold` apply: create the greenfield-planned repos + register them.
# Mirrors lib/prd-issues.sh's gated/ungated/pure three-way skeleton and its TTY gate.

# git@github.com:acme  OR  https://github.com/acme  -> acme
_scaffold_resolve_org() { printf '%s' "$1" | sed -E 's#.*github\.com[:/]([^/]+).*#\1#'; }

_scaffold_validate_plan() {
  local sj="$1" tj="$2" req="$3" bare_org="$4"
  jq -e . "$sj" >/dev/null 2>&1 || { log_error "scaffold.json not valid JSON: $sj" "prd"; return 1; }
  [[ "$(jq -r '.requirement_id // ""' "$sj")" == "$req" ]] || { log_error "scaffold requirement_id mismatch" "prd"; return 1; }
  local names; names=" $(jq -r '.repos[].name' "$sj" | tr '\n' ' ') "
  local n; n=$(jq '.repos | length' "$sj")
  [[ "$n" -ge 1 ]] || { log_error "scaffold plan has no repos" "prd"; return 1; }
  local i
  for (( i=0; i<n; i++ )); do
    local r name org vis f; r=$(jq -c ".repos[$i]" "$sj")
    for f in name org visibility type; do
      printf '%s' "$r" | jq -e "has(\"$f\")" >/dev/null 2>&1 || { log_error "repo[$i] missing field: $f" "prd"; return 1; }
    done
    name=$(printf '%s' "$r"|jq -r .name); org=$(printf '%s' "$r"|jq -r .org); vis=$(printf '%s' "$r"|jq -r .visibility)
    validate_repo_name "$name" || { log_error "invalid repo name: $name" "prd"; return 1; }
    [[ "$name" =~ $_MRA_ID_REGEX ]] || { log_error "repo name outside $_MRA_ID_REGEX: $name" "prd"; return 1; }
    [[ "$org" == "$bare_org" ]] || { log_error "repo $name org '$org' != workspace org '$bare_org' (v1 single-org)" "prd"; return 1; }
    [[ "$vis" == "private" || "$vis" == "public" ]] || { log_error "repo $name visibility must be private|public" "prd"; return 1; }
  done
  if [[ -n "$tj" && -f "$tj" ]]; then
    local p
    while IFS= read -r p; do [[ -z "$p" ]] && continue; [[ "$names" == *" $p "* ]] || { log_error "task project '$p' not in scaffold repos" "prd"; return 1; }; done < <(jq -r '.tasks[]?.project' "$tj")
  fi
  return 0
}

_scaffold_scan_pii() {
  local sj="$1" hits
  hits=$(jq -r '.repos[] | .name, .org, (.description // "")' "$sj" \
    | grep -niE '@[a-z0-9._-]+\.(com|org|net|io|tv)|(ghp_|sk-|AKIA)[A-Za-z0-9]{10,}|-----BEGIN' || true)
  [[ -z "$hits" ]] || { log_error "prd-scaffold: possible secret/PII in scaffold plan — aborting" "prd"; printf '%s\n' "$hits" >&2; return 1; }
  return 0
}

_scaffold_print_plan() {
  local sj="$1" org="$2" n i
  log_info "Scaffold plan (org $org):" "prd"
  n=$(jq '.repos|length' "$sj")
  for (( i=0; i<n; i++ )); do
    printf '  create %s/%s [%s] %s\n' "$org" "$(jq -r ".repos[$i].name" "$sj")" "$(jq -r ".repos[$i].visibility" "$sj")" "$(jq -r ".repos[$i].type" "$sj")" >&2
  done
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_prd_scaffold.sh`
Expected: PASS (resolve-org, validate cases, PII cases).

- [ ] **Step 5: Commit**

```bash
git add lib/prd-scaffold.sh tests/test_prd_scaffold.sh
git commit -m "feat(prd): scaffold plan validation, org resolution, PII scan, print-plan"
```

---

## Task 6: pure `_scaffold_register` + `_scaffold_write_scope` (atomic additive jq)

**Files:**
- Modify: `lib/prd-scaffold.sh`
- Test: `tests/test_prd_scaffold.sh` (append)

**Interfaces:**
- Produces:
  - `_scaffold_register "$ws" "$name" "$type" "$desc" "$deps_csv"` — idempotent, name-keyed, **additive** upsert into `.collab/dep-graph.json` (`.projects[name]` in the init shape, only if absent), `.collab/manual-deps.json` (append `{source:name,target:dep,type:"api"}` per dep), `.collab/repos.json` (`.repos[]` append). Inits missing `manual-deps.json`/`repos.json`. **Every write is `jq … "$f" > "$tmp" && mv "$tmp" "$f"`** (never in-place). No `gh`/`git`.
  - `_scaffold_write_scope "$ws" "$req" "$name..."` — writes `<REQ>-scope` (space-separated created names).

- [ ] **Step 1: Append the failing tests (before the footer in `tests/test_prd_scaffold.sh`)**

```bash
# --- pure register: additive, atomic, curated-node-untouched, idempotent ---
WS2=$(mktemp -d); mkdir -p "$WS2/.collab/requirements"
# a CURATED dep-graph with an existing repo carrying edges we must not lose
cat > "$WS2/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"git@github.com:acme","projects":{"erp":{"type":"rails-api","port":3000,"deps":{},"consumedBy":["partner-api-gateway"],"confidence":{"x":1}}}}
JSON
_scaffold_register "$WS2" "billing-api" "service" "api" ""
_scaffold_register "$WS2" "billing-ui" "web" "ui" "billing-api"
# curated node byte-preserved (still has consumedBy + confidence)
assert_eq "curated erp.consumedBy preserved" "partner-api-gateway" "$(jq -r '.projects.erp.consumedBy[0]' "$WS2/.collab/dep-graph.json")"
assert_eq "curated erp.confidence preserved" "1" "$(jq -r '.projects.erp.confidence.x' "$WS2/.collab/dep-graph.json")"
# new nodes added in init shape
assert_eq "billing-api node type" "service" "$(jq -r '.projects["billing-api"].type' "$WS2/.collab/dep-graph.json")"
assert_eq "billing-api init shape port null" "null" "$(jq -r '.projects["billing-api"].port' "$WS2/.collab/dep-graph.json")"
# manual-deps + repos.json created (were absent) and populated
assert_eq "manual-deps edge ui->api" "billing-api" "$(jq -r '.[]|select(.source=="billing-ui").target' "$WS2/.collab/manual-deps.json")"
assert_eq "repos.json entry" "billing-ui" "$(jq -r '.repos[]|select(.name=="billing-ui").name' "$WS2/.collab/repos.json")"
# idempotent: re-run adds nothing
before=$(jq '.projects|length' "$WS2/.collab/dep-graph.json")
_scaffold_register "$WS2" "billing-api" "service" "api" ""
assert_eq "register idempotent (no dup node)" "$before" "$(jq '.projects|length' "$WS2/.collab/dep-graph.json")"
assert_eq "register idempotent (no dup repo)" "1" "$(jq '[.repos[]|select(.name=="billing-api")]|length' "$WS2/.collab/repos.json")"
# scope written
_scaffold_write_scope "$WS2" REQ-2026-0002 billing-api billing-ui
assert_eq "scope file content" "billing-api billing-ui" "$(cat "$WS2/.collab/requirements/REQ-2026-0002-scope")"
rm -rf "$WS2"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_prd_scaffold.sh`
Expected: FAIL — `_scaffold_register: command not found`.

- [ ] **Step 3: Implement `_scaffold_register` + `_scaffold_write_scope`**

```bash
# Additive, atomic (jq > $tmp && mv), name-keyed idempotent. NEVER build_dep_graph/mra scan.
_scaffold_register() {
  local ws="$1" name="$2" type="$3" desc="$4" deps_csv="$5"
  local dg="$ws/.collab/dep-graph.json" md="$ws/.collab/manual-deps.json" rj="$ws/.collab/repos.json" tmp
  [[ -f "$md" ]] || echo '[]' > "$md"                 # init if absent (§15 fix 2)
  [[ -f "$rj" ]] || echo '{"repos":[]}' > "$rj"
  # 1) dep-graph node, init shape, only if absent — ATOMIC (§15 fix 1)
  tmp=$(mktemp)
  jq --arg n "$name" --arg t "$type" \
    '.projects[$n] = (.projects[$n] // {"type":$t,"port":null,"dockerImage":null,"dockerCompose":null,"lastCommit":"unknown","deps":{},"consumedBy":[],"confidence":{}})' \
    "$dg" > "$tmp" && mv "$tmp" "$dg"
  # 2) manual-deps edges (source depends on target), dedup — ATOMIC
  local d; IFS=',' read -ra darr <<< "$deps_csv"
  for d in ${darr[@]+"${darr[@]}"}; do
    [[ -z "$d" ]] && continue
    tmp=$(mktemp)
    jq --arg s "$name" --arg t "$d" \
      'if any(.[]?; .source==$s and .target==$t) then . else . + [{"source":$s,"target":$t,"type":"api"}] end' \
      "$md" > "$tmp" && mv "$tmp" "$md"
  done
  # 3) repos.json entry, dedup — ATOMIC
  tmp=$(mktemp)
  jq --arg n "$name" --arg desc "$desc" \
    'if any(.repos[]?; .name==$n) then . else .repos += [{"name":$n,"clone":true,"branch":"main","description":$desc,"archived":false}] end' \
    "$rj" > "$tmp" && mv "$tmp" "$rj"
}

_scaffold_write_scope() {
  local ws="$1" req="$2"; shift 2
  printf '%s\n' "$*" > "$ws/.collab/requirements/$req-scope"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_prd_scaffold.sh`
Expected: PASS (curated node preserved, new nodes in init shape, manual-deps/repos.json created + populated, idempotent, scope written).

- [ ] **Step 5: Commit**

```bash
git add lib/prd-scaffold.sh tests/test_prd_scaffold.sh
git commit -m "feat(prd): atomic additive dep-graph/manual-deps/repos.json registration + scope writer"
```

---

## Task 7: `_scaffold_create_all` worker (ungated: gh/git, ledger, resume)

**Files:**
- Modify: `lib/prd-scaffold.sh`
- Test: `tests/test_prd_scaffold.sh` (append)

**Interfaces:**
- Consumes: `_prd_account_token` (prd-issues.sh), `_scaffold_register` (Task 6), bare `gh`/`git` (mockable).
- Produces: `_scaffold_create_all "$ws" "$scaffold_json" "$req" "$bare_org"` — the un-gated worker (tested directly since the gate needs a TTY). Per repo in plan order: in-ledger→skip; else `gh repo view` pre-check (exists-not-in-ledger→**abort**), else create in `( cd "$ws" && … --clone )`, write ledger `{created:true,registered:false}` immediately, verify/fallback clone, seed commit+push (GH_TOKEN pinned), `_scaffold_register`, flip `registered:true`. Aborts (return 1) on token/create failure. Writes `<REQ>-scope` from created names.

- [ ] **Step 1: Append the failing tests (before the footer)**

```bash
# --- create worker: order, ledger, adopt-abort, resume, register+scope (gh+git shimmed) ---
WS3=$(mktemp -d); mkdir -p "$WS3/.collab/requirements"
printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS3/.collab/dep-graph.json"
cat > "$WS3/.collab/requirements/REQ-2026-0003-scaffold.json" <<'JSON'
{"requirement_id":"REQ-2026-0003","repos":[
 {"name":"billing-api","org":"acme","visibility":"private","type":"service","description":"api","deps":[]},
 {"name":"billing-ui","org":"acme","visibility":"private","type":"web","description":"ui","deps":["billing-api"]}]}
JSON
SJ3="$WS3/.collab/requirements/REQ-2026-0003-scaffold.json"
GH_LOG=$(mktemp)
config_get() { [[ "$1" == ghAccounts ]] && echo '{"acme":"acme-bot"}' || echo ""; }
gh() {
  echo "gh $*" >> "$GH_LOG"
  case "$1 $2" in
    "auth token") echo "TOK";;
    "repo view") return 1;;                # not exists -> allow create
    "repo create") ( cd "$3"/../ 2>/dev/null; : );;  # clone side effect faked by git() below
    *) return 0;;
  esac
}
git() { echo "git $*" >> "$GH_LOG"; case "$*" in *"init"*) mkdir -p "${3:-.}/.git";; esac; return 0; }
# make the fake clone land at $ws/name: intercept `gh repo create ... --clone` by pre-creating the dir
gh() {
  echo "gh $*" >> "$GH_LOG"
  case "$1 $2" in
    "auth token") echo "TOK";;
    "repo view") return 1;;
    "repo create") local slug; for a in "$@"; do case "$a" in acme/*) slug="${a#acme/}";; esac; done; mkdir -p "$PWD/$slug/.git";;
    *) return 0;;
  esac
}
( cd "$WS3" && _scaffold_create_all "$WS3" "$SJ3" REQ-2026-0003 acme ) >/dev/null 2>&1
LED="$WS3/.collab/requirements/REQ-2026-0003-scaffold-repos.json"
assert_eq "ledger billing-api created" "true" "$(jq -r '.["billing-api"].created' "$LED")"
assert_eq "ledger billing-api registered" "true" "$(jq -r '.["billing-api"].registered' "$LED")"
assert_eq "two repo create calls" "2" "$(grep -c 'repo create' "$GH_LOG")"
grep -q 'repo create acme/billing-api' "$GH_LOG" && ok "created api before ui (order)" || fail "creation order wrong"
assert_eq "dep-graph got billing-ui node" "web" "$(jq -r '.projects["billing-ui"].type' "$WS3/.collab/dep-graph.json")"
assert_eq "scope from created" "billing-api billing-ui" "$(cat "$WS3/.collab/requirements/REQ-2026-0003-scope")"
# resume: re-run creates nothing new
: > "$GH_LOG"; ( cd "$WS3" && _scaffold_create_all "$WS3" "$SJ3" REQ-2026-0003 acme ) >/dev/null 2>&1
assert_eq "resume creates nothing" "0" "$(grep -c 'repo create' "$GH_LOG")"
# adopt-abort: a fresh plan repo that gh repo view says EXISTS -> abort, no create
cat > "$WS3/.collab/requirements/REQ-2026-0004-scaffold.json" <<'JSON'
{"requirement_id":"REQ-2026-0004","repos":[{"name":"already-there","org":"acme","visibility":"private","type":"service","description":"x","deps":[]}]}
JSON
gh() { echo "gh $*" >> "$GH_LOG"; case "$1 $2" in "auth token") echo TOK;; "repo view") return 0;; "repo create") echo SHOULD_NOT >> "$GH_LOG";; *) return 0;; esac; }
: > "$GH_LOG"; ( cd "$WS3" && _scaffold_create_all "$WS3" "$WS3/.collab/requirements/REQ-2026-0004-scaffold.json" REQ-2026-0004 acme ) >/dev/null 2>&1; rc=$?
assert_eq "adopt-abort returns 1" "1" "$rc"
grep -q 'SHOULD_NOT' "$GH_LOG" && fail "created an existing repo (adopt!)" || ok "adopt-abort: no create on existing repo"
unset -f gh git config_get
rm -rf "$WS3" "$GH_LOG"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_prd_scaffold.sh`
Expected: FAIL — `_scaffold_create_all: command not found`.

- [ ] **Step 3: Implement `_scaffold_create_all`**

```bash
_scaffold_create_all() {
  local ws="$1" sj="$2" req="$3" bare_org="$4"
  local ledger="$ws/.collab/requirements/$req-scaffold-repos.json"
  [[ -f "$ledger" ]] || echo '{}' > "$ledger"
  local tok; tok=$(_prd_account_token "$bare_org") || return 1   # abort before any create
  local created=() n i; n=$(jq '.repos|length' "$sj")
  for (( i=0; i<n; i++ )); do
    local name vis desc type deps
    name=$(jq -r ".repos[$i].name" "$sj"); vis=$(jq -r ".repos[$i].visibility" "$sj")
    desc=$(jq -r ".repos[$i].description // \"\"" "$sj"); type=$(jq -r ".repos[$i].type" "$sj")
    deps=$(jq -r "[.repos[$i].deps[]?]|join(\",\")" "$sj")
    if jq -e --arg n "$name" 'has($n)' "$ledger" >/dev/null 2>&1; then
      created+=("$name")   # resume: already created
    else
      if GH_TOKEN="$tok" gh repo view "$bare_org/$name" >/dev/null 2>&1; then
        log_error "repo $bare_org/$name already exists (not from this run) — aborting (adopt not supported)" "prd"; return 1
      fi
      ( cd "$ws" && GH_TOKEN="$tok" gh repo create "$bare_org/$name" "--$vis" --description "$desc" --clone ) \
        || { log_error "gh repo create failed: $name" "prd"; return 1; }
      local tmp; tmp=$(mktemp)
      jq --arg n "$name" --arg o "$bare_org" --arg v "$vis" \
        '. + {($n):{org:$o,url:("https://github.com/"+$o+"/"+$n),visibility:$v,created:true,registered:false}}' \
        "$ledger" > "$tmp" && mv "$tmp" "$ledger"
      # verify clone landed at $ws/name; fallback for unborn/no-clone
      [[ -d "$ws/$name/.git" ]] || { mkdir -p "$ws/$name"; git -C "$ws/$name" init -q; \
        git -C "$ws/$name" remote add origin "https://github.com/$bare_org/$name.git" 2>/dev/null || true; }
      GH_TOKEN="$tok" git -C "$ws/$name" commit --allow-empty -q -m "chore: scaffold $name ($req)" || true
      GH_TOKEN="$tok" git -C "$ws/$name" push -u origin HEAD >/dev/null 2>&1 || log_warn "push failed for $name (re-run to resume)" "prd"
      created+=("$name")
    fi
    _scaffold_register "$ws" "$name" "$type" "$desc" "$deps"
    local tmp2; tmp2=$(mktemp)
    jq --arg n "$name" '.[$n].registered = true' "$ledger" > "$tmp2" && mv "$tmp2" "$ledger"
  done
  _scaffold_write_scope "$ws" "$req" ${created[@]+"${created[@]}"}
}
```

> Note (§15 fix 4): `GH_TOKEN=$tok git push` relies on `gh auth git-credential` honoring `GH_TOKEN` for https remotes. Task 11's smoke + a doc note verify this on a real repo; v1 is single-org so blast radius is bounded.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_prd_scaffold.sh`
Expected: PASS (order, ledger created/registered, register into dep-graph, scope, resume-skip, adopt-abort).

- [ ] **Step 5: Commit**

```bash
git add lib/prd-scaffold.sh tests/test_prd_scaffold.sh
git commit -m "feat(prd): scaffold create worker — gh repo view pre-check, create+clone, ledger/resume, seed, register"
```

---

## Task 8: gated `mra_prd_scaffold` entry (TTY gate)

**Files:**
- Modify: `lib/prd-scaffold.sh`
- Test: `tests/test_prd_scaffold.sh` (append gate tests)

**Interfaces:**
- Produces: `mra_prd_scaffold --scaffold <path> --tasks <path> --req <ID> [--confirm] [--dry-run]` — validate→PII→resolve-org→token→print-plan→gate→`_scaffold_create_all`. Creates ONLY when `[ -t 0 ]` AND `--confirm` AND not `--dry-run` AND the TTY `[y/N]` is yes. Otherwise prints and returns 0.

- [ ] **Step 1: Append the gate tests (before the footer)**

```bash
# --- gate: non-TTY / no-confirm / dry-run create nothing ---
WS4=$(mktemp -d); mkdir -p "$WS4/.collab/requirements"
printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS4/.collab/dep-graph.json"
cat > "$WS4/.collab/requirements/REQ-2026-0005-scaffold.json" <<'JSON'
{"requirement_id":"REQ-2026-0005","repos":[{"name":"api","org":"acme","visibility":"private","type":"service","description":"x","deps":[]}]}
JSON
SJ4="$WS4/.collab/requirements/REQ-2026-0005-scaffold.json"
config_get() { [[ "$1" == ghAccounts ]] && echo '{"acme":"acme-bot"}' || echo ""; }
gh() { case "$1 $2" in "auth token") echo TOK;; esac; return 0; }
_scaffold_create_all() { echo "CREATE_CALLED"; }   # stub the worker; gate must not reach it
out=$(mra_prd_scaffold --scaffold "$SJ4" --tasks "" --req REQ-2026-0005 </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "no --confirm -> no create" || fail "created without --confirm"
out=$(mra_prd_scaffold --scaffold "$SJ4" --tasks "" --req REQ-2026-0005 --confirm --dry-run </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "--dry-run -> no create" || fail "created under --dry-run"
out=$(mra_prd_scaffold --scaffold "$SJ4" --tasks "" --req REQ-2026-0005 --confirm </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "non-TTY + --confirm -> no create" || fail "created from non-TTY"
# missing scaffold file -> error
mra_prd_scaffold --scaffold "$WS4/.collab/requirements/nope.json" --req R </dev/null >/dev/null 2>&1; assert_eq "missing scaffold aborts" "1" "$?"
unset -f _scaffold_create_all gh config_get
rm -rf "$WS4"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_prd_scaffold.sh`
Expected: FAIL — `mra_prd_scaffold: command not found`.

- [ ] **Step 3: Implement `mra_prd_scaffold`**

```bash
mra_prd_scaffold() {
  local scaffold="" tasks="" req="" confirm=false dry=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scaffold) scaffold="${2:-}"; shift 2;;
      --tasks) tasks="${2:-}"; shift 2;;
      --req) req="${2:-}"; shift 2;;
      --confirm) confirm=true; shift;;
      --dry-run) dry=true; shift;;
      *) log_error "prd-scaffold: unknown arg: $1" "prd"; return 1;;
    esac
  done
  [[ -n "$scaffold" && -n "$req" ]] || { log_error "usage: mra prd-scaffold --req <ID> [--confirm] [--dry-run]" "prd"; return 1; }
  [[ -f "$scaffold" ]] || { log_error "scaffold plan not found: $scaffold" "prd"; return 1; }
  local ws; ws=$(cd "$(dirname "$scaffold")/../.." && pwd)
  local gitorg bare_org
  gitorg=$(jq -r '.gitOrg // ""' "$ws/.collab/dep-graph.json" 2>/dev/null); bare_org=$(_scaffold_resolve_org "$gitorg")
  _scaffold_validate_plan "$scaffold" "$tasks" "$req" "$bare_org" || return 1
  _scaffold_scan_pii "$scaffold" || return 1
  _prd_account_token "$bare_org" >/dev/null || return 1     # fail-loud before the gate
  _scaffold_print_plan "$scaffold" "$bare_org"
  if [[ "$dry" == true || "$confirm" != true ]]; then
    log_info "preview only — no repos created. Re-run with --confirm in your terminal." "prd"; return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "refusing to create repos non-interactively — run \`mra prd-scaffold --req $req --confirm\` in your own terminal" "prd"; return 0
  fi
  local cnt; cnt=$(jq '.repos|length' "$scaffold")
  printf 'Create %s repo(s) in %s? [y/N] ' "$cnt" "$bare_org" > /dev/tty
  local ans; read -r ans < /dev/tty
  [[ "$ans" == [yY]* ]] || { log_info "aborted — no repos created." "prd"; return 0; }
  _scaffold_create_all "$ws" "$scaffold" "$req" "$bare_org"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_prd_scaffold.sh`
Expected: PASS (gate blocks non-TTY/no-confirm/dry-run; missing scaffold aborts; all earlier cases).

- [ ] **Step 5: Commit**

```bash
git add lib/prd-scaffold.sh tests/test_prd_scaffold.sh
git commit -m "feat(prd): TTY/confirm-gated mra_prd_scaffold entry (mirrors prd-issues gate)"
```

---

## Task 9: `bin/mra.sh` `prd-scaffold)` dispatch + source + usage

**Files:**
- Modify: `bin/mra.sh`
- Test: covered by Task 10 (a dispatch smoke)

**Interfaces:** Consumes `resolve_workspace`, `mra_prd_scaffold` (Task 8).

- [ ] **Step 1: Source the lib + add the `prd-scaffold)` case (mirror `prd-issues)`)**

In the source block (after `source "$MRA_DIR/lib/prd-issues.sh"`):
```bash
source "$MRA_DIR/lib/prd-scaffold.sh"
```
Add the case after `prd-issues)` (it mirrors it but requires `<REQ>-scaffold.json` instead of `<REQ>-scope`, and does NOT call `validate_repo_subset`):
```bash
    prd-scaffold)
      shift
      local workspace; workspace=$(resolve_workspace)
      local req="" extra=()
      while [[ $# -gt 0 ]]; do case "$1" in --req) req="$2"; shift 2 ;; *) extra+=("$1"); shift ;; esac; done
      [[ -n "$req" ]] || { log_error "usage: mra prd-scaffold --req <REQ-ID> [--confirm] [--dry-run]" "prd"; exit 1; }
      local scaffold="$workspace/.collab/requirements/$req-scaffold.json"
      local tasks="$workspace/.collab/requirements/$req-tasks.json"
      [[ -f "$scaffold" ]] || { log_error "not a greenfield REQ (no scaffold plan) — was it created by 'mra prd --new'?" "prd"; exit 1; }
      mra_prd_scaffold --scaffold "$scaffold" --tasks "$tasks" --req "$req" "${extra[@]}"
      ;;
```
Add the usage line near the other prd verbs:
```bash
  prd-scaffold --req <ID> [--confirm] [--dry-run]   Apply: create the greenfield-planned repos (operator-run, TTY-gated)
```

- [ ] **Step 2: Smoke it**

Run: from a temp workspace, `MRA_WORKSPACE=<ws> bash bin/mra.sh prd-scaffold --req REQ-2026-0001` with a fixture `<ws>/.collab/requirements/REQ-2026-0001-scaffold.json` and no `--confirm` → exits 0, prints the plan, creates nothing. Missing scaffold → exit 1.

- [ ] **Step 3: Commit**

```bash
git add bin/mra.sh
git commit -m "feat(prd): mra prd-scaffold dispatch (requires <REQ>-scaffold.json, TTY-gated apply)"
```

---

## Task 10: wire tests into `test.sh` + full suite

**Files:**
- Modify: `test.sh` (only if it uses an explicit list, not a glob)
- Test: the whole suite

- [ ] **Step 1: Confirm the runner discovers the new tests**

Run: `grep -nE 'tests/test_\*|for script' test.sh`
`test.sh` globs `tests/test_*.sh` — `test_prd.sh` and `test_prd_scaffold.sh` are auto-discovered; no edit needed. If (and only if) `test.sh` uses an explicit list, add both files.

- [ ] **Step 2: Append a `prd-scaffold)` dispatch smoke to `tests/test_prd_scaffold.sh` (before footer)**

```bash
# --- dispatch smoke: mra prd-scaffold preview exits 0, missing plan aborts ---
MRA="$SCRIPT_DIR/bin/mra.sh"
WS5=$(mktemp -d); mkdir -p "$WS5/.collab/requirements"
printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS5/.collab/dep-graph.json"
cat > "$WS5/.collab/requirements/REQ-2026-0006-scaffold.json" <<'JSON'
{"requirement_id":"REQ-2026-0006","repos":[{"name":"api","org":"acme","visibility":"private","type":"service","description":"x","deps":[]}]}
JSON
# ghAccounts must resolve for the preview's token pre-check; set via the real config path
( cd "$WS5" && MRA_WORKSPACE="$WS5" MRA_CONFIG=<(echo '{"ghAccounts":{"acme":"acme-bot"}}') bash "$MRA" prd-scaffold --req REQ-2026-0006 </dev/null >/dev/null 2>&1 )
# NOTE: process substitution for MRA_CONFIG may not survive; if the token pre-check fails the run still
# exits 0 (preview) OR 1 (token) — assert it does NOT create. Prefer asserting exit is 0 or 1, never a crash:
rc=$?; [[ "$rc" -eq 0 || "$rc" -eq 1 ]] && ok "prd-scaffold preview dispatch is well-formed (rc=$rc)" || fail "dispatch crashed rc=$rc"
( cd "$WS5" && MRA_WORKSPACE="$WS5" bash "$MRA" prd-scaffold --req REQ-9999-0000 </dev/null >/dev/null 2>&1 ); assert_eq "missing scaffold plan aborts" "1" "$?"
rm -rf "$WS5"
```

- [ ] **Step 3: Run the FULL suite**

Run: `bash test.sh`
Expected: `shell tests: N passed, 0 failed` + `mcp-server` line; the new `test_prd.sh` and `test_prd_scaffold.sh` green; brownfield `test_prd_cli.sh`/`test_prd_issues.sh`/`test_launch.sh` unaffected. If any fail, STOP and fix.

- [ ] **Step 4: Commit**

```bash
git add tests/test_prd_scaffold.sh
git commit -m "test(prd): prd-scaffold dispatch smoke; full suite green"
```

---

## Task 11: Docs + dry-run smoke

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README — document the greenfield flow**

Add rows near the existing `mra prd` rows:
```markdown
| `mra prd --new <name>` | Greenfield: interactive from-scratch architecture brainstorm → proposes a repo split → writes PRD + specs + task plan + a scaffold plan under `.collab/` (creates nothing) |
| `mra prd-scaffold --req <ID> [--confirm]` | Apply step (operator-run, TTY-gated): `gh repo create` the planned repos + seed + register into the dep-graph |
```
Add a short "Greenfield flow" note: `mra prd --new <name>` → `mra prd-scaffold --req <ID> --confirm` → `mra prd-issues --req <ID> --confirm` → `mra dev <repo> "<task>"`. Requires an already-`mra init`'d workspace (`.collab/dep-graph.json`) and a `ghAccounts` mapping for the org.

- [ ] **Step 2: CHANGELOG entry**

```markdown
### Added
- `mra prd --new <name>` — greenfield interactive planner: brainstorms a brand-new project's architecture from scratch, proposes a repo split + stack, and writes a PRD + specs + task plan + a scaffold plan. Creates nothing.
- `mra prd-scaffold --req <ID> [--confirm]` — operator-run, **TTY-gated** apply that `gh repo create`s the planned repos (per-repo `GH_TOKEN` via `ghAccounts`, immutable ledger + `gh repo view` adopt-abort, atomic additive dep-graph registration — never `mra scan`), seeds each with an empty commit, and registers them into the workspace.
```

- [ ] **Step 3: Real dry-run smoke (no network)**

Run (in an `mra init`'d workspace with a fixture `<REQ>-scaffold.json`): `mra prd-scaffold --req <REQ> --dry-run` → prints the "will create" plan and creates nothing. Confirm the account pre-check resolves (or aborts loud if `ghAccounts` is unset).

- [ ] **Step 4: Commit + final verification**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(prd): document mra prd --new + mra prd-scaffold greenfield flow"
bash test.sh
```
Report the final `shell tests: N passed, M failed` line as completion evidence.

---

## Backlog (deferred)
- `--org` override / multi-org greenfield (v1 forces the workspace `gitOrg`).
- `--adopt` an existing remote repo into a plan (v1 aborts on a pre-existing name).
- Workspace bootstrap (v1 requires an `mra init`'d workspace).
- `mra dev --issue N` (closes prd → scaffold → issue → dev).
- A per-repo template/skeleton (v1 seeds an empty commit only).
