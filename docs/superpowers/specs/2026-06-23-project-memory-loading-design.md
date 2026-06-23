# Project-Memory Loading (per-project CLAUDE.md / AGENTS.md / .claude/rules) — Design

**Date:** 2026-06-23
**Status:** Designed, pending implementation. Decisions ratified by a 4-reviewer + 1-synthesizer multi-agent vote (lenses: bash-cli-conventions, context-engineering-cost, test-maintainability, adversarial-safety).
**Scope:** Make each loaded project's native `CLAUDE.md` / `AGENTS.md` / `.claude/rules/` load into the `claude` CLI that `mra` launches, instead of relying solely on PKB distillation — gated by a config flag, guarded against cross-project leakage, and locked with offline regression tests.

---

## 1. Problem

`mra` launches `claude` with `--add-dir <project>` for every loaded project (interactive `launch_claude` and every headless `claude -p` call).

**Verified empirically (claude 2.1.186, canary fixtures):**

| Artifact in an `--add-dir` project | Loads by default? | Evidence |
|---|---|---|
| `.claude/skills/` (Agent Skills) | ✅ **Yes** — auto-loaded; skills are the documented exception to `--add-dir` being file-access-only. Unaffected by `--setting-sources`. | Canary skill's description (magic token) appeared in context with `--add-dir`, absent without it. |
| `CLAUDE.md` / `AGENTS.md` / `.claude/rules/` | ❌ **No** — not loaded from `--add-dir` dirs by default. | Memory tokens appeared **only** with `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`; absent without it. |

So **skills already work** and need no change. The real gap is **per-project memory/rules**: today `mra` only sees them via PKB distillation (`lib/pkb.sh` → `.mra/pkb/conventions.md`), which (a) requires a prior `mra analyze`, (b) is a lossy summary rather than the author's verbatim instructions, and (c) means a project **without** a PKB is invisible to the interactive orchestrator's rules.

Setting `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` makes claude load `.claude/CLAUDE.md`, `.claude/rules/*.md` (and, when `local` setting-source is not excluded, `CLAUDE.local.md`) from each `--add-dir` directory natively.

## 2. Goals / Non-goals

**Goals**
- Each loaded project's committed `CLAUDE.md` / `AGENTS.md` / `.claude/rules/` reaches the `claude` process natively, across **all** mra paths (interactive launch, `--all`, every headless `claude -p`, pkb generators) from a **single** central switch.
- A config flag (`mra config project-memory on/off`) that is authoritative over mra's process tree.
- No cross-project leakage of gitignored personal memory (`CLAUDE.local.md`).
- Offline regression tests that actually lock the env-inheritance behaviour (not just argv).
- PKB and native loading stay **complementary**, not triply redundant.

