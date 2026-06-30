# `mra prd` — Interactive Cross-Repo PRD / Spec / Issues Planner — Design

**Date:** 2026-06-30
**Status:** Approved design (v1), deepened by multi-agent council. Pending implementation.
**Scope:** A **plan → apply** pair of commands:
- **`mra prd [projects…]`** — an **interactive** guided session that brainstorms a cross-repo feature (frontend + backend + data architecture), writes an **HTML PRD** + **per-repo HTML specs** + a machine-readable **task plan**, and prints the issue plan. It does **not** open issues.
- **`mra prd-issues --req <REQ-ID> [--confirm] [--dry-run]`** — an **operator-run** apply step that opens the dependency-ordered GitHub issues. The human running this command in their own shell **is** the create gate.

It is the upstream of `mra dev`: `mra prd` decides *what* to build and lands the artifacts/plan; the operator applies the issues; `mra dev` implements them.
**Relationship to existing commands:** the existing `mra plan` (5-persona strategy council) and `agents/pm-agent.md` are **left untouched**. `mra prd` reuses pm-agent's Requirement-Card + Task-Plan-JSON formats, the launch infrastructure, PKB, the dep-graph, and `render-html.py`.
**Provenance:** deepened by a multi-agent council — genuine 3-way vote (**P2 *safety-first* won 8.7 / Borda 11**; P3 *max-reuse* 8.5 / 8; P1 *YAGNI* 7.9 / 5), then hardened by an adversarial critic (7 gaps closed, §15). Every decision is grounded in real `mra` source.

---

## 1. Problem

`mra` has no upstream planning command. The closest capability (`agents/pm-agent.md`) only runs dispatched-by-the-orchestrator inside a session, produces markdown only, and cannot open issues. `mra dev` consumes a *task* but nothing produces those tasks in a structured, cross-repo, human-validated way. `mra prd` fills the gap — and, crucially, does so without handing an autonomous agent the keys to create irreversible, possibly-public GitHub issues (§4).

## 2. Goals / Non-goals

**Goals**
- `mra prd [projects…]` runs an **interactive** brainstorm (FE/BE/data, one question at a time), grounded in the loaded repos (dep-graph + PKB).
- Produce a **workspace-level HTML PRD** + **per-repo HTML specs** + a **Task-Plan JSON** (pm-agent schema), all under `<workspace>/.collab/`.
- Open **dependency-ordered GitHub issues** — one per task in the owning repo — via a **separate operator-run apply step** with a genuine human gate.
- Be the clean upstream of `mra dev`.

