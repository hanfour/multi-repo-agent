# `mra prd --new` — Greenfield Interactive Planner + Scaffold Apply — Design

**Date:** 2026-07-01
**Status:** Approved design (v1), deepened by multi-agent council. Pending implementation.
**Scope:** Add a **greenfield** mode to the planner: `mra prd --new <name>` runs an interactive, from-scratch architecture brainstorm (no existing repos/PKB), the agent **proposes a repo split + tech stack** for the human to confirm, and writes a PRD + per-repo specs + Task-Plan JSON + a new **scaffold plan** under `.collab/`. It **creates nothing**. A separate operator-run, **TTY-gated** `mra prd-scaffold --req <ID> --confirm` then creates the planned GitHub repos (`gh repo create` + clone + seed + register into the dep-graph). Issue creation stays the existing `mra prd-issues`.
**Full greenfield flow:** `mra prd --new <name>` (plan) → `mra prd-scaffold --req <ID> --confirm` (create repos) → `mra prd-issues --req <ID> --confirm` (open issues) → `mra dev <repo> "<task>"` (implement).
**Provenance:** deepened by a multi-agent council — genuine 3-way vote (**P2 *safety-first* won 19.6 / Borda 12**; P3 *max-reuse* 18.6 / 7; P1 *YAGNI* 17.8 / 5; 4 judges), then hardened by an adversarial critic (6 gaps closed, §15). Every decision is grounded in real `mra` source.

---

## 1. Problem

`mra prd` (brownfield) plans a feature across **existing** repos, grounded in their PKB, and `validate_repo_subset` (`pr-ops.sh`) requires each project to already be a git-repo dir. A **brand-new project** has no repos, no PKB, no dep-graph entries — the architecture is being *invented*, not extended. So `mra prd <newname>` aborts, and there is no path from "an idea" to "repos + a PRD + tickets" inside `mra`. This adds that path without letting an autonomous agent create irreversible GitHub repos.

## 2. Goals / Non-goals

**Goals**
- `mra prd --new <name>` — interactive, from-scratch brainstorm (intent → FE → BE → data); the agent proposes a repo split + stack, the human confirms.
- Emit a PRD + per-repo specs + Task-Plan JSON + a **`<REQ>-scaffold.json`** plan, all under `<workspace>/.collab/`. The interactive agent **creates nothing**.
- `mra prd-scaffold --req <ID> --confirm` — operator-run, **TTY-gated** apply that `gh repo create`s the planned repos, seeds them, and **registers** them into the dep-graph (additively).
- Reuse the brownfield `mra prd` machinery; leave its behavior **byte-for-byte** intact.

**Non-goals (v1)**
- Auto-creating repos or issues from the interactive session (plan/apply split, §4).
- Multi-org greenfield (`--org` override) — all new repos go to the workspace's `gitOrg`. Backlog.
- Adopting a pre-existing remote repo into a plan (`--adopt`) — a planned name that already exists remotely **aborts**. Backlog.
- Workspace bootstrap — `mra prd --new` requires an already-`mra init`'d workspace (`.collab/dep-graph.json`).
- `mra dev --issue N` — still backlog.

## 3. Command surface

```
mra prd --new <name>                              # greenfield plan (interactive; creates nothing)
mra prd-scaffold --req <REQ-ID> [--confirm] [--dry-run]   # operator-run, TTY-gated: create the planned repos
```

- **`--new <name>`** (D1): a value-taking arm placed **above** the `-*)` catch in the existing `prd)` parse loop. Accept ONLY the canonical `--new <name>` form; reject `--new=<name>` (the `-*)` arm errors) and a bare/`-*` value (`[[ -n "${2:-}" && "$2" != -* ]]` guard, so `mra prd --new --no-sync` never sends `--no-sync` into `gh repo create org/NAME`). Validate `<name>` with `validate_repo_name` + `_MRA_ID_REGEX`. **A greenfield invocation takes NO positional projects** — error if any are also given (§15 fix 6).
- **`mra prd-scaffold`** (D7): mirrors the `prd-issues)` skeleton. Requires `<REQ>-scaffold.json` (the greenfield marker) instead of a git dir; does NOT call `validate_repo_subset`. Without `--confirm` (or with `--dry-run`, or non-TTY) it prints the shell-computed "will create" plan and creates nothing.