**Non-goals**
- Editing `agents/orchestrator.md` or any agent prompt to make the model *actively use* skills/rules (a separate, deferred concern — the user chose the loading mechanism, not prompt-tuning).
- Changing skill discovery (already works).
- Loading `settings.local.json` (the env var does **not** govern it; mra's own is 12 KB of internal patterns).

## 3. Verified facts the design relies on

1. `--add-dir` auto-loads `.claude/skills/`; does **not** auto-load CLAUDE.md/rules. (canary test)
2. `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` makes CLAUDE.md + `.claude/rules/` load from `--add-dir` dirs. (canary test)
3. `--setting-sources` only filters `settings.json` scope; it does **not** filter skills/memory — **except** that excluding `local` drops `CLAUDE.local.md`. (claude-code-guide, docs)
4. Every headless caller already passes `--setting-sources project` (`pkb.sh`, `review.sh:370`, `ask.sh:143/154`, `eval.sh:235/304`, `review-debate.sh`, `model-provider.sh:23`, `test-audit.sh:113`, `review-personas.sh:81`) → `CLAUDE.local.md` excluded there → ON is clean.
5. Interactive `launch_claude` (`lib/launch.sh:97`) calls **bare** `claude` with **no** `--setting-sources` → default scope **includes** `local` → with the env var ON it would pull every sibling repo's `CLAUDE.local.md` into one shared context. **This is the design's hard gate.**
6. `tests/test_launch.sh` stubs `claude()` as a **shell function** in the same process → it can observe exported env vars, even though env vars are not in argv.
7. `bin/mra.sh` sources ~56 single-purpose libs, then `main()` (~line 149) does `case "$command"` dispatch. config keys are camelCase; `config_handle` CLI args are kebab (`auto-scan`, `parallel-test`).

## 4. Design decisions (ratified by vote)

### D1 — Naming: `loadProjectMemory` / `project-memory`
Config key `loadProjectMemory` (camelCase) + CLI subcommand `project-memory` (kebab) — the only pair consistent with both existing conventions. **Requirement:** docs (help, `usage()`, README, code comment) must state precisely that the flag governs **CLAUDE.md + AGENTS.md + .claude/rules only** — not skills (already auto-load), not `settings.local.json`.
*Recorded fallback if "memory" later reads as misleading: `loadProjectInstructions` / `project-instructions`. Not adopted now.*

### D2 — PKB stays complementary by tier (no blind duplication)
When `loadProjectMemory` is ON, `pkb_build_context` must **drop** the full-tier verbatim "Full Conventions" block (`lib/pkb.sh:417-424`) and the verbatim conventions fallback (`pkb.sh:354-359`), and **keep** the tagged `[CONVENTION]`/`[PATTERN]`/`[DECISION]` L1 essentials plus the cross-codebase sitemap/architecture/api-surface/modules/tunnels and accumulated `[DECISION]`s that exist in no CLAUDE.md. `pkb_build_context` learns the flag state by calling `config_get loadProjectMemory` directly — it runs in the mra parent process (assembling the system prompt for launch/review/ask), where `config_get` is already sourced — rather than threading a new parameter through every caller. Rationale: `conventions.md` is distilled *from* the same files the env var now auto-loads (`pkb.sh:609`), so the verbatim block is a second/third copy (~1–2k tokens/project, ×N on `--all`).

### D3 — New lib, central call, unset-on-off
- New file **`lib/project-memory.sh`** exporting `apply_project_memory_env()` (~15 lines). Sourced in `bin/mra.sh` alongside other libs. Do **not** bolt onto `config.sh` (which is pure JSON get/set with zero env side-effects).
- Called **once at the very top of `main()`** (right after `local command="${1:-}"`, before the help check and `case` dispatch) so the export precedes `resolve_workspace` and every subcommand.
- `config_handle` still gains the `project-memory` arm (that *is* config plumbing).
- The helper: idempotent; reads the flag via `config_get` (honours `MRA_CONFIG` for tests); exports `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` when ON; **explicitly `unset`s it when OFF/missing** so mra is authoritative even over a globally-exported shell var (otherwise `config off` is a silent no-op).

### D4 — Default ON, behind a hard gate
Default `loadProjectMemory: true` **only if** the same change adds `--setting-sources user,project` to the interactive `launch_claude` invocation (`lib/launch.sh:97`), excluding `local` scope so each repo's gitignored `CLAUDE.local.md` is never pulled in. Without that guard, default-ON is a cross-project privacy regression and is **rejected**. If the launch guard is deferred out of this change, the flag defaults **OFF** until it lands.

*Refinement during planning (deviates from the vote's bare `project`):* the guard uses `user,project`, not `project`. Both exclude `local` (the leak vector), but bare `project` would also drop the operator's `~/.claude/settings.json` (global allowedTools/hooks) from the **interactive** orchestrator session — a permissions regression. `user,project` excludes only `local`. Headless callers keep their existing bare `project` (ephemeral, already audited).
*Dissent preserved (adversarial reviewer): prefers default OFF even after the guard, on `--all` token-cost grounds. Escape hatch: if token blowup is observed, flip the default to OFF — the D2 tier-trim mitigates this.*

### D5 — Offline regression tests (three layers; real-API canary stays out of the suite)
1. **`tests/test_project_memory.sh` (unit):** call `apply_project_memory_env` against a temp `MRA_CONFIG` with the flag on / off / missing; assert the env var is exported when ON and **unset** when OFF or missing.
2. **`tests/test_launch.sh` (extend):** make the same-process `claude()` stub also append `printf 'ENV:%s\n' "${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD:-unset}" >> "$CAPTURE"`; drive launch with flag ON → assert `ENV:1`, OFF → assert `ENV:unset`. Keep existing `grep -cx` argv assertions intact (append the ENV line separately). Also assert launch now passes `--setting-sources project`.
3. **Ordering guard (static):** assert `apply_project_memory_env` precedes `case "$command"` in `bin/mra.sh` (cheap grep) so a future refactor can't silently move it below dispatch. Optionally back with an `MRA_CLAUDE_BIN`-mock headless inheritance check.

## 5. Component changes

| File | Change | Phase |
|---|---|---|
| `lib/project-memory.sh` (new) | `apply_project_memory_env()`: export when ON, unset when OFF/missing; scope comment | 1 |
| `bin/mra.sh` | source the new lib; call `apply_project_memory_env` at top of `main()` | 1 |
| `config.json` | add `"loadProjectMemory": true` (only with the launch guard — see D4) | 1 |
| `lib/config.sh` | `config_handle`: add `project-memory on/off` arm mirroring `parallel-test` | 1 |
| `lib/launch.sh` | add `--setting-sources project` to the `claude` invocation (line 97) — **hard gate for default-ON** | 1 |
| `tests/test_project_memory.sh` (new) | unit: flag on/off/missing → export/unset | 1 |
| `tests/test_launch.sh` | extend stub to capture env; assert ENV + `--setting-sources project` | 1 |
| `README.md` / `usage()` / `CHANGELOG.md` | document `mra config project-memory`, exact scope, hard-gate note | 1 |
| `lib/pkb.sh` | `pkb_build_context`: when flag ON, drop full-tier verbatim conventions (`417-424`) + fallback (`354-359`) | 2 |
| `lib/pkb.sh` | `_pkb_generate_conventions` (`:609`): when flag ON, drop/condition the "read CLAUDE.md/AGENTS.md/.claude/rules" instruction so nested generators don't double-feed | 2 |

**Phase 1** = the cohesive, shippable feature (loading + hard gate + tests + docs).
**Phase 2** = PKB token de-duplication (mitigates the redundancy this feature introduces). Splittable into a follow-up PR if Phase 1 review is large; the adversarial dissent accepts overlap as an interim with a tracking note.

## 6. Risks & mitigations (must-fix, from the vote)

1. **`CLAUDE.local.md` cross-project leakage (interactive launch).** → Add `--setting-sources user,project` to `launch.sh:97` in the same change as default-ON (excludes `local` scope while preserving the operator's user-scope settings); test asserts it. *(D4, hard gate.)*
2. **No unset-when-off → `config off` is a silent no-op against a global shell var.** → Explicit `unset` on OFF/missing; unit-tested. *(D3.)*
3. **Env inheritance untestable by argv-only harness; a refactor could silently disable it.** → Same-process function-stub env capture + static ordering grep. *(D5.)*
4. **Triple redundancy of rule content (~1–2k tokens/project, ×N).** → Phase 2 tier-trim of `pkb_build_context`. *(D2.)*
5. **PKB generator subprocesses double-feed** (inherit env var *and* are prompted to read the same files). → Phase 2: condition the `pkb.sh:609` prompt when native loading is active. *(D2.)*
6. **Naming/scope confusion** ("memory" undersells AGENTS.md + rules; collides with Claude's MEMORY.md). → Precise docs everywhere; recorded fallback name. *(D1.)*

## 7. Out of scope
- Prompt-tuning agents to actively invoke skills/rules.
- Skill discovery changes.
- Loading `settings.local.json`.
- Auto merge/rebase or any new command surface.