**Non-goals (v1)**
- Headless one-shot generation (the planner is interactive by design).
- Letting the **agent** create issues directly (the safety finding in §4 — the agent plans; the operator applies).
- Implementing anything (`mra dev`'s job).
- `mra dev --issue N` integration (backlog; the create→number contract + `mra-prd` label are designed to support it later).
- Touching `mra plan` / `pm-agent.md` / the orchestrator.

## 3. Command surface

```
mra prd [projects…] [--no-sync]
mra prd-issues --req <REQ-ID> [--confirm] [--dry-run]
```

**`mra prd`** — `[projects…]` resolved like the default launch (workspace + dep-graph + `--add-dir`). Named projects are validated up front via the existing `validate_repo_subset` (`lib/pr-ops.sh:41`, fails loud on any missing/non-repo); empty → all repos (`list_all_projects`, mirroring `--all`, not the literal empty-array path). `--no-sync` skips the non-fatal pre-sync. The planner never creates issues, so it has no `--dry-run` of its own — preview/create lives entirely in `mra prd-issues`.

**`mra prd-issues`** — the apply step, **run by the operator**, not the agent. `--req` selects the REQ to apply (reads `<workspace>/.collab/requirements/REQ-…-tasks.json`). Without `--confirm` it prints the full shell-computed plan and creates nothing (preview). With `--confirm` it creates the issues — **but only from an interactive terminal**: the create path requires a TTY `Create N issues across M repos? [y/N]` confirmation (`[ -t 0 ]`), so a non-TTY caller (an agent's Bash tool, CI) can never create. `--dry-run` forces preview even with `--confirm`.

## 4. The plan/apply split — and why (the load-bearing safety decision)

The council's first design had the **interactive agent** call a hidden `mra prd-issues` after an in-session "yes". The adversarial critic showed this gate is **illusory** for two compounding reasons (both verified):
1. The confirm token lives in the **agent's own environment**, so the agent can pass `--confirm` without a genuine human yes.
2. The only true human barrier left is the harness **OS permission prompt** on the agent's Bash call — but the interactive launch passes **no `--allowedTools`** (`lib/launch.sh:101-102`), so it is governed entirely by **user settings**, and **this operator's documented practice is to allowlist tools** (`rules/common/hooks.md`, MEMORY). A single `Bash`/`mra` allowlist entry suppresses the prompt → **zero human gate** for an irreversible, possibly-public write.
3. `--dry-run` was only an env var the agent could `unset`.

**Resolution (this design):** **the agent never creates issues.** `mra prd` (interactive) ends by writing the Task-Plan JSON and printing:
> Review the PRD: `<…REQ-…html>`. To create the N issues, run: `mra prd-issues --req REQ-YYYY-NNNN --confirm`

The operator runs `mra prd-issues` **in their own shell**. Mechanically, the create path **requires an interactive TTY**: it prompts `[y/N]` and reads from the terminal, and **refuses to create when stdin is not a TTY** (`[ -t 0 ]`). The agent's Bash tool is not a TTY, so even if `prd-issues`/`gh` are allowlisted and the agent invokes `--confirm`, it gets the printed plan and exits — it cannot create. Only a human at a real terminal can. This is the standard *plan/apply* split (terraform-style) applied to an irreversible public boundary, with the TTY check making it agent- and allowlist-proof regardless of settings. As defense-in-depth, `mra doctor` warns if `mra`/`gh`/`prd-issues` appear in the user allowlist. (A documented `--yes` escape for deliberate automation is backlog.)

> This **supersedes** the earlier "agent opens issues after in-session confirm." If you prefer the in-session flow despite the finding, that is the one decision to flag on review.

## 5. Architecture

| File | Action | Responsibility |
|---|---|---|
| `lib/launch.sh` | **modify** | Extract `_launch_interactive(workspace, graph, sys_prompt_file, extra_fragments[], projects…)` holding the shared add-dir / `--setting-sources user,project` / PKB-injection / fragment-join / exec assembly. `launch_claude` becomes a thin wrapper passing `agents/orchestrator.md`. **Regression-gated** (§12): before extracting, `test_launch.sh` must assert the single `--append-system-prompt` join (launch.sh:90-99), the `--setting-sources` flag (launch.sh:33), and PKB-present injection (launch.sh:72-87) via a `CLAUDE_BIN` stub — so "no behavior change" is enforced, not assumed. |
| `lib/prd.sh` | **create** | `_prd_alloc_req_id` (atomic REQ-YYYY-NNNN via `mkdir`-lock in `.collab/requirements/.locks/`, max+1 scan, retry on EEXIST, per-year reset, on-exit cleanup of an empty reservation); pure `_prd_build_launch_argv`; `prd_launch` (export `MRA_PRD_REQ_ID` + `MRA_PRD_PROJECTS` (resolved scope); build abs-workspace + abs-`mra`-path + "present-and-stop" narration fragments; `( cd "$workspace" && _launch_interactive agents/prd-agent.md … )` interactive). |
| `agents/prd-agent.md` | **create** | Interactive PM/brainstorm prompt: FE/BE/data one-question-at-a-time, surface-assumptions discipline, reuse pm-agent Requirement-Card + Task-Plan-JSON formats, treat `MRA_PRD_REQ_ID` + abs workspace as given, write `.collab/` `.md`, call `prd_render_html`, then **present the shell-printed issue plan and STOP**, instructing the operator to run `mra prd-issues`. Forbids secrets/PII in PRD/issue bodies. |
| `lib/prd-issues.sh` | **create** | `prd_render_html` (render-html.py wrapper: `import markdown` preflight, `.collab` path-prefix guard, **non-empty source AND non-empty sibling `.html`** post-verify); `mra_prd_open_issues` (validate → topo-order → accounts → labels → PII scan → two-pass create+link → ledger; the create gate). |
| `bin/mra.sh` | **modify** | Source the two libs; add `prd)` dispatch (validate_repo_subset, empty→all, sync-unless-`--no-sync`, alloc, `prd_launch`) and a **public** `prd-issues)` dispatch → `mra_prd_open_issues`; usage rows. `mra plan` untouched. |
| `lib/doctor.sh` | **modify** | Warn when `mra`/`gh`/`prd-issues` are present in the user allowlist (defense-in-depth for §4). |
| `tests/test_prd_*.sh` | **create** | `test_prd_cli.sh`, `test_prd_issues.sh`, `test_prd_render.sh` (§12). |
| `README.md` / `CHANGELOG.md` | **modify** | Command rows, the `ghAccounts` config key, the allowlist posture. |

Reused as-is: `lib/launch.sh` assembly, `lib/pkb.sh`, dep-graph, `render-html.py`, pm-agent formats, `validate_repo_subset`/`list_all_projects`/`sync_from_repos_json`, `order_repos_by_deps` structure, the `review.sh` owner-from-origin sed idiom, the `dev.sh` GH_TOKEN-pinning precedent.

## 6. Interactive plan flow (`mra prd`, driven by `agents/prd-agent.md`)

```
0. Init: read .collab/dep-graph.json + each loaded repo's PKB/CLAUDE.md; identify affected
   repos + roles (frontend/backend/service/data) from the graph.
1. Intent & scope: purpose, users, success criteria; confirm in-scope repos (surface
   assumptions, ask before guessing).
2. Frontend Q&A  (components / routes / state / interactions)        ← one question at a time
3. Backend Q&A   (API contracts / services / auth / side effects)
4. Data Q&A      (schema / models / migrations / ownership / consistency)
5. Write artifacts: .collab/requirements/REQ-…md (PRD), .collab/specs/REQ-…-<repo>.md
   (per repo), .collab/requirements/REQ-…-tasks.json (requirement_id == MRA_PRD_REQ_ID).
6. Render HTML: prd_render_html on the PRD + every spec (always, even under --dry-run).
7. PRESENT the shell-printed issue plan (from `mra prd-issues --req … --dry-run`) and STOP,
   telling the operator to run `mra prd-issues --req REQ-… --confirm`. The agent does NOT create.
```

The agent surfaces assumptions before acting (mirrors `orchestrator.md`), and never creates issues.

## 7. Apply flow (`mra prd-issues`, operator-run)

`mra_prd_open_issues` does, in order, **all mechanical facts in shell (never agent prose)**:
1. **Validate** the Task-Plan JSON before any `gh` call (D14): each task has `id/project/tier/dependencies/acceptance_criteria`; every `task.project` is a member of `MRA_PRD_PROJECTS` (the resolved launch scope — not merely any workspace repo, so blast radius can't widen); every `dependencies` id exists in the plan; `requirement_id == --req`. Abort cleanly naming the bad field; no self-heal.
2. **Topo-order** tasks by the intra-plan task-id DAG (Kahn) with `tier` ascending as tie-break (mirrors `order_repos_by_deps`' structure, `pr-ops.sh`). **On a cycle**: warn and fall back to input order (matching `pr-ops.sh:23-26`), still create all N. The workspace dep-graph `consumedBy`/`deps` is a non-blocking sanity warning on contradiction.
3. **Accounts** (D9): per target repo, resolve owner from the `origin` remote (`review.sh:44-45` sed idiom), map owner-org → gh login via a **new config key `ghAccounts`** (JSON object), set `GH_TOKEN=$(gh auth token --user <login>)` per `gh` call. **Abort loudly** if (a) no mapping for the owner, **or (b)** the token resolves empty / non-zero exit (login never authenticated) — with a `gh auth login --user <login>` hint — before any create, so `gh` can never fall back to the active/wrong account.
4. **Labels** (D13): `gh label create mra-prd --force` + `tier:<n> --force` per repo (idempotent), so a missing label can't abort mid-batch.
5. **PII/secret scan** (grafted): scan each issue/PRD body for the same patterns as the public-push hygiene (real names / `@`-emails / internal hosts / token shapes); abort and report if hit. Human still reviews the printed plan.
6. **Confirm gate**: re-print the FULL shell-computed plan; the create path requires `--confirm` AND not `--dry-run` AND **an interactive TTY** `[y/N]` confirmation (`[ -t 0 ]`). A non-TTY caller (agent Bash, CI) prints the plan and exits 0 with zero creates — this is what makes the gate agent- and allowlist-proof. (A documented `--yes` escape for deliberate automation is backlog.)
7. **Two-pass create + link** (D11/D12): pass 1 creates all issues dep-ordered, parsing the trailing `/issues/<N>` from `gh issue create` stdout into an **immutable sidecar ledger** `.collab/requirements/REQ-…-issues.json` (`task-id → {owner/repo, number, url}`) plus a hidden body marker (`<!-- mra-prd REQ-id:task-id -->`); pass 2 `gh issue edit --body` injects plain-text `Depends on: owner/repo#N` from the ledger (idempotent, best-effort). Re-run after partial failure consults the ledger, **skips already-created task-ids**, and resumes — so a retry never files duplicate public issues. The `mra-prd` label is the stable resume-discovery filter (`gh issue list --label mra-prd` can rebuild the ledger).

## 8. Artifacts (workspace `.collab/`)

- **PRD** — `<workspace>/.collab/requirements/REQ-YYYY-NNNN.md` → `.html`. Sections: Problem / Goals & Non-goals / Users / **Frontend architecture** / **Backend architecture** / **Data architecture** / Cross-repo impact (from `consumedBy`/`deps`) / Task decomposition / Open questions.
- **Spec** — per affected repo: `<workspace>/.collab/specs/REQ-YYYY-NNNN-<repo>.md` → `.html` (API contracts, models, file-level changes, test plan).
- **Task Plan** — `<workspace>/.collab/requirements/REQ-YYYY-NNNN-tasks.json` (pm-agent `tasks[]` schema) — the machine source for the apply step.
- **Issue ledger** — `<workspace>/.collab/requirements/REQ-YYYY-NNNN-issues.json` (written by the apply step).
- REQ-id is allocated atomically by `_prd_alloc_req_id` (mkdir-lock, §5) and re-validated for uniqueness (no existing ledger) before any create. HTML via the existing `render-html.py` (writes `.html` beside the source). Artifacts are confined to `.collab/` by `cd` + an abs-path fragment + `prd_render_html`'s path-prefix guard — **never** a repo's git tree, never a commit/push.

## 9. Safety

- **Genuine human create-gate (§4):** the create path requires an interactive TTY `[y/N]` (`[ -t 0 ]`); a non-TTY caller (agent Bash, CI) cannot create — agent-uncircumventable and allowlist-proof regardless of settings. `mra doctor` additionally warns if `mra`/`gh`/`prd-issues` are allowlisted.
- **`--dry-run` / no-`--confirm` create nothing**; TTY runs add a `[y/N]` prompt.
- **Correct-account writes:** per-repo `GH_TOKEN` from `ghAccounts`, abort on missing mapping OR unresolvable token — never file under the active/wrong account.
- **Bounded blast radius:** `task.project` must be in the resolved `MRA_PRD_PROJECTS` scope; full schema/dep-id/requirement_id validation before any `gh` call → no half-created sets.
- **No duplicate public issues on resume:** immutable ledger keyed on task-id + hidden body marker.
- **No repo mutation:** artifacts confined to `.collab/`.
- **PII/secret scan** before any create, plus the agent prompt forbids secrets/PII and the human reviews the printed plan.
- **Concurrency-safe REQ ids:** atomic mkdir-lock + helper re-validation.

## 10. Failure handling

Named-but-missing project → `validate_repo_subset` reports all and aborts before launch. Sync failure → non-fatal. `markdown` import missing or `.html` empty/skip → `prd_render_html` fails loudly with an install hint (`render-html.py` returns 0 on a **missing** source and writes a non-empty template for an **empty** source — so the wrapper checks **both** source-non-empty and sibling-`.html`-non-empty). Malformed tasks.json / unknown dep-id / out-of-scope `task.project` / `requirement_id` mismatch → abort before the first create, naming the bad field. No `ghAccounts` mapping or unresolvable token → abort that loop loudly. `gh create` fails mid-batch → ledger holds successes; re-run skips them and surfaces remaining task-ids. `gh issue edit` (pass 2) failure → non-blocking, logged. REQ-id mkdir clash → retry next number; abandoned reservation cleaned on normal exit (accepted gap on crash).

## 11. Integration with `mra dev` (backlog)

Issues filed here are the input to a future `mra dev --issue <N>` (fetch issue title/body as the task). The create→number contract + `mra-prd`/`tier:<n>` labels are designed to support it; the `prd → issue → dev` loop is not closed in v1.

## 12. Testing

Plain-bash (`ok`/`fail`/`assert_eq`, no `.bats`); the interactive `claude` launch is not executed in CI — only arg/context assembly and the gh/helper seam are tested.
- **`test_prd_cli.sh`** — prd arg parsing; empty→all, named-missing aborts via `validate_repo_subset`; `_prd_build_launch_argv` asserts add-dir count, **`prd-agent.md` not `orchestrator.md`**, `--setting-sources user,project`, a single `--append-system-prompt`, lang directive, `REQ_ID`/`PROJECTS` propagation (via `MRA_PRD_CLAUDE_BIN` stub); concurrent `_prd_alloc_req_id` yields distinct ids.
- **`test_prd_issues.sh`** — gh mocked as a bash function recording argv + echoing `https://github.com/<owner>/<repo>/issues/<counter>`: ordering, stdout-`#`-parse, two-pass `owner/repo#N` linking, label-ensure, per-repo `GH_TOKEN` pin + **unmapped-owner abort + unresolvable-token abort**, ledger resume keyed on task-id, schema/dep-id/**scope (MRA_PRD_PROJECTS)**/requirement_id validation aborts, **cycle fixture** (all N still created + linked, fallback order + warning), PII-scan abort, and the **zero-create invariants** (no `--confirm`; `--dry-run`; **non-TTY even with `--confirm`** — the create path checks `[ -t 0 ]`).
- **`test_prd_render.sh`** — `prd_render_html` on a fixture produces a non-empty sibling `.html`; **refuses a source outside `<workspace>/.collab`**; `markdown`-import preflight fails loudly; **missing source AND empty source** are both caught by post-verify (separate cases).
- **`test_launch.sh`** (pre-work, §5 D1) — assert the prompt-join, `--setting-sources`, and PKB-injection BEFORE the `_launch_interactive` extraction.

## 13. Task breakdown

| # | Task | Deps | Acceptance |
|---|---|---|---|
| 0 | `lib/prd-issues.sh`: `prd_render_html` + `mra_prd_open_issues` (print-first, mock-gh) — **build the irreversible boundary first** | — | `test_prd_issues.sh` + `test_prd_render.sh` green: validate (fields+scope+dep-id+requirement_id), topo+cycle-fallback, per-repo GH_TOKEN pin + unmapped/unresolvable abort, label `--force`, PII scan, two-pass create+stdout-#-parse + ledger/marker + `owner/repo#N` links; dry-run, no-confirm, and non-TTY-with-confirm create nothing; render produces non-empty `.html` with path guard + missing/empty source detection. |
| 1 | `lib/launch.sh`: add the §5 regression assertions to `test_launch.sh`, then extract `_launch_interactive`; `launch_claude` → thin wrapper | — | Existing launch tests (with the new prompt-join/setting-sources/PKB assertions) pass; no behavior change for `mra <projects…>`. |
| 2 | `lib/prd.sh`: `_prd_alloc_req_id` (mkdir-lock + on-exit cleanup), pure `_prd_build_launch_argv`, `prd_launch` (export token/dry-run/req-id/**projects**, cd+exec) | 1 | `test_prd_cli.sh` passes via stub; argv asserts add-dir/PKB/lang/req-id/projects/workspace+mra-path fragments; REQ-id atomic + distinct under concurrency. |
| 3 | `agents/prd-agent.md`: interactive FE/BE/data brainstorm reusing pm-agent formats; render + **present-and-stop** (instruct operator to run `mra prd-issues`); forbids secrets/PII | 0,2 | Prompt writes `.collab` `.md`, calls `prd_render_html`, treats `MRA_PRD_REQ_ID` + abs workspace as given, presents the plan and STOPS (does not create). |
| 4 | `bin/mra.sh`: `prd)` dispatch + public `prd-issues)` dispatch; source libs; usage. `lib/doctor.sh`: allowlist warning | 0,3 | `mra prd` launches via stub; empty→all, named-missing aborts; `mra prd-issues` routes to the helper; usage lists both; `mra plan` untouched; `mra doctor` warns on allowlisted `gh`/`prd-issues`; full `test.sh` green. |
| 5 | Docs: README `mra prd`/`mra prd-issues` rows + `ghAccounts` key + allowlist posture; CHANGELOG; re-render this spec `.md`→`.html` | 4 | README/CHANGELOG updated; `render-html.py` run on this spec (MEMORY `feedback_render_html`). |

## 14. Residual risks

- **`mra`-on-PATH handoff** (council-flagged): `mra prd` instructs the operator to run `mra prd-issues`; if the operator's `mra` isn't on PATH the apply step needs the absolute path (printed in the instruction). Covered by the direct-subcommand tests, not a live agent run.
- **In-session "yes" is gone as a risk** — the agent no longer creates; the operator-run apply is the gate. (This is the main improvement over the council's first design.)
- **`gh issue create` stdout-URL format is pinned by assumption** (no precedent; grep-confirmed). A gh CLI change to stdout breaks number parsing and the mock contract.
- **`ghAccounts` is a new operator config key** — unmapped owner safely aborts but is a setup burden; needs clear `doctor`/preflight messaging.
- **PII scan is pattern-based** — reduces but doesn't eliminate the possibly-public-write risk; the human review of the printed plan remains the backstop.
- **`render-html.py` hardcodes `lang=zh-Hant`** and a generic eyebrow (render-html.py:259,333-342) — accepted for v1; revisit for non-zh PRDs without forking the renderer.
- **`_launch_interactive` extraction touches the shared default-launch path** — regression risk bounded only by the (now-strengthened) launch tests staying green.
- **`mra dev --issue N`** is backlog; the `prd → issue → dev` loop is not closed in v1.

## 15. Provenance & critic gaps closed

Council vote: **P2 (safety-first) won** 8.7/Borda 11 (P3 8.5/8, P1 7.9/5; 4 judges, all 3 plans scored). Synthesized on P2's backbone with P3/P1 grafts (max-reuse `_launch_interactive` extraction; YAGNI deferrals). The adversarial critic's 7 gaps are all folded in:
1. **(HIGH)** `--dry-run` was a soft env var + token minted under dry-run → could create. **Closed** by the §4 plan/apply split (agent never creates; the create path requires an interactive TTY) — the operator-run apply is the gate.
2. **(HIGH)** in-session confirm gate illusory (token in agent env + user allowlists suppress the OS prompt). **Closed** by §4: the create path requires an interactive TTY (`[ -t 0 ]`), so a non-TTY agent Bash call can't create regardless of allowlist, + `mra doctor` warning.
3. **(MED)** `task.project` scope guard degraded to existence-only. **Closed** by exporting `MRA_PRD_PROJECTS` and asserting membership (§7.1).
4. **(MED)** `gh auth token --user` could fail silently → wrong-account write. **Closed** by checking exit/emptiness and aborting with a re-auth hint (§7.3).
5. **(MED)** `_launch_interactive` extraction's regression gate didn't cover prompt-join/setting-sources/PKB. **Closed** by adding those assertions to `test_launch.sh` first (§5/§12).
6. **(LOW)** render post-verify missed the empty-source case. **Closed** by asserting source-non-empty too (§5/§10).
7. **(LOW)** task-id cycle behavior unspecified. **Closed** by Kahn cycle-detect → input-order fallback + warning + a cycle test fixture (§7.2).