## 4. Plan/apply split (the safety spine, reused from `mra prd-issues`)

Creating GitHub repos is **irreversible and outward-facing** — the same class as opening issues. So the greenfield mode uses the exact plan/apply split the brownfield planner established (spec `2026-06-30-mra-prd-design.md` §4):

- **`mra prd --new` (plan):** the interactive agent brainstorms + writes artifacts + the scaffold plan, then **STOPS**. It never runs `gh`.
- **`mra prd-scaffold` (apply):** the **operator** runs it in their own terminal. The create path requires `--confirm` AND not `--dry-run` AND **an interactive TTY** (`[ -t 0 ]`), byte-identical to `prd-issues.sh:197-206`. A non-TTY caller (an agent's Bash tool, CI) prints the plan and returns 0 — it **can never create a repo**, regardless of tool allowlists.

## 5. Architecture

| File | Action | Responsibility |
|---|---|---|
| `agents/prd-agent-new.md` | **create** | Greenfield interactive system prompt: zero-repo from-scratch brainstorm (intent→FE→BE→data, one question at a time); **propose** a repo split + stack for the human to confirm; emit PRD + per-repo specs + `<REQ>-tasks.json` + `<REQ>-scaffold.json`; derive cross-repo edges + spec filenames from the proposed plan; PII ban; **CREATE NOTHING**; end by telling the operator to run `mra prd-scaffold` then `mra prd-issues`. No existing-repo/dep-graph assertions. |
| `lib/prd.sh` | **modify** | Add `prd_launch_new` sibling (reads `agents/prd-agent-new.md`, `projects=()` empty-array-safe, exports `MRA_PRD_MODE=new` + `MRA_PRD_NEW_NAME`, allocates the REQ via `_prd_alloc_req_id`, writes **no** eager scope sidecar). Brownfield `prd_launch` + `_prd_alloc_req_id` stay **byte-for-byte**. |
| `lib/prd-scaffold.sh` | **create** | The operator-gated apply lib, mirroring `prd-issues.sh`'s gated/ungated/pure three-way skeleton: gated `mra_prd_scaffold` (validate→PII→print-plan→dry/confirm→`[ -t 0 ]` gate) + `_scaffold_validate_plan`/`_scaffold_scan_pii`/`_scaffold_print_plan`/`_scaffold_resolve_org`; ungated `_scaffold_create_all` (all `gh`/`git`, mockable); pure-jq `_scaffold_register` + `_scaffold_write_scope`. |
| `bin/mra.sh` | **modify** | `prd)` loop: guarded `--new)` arm + early greenfield fork calling `prd_launch_new` (bypass `list_all_projects`/`validate_repo_subset`); `source lib/prd-scaffold.sh`; add the `prd-scaffold)` case; register both verbs in `usage()`. |
| `lib/launch.sh` | **modify** | Guard the 4 unguarded `"${projects[@]}"` expansions with `${projects[@]+"${projects[@]}"}` (greenfield is the first empty-array caller — §15 fix 5). |
| `tests/test_prd.sh` | **create** | Unit-tests the `bin/mra.sh` `prd) --new` dispatch fork itself. |
| `tests/test_prd_scaffold.sh` | **create** | Plain-bash tests on a `mktemp` workspace with `gh(){…}`+`git(){…}` shims. |
| `test.sh` | **modify** | Register the two new test files. |

Reused as-is: `prd_launch`/`_launch_interactive`, `_prd_alloc_req_id`, `_prd_account_token`/`ghAccounts`, the `prd-issues.sh` gate skeleton, `render_html`, the dep-graph node init shape (`init.sh:98-102`), the `repos.json` entry shape (`repos.sh:104`), the owner-org sed idiom (`repos.sh`).

## 6. Greenfield session flow (`mra prd --new`)

```
mra prd --new billing
 → prd) loop matches the guarded canonical --new arm (D1); validate_repo_name + _MRA_ID_REGEX on "billing";
   error if any positional project was also given.
 → early fork (D2): prd_launch_new  (reaches NEITHER list_all_projects NOR validate_repo_subset)
 → prd_launch_new: resolve_workspace requires .collab/dep-graph.json (D6); _prd_alloc_req_id reserves REQ;
   exports MRA_PRD_REQ_ID / MRA_PRD_MODE=new / MRA_PRD_NEW_NAME; launches _launch_interactive with
   agents/prd-agent-new.md and NO project args (zero --add-dir via build_add_dir_args no-op, zero PKB).
 → Agent brainstorms one question at a time (intent→FE→BE→data), PROPOSES repos
   [billing-api (service), billing-ui (web), edge ui→api] + stack, human confirms → writes:
     .collab/requirements/<REQ>.md            (PRD; Cross-repo impact from the proposed edges)
     .collab/specs/<REQ>-billing-api.md, <REQ>-billing-ui.md
     .collab/requirements/<REQ>-tasks.json    (pm-agent tasks[] schema; every task.project ∈ repos[].name)
     .collab/requirements/<REQ>-scaffold.json (§7 schema)
   renders HTML; then STOPS and prints the operator next-step. NO gh, NO scope sidecar, NO issues.
```

## 7. Scaffold plan + apply flow (`mra prd-scaffold`)

**Scaffold plan schema** — `<workspace>/.collab/requirements/<REQ>-scaffold.json` (D4):
```json
{ "requirement_id": "REQ-YYYY-NNNN",
  "repos": [ { "name": "billing-api", "org": "acme", "visibility": "private",
              "type": "service", "description": "...", "deps": ["<other repo names>"] } ] }
```
Validation (D4/D13, before any `gh`): `requirement_id == --req`; every `repos[].name` matches `_MRA_ID_REGEX` AND passes `validate_repo_name` (blocks `-*`, `.`, `..`, `*/*`); every `tasks[].project` ⊆ `repos[].name`; every `repos[].org == workspace gitOrg`; default `visibility:"private"`, `"public"` requires explicit opt-in.

**Apply flow (operator-run):**
```
mra prd-scaffold --req <REQ> --confirm
 → prd-scaffold): resolve_workspace; require <REQ>-scaffold.json (greenfield marker, D7); mra_prd_scaffold
 → GATE (mra_prd_scaffold): _scaffold_validate_plan → _scaffold_scan_pii (names+org+description)
   → _scaffold_resolve_org (bare org via the repos.sh sed idiom) + _prd_account_token validated against
     ghAccounts BEFORE any create (abort loud on missing mapping/unresolvable token)
   → _scaffold_print_plan ("will create org/name [private|public] <type>") to stderr
   → if --dry-run or no --confirm → return 0 (inert); if `[[ ! -t 0 ]]` → return 0 (refuse non-interactively)
   → else `Create N repo(s)? [y/N]` on /dev/tty; y → _scaffold_create_all
 → WORKER (_scaffold_create_all): ensure ledger <REQ>-scaffold-repos.json exists ({}); per repo in plan order:
     in-ledger → skip (resume);
     else `GH_TOKEN=$tok gh repo view org/name` — exists-but-not-in-this-run's-ledger → ABORT loud (never adopt);
          not-exists → create in a WORKSPACE-PINNED subshell (§15 fix 3):
            ( cd "$ws" && GH_TOKEN=$tok gh repo create org/name --<vis> --description d --clone )
          write the ledger entry immediately {created:true, registered:false}; verify the clone landed at
          $ws/name (fall back to git init / remote add on an unborn default branch, D8);
          seed: git -C $ws/name commit --allow-empty -m "chore: scaffold name (<REQ>)" && git push -u origin HEAD
          (GH_TOKEN pinned on the push; §15 fix 4);
          _scaffold_register (§8); flip ledger registered:true.
 → after all repos: _scaffold_write_scope OVERWRITES <REQ>-scope with the names ACTUALLY created/adopted (D5),
   so the downstream issue-creation blast-radius == reality.
```
Downstream (unchanged): `mra prd-issues --req <REQ> --confirm` now finds `<REQ>-scope` → loads `MRA_PRD_PROJECTS` → opens issues; then `mra dev billing-api "<task>"`.

## 8. Dep-graph registration — additive, pure-jq, **atomic** (D9 + §15 fixes 1 & 2)

`_scaffold_register` does an idempotent, name-keyed **additive** upsert — it **never** calls `build_dep_graph`/`mra scan` (those rebuild and wipe the curated `consumedBy`/`deps` edges of existing repos, `init.sh:84-118`). Three targets:
1. `dep-graph.json` `.projects[<name>]` in the **exact init shape** (`init.sh:98-102`): `{type, port:null, dockerImage:null, dockerCompose:null, lastCommit, deps:{}, consumedBy:[], confidence:{}}` with `type` from the plan; set top-level `gitOrg` only if unset.
2. `manual-deps.json` — append planned edges `{source, target, type}`.
3. `repos.json` `.repos[]` — append `{name, clone:true, branch:"main", description, archived:false}` (`repos.sh:104` shape).

**Atomicity (§15 fix 1, HIGH):** EVERY write goes `jq … "$f" > "$tmp" && mv "$tmp" "$f"` — **never** an in-place `jq … "$f" > "$f"` (which truncates the file before `jq` reads it and **destroys the curated dep-graph**). This mirrors `_prd_create_all`'s ledger write (`prd-issues.sh:157-158`).
**Missing-file init (§15 fix 2, MED):** `manual-deps.json` and `repos.json` may be absent in a pre-init workspace — init each before upsert (`[[ -f manual-deps.json ]] || echo '[]' > manual-deps.json`; `[[ -f repos.json ]] || echo '{"repos":[]}' > repos.json`), exactly as `_prd_create_all` inits its ledger, so registration can't fail *after* `gh repo create` already ran.

## 9. Safety

- **TTY gate (CRITICAL):** create requires `--confirm` AND not `--dry-run` AND `[ -t 0 ]`; a non-TTY/agent/CI call returns 0 with zero creates. The zero-create-on-non-TTY test is a merge gate.
- **Name-capture guard:** canonical `--new <name>` only, `$2 != -*`, so a flag can never become a repo name flowing into `gh repo create org/NAME` or `$ws/NAME`; `_MRA_ID_REGEX` + `validate_repo_name` re-asserted per repo at apply (since `--new` bypasses `validate_repo_subset`).
- **Dual-account:** org = workspace `gitOrg`; token via `_prd_account_token` validated against `ghAccounts` **before** the first create; abort loud on missing mapping/unresolvable token. `GH_TOKEN` pinned on every `gh` and `git push` call (the https-credential-helper assumption is documented + verified in Task 7, §15 fix 4).
- **Idempotent resume + adopt-abort:** immutable ledger keyed by name, written the instant `gh repo create` returns (`created`/`registered` split); re-runs skip ledgered repos; a planned name that exists remotely but not in this run's ledger **aborts** via a `gh repo view` pre-check (never silently adopts).
- **Additive registration:** pure-jq, atomic (§8), never `build_dep_graph`/`mra scan`.
- **PII/name/org hygiene:** scan repo names + org + description before any create; default `--private`, public is explicit opt-in (workspace memory rule: scan PII before any public-facing action); `org == gitOrg` enforced so `sync` can re-clone.
- **Brownfield untouched:** `prd_launch` / `agents/prd-agent.md` byte-for-byte; greenfield forks before reaching them.

## 10. Failure handling

`--new` with no name or a `-*` value → clean usage error, exit 1. `--new <bad-slug>` → regex reject, exit 1. Missing `.collab/dep-graph.json` → `resolve_workspace`'s existing error. Missing `<REQ>-scaffold.json` in `prd-scaffold)` → "not a greenfield REQ (no scaffold plan) — was it created by `mra prd --new`?". Invalid plan JSON / `requirement_id` mismatch / `task.project` ⊄ repos / `org != gitOrg` / bad slug → return 1 before any `gh`, naming the bad field. No `ghAccounts` mapping / token failure → abort before the first create. `gh repo view` says exists + not in this run's ledger → abort loud. `gh repo create` real failure → return 1 mid-run; prior successes ledgered → re-run resumes. `git clone/seed/push` failure after remote create → repo ledgered `created:true, registered:false` → re-run resumes seeding + registration idempotently (clone-landing/unborn-branch fallback). PII hit → abort before any create. Non-TTY / no `--confirm` / `--dry-run` → return 0 (preview only, worker unreached).

## 11. Downstream (unchanged)

`mra prd-issues --req <REQ> --confirm` finds `<REQ>-scope` (written by the scaffold apply from repos *actually* created) → loads `MRA_PRD_PROJECTS` → opens the planned issues into the new repos. Then `mra dev <repo> "<task>"`. If `prd-issues` is run before scaffold, no `<REQ>-scope` exists → issue creation is naturally gated.

## 12. Testing

Plain-bash; the interactive `claude` launch is not run in CI — only the dispatch fork, the gate, and the `gh`/`git`-mocked apply seam.
- **`tests/test_prd.sh`** — the `bin/mra.sh` `prd) --new` fork: `--new <name>` forks to `prd_launch_new` with empty projects; `--new --no-sync` errors cleanly (the flag is never captured as a repo name); `--new <bad-slug>` rejected; `--new <name> extra` errors (stray positional, §15 fix 6); stubs prove `list_all_projects` and `validate_repo_subset` are **never** reached on the `--new` path; brownfield `mra prd`/`mra prd api ui` unchanged.
- **`tests/test_prd_scaffold.sh`** — on a `mktemp` workspace with `gh(){…}` + `git(){…}` shims (no network): plan validation (regex/req/subset/org), PII/name/org hygiene, the **TTY/no-confirm/dry-run zero-create gate** (`</dev/null`; the worker stub is never reached), `gh`+`git`-mocked create order / immutable ledger / resume-skip / **adopt-abort** / seed-commit+push / clone-landing verification, **pure `_scaffold_register` additive + curated-node-untouched-and-not-truncated + idempotent** (§15 fix 1), **empty-workspace init of `manual-deps.json`/`repos.json`** (§15 fix 2), scope-written-from-created-not-planned.
- **`tests/test_launch.sh`** — add a zero-project `_launch_interactive` case (empty-array guard, §15 fix 5) so greenfield's zero-`--add-dir` path is covered.

## 13. Task breakdown

| # | Task | Deps | Acceptance |
|---|---|---|---|
| 1 | `agents/prd-agent-new.md` — greenfield prompt + scaffold schema | — | One-question FE/BE/data brainstorm, no existing-repo/dep-graph assertions; documents `<REQ>-scaffold.json`; instructs deriving edges + spec filenames from the proposed plan; forbids `gh`/create; ends with the prd-scaffold→prd-issues instruction. |
| 2 | `lib/prd.sh` `prd_launch_new` sibling (D3/D5) + launch.sh empty-array guards (§15 fix 5) | 1 | Launches `_launch_interactive` with `prd-agent-new.md`, `projects=()` empty-array-safe, `MRA_PRD_MODE=new`+`MRA_PRD_NEW_NAME` exported, allocates REQ, writes NO scope; brownfield `prd_launch` diff shows only additions; `test_launch.sh` zero-project case green. |
| 3 | `bin/mra.sh` `prd)` `--new` arm + early fork (D1/D2, §15 fix 6) | 2 | Guarded parse (rejects missing/`-*`/split-form/stray-positional), validates slug, forks bypassing `list_all_projects`+`validate_repo_subset`; brownfield unchanged; `usage()` updated. |
| 4 | `tests/test_prd.sh` + wire into `test.sh` | 3 | All fork cases pass; runner includes the file. |
| 5 | `lib/prd-scaffold.sh` — validate + PII + resolve-org + print-plan (D4/D10/D13) | — | Validates regex/req/subset/org, scans names+org+desc, resolves `ghAccounts` token (abort on missing), prints will-create plan; mock `config_get`/`gh`; no create yet. |
| 6 | `lib/prd-scaffold.sh` — pure `_scaffold_register` + `_scaffold_write_scope` (D5/D9, §15 fixes 1&2) | 5 | Atomic (`>$tmp && mv`) additive jq upsert into dep-graph node (init shape) + manual-deps edges + repos.json; inits missing `manual-deps.json`/`repos.json`; curated node/edges proven untouched **and not truncated**; idempotent; scope from actually-created repos; no `gh`/`git`. |
| 7 | `lib/prd-scaffold.sh` — `_scaffold_create_all` worker (D8/D10/D11, §15 fixes 3&4) | 6 | With `gh`+`git` shims: `gh repo view` pre-check, GH_TOKEN-pinned create `--clone` in a `(cd "$ws" && …)` subshell, clone-landing/unborn-branch fallback, seed commit+push (GH_TOKEN pinned; https-helper assumption documented+verified), immutable ledger on-create, resume-skip, adopt-abort; token failure returns 1; calls `_scaffold_register` then flips `registered:true`. |
| 8 | `lib/prd-scaffold.sh` — gated `mra_prd_scaffold` entry (D7/D12) | 7 | validate→PII→print→dry/confirm→`[ -t 0 ]` gate→worker; non-TTY/no-confirm/dry return 0 (worker unreached); real failures return 1; matches prd-issues gate semantics. |
| 9 | `bin/mra.sh` `prd-scaffold)` case + source + usage (D7) | 8 | `source lib/prd-scaffold.sh`; `mra prd-scaffold --req <ID> [--confirm] [--dry-run]` resolves workspace, requires `<REQ>-scaffold.json`, passes flags; does NOT call `validate_repo_subset`; verb in usage. |
| 10 | `tests/test_prd_scaffold.sh` + wire into `test.sh` | 9 | All cases pass on a mktemp workspace with `gh`+`git` shims; no network; full suite green. |
| 11 | Docs + dry-run smoke | 10 | `mra prd-scaffold --req <ID> --dry-run` on a fixture prints the will-create plan and creates nothing; README documents the greenfield flow (`prd --new` → `prd-scaffold` → `prd-issues` → `dev`) + the pre-init-workspace requirement + `render-html` re-render of this spec. |

## 14. Residual risks

- **Name drift within a session:** the agent authors `repos[].name` in both `scaffold.json` and `tasks.json`; a mismatch (`billing-api` vs `billing_api`) is caught only at apply (regex + `tasks ⊆ repos`), not during authoring.
- **`gh repo create --clone` version drift** (target-dir vs CWD, unborn default branch) is mitigated by the verify-and-fallback step but relies on that fallback covering field versions.
- **Multi-org deferred** (D10 v1 single-org); a hand-edited foreign-org node is rejected by the `org==gitOrg` check; real cross-org needs a schema extension.
- **`detect_project_type` on an empty seeded tree returns `unknown`**; we trust `plan.type` at registration; a later `mra scan` could relabel an empty repo (benign; self-heals once code lands).
- **PII scan is pattern-based** — a novel internal codename in a public repo name could slip; default `--private` limits blast radius.
- **Greenfield brainstorm quality** (good architecture from zero context) is not CI-testable — relies on `prd-agent-new.md` prompt engineering + human confirm-in-the-loop.

## 15. Provenance & critic gaps closed

Council vote: **P2 (safety-first) won** 19.6/Borda 12 (P3 18.6/7, P1 17.8/5; 4 judges). Synthesized on P2's backbone with P3's minimal-surface arg discipline. The adversarial critic's 6 gaps are folded in:
1. **(HIGH)** dep-graph registration atomicity — an in-place `jq … > file` truncates before read, destroying the curated graph. **Closed** (§8): every `_scaffold_register` write uses `jq … "$f" > "$tmp" && mv "$tmp" "$f"`; the curated-node test asserts the file is not truncated.
2. **(MED)** `_scaffold_register` missing-file init — `manual-deps.json`/`repos.json` may be absent → jq aborts *after* `gh repo create` ran. **Closed** (§8): init each before upsert; empty-workspace test.
3. **(MED)** `gh repo create --clone` landing dir — clones into the worker's CWD, not `$ws`. **Closed** (§7): run in `( cd "$ws" && … )`; test asserts the repo lands at `$ws/name`.
4. **(MED)** `GH_TOKEN` on `git push` under dual accounts — unverified https-credential-helper path. **Closed** (§9/Task 7): documented + verified that `GH_TOKEN=$tok git push` authenticates as the mapped login (or push via `gh`).
5. **(MED)** greenfield empty-array under `set -u` — `launch.sh`'s unguarded `"${projects[@]}"` crashes on bash 3.2. **Closed** (§5): guard the 4 expansions with `${projects[@]+"${projects[@]}"}` + a zero-project `test_launch.sh` case.
6. **(LOW)** stray positional after `--new` silently discarded. **Closed** (§3): error if a greenfield invocation also has positional projects; test case.
