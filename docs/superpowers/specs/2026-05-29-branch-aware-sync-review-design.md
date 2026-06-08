# Branch-aware Sync & Review — Design

**Date:** 2026-05-29 (last updated 2026-06-01)
**Status:** Cumulative spec. Phases 0–4 designed (§3–§12); Phases 0–3 implemented and merged, Phase 4 designed/pending implementation. Phase 5 deferred (§12.8).
**Scope:** Add branch-aware remote/local sync and review extensions to `mra`, delivered in phases. This is one accumulating document — §3–§8 describe the Phase 0 skeleton and the authoritative phase map (§8); §9–§12 are the approved designs for Phases 1–4. The Phase 0 sections below are preserved as written; later sections supersede their "deferred to later phases" notes.

---

## 1. Problem

`mra` already has **internal sync helpers** (`lib/sync.sh`: `sync_repo`, `sync_workspace`, `sync_from_repos_json`) and a public `review` command (light/standard/debate, personas, `--pr`). Two gaps remain:

- **Sync is internal and default-branch only.** There is no public `mra sync` command today — the helpers run inside `init`/launch flows (and can be skipped with `--no-sync`). Those helpers pull a repo only when it is on its default branch (`main`/`master`); a repo on a feature branch is skipped with a warning. There is no cross-repo view of where each repo stands (branch, ahead/behind, dirty), no safe pull on feature branches, no push, no cross-repo branch coordination, and no PR chaining.
- **Review cannot see local work.** `mra review` always diffs `base...HEAD`. It cannot review uncommitted working-tree changes, and there is no integration that auto-reviews the repos a sync touched.

This spec adds **branch-aware sync** and **review extensions** as one cohesive workflow, built skeleton-first.

## 2. Goals / Non-goals

**Goals**
- A cross-repo branch status overview.
- Safe pull on feature branches (fast-forward only; never mutate a dirty or diverged working tree).
- Review of local uncommitted changes without a PR.
- A shared, unit-testable decision engine that later phases (push, PR chaining, auto-review) reuse.

**Non-goals of the Phase 0 skeleton** (note: items later designed in §9–§12 are marked)
- Auto merge/rebase of diverged branches (`--safe` only ever fast-forwards) — still a non-goal.
- Push, cross-repo branch create/switch, PR chaining — were Phase 0 non-goals; now designed in §9 (push, branch new/switch) and §10 (PR chaining).
- Any write to a repo from the status or review paths (read-only guarantee preserved) — still holds for `branch status` and all review paths.

## 3. Command surface (full blueprint, phased)

All `branch` and `sync` entries below are **new public commands**. `mra sync` does not exist today; Phase 0 introduces it. Positional/flag order follows the existing `review` parser convention — **repo/project is a positional argument, options are `--flags` after it** — unless a phase-specific command surface says otherwise (e.g. §17 lets `branch pr`/`branch merge` interleave flags with their trailing `[repos…]` positionals).

| Command | Capability | Phase |
|---|---|---|
| `mra branch status [--all] [--fetch] [--json]` | Cross-repo overview: branch / ahead·behind / dirty (default: only repos needing attention; `--all`: every repo; `--json`: machine-readable array of all repos) | 0, **11** |
| `mra review <repo> --working` | Review working-tree (staged + unstaged) changes | **0** |
| `mra sync [--safe] [--json]` | Public sync; `--safe` pulls feature branches ff-only, else skip+warn; `--json`: per-repo `{repo,action,ok}` array (default/`--safe`/`--push` only) | 0, **12** |
| `mra sync --push [--dry-run] [--json]` | Push local branch to origin; `--json`: per-repo `{repo,action,ok}` array | 1, **12** |
| `mra branch new <name> [repos…]` / `switch <name>` | Create/switch same-named branch across repos | 1 |
| `mra review <repo> --range A..B` / `--head <ref>` | Review a specific branch / commit range | 4 |
| `mra sync --review` | Auto-review repos that a sync touched | 2 |
| `mra branch pr [--base] [--dry-run] [repos…]` | Open PRs across repos in dependency order (`[repos…]` = subset) | 2, **9** |
| `mra branch merge [--strategy] [--dry-run] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [repos…]` | Dependency-ordered cross-repo PR merge with mergeable+CI gating (`[repos…]` = subset; `--wait-ci` polls CI until done before merging) | 7, 8, **9, 10** |

**`mra sync` default behavior (Phase 0):** with no flags, `mra sync` exposes the existing helper behavior as a public command — clone missing repos, pull repos on their default branch, skip feature branches with a warning (a regression-safe wrapper over today's helpers). `--safe` adds the branch-aware fast-forward path described in §4.2.

**Phase 0 (this implementation)** walks one end-to-end journey:

> Working across several repos on feature branches → `mra branch status` shows each repo's state → `mra sync --safe` fast-forwards the repos it safely can (skipping the rest with a warning) → `mra review <repo> --working` reviews local uncommitted changes.

This slice touches both subsystems thinly and establishes the `BranchState` model and decision engine that every later phase reuses. Phases 1–2 are explicitly out of scope here.

## 4. Architecture

Follows existing `mra` conventions: many small files, immutable functions (return new values, never mutate globals or repos), `KEY=VALUE` flat-string returns parseable by callers.

### 4.1 `BranchState` (data model)

`lib/branch.sh` computes, per repo, a snapshot returned as flat `KEY=VALUE` lines:

```
repo=my-api
branch=feat/new-auth          # current branch; "(detached)" when detached HEAD
upstream=origin/feat/new-auth # "(none)" when no tracking branch
ahead=2                       # commits ahead of upstream
behind=0                      # commits behind upstream (drives ff eligibility)
dirty=3                       # uncommitted file count (tracked: staged + unstaged)
sync_action=fast-forward      # computed by the decision engine (below)
```

**Fetch semantics (important).** `ahead`/`behind` are only accurate if remote-tracking refs are current. To keep the read-only guarantee meaningful, `get_branch_state()` does **not** fetch by default — it reads local refs only, so `ahead`/`behind` may be stale relative to `origin`. Fetch is opt-in / contextual:

- `mra branch status` — no fetch; local refs only. Output notes that ahead/behind reflect the last fetch.
- `mra branch status --fetch` — runs `git fetch --quiet` first for fresh counts.
- `mra sync --safe` — fetches internally before computing state (a fast-forward needs current refs to be correct anyway).

A fetch updates remote-tracking refs and `.git/FETCH_HEAD` but never touches the working tree or local branches; "read-only" in this spec means **the working tree and local branches are never modified**. `branch status` without `--fetch` writes nothing at all.

### 4.2 Decision engine `branch_sync_action()`

A pure function: inputs `ahead`, `behind`, `dirty`, `upstream` → returns exactly one action string. This is the testability anchor of Phase 0 and the shared judgement source for Phase 1 (push) and Phase 2 (which repos changed → auto-review).

**Evaluation is strictly ordered — the first matching rule wins** (this removes overlap between `dirty`, `diverged`, and `no-upstream`):

| # | Condition | `sync_action` | `--safe` behavior |
|---|---|---|---|
| 1 | `upstream = (none)` | `no-upstream` | skip (hint: no tracking branch set) |
| 2 | `behind = 0` and `ahead = 0` | `up-to-date` | no-op |
| 3 | `behind = 0` and `ahead > 0` | `ahead-only` | no-op (ahead is left for Phase 1 push) |
| 4 | `behind > 0` and `ahead > 0` | `diverged` | skip + warn (needs rebase/merge — deferred) |
| 5 | `behind > 0` and `ahead = 0` and `dirty > 0` | `dirty-skip` | skip + warn (a ff would touch a dirty tree) |
| 6 | `behind > 0` and `ahead = 0` and `dirty = 0` | `fast-forward` | `git pull --ff-only` |

Notes on the ordering: `no-upstream` is checked first because ahead/behind are undefined without an upstream. `diverged` (rule 4) is reported regardless of `dirty` — a diverged branch is skipped either way, and reporting `diverged` is more informative than `dirty-skip`. `dirty-skip` (rule 5) only matters for the one case where a ff *would* otherwise run. This makes `dirty + diverged` → `diverged` and `dirty + no-upstream` → `no-upstream` deterministic.

### 4.3 Module responsibilities

- **`lib/branch.sh` (new)** — `get_branch_state()`, `branch_sync_action()`, `render_branch_table()`. Read-only introspection and formatting.
- **`lib/sync.sh` (extended)** — new public `mra sync` entrypoint wrapping the existing helpers (default behavior unchanged) plus a `--safe` path: fetch → per repo, get `BranchState` → ask the decision engine → execute (`git pull --ff-only`) or skip. `--safe` is opt-in.
- **`lib/review.sh` (extended)** — new `--working` path: when `--working` is passed, diff source switches from `base...HEAD` to the working tree via `git diff HEAD` (tracked staged + unstaged changes). Strategy selection, debate, and output reuse existing code. **Untracked files are out of scope for Phase 0** — `git diff HEAD` excludes them; if the working tree contains only untracked files, the path reports "no uncommitted changes to review" (handling `git ls-files --others --exclude-standard` is deferred).
- **`bin/mra.sh`** — new `branch` subcommand dispatch (`status`); new `sync` command dispatch with `--safe`/`--fetch`-style flag parsing; `review` parser gains a `--working` flag (repo stays positional, matching the existing convention).

## 5. Data flow

1. **`mra branch status`** → (if `--fetch`, `git fetch --quiet` per repo first) → for each repo in workspace: `get_branch_state()` → collect → filter (default keeps only repos **needing attention**: `dirty>0`, `ahead>0`, `behind>0`, or not on the default branch; `--all` keeps every repo) → `render_branch_table()` → print. When the filtered set is empty (and not `--all`), print "all repos clean and up to date". Read-only (no working-tree/branch writes; no fetch unless `--fetch`).
2. **`mra sync --safe`** → for each repo: `git fetch --quiet` → `get_branch_state()` → `branch_sync_action()` → if `fast-forward`, run `git pull --ff-only`; otherwise log a skip reason. Each repo independent.
3. **`mra review <repo> --working`** → resolve repo dir → `git diff HEAD` (tracked staged + unstaged) → if empty, print "no uncommitted changes to review" and exit 0 → else feed into existing strategy-selection + review pipeline.

## 6. Error handling

Per project rules: explicit handling at every level, no silent swallowing, user-friendly UI messages with detailed server-side logs.

- **Boundary validation:** `branch` subcommands validate the workspace exists and each dir is a git repo (non-git dirs reuse `should_skip_dir`). `review <repo> --working` requires a present, existing repo argument; fail fast with a clear message.
- **Per-repo isolation:** in `branch status` and `sync --safe`, a single repo failing (fetch failure, detached HEAD, no upstream) marks that row as failed via `log_error` and continues to the next repo. The command returns non-zero if any repo failed.
- **Detached HEAD / no upstream:** surfaced as `branch=(detached)` / `upstream=(none)` in `BranchState`; the decision engine returns `no-upstream` (rule 1) and `--safe` skips — never an error that aborts the batch.
- **Safety first:** `--safe` only runs `--ff-only`. It never auto-merges/rebases and never touches a repo with uncommitted changes — it skips with a warning rather than risk the user's working tree.
- **Read-only guarantee:** `branch status` (without `--fetch`) writes nothing; `--fetch` and `sync --safe` may update remote-tracking refs + `.git/FETCH_HEAD` but never the working tree or local branches. The review path never writes to a repo; review agents keep the existing `--disallowedTools "Write,Edit"`.
- **Empty `--working` diff:** a clean working tree (or one with only untracked files, which are out of scope) prints "no uncommitted changes to review" and exits 0 — the agent is not invoked on an empty diff.

## 7. Testing

Reuses repo conventions: `tests/test_*.sh` plain-bash asserts with error counters, `tests/fixtures` git repos, registered in `test.sh`. Target ≥80% coverage; the decision engine approaches full coverage.

1. **`tests/test_branch.sh` (new, unit-focused)** — exhaustively test the pure `branch_sync_action()` across ahead/behind/dirty/upstream combinations, asserting the correct action per the strictly-ordered rules in §4.2. Explicitly cover the overlap cases the ordering disambiguates: `dirty + diverged` → `diverged`, `dirty + no-upstream` → `no-upstream`, `behind>0 + ahead=0 + dirty>0` → `dirty-skip`. Validate `get_branch_state()` parsing (including `(detached)` / `(none)`) against a fixture repo using local refs only (no fetch).
2. **`tests/test_sync.sh` (extended)** — fixture a behind feature branch → `sync --safe` fast-forwards; fixture diverged / dirty → skips and leaves the working tree untouched (assert `git rev-parse HEAD` unchanged before/after). Assert plain `mra sync` (no flags) reproduces the existing helper behavior (regression-safe no-change).
3. **`tests/test_review_working.sh` (new)** — with tracked uncommitted changes, `review <repo> --working` captures a diff containing them; with a clean tree (and with only untracked files present) returns the "no changes" message and exits 0. To avoid real Claude calls, follow existing review tests: exercise diff acquisition and strategy selection, mock/skip the agent-invocation layer.

## 8. Out of scope of Phase 0 (deferred)

- **Phase 1 (designed in §9):** `branch new`/`switch` (cross-repo branch lifecycle), `sync --push` (+ `--dry-run`).
- **Phase 2 (designed in §10):** `sync --review` (auto-review changed repos), `branch pr` (cross-repo PR chaining).
- **Phase 3 (designed in §11):** hardening sweep — the §9.7 and §10.8 follow-ups (no new commands).
- **Phase 4 (designed in §12):** `review --range`/`--head` + diff-acquisition unification (retires §8.1.5 — debate/persona use `review-diff.sh`).
- **Phase 5 (designed in §13):** review-correctness group — `is_api_change` mode-aware (§8.1.1/§12.6/§12.8.3), `--working + --pr` guard (§8.1.2), mode-aware prompt preamble (§8.1.3), eval PKB via `review_diff_files` (§12.8.1), remove legacy `base` mode (§12.8.2).
- **Phase 6 (designed in §14):** cleanup backlog — controller-detection grep bug (§13.5.1), §8.1.4 dead `action` lookup, eval `is_api_change` consistency (§13.5.3), §13.5.2 test gaps, §11.6.1 `set -euo pipefail` sweep (13 files).
- **Phase 7 (designed in §15):** `mra branch merge` — cross-repo dependency-ordered PR merging with mergeable+CI gating, stop-on-first-failure, `--strategy`/`--dry-run`.
- **Phase 8 (designed in §16):** final polish — `branch merge --delete-branch` (§15.8.2), `integration-test.sh` `is_api_change` consistency (§14.5.1), concerns-only negative test (§14.5.2), `merge_repo` skip log-level alignment (§15.8.1).
- **Phase 9 (designed in §17):** `branch pr`/`branch merge` optional `[repos...]` subset (reactivates §11.6.2) — mirrors `branch new`; fail-fast subset validation, default-branch repos skipped, excluded-dependency warning.
- **Phase 10 (designed in §18):** `branch merge --wait-ci [--ci-timeout <sec>]` — opt-in CI-polling auto-merge; poll each PR's checks until they finish (fail-fast on red, stop on timeout) then merge. New `wait_for_pr_checks` in `lib/ci.sh`.
- **Phase 11 (designed in §19):** `branch status --json` — machine-readable JSON array of all repos' branch state (each object carries `needs_attention`). New pure `branch_state_json` in `lib/branch.sh`; on the JSON emit path stdout stays JSON-only (fetch failures → stderr; pre-emit fatal errors exit non-zero with no JSON — see §19.3).
- **Phase 12 (designed in §20):** `sync --json` for the default / `--safe` / `--push` modes — per-repo `{repo, action, ok}` JSON array via a shared result model (`sync_result_json` + a `SYNC_RESULT_FILE` sink in `lib/sync.sh`); text mode untouched; `--review --json` rejected. Stdout JSON-only (human logs → stderr in JSON mode).
- **Phase 13 (designed in §21):** `mra plan --dual` — opt-in multi-model council; each persona runs on **claude AND codex** (dual-run), synthesizer marks cross-model agreement vs disagreement for human decision. New `lib/model-provider.sh` (`call_model` provider abstraction, codex via `codex exec -s read-only`); default (no `--dual`) = current claude-only council, unchanged.
- **Won't fix / N/A:** §15.8.3 (malformed-JSON message — not a real risk; `gh` returns valid JSON or non-zero); `sync --review --json` (review output is freeform LLM prose — no clean JSON contract, same reason `review --json` was declined).

Each later phase reuses `BranchState` and `branch_sync_action()` from Phase 0.

### 8.1 Known limitations & follow-ups (from Phase 0 final review)

Phase 0 shipped with these intentional gaps, captured here so they are not lost. §8.1.5 is retired in Phase 4 (§12, diff unification); §8.1.1–§8.1.4 are deferred to Phase 5:

1. **`--working` + `is_api_change`:** in working mode, API-change detection still reads the committed diff (`<default>...HEAD`), so uncommitted API-surface changes do not trigger consumer-context loading. This is the only place `diff_mode` is not yet threaded through. Fix: pass `diff_mode`/`resolved_base` into `is_api_change` (or a `_working` variant).
2. **`--working` + `--pr` not guarded:** combining them is semantically incoherent (posting a review of uncommitted local changes as a PR inline review — line numbers won't match). Fix: reject with a clear error, consistent with the existing `--working + --personas` / `--working + --strategy debate` guards.
3. **Review prompt preamble in `--working` mode:** `build_review_prompt` still says "reviewing a pull request" regardless of mode. Fix: switch the preamble to "reviewing uncommitted working-tree changes" when `diff_mode == working`.
4. **Dead `action` lookup in `branch_format_row`:** it reads key `action` (always empty) then falls back to `sync_action`. Works correctly but the first lookup is dead. Fix: read `sync_action` directly.
5. **`review-diff.sh` not yet used by debate/persona paths:** correct Phase-0 boundary (`--working` forces single-pass). When `--working` scope expands, migrate those paths too to avoid re-divergence.

## 9. Phase 1 — Cross-repo branch lifecycle

**Status:** Approved (design) — 2026-05-29. Implementation scope for the next plan. Builds on Phase 0; reuses `BranchState`, `get_branch_state`, `branch_state_get`, and the `failed`-counter per-repo-isolation convention.

### 9.1 Command surface

All are new public commands / flags. `branch` subcommands and `sync` flags follow the Phase 0 conventions (positional first, `--flags` after).

| Command | Capability |
|---|---|
| `mra branch new <name> [repos…]` | Create + checkout a same-named branch across the workspace (or the listed repos) |
| `mra branch switch <name>` | Switch repos that already have `<name>` to it |
| `mra sync --push [--dry-run]` | Push local branches per the push decision engine; `--dry-run` previews only |

**`branch new <name> [repos…]`:** with no repos listed, acts on every git repo in the workspace; otherwise only the listed repos (each validated; missing/non-git → log_error that item, continue). Per repo: if `<name>` already exists → `git checkout <name>` (switch) + `log_warn "branch already exists, switched"`; else `git checkout -b <name>` with base = the repo's current HEAD. Per-repo isolation; any failure → non-zero exit.

**`branch switch <name>`:** per repo, if `<name>` exists (`git show-ref --verify --quiet refs/heads/<name>`) → `git checkout <name>` (a dirty tree that blocks checkout makes git fail → skip + warn, never force, never discard changes); else skip + warn. Does NOT create (that is `branch new`). Per-repo isolation.

**`sync --push [--dry-run]`:** per repo: `git fetch --quiet` (read-only refresh) → `get_branch_state` → `branch_push_action` → act per §9.2. Never `--force`/`--force-with-lease`. `--dry-run` performs the fetch but prints `would push …` instead of pushing (zero writes beyond remote-tracking refs). Default-branch is not specially protected — the decision engine governs by ahead/behind only (a deliberate choice). A detached HEAD is skipped (`skip-detached`, §9.2).

**Dirty and push (note vs. `sync --safe`):** unlike `sync --safe`, which has a `dirty-skip` action, `sync --push` does NOT consider the working tree — only committed refs are pushed, so a dirty tree never blocks a push. To avoid confusion with the `--safe` semantics, the push output still surfaces the repo's `dirty` count (e.g. `pushed (3 uncommitted files remain local)`) so users know uncommitted work stays local-only.

### 9.2 Push decision engine `branch_push_action()`

Pure function in `lib/branch.sh`, sibling to `branch_sync_action`. Inputs `ahead`, `behind`, `upstream`, `branch` (push does NOT consider `dirty` — uncommitted files don't affect pushing commits). `branch` is needed to distinguish a real unpublished branch from a detached HEAD, since both surface as `upstream=(none)` in the Phase 0 model. First matching rule wins:

| # | Condition | Result | `sync --push` behavior |
|---|---|---|---|
| 1 | `branch = (detached)` | `skip-detached` | skip + warn (no branch to push; check out a branch first) |
| 2 | `upstream = (none)` | `push-new` | `git push -u origin <branch>` (publish + set tracking) |
| 3 | `ahead = 0` & `behind = 0` | `up-to-date` | no-op |
| 4 | `ahead > 0` & `behind = 0` | `push` | `git push` (non-force) |
| 5 | `ahead > 0` & `behind > 0` | `skip-diverged` | skip + warn (pull/reconcile first) |
| 6 | `ahead = 0` & `behind > 0` | `skip-behind` | skip + warn (behind; pull first) |

Rule 1 is checked first so a detached HEAD can never reach the `push-new` path and attempt `git push -u origin "(detached)"`.

### 9.3 Architecture / module responsibilities

- **`lib/branch.sh` (extended)** — add the pure `branch_push_action()`. Still zero writes.
- **`lib/branch-ops.sh` (new)** — mutating cross-repo branch operations: `create_branch_in_repo()`, `switch_branch_in_repo()`, `create_branch_workspace()`, `switch_branch_workspace()`. Isolating writes here keeps `branch.sh` read-only/pure.
- **`lib/sync.sh` (extended)** — `push_repo()` and `push_workspace()` (sibling to `safe_sync_repo`/`safe_sync_workspace`); both accept a dry-run flag.
- **`bin/mra.sh`** — `branch)` dispatch gains `new`/`switch` subcommands; `sync)` gains `--push` and `--dry-run`; usage updated. Source `lib/branch-ops.sh` after `lib/branch.sh`.

### 9.4 Data flow

1. `mra branch new <name> [repos…]` → validate `<name>` (§9.5; fail fast before touching repos) → resolve repo set → per repo `create_branch_in_repo` (checkout -b, or checkout + warn if exists) → tally failures.
2. `mra branch switch <name>` → validate `<name>` (§9.5) → per repo `switch_branch_in_repo` (checkout if ref exists, else skip + warn) → tally failures.
3. `mra sync --push [--dry-run]` → `push_workspace` → per repo `push_repo` (fetch → state → `branch_push_action` → push/`-u`/skip, or `would push` when dry-run) → tally failures.

### 9.5 Error handling

Same principles as Phase 0: explicit per-level handling, no silent swallowing, per-repo isolation with a `failed` counter (any failure → non-zero exit), user-friendly messages.

- `<name>` is required for `branch new`/`switch`; empty → usage error.
- **Branch name validation (fail fast, before touching any repo):** validate `<name>` with `git check-ref-format --branch "<name>"`; reject invalid names with a clear error. Additionally reject any `<name>` beginning with `-` (would be parsed as a git option). In every `git` invocation, pass the name after a `--` separator and/or as a quoted positional (`git checkout -b -- "<name>"` where supported, `git push origin -- "<name>"`) so a crafted name can never inject options. This makes `branch new`/`switch` error behavior deterministic and testable.
- Listed repos for `branch new` are validated; a missing/non-git repo logs an error for that item and continues.
- `sync --push` never force-pushes; `skip-diverged`/`skip-behind` warn and leave the remote untouched. A detached HEAD → `skip-detached` (warn, no push). `--dry-run` guarantees no push.
- `branch switch` delegates the dirty/conflict decision to `git checkout`; a non-zero checkout → skip + warn, never `-f`, never discard changes.
- Empty workspace / no git repos → informational message, exit 0.

### 9.6 Testing

Reuses `tests/test_*.sh` plain-bash asserts + bare-repo fixtures (auto-discovered by `test.sh`).

1. **`tests/test_branch.sh` (extended)** — `branch_push_action(ahead, behind, upstream, branch)` across all combinations: `skip-detached` (branch `(detached)`, even with `upstream=(none)`), `push-new` (no-upstream, real branch), `up-to-date`, `push` (ahead-only), `skip-diverged` (ahead+behind), `skip-behind` (behind-only). Assert rule 1 (detached) wins over rule 2 (no-upstream).
2. **`tests/test_branch_ops.sh` (new)** — multi-repo fixture: `create_branch_workspace feat/x` puts every repo on `feat/x` (`git rev-parse --abbrev-ref HEAD`); a repo that already has `feat/x` is switched without fatal error. `switch_branch_workspace feat/x` switches repos that have the branch and leaves repos without it on their original branch (assert unchanged). **Name validation:** an invalid name (e.g. `feat/x..y` or `feat~1`) and a leading-dash name (e.g. `--foo`) are rejected before any repo is modified (assert non-zero return and that no repo changed branch).
3. **`tests/test_sync.sh` (extended)** — bare-upstream + clone fixtures: local-ahead → `push_repo` (non-dry-run) makes the bare ref advance; no-upstream new branch → `push -u` then `@{upstream}` resolves; behind/diverged → `push_repo` leaves the bare ref unchanged; `--dry-run` with local-ahead leaves the bare ref unchanged (proves zero push).

Target ≥80% coverage; both decision engines approach full coverage.

### 9.7 Phase 1 known limitations & follow-ups (from final review, deferred to Phase 3)

Phase 1 shipped with these intentional gaps, captured so they are not lost:

1. **Test harness `((errors++))` under `set -e`:** the repo-wide test convention uses `((errors++))`, which (when a counter is 0) returns exit 1 and, under `set -euo pipefail`, aborts the test on the FIRST failing assertion instead of accumulating all failures. Harmless while tests pass; it weakens diagnostics when they don't. Pre-existing across all `tests/test_*.sh` (not introduced by Phase 1). Fix repo-wide: `errors=$((errors+1))`.
2. **`mra sync --dry-run` without `--push`:** silently performs a normal clone/pull (dry-run only applies to `--push`). Fix: warn, or extend dry-run to the pull path.
3. **`mra sync --safe --push`:** `--push` silently wins (checked first). Fix: document as mutually exclusive or error on both.
4. **Diverged push integration fixture:** the `diverged` push case is covered at the unit level (`branch_push_action`) but lacks a bare-remote integration fixture in `test_sync.sh` (the `behind` case has one). Add a two-clone diverged fixture asserting the remote ref is unchanged.
5. **`branch new <repos…>` path traversal:** a repo-name arg like `../../x` is joined to `$workspace/` without containment validation. Low risk for a local CLI, but a `basename`/`realpath` containment check would close it.

## 10. Phase 2 — Cross-repo PR workflow

**Status:** Approved (design) — 2026-05-29. Implementation scope for the next plan. Completes the original headline asks ("auto-review after sync", "PR chaining"). Builds on Phase 0/1; reuses `BranchState`, `safe_sync_repo`, `push_repo`, `review_project`, and `lib/deps.sh` relationship queries.

### 10.1 Command surface

| Command | Capability |
|---|---|
| `mra sync --review` | Run safe-sync, then auto-review repos with changes (terminal review, no PR) |
| `mra branch pr [--base <ref>] [--dry-run]` | Push feature-branch repos and open PRs across them in dependency order |

**`sync --review`:** runs the safe-sync loop while recording which repos' HEAD actually moved (`changed`). The review target set = `changed` ∪ { repos with `ahead>0` OR not on the default branch } (i.e. upstream commits just pulled in, plus your own local work). Each target is reviewed via `review_project` in terminal mode (no GitHub/`gh` needed). Empty target set → "no repos to review", exit 0. Does NOT require `gh`.

**`branch pr [--base <ref>] [--dry-run]`:** requires `gh`. Collects repos on a feature branch (not the default branch, not detached), orders them dependency-first, and for each: first checks **PR eligibility** — if the feature branch has no commits relative to base (`git rev-list --count <base>..<branch>` is 0, i.e. no diff to propose), skip with an info message and do NOT push (an empty branch would otherwise push and then make `gh pr create` fail, misreporting "nothing to PR" as an error); this is not a failure. Otherwise reuse Phase 1 `push_repo` (publishing with `-u` if needed; `behind`/`diverged` → skip + warn, no PR), then `gh pr create --base <default-or-`--base`> --head <current>`. An already-existing PR for the head → skip + report its URL (not a failure). `--dry-run` prints `would open PR: <repo> <branch> → <base>` and performs no push and no PR.

### 10.2 Architecture / module responsibilities

- **`lib/review-select.sh` (new)** — pure `review_targets(workspace, changed…)` returning the union (changed ∪ ahead>0 ∪ off-default) using `get_branch_state`. No writes.
- **`lib/sync.sh` (extended)** — `sync_review_workspace(workspace)`: per repo capture HEAD before/after a `safe_sync_repo`, collect `changed`, compute `review_targets`, then `review_project` (terminal) each. Returns non-zero if any review failed.
- **`lib/pr-ops.sh` (new)** — `order_repos_by_deps(graph_file, repos…)` (Kahn best-effort; un-orderable remainder falls back to workspace/alpha order with a logged note), `pr_repo(repo_dir, base, dry_run)` (push + existing-PR detect + `gh pr create`), `pr_workspace(workspace, base, dry_run)`. Isolates PR/`gh` interaction, mirroring `branch-ops.sh`.
- **`bin/mra.sh`** — `sync)` gains `--review`; `branch)` gains a `pr` subcommand (`--base`/`--dry-run`); `gh auth status` preflight for `branch pr`; usage. Source `lib/review-select.sh` and `lib/pr-ops.sh`.

### 10.3 Data flow

1. `mra sync --review` → per repo: `before=HEAD` → `safe_sync_repo` → `after=HEAD`; `before!=after` → add to `changed`. → `targets = review_targets(workspace, changed…)` → per target `review_project` (terminal). Empty → info + exit 0.
2. `mra branch pr [--base] [--dry-run]` → `gh auth status` (fail fast if unauth) → collect feature-branch repos → `order_repos_by_deps` → per repo: `pr_repo` (skip default-branch/detached; skip + info if no commits vs base — no push; else push via `push_repo`; skip-on-behind/diverged; existing-PR → report URL; else `gh pr create`). `--dry-run` → preview only.

### 10.4 `order_repos_by_deps` (Kahn best-effort)

Orders ONLY the repos in the to-PR set (dependencies before consumers, so a consumer's PR can reference its upstream):

```
remaining = set; ordered = []
loop:
  ready = { r in remaining : every in-set dep of r is already in ordered }
  if ready empty: append remaining (workspace/alpha order) to ordered, log a note, break
  append ready (alpha order) to ordered; remove from remaining
until remaining empty
```

Pure function; testable with a graph fixture (a depends on b ⇒ b before a; unrelated/cyclic ⇒ stable fallback, no error).

### 10.5 Error handling

Same principles: per-repo isolation with a `failed` counter (any failure → non-zero exit), no silent swallowing.

- `branch pr` preflight `gh auth status`; unauth → log_error + exit 1 before touching repos.
- `gh pr create` failure: distinguish already-exists (detect via `gh pr view --json url`; skip + report URL; NOT a failure) from a real error (log_error + count failure).
- No feature-branch repos → info, exit 0. `sync --review` empty target set → info, exit 0.
- **PR eligibility:** a feature branch with no commits relative to base (`rev-list --count <base>..<branch>` = 0) → skip + info, NO push, not a failure. Prevents pushing a just-created empty branch only to have `gh pr create` fail.
- `push_repo` never force-pushes (Phase 1 guarantee); `behind`/`diverged`/`detached` → skip + warn, no PR.
- `--dry-run` (branch pr) performs no push and no `gh` write.

### 10.6 Testing

Reuses `tests/test_*.sh` + bare-repo fixtures. `gh pr create` and `review_project` (Claude) are NOT executed in tests — coverage targets the pure decisions, `--dry-run` zero-write, and the sync-detection half; the `gh`/Claude call layers are isolated per existing repo convention. **This boundary is stated so coverage is not mistaken for end-to-end `gh` testing.**

1. **`tests/test_review_select.sh` (new)** — `review_targets`: multi-repo fixture; given a `changed` set, assert the union is correct (changed ∪ ahead>0 ∪ off-default); a clean on-default repo not in `changed` is NOT selected.
2. **`tests/test_pr_ops.sh` (new)** — `order_repos_by_deps`: graph fixture where a depends on b ⇒ assert b precedes a; unrelated/cyclic ⇒ fallback order, no error. `pr_repo --dry-run`: bare-remote + feature-branch fixture ⇒ prints would-open AND the remote gains no ref / no PR (proves zero write; no real `gh`). A default-branch repo ⇒ `pr_repo` skips (no push, no `gh`). A feature branch with NO commits vs base ⇒ `pr_repo` skips + info, the bare remote gains no ref (proves no push), not a failure.
3. **`tests/test_sync.sh` (extended)** — `sync_review_workspace` sync half: a behind fixture ⇒ after the run the repo's HEAD advanced and it is counted in `changed` (the review call layer is mocked/skipped, matching existing review tests — not a real Claude call).

Target ≥80% coverage; pure functions approach full coverage.

### 10.7 Out of scope (Phase 3)

`review --range`/`--head`; the §8.1 review follow-ups; the §9.7 hardening follow-ups; any auto-merge or PR-merge orchestration.

### 10.8 Phase 2 known limitations & follow-ups (from final review, deferred to Phase 3)

Phase 2 shipped with these intentional gaps, captured so they are not lost:

1. **`sync --review --dry-run` silently ignores `--dry-run`:** `--dry-run` is parsed but not forwarded when `--review` is the active mode, so the safe-sync runs for real. Spec §10.1 only defines `--dry-run` for `branch pr`. Fix: reject the `--review --dry-run` combination with a usage error, or define and implement a preview mode for `sync --review`.
2. **`pr_workspace` candidate collection vs `--base`:** candidates are repos where `branch != default_branch`. When `--base` names a non-default ref, repos sitting on that ref are collected then skipped in `pr_repo` (harmless but wasteful). Fix: exclude the resolved base ref from candidates.
3. **`pr_repo` invalid `base_ref` is silent:** `git rev-list --count <base>..<branch> || echo 0` treats an unknown base as "no commits → skip" without surfacing the misconfiguration. Fix: `log_warn` when the base ref cannot be resolved.
4. **`sync` flag silent-win ordering:** the mode chain is `--review` > `--push` > `--safe` > default; combining flags silently ignores the lower-priority ones (extends §9.7.3). Fix: document as mutually exclusive or error on multiple modes.

(The repo-wide `((errors++))` test-harness fix from §9.7.1 also applies to the Phase 2 test files `test_review_select.sh` / `test_pr_ops.sh`.)

## 11. Phase 3 — Hardening sweep

**Status:** Approved (design) — 2026-05-30. Implementation scope for the next plan. No new commands; targeted robustness/UX/test fixes that retire the §9.7 and §10.8 follow-ups. Review extensions (`review --range`/`--head`) and the §8.1 review follow-ups are deferred to Phase 4.

### 11.1 Groups & exact behavior

**① sync flag discipline** (`bin/mra.sh` `sync)` dispatch; retires §9.7.2, §9.7.3, §10.8.1, §10.8.4)
- `--safe` / `--push` / `--review` are **mutually exclusive**: after parsing, if more than one is true → `log_error "sync: choose only one of --safe / --push / --review" "sync"` + `exit 1`.
- `--dry-run` applies **only** to `--push`: if `--dry-run` is set without `--push` (alone, or with `--safe`/`--review`/default) → `log_error "sync: --dry-run only applies to --push" "sync"` + `exit 1`.
- After these gates, behavior is unchanged (single mode or default).

**② `branch pr` base/eligibility polish** (`lib/pr-ops.sh`; retires §10.8.2, §10.8.3)
- `pr_workspace` collects a repo as a candidate when its branch is NOT detached AND not equal to the **resolved base** (the `--base` value if given, else the repo's default branch) — so a repo sitting on the base ref is never collected then skipped.
- `pr_repo`: if `git rev-list --count "<base>..<branch>"` fails because the base ref cannot be resolved (distinguish from a real 0-count), `log_warn "$repo_name: base '<base>' not found — skipping" "branch"` + `return 0`, rather than silently treating it as "0 commits".

**③ `branch new` path-traversal** (`lib/branch-ops.sh`; retires §9.7.5)
- New pure `validate_repo_name(name)`: rejects (returns non-zero) a name that contains `/`, equals `.` or `..`, or begins with `-`. `create_branch_workspace` validates each explicitly-listed repo name before touching the filesystem; an invalid name → `log_error` for that item + count it as a failure (no fs access for that item).

**④ diverged push integration fixture** (`tests/test_sync.sh`, test-only; retires §9.7.4)
- A two-clone diverged fixture (A and B each commit and push; A is both ahead and behind) → `push_repo` on A leaves the bare remote ref unchanged (integration-level evidence to complement the unit-level `branch_push_action` coverage).

**⑤ test harness `((errors++))` repo-wide** (all `tests/test_*.sh`; retires §9.7.1)
- Mechanically replace `((errors++))` with `errors=$((errors+1))` so a failing assertion accumulates all failures instead of aborting on the first under `set -euo pipefail`.

### 11.2 Architecture / module responsibilities

- **`lib/branch-ops.sh`** — add pure `validate_repo_name()`; call it inside `create_branch_workspace` for listed repos.
- **`lib/pr-ops.sh`** — `pr_workspace` candidate filter uses the resolved base; `pr_repo` distinguishes unresolved base from 0-count.
- **`bin/mra.sh`** — `sync)` dispatch adds the mutual-exclusion + `--dry-run`-requires-`--push` gates before mode selection.
- **`tests/`** — new `test_sync_flags.sh`; extend `test_pr_ops.sh`, `test_branch_ops.sh`, `test_sync.sh`; the `((errors++))` sweep touches every `test_*.sh`.

### 11.3 Error handling

- sync flag conflicts → hard `log_error` + `exit 1` (deterministic, no silent mode-win).
- `validate_repo_name` failure → `log_error` for that repo + failure count; never touches the filesystem for an invalid name.
- `pr_repo` unresolved base → `log_warn` + skip (return 0), surfacing the misconfiguration without aborting the batch.
- All per-repo isolation and `failed`-counter conventions from earlier phases are preserved.

### 11.4 Testing

Reuses `tests/test_*.sh` + fixtures (auto-discovered by `test.sh`).

1. **`tests/test_sync_flags.sh` (new)** — subprocess calls `MRA_WORKSPACE=<tmp> bash bin/mra.sh sync <flags>` asserting exit code + message: `--safe --push` → exit 1 + "choose only one"; `--review --push` → exit 1; `--dry-run` (no `--push`) → exit 1 + "only applies to --push"; `--push --dry-run` → exit 0 (valid, runs through an empty/clean workspace); a single mode flag → not rejected by the discipline gate.
2. **`tests/test_pr_ops.sh` (extended)** — a repo on the `--base` ref is NOT a candidate (no would-open in dry-run with `--base`); `pr_repo` with an unresolvable `--base` (e.g. `nosuchref`) → output contains "not found", skips, bare remote unchanged.
3. **`tests/test_branch_ops.sh` (extended)** — `validate_repo_name`: valid (`api`, `my-repo`, `repo123`); invalid (`a/b`, `.`, `..`, `-foo`, `../x`). Integration: `create_branch_workspace WS feat/x "../evil"` → that item errors, returns non-zero, and nothing is created outside the workspace (assert `../evil` does not exist).
4. **`tests/test_sync.sh` (extended)** — the diverged two-clone fixture: `push_repo` on the diverged clone leaves the bare ref unchanged.
5. **`((errors++))` sweep** — verified by `bash test.sh` staying green after the change; multi-failure accumulation is confirmed manually during implementation (a temporary injected failure shows a count, then removed — not committed).

### 11.5 Out of scope (Phase 4)

`review --range`/`--head`; the §8.1 review follow-ups (`is_api_change` working-mode, `--working + --pr` guard, working-mode prompt preamble, dead `action` lookup cleanup, debate/persona `review-diff` migration); any auto-merge / PR-merge orchestration.

### 11.6 Phase 3 follow-ups (from final review, deferred to Phase 4)

Captured so they are not lost:

1. **Pre-existing test files lacking `set -euo pipefail`:** ~13 `tests/test_*.sh` (e.g. `test_db_safety.sh`, `test_docker_trust.sh`, `test_doctor_security.sh`) never enabled strict mode. Out of scope for Phase 3; a dedicated cleanup commit could standardize them.
2. **`validate_repo_name` for a future `branch pr` repo-subset:** if a later phase adds a per-repo subset to `branch pr` (like `branch new`'s), it should reuse `validate_repo_name`. Not a gap today (no such CLI path exists).

## 12. Phase 4 — Review range/head + diff-acquisition unification

**Status:** Approved (design) — 2026-06-01. Implementation scope for the next plan. Adds `review --range`/`--head` and unifies diff acquisition so single-pass, debate, and persona paths all use `lib/review-diff.sh` (retiring §8.1.5).

### 12.1 Command surface (`mra review`)

| Flag | Semantics |
|---|---|
| `mra review <repo> --head <ref>` | Review `<base>...<ref>` (the tip becomes `<ref>` instead of `HEAD`; pairs with `--base`) |
| `mra review <repo> --range <R>` | Review the raw git range `<R>` (e.g. `A..B`, `v1..v2`), passed straight to `git diff <R>` |

`--range` is interpreted as a raw git range (the user's two-dot/three-dot choice is respected). `--head` uses three-dot (`base...ref`), matching the existing default `base...HEAD`.

**Mutual exclusion (hard error + `return 1`, mirroring Phase 3 flag discipline):**
- `--range` and `--head` are mutually exclusive.
- `--range`/`--head` are incompatible with `--pr` (a PR supplies its own base/head).
- `--range`/`--head` are incompatible with `--working` (the working tree has no commit range).
- The existing `--working + --personas` and `--working + --strategy debate` guards remain.

### 12.2 Diff model — `(mode, range_expr)`

`lib/review-diff.sh` is generalized to a single source of truth:

```
review_diff_text(project_dir, mode, range_expr):
  working → git diff HEAD                 # staged + unstaged tracked changes
  range   → git diff "$range_expr"        # any range: base...HEAD / base...ref / A..B
  (on failure → echo "")
review_diff_files(project_dir, mode, range_expr):  # same with --name-only
```

`mode=range` subsumes default / `--head` / `--range` — they differ only in the `range_expr` string the caller builds.

`review.sh` computes `range_expr` at one decision point (after resolving `base_ref` as today):

```
if working:          mode=working; range_expr=""
elif range_arg set:  mode=range;   range_expr="$range_arg"               # raw
elif head_arg set:   mode=range;   range_expr="${resolved_base}...${head_arg}"
else:                mode=range;   range_expr="${resolved_base}...HEAD"  # = current default
```

**Validation of an EXPLICIT `--range`/`--head` (fail loud, never silently empty):** when the user supplied `--range`/`--head`, `review.sh` validates the range resolves *before* running the review — `git -C "$dir" rev-list "$range_expr" -- >/dev/null 2>&1` (rev-list errors on an unknown ref/range, succeeds on a valid one even when empty). Two distinct outcomes:
- **Invalid ref/range** (rev-list fails — e.g. the typo `maim..HEAD`) → `log_error "review: invalid range/ref '<range_expr>'"` + `return 1` (non-zero exit; NO review, NO `(diff unavailable)` run).
- **Valid but empty** (rev-list succeeds, diff is empty) → `log_info "review: no changes in '<range_expr>' — nothing to review"` + `return 0`.

This validation+empty-check applies ONLY to explicit `--range`/`--head` (and is a clean addition for `--working`, which already early-returns "no uncommitted changes"). The **default** `base...HEAD` path keeps its current behavior (no pre-validation, no empty early-return) for byte-for-byte backward compatibility.

### 12.3 Threading `(mode, range_expr)` through all paths (retires §8.1.5)

- **single-pass:** `build_review_prompt` takes `(mode, range_expr)` (replacing the `${11:-base}` diff_mode param) and calls `review_diff_text` internally.
- **debate:** `run_debate_review` takes `(mode, range_expr)` (replacing the `base_ref`-derived inline diff) and calls `review_diff_text`.
- **persona:** the persona block in `review.sh` replaces its inline `git diff "${resolved_base_p}...HEAD"` with `review_diff_text "$project_dir" "$mode" "$range_expr"`.

The four previously-duplicated diff-acquisition sites converge on `review-diff.sh`. `--range`/`--head` therefore take effect in light, standard, debate, and persona modes.

### 12.4 Architecture / module responsibilities

- **`lib/review-diff.sh`** — generalize to `(mode, range_expr)`.
- **`lib/review.sh`** — parse `--head`/`--range`; mutual-exclusion gates; build `range_expr`; thread `(mode, range_expr)` to all three paths.
- **`lib/review-prompt.sh`** — `build_review_prompt` accepts `(mode, range_expr)`; uses `review_diff_text`.
- **`lib/review-debate.sh`** — `run_debate_review` accepts `(mode, range_expr)`; uses `review_diff_text`.
- **`bin/mra.sh`** — `review)` dispatch forwards `--head`/`--range`; usage updated.

### 12.5 Error handling

- Mutual-exclusion violations → `log_error` with a clear message + `return 1` (so `review_project` is non-zero and the dispatch exits 1), checked after parsing and before the review flow.
- **Explicit `--range`/`--head` that is an invalid ref/range** → `log_error` + `return 1` (per §12.2 validation) — it never silently degrades to `(diff unavailable)` and never exits 0. A typo like `--range maim..HEAD` fails loudly.
- **Explicit `--range`/`--head` that is valid but empty** → `log_info "no changes …"` + `return 0` (the agent is not invoked on an empty range).
- The DEFAULT `base...HEAD` path keeps current behavior: an unavailable/empty default diff still falls through to `(diff unavailable)` in the single-pass prompt (regression-safe; not changed by this phase). Review agents keep `--disallowedTools "Write,Edit"`; review is read-only.
- Backward compatibility: with no `--range`/`--head`/`--working`, `range_expr` defaults to `base...HEAD` — byte-for-byte equivalent to current behavior.

### 12.6 Known limitation (deferred, §8.1.1 family)

`is_api_change` still computes from `default_branch...HEAD`; it is NOT range-aware, so `--range`/`--head` do not change which consumer context is loaded for the API-change heuristic. Deferred to Phase 5 alongside the `--working` `is_api_change` gap.

### 12.7 Testing

Reuses `tests/test_*.sh`; the Claude call layers (debate/persona/actual single-pass invocation) are NOT executed in tests — coverage targets the pure `review_diff_text` range mode, the `range_expr` construction, and the mutual-exclusion gates. Stated here so coverage is not mistaken for end-to-end review testing.

1. **`tests/test_review_working.sh` (extended) or new `tests/test_review_diff.sh`** — `review_diff_text`/`review_diff_files` `range` mode against a fixture: commits A then B → `range "A..B"` contains B's change, excludes pre-A; `base...HEAD` equals the current default; `working` mode unchanged (regression).
2. **`tests/test_review_flags.sh` (new, subprocess-driven, like `test_sync_flags.sh`)** — `MRA_WORKSPACE=… bash bin/mra.sh review <repo> <flags>` asserts, all BEFORE any Claude call (so no agent invocation is exercised):
   - Mutual-exclusion combos exit non-zero with a clear message: `--range A..B --head x`, `--range A..B --pr 1`, `--head x --working`.
   - **Invalid range** `--range maim..HEAD` (typo) → exit non-zero + "invalid range/ref" (proves no silent `(diff unavailable)` / no exit 0).
   - **Valid empty range** (e.g. `--range HEAD..HEAD`) → exit 0 + "no changes" (the validation passes, the empty-diff early-return fires before Claude).
3. **Regression** — existing `test_review_working.sh`, `test_review_personas.sh`, `test_review_safety.sh` stay green, proving base/working behavior and the persona path's switch to `review-diff.sh` are unchanged.

### 12.8 Out of scope (Phase 5)

The remaining §8.1 follow-ups (§8.1.1–§8.1.3 review-subsystem; §8.1.4 `branch_format_row` UI cleanup); `is_api_change` range/working-awareness; the §11.6 follow-ups; any auto-merge / PR-merge orchestration.

**Additional Phase 4 final-review follow-ups (deferred to Phase 5):**
1. **`eval.sh` PKB `changed_files` bypasses `review-diff.sh`:** `_eval_run_review` builds its PKB module-detection `changed_files` with a raw `git diff --name-only "${resolved_base}...HEAD"`, not `review_diff_files`. Harmless today (eval-review is always `--pr`, so `resolved_base` always resolves), but a second un-unified diff site. Route it through `review_diff_files`.
2. **Legacy `base` mode in `review-diff.sh` is now untested:** after the migration, production callers use `range`/`working`; the `base` else-branch (with its two-command fallback) has no test. Either add a regression test (assert `range "A...B"` == `base "A"` output) or remove `base` mode once no direct callers remain.
3. **`is_api_change` not range-aware:** with `--range`/`--head`, the API-change heuristic still reads `default_branch...HEAD`, so consumer context may be mis-loaded for a narrow range (same family as the `--working` gap, §12.6).

## 13. Phase 5 — Review correctness group

**Status:** Approved (design) — 2026-06-01. Implementation scope for the next plan. No new commands; five review-subsystem correctness fixes retiring §8.1.1–§8.1.3, §12.6, §12.8.1–§12.8.3.

### 13.1 Items & exact behavior

**① `is_api_change` mode-aware** (`lib/change-detector.sh` + `lib/review.sh`; retires §8.1.1/§12.6/§12.8.3)
- Signature → `is_api_change(project_dir, project_type, [mode], [range_expr])`. It computes its changed-file list and any diff-content checks via `review_diff_files`/`review_diff_text "$project_dir" "$mode" "$range_expr"` instead of the hard-coded `git diff "$default_branch"...HEAD`.
- Backward compatible: when `mode`/`range_expr` are omitted, default `mode="range"`, `range_expr="${default_branch}...HEAD"` (current behavior). Any non-review caller is unaffected.
- `review.sh`: move the `(mode, range_expr)` decision point (including the explicit-range `rev-list` validation) to BEFORE the `is_api_change` call (currently ~line 181), and pass `"$mode" "$range_expr"`. So `--range`/`--head`/`--working` make the API-change heuristic (hence consumer-context loading) match the actual reviewed diff. The empty-range early-return still happens later, after `changed_count`.

**② `--working + --pr` guard** (`lib/review.sh`; retires §8.1.2)
- In the existing `--working` guard block (which already rejects `--working + --personas` and `--working + --strategy debate`), add: `--working` with `--pr` → `log_error "review: --working cannot be combined with --pr (working-tree changes have no PR line mapping)"` + `return 1`.

**③ Mode-aware prompt preamble** (`lib/review-prompt.sh`; retires §8.1.3)
- The `build_review_prompt` opening line ("You are reviewing a pull request for the project …") becomes mode-aware using the existing `mode`/`range_expr` params: `working` → "reviewing the uncommitted working-tree changes for the project …"; `range` with a non-default `range_expr` → "reviewing the changes in '<range_expr>' for the project …"; the default `…...HEAD` → keep the "pull request" wording.

**④ eval PKB via `review_diff_files`** (`lib/eval.sh`; retires §12.8.1)
- `_eval_run_review`'s PKB module-detection `git diff --name-only "${resolved_base}...HEAD"` → `review_diff_files "$project_dir" range "${resolved_base}...HEAD"`. Same result, one source of truth.

**⑤ Remove legacy `base` mode** (`lib/review-diff.sh` + `tests/test_review_working.sh`; retires §12.8.2)
- `review_diff_text`/`review_diff_files` keep only `working` and `range` (remove the `base` else-branch; no production caller remains after Phase 4). The mode argument is now `working` → working tree, anything else → treated as `range` (a single, documented default). Update `test_review_working.sh`'s direct `base`-mode assertions to `range "main...HEAD"`.

### 13.2 Architecture / module responsibilities

- **`lib/change-detector.sh`** — `is_api_change` gains optional `(mode, range_expr)`; uses `review_diff_*`.
- **`lib/review.sh`** — reorder `(mode, range_expr)` decision before `is_api_change`; pass it in; add `--working + --pr` gate.
- **`lib/review-prompt.sh`** — mode-aware preamble.
- **`lib/eval.sh`** — PKB changed-files via `review_diff_files`.
- **`lib/review-diff.sh`** — drop `base` mode (working|range only).

### 13.3 Error handling

- `--working + --pr` → hard `log_error` + `return 1` (non-zero exit), consistent with the other `--working`/range gates.
- `is_api_change` is read-only and best-effort: on any git failure it still returns a safe value (`none`/`low`), never aborts the review.
- No behavior change to the default review path; review remains read-only (`--disallowedTools "Write,Edit"`).

### 13.4 Testing

Reuses `tests/test_*.sh`; Claude call layers are not executed.

1. **`tests/test_change_detector.sh` (new)** — `is_api_change` against a fixture: a range containing an API-surface change (per `project_type`, e.g. rails-api `config/routes.rb`) → high/`true`; a range without it → `low`/`none`; omitting `mode`/`range_expr` falls back to `default...HEAD` (backward-compat). Pure git, no Claude.
2. **`tests/test_review_flags.sh` (extended)** — subprocess `review repo --working --pr 1` → non-zero exit + message mentioning `--working`/`--pr`.
3. **`tests/test_review_working.sh` (extended)** — call `build_review_prompt` directly (no Claude): `mode=working` output contains "uncommitted working-tree" and NOT "pull request"; `mode=range` with a non-default range contains the range wording; default keeps "pull request". Also: the file's direct `review_diff_text` assertions switch from `base` to `range "main...HEAD"`.
4. **`tests/test_review_diff.sh` (regression)** — `range`/`working` modes still pass after `base` removal.
5. **Regression** — `test_review_personas.sh`, `test_review_safety.sh` stay green; default review unchanged. The eval PKB rewiring is verified by `bash -n` + green suite + grep that `_eval_run_review` now calls `review_diff_files` (eval-review's end-to-end `gh`/Claude path is not exercised, per existing convention).

### 13.5 Out of scope (Phase 6)

§8.1.4 (`branch_format_row` dead `action` lookup); §11.6.1 (13 test files lacking `set -euo pipefail`); §11.6.2; any auto-merge / PR-merge orchestration.

**Additional Phase 5 final-review follow-ups (deferred to Phase 6):**
1. **`change-detector.sh` controller-detection bug (pre-existing, not from Phase 5):** line ~39 `echo "$changed_files" | grep -qE "^app/controllers/" | grep -v "concerns/"` is a no-op — `grep -q` produces no stdout, so the piped `grep -v` always sees empty input and the `if` is never true. The rails-api "controller public method changed" / "route definition in controller" `high`-confidence triggers therefore never fire (routes.rb / serializers / schema / docker-compose triggers are unaffected). Exists identically on `main`. Fix: restructure to two separate conditions (e.g. `grep -qE "^app/controllers/" <<<"$changed_files" && ! grep -q "concerns/" <<<"$changed_files"`).
2. **Test-coverage gaps (logic verified, untested):** `is_api_change` `working` mode; explicit `--range A..B` preamble wording ("changes in 'A..B'"); `--head` non-HEAD range preamble. Add fixtures.
3. **`eval.sh:199` `is_api_change` call** still uses 2-arg back-compat; for consistency pass `"range" "${resolved_base}...HEAD"` explicitly (currently correct via the back-compat default).

## 14. Phase 6 — Cleanup backlog

**Status:** Approved (design) — 2026-06-01. Implementation scope for the next plan. No new commands; five cleanups retiring §13.5.1–§13.5.3, §8.1.4, §11.6.1. (auto-merge / §11.6.2 → Phase 7.)

### 14.1 Items & exact behavior

**① controller-detection grep bug (behavior fix)** (`lib/change-detector.sh`)
- The `rails-api` controller check is currently `if echo "$changed_files" | grep -qE "^app/controllers/" | grep -v "concerns/"; then` — a no-op (`grep -q` emits nothing, so the piped `grep -v` always sees empty input → the `if` is never true). The "controller public method changed" / "route definition in controller" high-confidence triggers therefore never fire.
- Fix to: `if echo "$changed_files" | grep -E "^app/controllers/" | grep -qvE "concerns/"; then` (list the controller files; succeed if any is NOT under `concerns/`). This is a deliberate behavior fix — after it, a controller change whose content diff adds a public method / route correctly yields `high` (the inner content-diff gate is unchanged). Other triggers (routes.rb, serializers, schema, docker-compose) are unaffected.

**② Remove dead `action` lookup** (`lib/branch.sh`, `branch_format_row`; §8.1.4)
- Replace the two lines `action=$(branch_state_get "$s" action 2>/dev/null)` + `[[ -z "$action" ]] && action=$(branch_state_get "$s" sync_action)` with a single `action=$(branch_state_get "$s" sync_action)` (the state always emits `sync_action`; the `action` key never exists).

**③ eval `is_api_change` consistency** (`lib/eval.sh`; §13.5.3)
- `is_api_change "$project_dir" "$project_type"` → `is_api_change "$project_dir" "$project_type" range "${resolved_base}...HEAD"` (explicit mode/range, matching `review.sh`; behavior-equivalent via the prior back-compat default).

**④ Test-coverage gaps** (`tests/`; §13.5.2)
- `tests/test_change_detector.sh`: add a `working`-mode case (uncommitted `config/routes.rb` → `high`).
- `tests/test_review_working.sh`: add an explicit `--range A..B` preamble assertion ("changes in 'A..B'" present, "pull request" absent) — the same code path covers `--head`'s `base...ref`.

**⑤ `set -euo pipefail` sweep** (13 `tests/test_*.sh`; §11.6.1)
- Add `set -euo pipefail` (after the shebang) to the 13 files that lack it: `test_db_safety.sh`, `test_docker_trust.sh`, `test_doctor_security.sh`, `test_install_alias.sh`, `test_lint_profile.sh`, `test_project_path.sh`, `test_review_safety.sh`, `test_scan_rebuild.sh`, `test_scanners.sh`, `test_security_log.sh`, `test_snapshot.sh`, `test_url_policy.sh`, `test_validate.sh`. Process one file at a time; run it after adding strict mode. If `set -u`/`set -e` surfaces a latent issue (unbound variable, or a previously-ignored non-zero exit), apply the minimal fix (`${var:-}` for unbound; `|| true` for an intentionally-failing probe) WITHOUT changing the test's assertions. This is exploratory per-file work; any non-trivial fix is reported.

### 14.2 Architecture / module responsibilities

- **`lib/change-detector.sh`** — fix the controller grep so the condition can be true.
- **`lib/branch.sh`** — `branch_format_row` reads `sync_action` directly.
- **`lib/eval.sh`** — explicit `is_api_change` mode/range args.
- **`tests/`** — coverage additions + the 13-file strict-mode sweep.

### 14.3 Error handling

- The controller fix only changes which inputs make the `if` true; `is_api_change` remains read-only and best-effort (catches git failures, returns `none`/`low`).
- The `set -euo pipefail` sweep makes the 13 test files fail-fast on errors; any minimal fix preserves the existing pass/fail assertions.
- No production command behavior changes besides the intended controller-detection fix.

### 14.4 Testing

1. **`tests/test_change_detector.sh` (extended)** — a range whose diff adds `def index` in `app/controllers/x_controller.rb` → `high` (proves the controller fix fires); a `concerns/`-only controller change is not raised to `high` by this rule. Plus the `working`-mode case (uncommitted `config/routes.rb` → `high`).
2. **`tests/test_branch.sh` (regression)** — the existing `branch_format_row` assertion stays green after the dead-lookup removal.
3. **`tests/test_review_working.sh` (extended)** — explicit `--range A..B` preamble wording.
4. **`eval.sh` ③** — verified by `bash -n` + green suite + grep confirming the 4-arg `is_api_change` call (the gh/Claude path is not exercised, per convention).
5. **`set -euo pipefail` sweep ⑤** — each of the 13 files is run individually after adding strict mode and must pass; `bash test.sh` stays fully green.

### 14.5 Out of scope (Phase 7)

auto-merge / PR-merge orchestration (cross-repo dependency-ordered PR merging — its own design: merge strategy, CI/conflict gating, ordering, dry-run, safety); §11.6.2 (`validate_repo_name` for a future `branch pr` repo-subset — no CLI path exists yet).

**Phase 6 final-review follow-ups (deferred to Phase 7):**
1. **`integration-test.sh:125` `is_api_change` call** is still 2-arg back-compat (pre-existing; not touched in Phase 6). For full consistency, pass `range "${default_branch}...HEAD"` explicitly; the back-compat default in `is_api_change` could then be retired.
2. **Concerns-only negative test:** add a fixture where only `app/controllers/concerns/*.rb` changed and assert the controller rule does NOT raise `high` (locks the `grep -qvE concerns/` exclusion). The Phase 6 positive case is covered; the negative case is not.

## 15. Phase 7 — Cross-repo PR merge orchestration

**Status:** Approved (design) — 2026-06-01. Implementation scope for the next plan. Adds `mra branch merge`: merge the open PRs for each repo's feature branch, in dependency order, gated on mergeability + CI.

### 15.1 Command surface

| Command | Behavior |
|---|---|
| `mra branch merge [--strategy merge\|squash\|rebase] [--dry-run]` | Collect feature-branch repos → `order_repos_by_deps` (deps first) → `merge_repo` each. Default strategy `merge`. `--dry-run` previews. |

- Default merge strategy is `merge` (a merge commit); `--strategy squash`/`rebase` override. Invalid `--strategy` → error + exit 1.
- Requires `gh` (auth preflight at dispatch, like `branch pr`).

### 15.2 Gating (per PR, before merging)

Queried live from GitHub via `gh` (no local fetch):
- **PR existence/state:** `gh pr view "$branch" --json number,state,mergeable`. No PR, or state ≠ `OPEN` → skip + info (not a failure).
- **Mergeable (no conflicts):** the `mergeable` field must be `MERGEABLE`.
- **CI green:** `gh pr checks "$branch"` exit 0 (non-zero = a check failed OR is pending — both block).
- Approval is NOT required (individual/small-team repos often have no reviewer).

### 15.3 Stop-on-first-failure

Because merges run in dependency order (upstream before consumers), a repo whose PR **exists but cannot merge** (conflict / CI not green / pending) or whose `gh pr merge` **fails** → `log_error` and the whole batch STOPS (`merge_workspace` returns non-zero; the dispatch exits non-zero). This prevents merging a consumer before its upstream has landed. Skips (no PR / non-OPEN / on default branch / detached) are not failures and the loop continues.

### 15.4 Data flow

```
merge_workspace(workspace, strategy, dry_run):
  graph_file = get_dep_graph_path(workspace)
  candidates = feature-branch repos (branch != default, != "(detached)")
  empty → info, return 0
  ordered = order_repos_by_deps(graph_file, candidates...)
  for repo in ordered:
    merge_repo("$workspace/$repo", strategy, dry_run) || return 1   # stop-on-first-failure
  return 0

merge_repo(repo_dir, strategy, dry_run):
  should_skip_dir → return 0
  branch = symbolic-ref --short -q HEAD  ((detached) → return 0)
  branch == get_default_branch → return 0 (skip)
  pr_json = gh pr view "$branch" --json number,state,mergeable  (fail/empty → "no open PR", return 0)
  state ≠ OPEN → "PR not open", return 0
  mergeable ≠ MERGEABLE → log_error "not mergeable", return 1
  ! gh pr checks "$branch" → log_error "CI not green", return 1
  dry_run → log_info "would merge PR #N ($strategy)", return 0
  gh pr merge "$branch" --$strategy → log_success "merged PR #N", return 0  (else log_error, return 1)
```

### 15.5 Architecture / module responsibilities

- **`lib/pr-ops.sh` (extended)** — add `merge_repo()` and `merge_workspace()` (siblings of `pr_repo`/`pr_workspace`); reuse `order_repos_by_deps`, `get_default_branch`, `should_skip_dir`.
- **`bin/mra.sh`** — `branch)` dispatch gains a `merge` subcommand (`--strategy`/`--dry-run`), with a `check_gh_auth` preflight; usage updated.

### 15.6 Error handling

- `gh` auth preflight; unauth → log_error + exit 1.
- Invalid `--strategy` → log_error + exit 1.
- Gating block / merge failure → log_error + non-zero (stop-on-first-failure).
- Skips (no PR / non-OPEN / default branch / detached) → info, continue.
- `--dry-run` performs only read-only `gh pr view`/`gh pr checks` — never `gh pr merge`. No local repo writes in any path (merges happen on GitHub).

### 15.7 Testing

Reuses `tests/test_pr_ops.sh`. `gh pr view`/`gh pr checks`/`gh pr merge` are NOT executed in tests (no GitHub PR available) — coverage targets the skip paths, the collect+order logic (via a stubbed `merge_repo`), and `--strategy` validation. Stated here so coverage is not mistaken for end-to-end `gh` testing.

1. **`merge_repo` skip paths** — a default-branch repo → skip (returns before any `gh`); a feature-branch repo in a local fixture with no GitHub PR → `gh pr view` fails → "no open PR" skip + return 0 + no merge; dry-run on the same → still the no-PR skip.
2. **`merge_workspace` collect+order** — multi-repo fixture: only feature-branch repos are collected; `merge_repo` is invoked in `order_repos_by_deps` order (verify with a `merge_repo` stub recording call order, like the Phase 2 `sync_review` `review_project` stub).
3. **`--strategy` validation** — subprocess `branch merge --strategy bogus` → non-zero exit + message (when `gh` is authenticated; the validation gate fires before any merge).
4. **Regression** — `order_repos_by_deps`, `pr_repo`, `pr_workspace` tests unchanged.

### 15.8 Out of scope

Auto-resolving conflicts; waiting/polling for pending CI (a blocked/pending PR stops the batch — rerun `branch merge` later); auto-deleting merged branches; merge-queue integration. §11.6.2 and the §14.5 follow-ups remain backlog.

**Phase 7 final-review follow-ups (deferred):**
1. **Skip-path log levels in `merge_repo`** use `log_info` for detached-HEAD / on-default-branch, whereas `pr_repo` uses `log_warn`. Cosmetic; align or document the divergence (merge skips are expected states, so `log_info` is defensible).
2. **`--delete-branch` option** — `gh pr merge --delete-branch` is a common workflow; a future `mra branch merge --delete-branch` could pass it through.
3. **Malformed-JSON message:** if `gh pr view` ever returns non-empty invalid JSON, `merge_repo` reports "PR not open () — skipping" (safe, but the empty state in the message is slightly misleading). Not a real risk (gh returns valid JSON or non-zero).

## 16. Phase 8 — Final polish

**Status:** Approved (design) — 2026-06-01. Implementation scope for the next plan. Four small follow-ups; no new subsystem. Closes the actionable backlog.

### 16.1 Items & exact behavior

**① `branch merge --delete-branch`** (`bin/mra.sh` + `lib/pr-ops.sh`; retires §15.8.2)
- Opt-in flag (default: do NOT delete). The `merge)` dispatch parses `--delete-branch` and threads it through `merge_workspace` → `merge_repo`.
- `merge_repo` gains a 4th param `delete_branch` (default `false`); on the real merge it runs `gh pr merge "$branch" --"$strategy"` plus `--delete-branch` when set. Dry-run preview appends "(+delete-branch)" when set.

**② `integration-test.sh` `is_api_change` consistency** (`lib/integration-test.sh`; retires §14.5.1)
- `is_api_change "$project_dir" "$project_type"` → `is_api_change "$project_dir" "$project_type" range "$(get_default_branch "$project_dir")...HEAD"` (explicit mode/range like `review.sh`/`eval.sh`; behavior-equivalent). The 2-arg back-compat default in `is_api_change` is KEPT (still covered by `test_change_detector.sh`, a safety net).

**③ Concerns-only negative test** (`tests/test_change_detector.sh`, test-only; retires §14.5.2)
- Fixture where a range changes ONLY `app/controllers/concerns/*.rb` (no routes/serializer/schema) → assert the result is NOT `high` (locks the `grep -qvE concerns/` exclusion; the Phase 6 positive case is already covered).

**④ `merge_repo` skip log-level alignment** (`lib/pr-ops.sh`; retires §15.8.1)
- The detached-HEAD and on-default-branch skips in `merge_repo` switch from `log_info` to `log_warn`, matching `pr_repo`'s convention. (The no-PR / non-OPEN skips remain `log_info`.)

### 16.2 Architecture / module responsibilities

- **`lib/pr-ops.sh`** — `merge_repo` gains `delete_branch` param + uses it in `gh pr merge`; `merge_workspace` threads it; the two skip logs become `log_warn`.
- **`bin/mra.sh`** — `branch merge` dispatch parses `--delete-branch` and passes it to `merge_workspace`; usage updated.
- **`lib/integration-test.sh`** — explicit `is_api_change` mode/range.
- **`tests/`** — `--delete-branch` dry-run preview test; concerns-only negative test.

### 16.3 Error handling

- `--delete-branch` is purely additive to the `gh pr merge` invocation; all existing gating/skip/stop semantics are unchanged.
- No behavior change to `is_api_change` (explicit call equals the prior back-compat default); no behavior change from the log-level swap (message text unchanged).

### 16.4 Testing

1. **`tests/test_pr_ops.sh`** — `merge_repo` dry-run with `delete_branch=true` on a no-PR fixture still hits the no-PR skip (gh layer untested per convention); the dispatch passes `--delete-branch` through (subprocess reaches the no-PR skip / gh-auth path). The existing skip-path/order/strategy tests stay green; merge_repo skip messages still contain "detached"/"default branch" after the log-level change.
2. **`tests/test_change_detector.sh`** — concerns-only range → NOT `high`.
3. **Regression** — `bash test.sh` fully green; `is_api_change` 2-arg back-compat test unchanged.

### 16.5 Out of scope / closed

At Phase 8 closure the actionable backlog from Phases 0–7 was cleared, with §11.6.2 (no `branch pr` repo-subset CLI path) and §15.8.3 marked won't-fix. §11.6.2 is **now reopened as Phase 9** (§17, designed 2026-06-05). §15.8.3 (malformed-JSON message — not a real risk; `gh` returns valid JSON or non-zero) remains **won't fix / N/A**.

## 17. Phase 9 — `branch pr`/`branch merge` repo subset

**Status:** Implemented — 2026-06-05. `branch pr`/`branch merge` accept `[repos…]`; `validate_repo_subset` + `warn_excluded_feature_deps` in `lib/pr-ops.sh`. Reactivated §11.6.2.

### 17.1 Goal & command surface

Let `branch pr` and `branch merge` accept an optional trailing `[repos...]` list that restricts the operation to that subset, mirroring `branch new <name> [repos...]`. **No subset args = current behavior** (operate on every feature-branch repo in the workspace).

```
mra branch pr    [--base <ref>] [--dry-run] [repos...]
mra branch merge [--strategy merge|squash|rebase] [--dry-run] [--delete-branch] [repos...]
```

- Flag and positional tokens may interleave; after flag parsing, every remaining non-flag token is a repo name.
- The existing `validate_repo_name` rejects `-*` / `.` / `..` / `*/*`, so a mistyped flag landing in the repo list is caught as an invalid name rather than silently treated as a repo.

### 17.2 Exact behavior

**Dispatch ordering.** To keep subset validation cheap and side-effect-free, the `branch pr` / `branch merge` dispatch reorders its preflight so that subset validation runs **before** the `gh auth` check (which today runs first — `bin/mra.sh:663`, mirroring §10.5 / §15.6). The new order is:

> parse args → `resolve_workspace` → **validate subset** (only if `[repos…]` given) → `check_gh_auth` → `pr_workspace` / `merge_workspace`

A bad repo name therefore aborts before the gh-auth preflight and before any `gh` API call — the user gets the "invalid repo name" / "not a git repo" error without needing gh set up. The dispatch now always runs `resolve_workspace` before `check_gh_auth` (both are read-only preflights — Phase 2 / Phase 7 ran `check_gh_auth` first; swapping two side-effect-free checks is observationally identical). When no subset is given, `validate_repo_subset` is skipped and the **full-workspace scan behavior is unchanged** from Phase 2 / Phase 7.

**Subset validation (fail fast).** When a subset is given, the WHOLE list is validated before `check_gh_auth` and before any `pr_repo`/`merge_repo` call:
1. Each name passes `validate_repo_name` (else `log_error` "invalid repo name").
2. Each named repo must resolve to a non-skipped git repo in the workspace (`should_skip_dir` false; else `log_error` "not a git repo").
3. If any name fails (1) or (2), abort the whole command (return non-zero) — **no gh-auth check, no PR opened, no merge performed.** All bad names are reported, not just the first.

**Candidate selection within the subset.** Of the validated named repos, those NOT on a feature branch (on the default branch, or detached) are skipped with `log_info` ("nothing to PR" / "nothing to merge"); the rest are candidates. (Feature-branch detection stays per-command: `pr` compares against `base_ref` = `--base` override or default; `merge` compares against the repo default.)

**Dependency handling (warn, don't block).** Candidates are ordered with `order_repos_by_deps` **within the subset only**. Additionally, if a subset repo depends (per the dep graph) on a repo that is itself on a feature branch but excluded from the subset, emit `log_warn` (order/wholeness risk) and continue — the explicit subset is respected.

**No subset = unchanged.** When no repo args are given, both functions run their existing full-workspace scan verbatim.

### 17.3 Architecture / module responsibilities

- **`lib/pr-ops.sh`**
  - `pr_workspace` / `merge_workspace` gain an optional trailing repo-list parameter. When non-empty, they iterate the named subset (immutably building a new candidate array) instead of scanning all dirs; when empty, the current scan path is unchanged.
  - New shared helper `validate_repo_subset workspace repos...` — validates names + existence per §17.2, reports all failures, returns non-zero if any. Reuses `validate_repo_name` from `lib/branch-ops.sh`. Called by the dispatch (not by `pr_workspace`/`merge_workspace`) so it runs before `check_gh_auth`; the two workspace functions may trust the names are already valid and only do candidate selection + the dep warning.
  - New shared helper `warn_excluded_feature_deps graph_file subset... -- feature_repos...` (or equivalent signature) — emits the excluded-dependency warning. Pure logging; no control-flow effect.
- **`bin/mra.sh`** — the `pr)` and `merge)` sub-dispatches under `branch)` collect non-flag positionals into a `repos` array, then follow the §17.2 dispatch ordering: `resolve_workspace` → (if `repos` non-empty) `validate_repo_subset` (abort on failure) → `check_gh_auth` → `pr_workspace`/`merge_workspace "$@" "${repos[@]}"`. The existing `check_gh_auth` call moves to **after** subset validation. Usage strings updated to show `[repos...]`.
- No change to `pr_repo` / `merge_repo` (single-repo workers) — the subset is resolved entirely above them.

### 17.4 Error handling

- Subset validation is fail-fast and side-effect-free: a bad name aborts before the `gh auth` preflight and any `gh` API call (see the §17.2 dispatch ordering — `check_gh_auth` moves after subset validation).
- All existing gating, skip, stop-on-first-failure, dry-run, and `--delete-branch` semantics are unchanged — the subset only narrows which repos enter the existing pipeline.
- Excluded-dependency detection is advisory (`log_warn`) and never changes exit status on its own.

### 17.5 Testing (extend `tests/test_pr_ops.sh`, existing PASS/FAIL harness)

1. Subset of 2 of 3 feature-branch repos → only the named 2 are acted on (dry-run; assert output names).
2. Named repo that does not exist → `log_error`, non-zero exit, and **no** `pr_repo`/`merge_repo` invoked (assert absence in dry-run output).
3. Named repo on the default branch → skipped with info; other named repos still proceed.
4. Subset repo depends on an excluded feature-branch repo → warning emitted; command still proceeds.
5. Invalid repo names (`-x`, `a/b`) → rejected as invalid name.
6. Dependency ordering within the subset is respected (assert order in dry-run output).
7. **Dispatch ordering:** a bad subset name aborts the `validate_repo_subset` path; assert the error is the invalid-name/not-a-git-repo message (not a gh-auth error), confirming validation runs before `check_gh_auth`.
8. **Regression:** no-arg `branch pr`/`branch merge` behavior unchanged; `bash test.sh` fully green.

### 17.6 Out of scope (Phase 9)

- No subset for `mra sync` or `mra review` (separate surfaces).
- No auto-inclusion of excluded dependencies (decided: warn only).
- No CI-polling auto-merge (now designed as Phase 10, §18).

## 18. Phase 10 — CI-polling auto-merge

**Status:** Implemented — 2026-06-05. `branch merge --wait-ci [--ci-timeout <sec>]` polls CI via `wait_for_pr_checks` in `lib/ci.sh` (exit-code driven); `ci_wait_timeout` threaded through `merge_workspace`/`merge_repo`.

### 18.1 Goal & command surface

Add an opt-in `--wait-ci` flag to `mra branch merge` that polls each PR's CI checks until they finish (instead of the current immediate stop when CI is not yet green), then merges. `--ci-timeout` is configurable; the poll interval is a fixed constant.

```
mra branch merge [--strategy S] [--dry-run] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [repos...]
```

- `--wait-ci` — enable polling. Default OFF: without it, `branch merge` keeps the current behaviour (one-shot `gh pr checks`, stop if not green). Fully backward-compatible.
- `--ci-timeout <sec>` — max seconds to wait per PR. Default **1800** (30 min). Must be a positive integer. **If `--ci-timeout` is given without `--wait-ci`, error** (clearer than silently ignoring).
- Poll interval — fixed constant `CI_POLL_INTERVAL` (default 30s) in `lib/ci.sh`. Not user-configurable (YAGNI).
- `branch pr` is unchanged (it opens PRs, it does not merge or gate on CI).

### 18.2 Exact behavior

The current `merge_repo` CI gate (`lib/pr-ops.sh` §15.2: one-shot `gh pr checks "$branch"` → if not green, `log_error … stopping; return 1`) is conditionally replaced by a poll.

**When polling is enabled and not dry-run**, the CI gate calls `wait_for_pr_checks "$repo_dir" "$branch" "$ci_timeout"`, which drives off `gh pr checks`'s **documented exit codes** rather than parsing state buckets (robust, no JSON brittleness):
- `gh pr checks "$branch"` exit `0` → all checks passed → **green** → proceed to merge.
- exit `8` → **checks pending** (`gh`'s documented "pending" code) → sleep `CI_POLL_INTERVAL`, then re-poll, until the elapsed time reaches the timeout.
- any **other** non-zero exit (e.g. `1`) → **not green** → **fail-fast**: stop immediately (`return 1`), do not wait the full timeout. This bucket includes both a failed check **and the "no checks reported on the branch" case** (`gh` exits non-zero, not 8, when a PR has no checks). Treating no-checks as a stop is **identical to today's one-shot gate** (`if ! gh pr checks; then … "CI not green — stopping"`, §15.2) — Phase 10 introduces no behaviour change for the no-checks case.
- Elapsed ≥ timeout while still pending (exit `8`) → **timed out** → treat as failure: `log_error "$repo: CI did not finish within <sec>s — stopping"` → `return 1` (the batch then halts via stop-on-first-failure, §15.3).

(Exit code 8 = "Checks pending" is confirmed from `gh pr checks --help`. Relying on exit codes means a transient pending state never trips the failure path — the exact case Phase 10 exists to wait through. `gh pr checks` exits 0 only when checks exist and all passed; no-checks and failures are both non-8 non-zero, so both stop, matching §15.2.)

`wait_for_pr_checks` returns `0` (green), `1` (failed), or `2` (timed out); `merge_repo` maps `1`/`2` to a stop (`return 1`) with distinct messages.

**When polling is disabled** (`ci_wait_timeout` empty): `merge_repo` runs the existing one-shot `gh pr checks` gate verbatim — no behaviour change.

**Dry-run + `--wait-ci`:** do NOT poll (avoid blocking up to 30 min just to preview). Preview only: `"$repo: would wait for CI (timeout <sec>s) then merge PR #<n> (<strategy>)"`. The merge itself is still previewed, not executed.

### 18.3 Architecture / module responsibilities

**Signature note (why one new param, not two).** `merge_repo` is `(repo_dir, strategy, dry_run, delete_branch)` and `merge_workspace` is `(workspace, strategy, dry_run, delete_branch, [subset…])` with the subset at `${@:5}` (Phase 9). Adding both `wait_ci` (bool) and `ci_timeout` (int) as separate positionals would bloat the signature, push the subset to `${@:7}`, and is exactly the kind of positional fragility that caused a Phase 9 bug. Instead the two concepts collapse into a **single param `ci_wait_timeout`**: empty string = do not poll (default, current behaviour); a positive integer = poll with that timeout. One new positional.

- **`lib/ci.sh`** — new `wait_for_pr_checks repo_dir branch timeout_sec [interval_sec]` → returns `0` green / `1` failed / `2` timed-out. Pure poll loop that inspects the **exit code** of `gh pr checks "$branch"` (`0`=green, `8`=pending→keep polling, other non-zero=failed); `interval_sec` defaults to the `CI_POLL_INTERVAL` constant (tests pass a small value); elapsed time tracked with the bash `SECONDS` builtin. This is the first runtime (non-generator) function in `ci.sh`.
- **`lib/pr-ops.sh`**
  - `merge_repo` gains a 5th param `ci_wait_timeout` (default `""`). The CI gate branches: non-empty + not dry-run → call `wait_for_pr_checks` and map its result; empty → existing one-shot check. The dry-run preview string includes the "would wait for CI (timeout Xs) then" clause when `ci_wait_timeout` is non-empty.
  - `merge_workspace` signature becomes `(workspace, strategy, dry_run, delete_branch, ci_wait_timeout, [subset…])` — subset moves to `${@:6}`; it threads `ci_wait_timeout` into each `merge_repo` call.
  - **Knock-on:** Phase 9 tests that call `merge_workspace` directly insert an empty `""` for `ci_wait_timeout` before the subset (`merge true false a` → `merge true false "" a`).
- **`bin/mra.sh`** — the `merge)` dispatch parses `--wait-ci` (a boolean `wait_ci`) and `--ci-timeout <sec>` (a `ci_timeout` value, validated as a positive integer) in the existing interleave-tolerant arg loop (Phase 9 allows flags and positionals in any order). Validation happens **after** the loop, off the captured state — NOT by requiring `--wait-ci` to appear first — so `--ci-timeout 60 --wait-ci` and `--wait-ci --ci-timeout 60` are both valid. Post-parse: if `ci_timeout` was set but `wait_ci` is false → error; otherwise `ci_wait_timeout` = (`wait_ci` ? (`ci_timeout` or default 1800) : `""`). Threads `ci_wait_timeout` into `merge_workspace`. The `pr)` block is untouched. Usage line updated.
- No change to `pr_repo`, `pr_workspace`, `validate_repo_subset`, `warn_excluded_feature_deps`, or `merge_repo`'s mergeable check.

### 18.4 Error handling

- `--ci-timeout` without `--wait-ci` → `log_error` + exit non-zero. Checked **after** arg parsing (off `wait_ci`/`ci_timeout` state), so flag order is irrelevant — `--ci-timeout 60 --wait-ci` is accepted.
- `--ci-timeout` non-integer / ≤ 0 → `log_error` + exit non-zero (validated where the value is parsed).
- Both validations run before `resolve_workspace`/subset/gh-auth — before any side effect.
- A failed or timed-out poll maps to the existing stop-on-first-failure path — no new control-flow surface.
- `wait_for_pr_checks` is read-only (only `gh pr checks`, `sleep`); it never writes or merges.
- All existing gating (mergeable), skip, dry-run, `--delete-branch`, and subset semantics are unchanged when `--wait-ci` is absent.

### 18.5 Testing

**`tests/test_ci.sh` (new suite) — `wait_for_pr_checks`** (stub a `gh` function returning scripted **exit codes** across calls; small interval):
1. `gh` exits `0` on first poll → returns `0` (green).
2. `gh` exits `8`, `8`, then `0` across polls → returns `0` (proves it keeps polling through pending; the pending stub MUST return exit code 8, gh's documented pending code).
3. `gh` exits `1` (a non-8 non-zero) → returns `1` immediately (fail-fast; does not wait out the timeout — assert it returns well under the timeout).
4. `gh` always exits `8` with a tiny timeout → returns `2` (timed out).
5. `gh` exits non-zero-non-8 (e.g. `1`) simulating "no checks reported" → returns `1` (treated as not-green / stop, matching today's one-shot gate — no-checks is NOT silently green).

**`tests/test_pr_ops.sh` — merge_repo / merge_workspace** (these must reach the CI gate, so stub `gh pr view` to report an OPEN + MERGEABLE PR; otherwise `merge_repo` returns at the earlier "no open PR" skip and never exercises the gate):
6. **Backward-compat:** `ci_wait_timeout=""` with an OPEN+MERGEABLE stubbed PR → `merge_repo` invokes the one-shot `gh pr checks` gate (assert via a `gh` stub that records the `checks` subcommand was called) and `wait_for_pr_checks` is NOT called.
7. **Poll path:** non-empty `ci_wait_timeout` (not dry-run) with the same stubbed PR → `wait_for_pr_checks` IS called (stub it to record invocation + return 0) and the one-shot `gh pr checks` gate is bypassed.
8. **Dry-run:** dry-run + non-empty `ci_wait_timeout` → preview contains "would wait for CI (timeout Xs)"; a stubbed `wait_for_pr_checks` confirms it is NOT called in dry-run.
9. **Signature:** Phase 9 subset tests updated with the `""` slot still select the right repos; a stubbed `merge_repo` confirms `ci_wait_timeout` is threaded through `merge_workspace`.

**`tests/test_pr_ops.sh` — dispatch:**
10. `branch merge --ci-timeout 60` (no `--wait-ci`) → error, non-zero exit.
11. `branch merge --ci-timeout 60 --wait-ci` (timeout BEFORE wait-ci) → accepted (no error), proving order-independent post-parse validation.
12. `branch merge --ci-timeout abc --wait-ci` → error (non-integer), non-zero exit.
13. `branch merge --wait-ci somerepo` (stub env) → subset validation still runs before gh-auth (reuses the Phase 9 ordering proof).

**Regression:** `bash test.sh` fully green (suite count +1 for `test_ci.sh`).

### 18.6 Out of scope (Phase 10)

- No `--wait-ci` on `branch pr` (pr does not merge).
- No user-configurable poll interval (fixed constant).
- No automatic CI re-run / retry on failure.
- No change to the mergeable check (stays one-shot; only the CI gate polls).

## 19. Phase 11 — `branch status --json`

**Status:** Implemented — 2026-06-05. `branch status --json` emits an all-repos JSON array via the new pure `branch_state_json` in `lib/branch.sh`; JSON-mode stdout stays JSON-only (fetch errors → stderr).

### 19.1 Goal & command surface

Add an opt-in `--json` flag to `mra branch status` that emits a machine-readable JSON array of every repo's branch state, for CI / external-tool consumption.

```
mra branch status [--all] [--fetch] [--json]
```

- `--json` emits **all repos** (it ignores the needs-attention filter — machine consumers want the full dataset and filter themselves). `--all` is therefore redundant under `--json` (allowed, no error).
- `--fetch` still works with `--json` (fetch fresh, then emit).
- Without `--json`, the existing text table is unchanged (zero behaviour change).

### 19.2 Output shape

A JSON array; one object per repo, in workspace directory order:

```json
[
  {"repo":"app","branch":"feat/x","upstream":"origin/feat/x",
   "ahead":2,"behind":0,"dirty":1,"sync_action":"ahead-only",
   "on_default":false,"needs_attention":true}
]
```

- `repo`, `branch`, `upstream`, `sync_action` — strings.
- `ahead`, `behind`, `dirty` — JSON numbers.
- `on_default`, `needs_attention` — JSON booleans.
- `needs_attention` mirrors `branch_row_needs_attention` so a consumer can reproduce the text-mode filter.
- Empty / no-repo workspace → `[]`.

### 19.3 stdout discipline

`_log` (and therefore `log_*`) writes to **stdout** (`lib/colors.sh`), so in `--json` mode the dispatch must keep stdout JSON-only:

- Do NOT print the table header or the "all repos clean and up to date" success line.
- `--fetch` failures (the only diagnostic that occurs *mid-emit*, per repo) are reported via `log_error … >&2` (stderr) and still cause a non-zero exit at the end, exactly as the text path does — but they never touch the JSON on stdout.
- **Scope of the guarantee + consumer contract.** There are three outcomes a JSON consumer can see:
  - **exit 0** — stdout contains *only* the complete JSON array; nothing on stderr.
  - **non-zero, mid-emit (per-repo `--fetch` failure)** — stdout *still* contains a JSON array (the states read, post-fetch-attempt); the fetch-failure message is on **stderr**. The non-zero exit is a warning that some counts may be stale, NOT an "ignore stdout" signal.
  - **non-zero, pre-emit fatal** — an unknown option in the `status` parser or `resolve_workspace` failing aborts *before* any JSON; these keep their existing `log_error` behaviour (currently stdout) and produce **no** JSON array.
  - **Robust consumer rule:** parse stdout as JSON — if it parses, use it (regardless of exit code), and treat a non-zero exit as "check stderr for fetch warnings"; if stdout does not parse, it was a pre-emit fatal error (read the message, which the non-zero exit confirms). Redirecting pre-emit diagnostics to stderr is out of scope (it would touch shared/unrelated dispatch paths) — §19.6 test 8 only locks the mid-emit fetch-failure case.

### 19.4 Architecture / module responsibilities

- **`lib/branch.sh`** — new pure function `branch_state_json state_block on_default needs_attention` that builds one JSON object with `jq -n`, using `--arg` for strings and `--argjson` for the numeric/boolean fields (the `jq --arg` injection discipline keeps branch names with quotes/spaces safe). It is the JSON sibling of `branch_format_row`, reading the same `get_branch_state` block. No change to `get_branch_state`, `branch_format_row`, `branch_row_needs_attention`, or `branch_sync_action`.
- **`bin/mra.sh`** — the `branch status` dispatch parses `--json`. In JSON mode it iterates all repos (no attention filter), computes `state`/`on_default`/`needs_attention` per repo, calls `branch_state_json`, collects the objects, and emits a single array via `jq -s '.'`; fetch errors go to stderr; no header/clean line. In text mode it runs the existing path verbatim. Usage line updated to show `[--json]`.

### 19.5 Error handling

- `--fetch` failure in `--json` mode → `log_error … >&2`, JSON still emitted for the repos read, non-zero exit at the end (consistent with text mode).
- `branch_state_json` relies on `get_branch_state` always emitting numeric `ahead`/`behind`/`dirty` (it defaults them to 0), so `--argjson` never receives a non-number.
- `--json` combined with `--all` is accepted (all-repos is already implied); no error.

### 19.6 Testing

**`tests/test_branch.sh` (existing suite) — `branch_state_json`:**

1. A state block + `on_default=false` + `needs_attention=true` → output parses (`jq -e`), string fields correct, `ahead`/`behind`/`dirty` are JSON numbers (`jq '.ahead|type=="number"'`), `on_default`/`needs_attention` are JSON booleans.
2. A branch name with special characters (a quote or a space) → still valid JSON (jq injection-safe).

**`tests/test_branch.sh` — `branch status --json` dispatch (real CLI via `MRA_WORKSPACE`):**

3. Multi-repo workspace (mix of default-branch and feature-branch repos) → `--json` output is a JSON array (`jq -e 'type=="array"'`) whose length equals the total repo count (including `needs_attention:false` repos).
4. `needs_attention` is correct per repo (clean default-branch repo → false; an ahead/dirty repo → true).
5. stdout is clean: the entire `--json` output parses with `jq .` (no header/log contamination).
6. Empty workspace → `[]`.
7. Text mode (no `--json`) regression — output unchanged.
8. **Failure-path stdout discipline (the risky case):** a repo whose `origin` points at a non-existent path (so `git fetch` fails) run with `--fetch --json` → assert (a) non-zero exit, (b) stdout still parses as a JSON array (`jq -e 'type=="array"'`), (c) the fetch-failure message appears on **stderr** (capture stdout/stderr separately), (d) stdout contains no `[branch]` log tag. This locks the mid-emit fetch-failure redirection that §19.3 requires.

**Regression:** `bash test.sh` fully green (no new suite — tests live in the existing `tests/test_branch.sh`).

### 19.7 Out of scope (Phase 11)

- No `--json` on other commands (only `branch status`).
- No field selection / jq-expression flag.
- No change to the text-mode output format.

## 20. Phase 12 — `sync --json` (default / --safe / --push)

**Status:** Implemented — 2026-06-05. `sync --json` (default/`--safe`/`--push`) emits a per-repo `{repo, action, ok}` array via `sync_result_json` + the `SYNC_RESULT_FILE` sink in `lib/sync.sh`; JSON-mode stdout stays JSON-only (worker logs → stderr). `--review --json` rejected.

### 20.1 Goal & command surface

Add an opt-in `--json` to `mra sync` for its three sync-outcome modes (default, `--safe`, `--push`), emitting a per-repo `{repo, action, ok}` JSON array for CI / external-tool consumption.

```
mra sync [--safe|--push] [--dry-run] [--json]
```

- `--json` composes with the default mode, `--safe`, or `--push` (orthogonal to the existing mutually-exclusive mode flags).
- `mra sync --review --json` → **error, non-zero exit, no JSON** (review output is freeform LLM prose with no clean JSON contract — the same reason `review --json` was declined).
- Existing rules unchanged: the three mode flags stay mutually exclusive; `--dry-run` applies only to `--push`.

### 20.2 Shared per-repo result model

Every repo that the run acts on yields one record `{repo, action, ok}`:

- `action` — a normalized lowercase-hyphen string (per-mode vocabulary in §20.3).
- `ok` — JSON boolean: `false` for the `*-failed` actions; `true` otherwise (including safe skips, which the workers already treat as non-errors by returning 0).
- Repos that `should_skip_dir` rejects (not a git repo) are **not recorded** — consistent with text mode, where they never appear.

A new pure `sync_result_json repo action ok` (`lib/sync.sh`) builds one JSON object with `jq -n` (`--arg` for `repo`/`action`, `--argjson` for `ok`), injection-safe — the sibling of Phase 11's `branch_state_json`.

### 20.3 Per-mode action vocabulary

**default (`sync_repo` — clone/pull):**

| Situation | action | ok |
|---|---|---|
| repo dir missing → clone succeeds | `cloned` | true |
| clone fails | `clone-failed` | false |
| on a feature branch (not default) → skip | `skipped-branch` | true |
| on default branch, fetch+pull succeeds | `pulled` | true |
| pull fails | `sync-failed` | false |

**`--safe` (`safe_sync_repo` — ff-only pull):**

| Situation | action | ok |
|---|---|---|
| fetch fails | `fetch-failed` | false |
| fast-forward pull succeeds | `pulled` | true |
| ff-only pull fails | `ff-failed` | false |
| up-to-date / ahead-only | `up-to-date` / `ahead-only` | true |
| diverged / dirty-skip / no-upstream / unknown | `diverged` / `dirty-skip` / `no-upstream` / `unknown` | true (safe skip) |

**`--push` (`push_repo` — push; `--dry-run` uses the `would-` forms):**

| Situation | action | ok |
|---|---|---|
| push-new succeeds / dry-run | `pushed-new` / `would-push-new` | true |
| push succeeds / dry-run | `pushed` / `would-push` | true |
| push-new fails / push fails | `push-new-failed` / `push-failed` | false |
| up-to-date | `up-to-date` | true |
| skip-detached / skip-diverged / skip-behind / unknown | same name | true (safe skip) |

### 20.4 Mechanism — JSON without disturbing text mode

The per-repo workers today call `log_*` (stdout) and return a code. **Text mode stays byte-identical** (the existing `tests/test_sync*.sh` human-message assertions must keep passing). The JSON path is added via a file sink:

- A new `_sync_record repo action ok` (`lib/sync.sh`) appends `repo<TAB>action<TAB>ok` to the file named by the env var `SYNC_RESULT_FILE` — **only when that var is set**. Unset (the normal/text path) → no-op, zero behaviour change. A file (not a shell variable) is used so records survive the `$(...)`/subshell boundaries the workers run under.
- Each worker (`sync_repo`, `safe_sync_repo`, `push_repo`) normalizes its outcome into an `action` (+ `ok`) and calls `_sync_record` at each result point, in addition to its existing human `log_*` line.
- **JSON dispatch:** `sync --json` creates a temp `SYNC_RESULT_FILE`, runs the chosen workspace function with its **stdout redirected to stderr** (`… 1>&2`, so the human `log_*` lines land on stderr and never pollute the JSON), then reads the result file and emits a single array via `sync_result_json` per line. Empty → `[]`. If any record has `ok=false`, exit non-zero.

### 20.5 Architecture / module responsibilities

- **`lib/sync.sh`** — add `sync_result_json` (pure jq object) and `_sync_record` (the `SYNC_RESULT_FILE` sink). Normalize `sync_repo` / `safe_sync_repo` / `push_repo` to compute an `action`/`ok` at each outcome and call `_sync_record` (human `log_*` lines preserved). No change to the workspace drivers' text behaviour.
- **`lib/repos.sh`** — `sync_from_repos_json` (default driver) is unchanged; recording happens in `sync_repo` at the worker layer.
- **`bin/mra.sh`** — the `sync` dispatch parses `--json`. `--review --json` → error. In JSON mode it sets up `SYNC_RESULT_FILE`, invokes the selected workspace function with stdout→stderr, reads the file, emits the array (or `[]`), and exits non-zero if any `ok=false`. Usage line updated. The `--review`, `branch_*`, and Phase 11 `branch_state_json` paths are untouched.

### 20.6 Error handling & consumer contract

- `--review --json` → `log_error` + non-zero exit, no JSON (a pre-emit fatal error).
- A per-repo failure (`clone-failed`/`sync-failed`/`fetch-failed`/`ff-failed`/`push*-failed`) records `ok:false`, the JSON array is still emitted, and the run exits non-zero (mid-emit failure).
- Consumer contract. **stdout is JSON-only in every emit case** (this is the machine contract). Unlike Phase 11's `branch status --json` (which *suppresses* its header/clean line so a successful run has empty stderr), `sync --json` *redirects* the workers' per-repo `log_*` lines to **stderr** — so **stderr normally carries human progress/skip/error lines even on a fully successful (exit 0) run**. stderr is therefore NOT an error signal here; the exit code is. Three outcomes:
  - **exit 0** — stdout = complete JSON array (every `ok:true`); stderr may contain the per-repo human log lines (normal, not a failure).
  - **non-zero mid-emit** — stdout = JSON array still emitted (one or more records `ok:false`); stderr has the human logs including the failures.
  - **non-zero pre-emit** (`--review --json`, unknown flag, no workspace) — no JSON on stdout; the error is on stdout/stderr per existing `log_error` behaviour.
  - Robust consumers parse stdout first; if it parses, use it and rely on the exit code (not stderr presence) to decide success.
- `_sync_record` is additive and side-effect-free when `SYNC_RESULT_FILE` is unset, guaranteeing text-mode behaviour is unchanged.

### 20.7 Testing

**`tests/test_sync.sh` (existing) — `sync_result_json`:**

1. `sync_result_json app pulled true` → valid JSON (`jq -e`); `.repo=="app"`, `.action=="pulled"`, `.ok==true` with `(.ok|type)=="boolean"`.
2. A repo name with a double-quote → still valid JSON (injection-safe).
3. `sync_result_json x clone-failed false` → `.ok==false`.

**`tests/test_sync.sh` — `_sync_record` sink:**

4. `SYNC_RESULT_FILE` unset → `_sync_record` writes nothing, no side effect.
5. `SYNC_RESULT_FILE` set → appends one `repo<TAB>action<TAB>ok` line; multiple calls accumulate.

**`tests/test_sync.sh` — worker recording (call the worker directly with `SYNC_RESULT_FILE` set):**

6. `safe_sync_repo`: a default-branch up-to-date repo records `up-to-date true`; a fetch-failure fixture (bad origin) records `fetch-failed false`.
7. `push_repo` dry-run: a feature branch with a commit records a `would-push*` action; an up-to-date default branch records `up-to-date`.
8. `sync_repo`: a missing repo dir records `cloned` (local bare origin) or `clone-failed` (bad origin); a feature-branch repo records `skipped-branch`.

**`tests/test_sync_flags.sh` (existing) — `sync --json` dispatch (real CLI via `MRA_WORKSPACE`):**

9. `sync --json` (default mode) → stdout is a JSON array (`jq -e 'type=="array"'`), each object has repo/action/ok, length matches.
10. `sync --safe --json` → valid array; stdout clean (whole output parses with `jq .`, no `[sync]` log tag); human messages on stderr.
11. `sync --review --json` → error, non-zero exit, no JSON.
12. Empty workspace `sync --json` → `[]`.
13. Failure path: a repo whose `--safe` fetch fails (bad origin) → non-zero exit, stdout still a JSON array containing that repo with `ok:false`, logs on stderr.
14. `sync --push --dry-run --json` (real CLI; a feature-branch repo with a local commit) → stdout is a clean JSON array (`jq -e 'type=="array"'`, no `[sync]` tag), the repo's `action` is a `would-push*` (or `up-to-date`), and the human log line is on **stderr** (captured separately). This exercises the `--push` parser + `--dry-run` + JSON-wrapper combination end-to-end (the worker-level test alone misses dispatch wiring).
15. Text-mode regression: `sync --safe` (no `--json`) output and messages unchanged.

**Regression:** `bash test.sh` fully green (no new suite — tests live in the existing `tests/test_sync.sh` / `tests/test_sync_flags.sh`).

### 20.8 Out of scope (Phase 12)

- `--review --json` (freeform LLM output — no clean contract).
- No change to any text-mode message format.
- No field-selection / jq-expression flag.
- No `--json` for non-sync commands beyond Phase 11's `branch status`.

## 21. Phase 13 — `mra plan --dual` (claude + codex multi-model council)

**Status:** Implemented — 2026-06-08. `mra plan --dual` runs each persona on claude AND codex via the new `lib/model-provider.sh` (`call_model` + `ensure_codex_available`); `run_plan_council` tags blocks by provider, writes a missing-side sentinel on a failed/empty call, and synthesizes with an agree/disagree template. Non-dual path unchanged; codex side runs `codex exec -s read-only`.

### 21.1 Goal & command surface

`mra plan`'s council today runs N personas, each a `claude -p` call, then a `claude` synthesizer merges them (`lib/plan-council.sh`). Phase 13 adds an opt-in `--dual` that runs each persona on **both** claude and codex (dual-run), and has the synthesizer explicitly mark where the two models agree (high confidence) vs disagree (flagged for human decision).

```
mra plan <project> "<task>" [--model <claude-tier>] [--dual]
```

- `--dual` enables the two-model council. Default (no `--dual`) = the current claude-only council, **zero behaviour change**.
- `--model` continues to control **only** the claude tier (default `sonnet`). codex uses its own configured default model (no `--codex-model` in v1).
- **Preflight:** `--dual` with `codex` not available → error + non-zero exit, before the council convenes (pre-emit, like the gh-auth checks).

### 21.2 Safety (no working-tree mutation from planning)

- **claude side** keeps the existing `--disallowedTools Write,Edit,NotebookEdit` — the **direct file-edit tools are disabled**. This matches the current council exactly and is NOT changed. Note this is not a hard sandbox: Bash remains available to claude (status quo for `mra plan` today), so the guarantee here is "no direct edit-tool mutations", not a kernel-level read-only jail.
- **codex side** runs `codex exec -s read-only` — a genuine read-only sandbox where model-generated shell commands may only read (no writes/exec-mutations). Invoked with the project dir as cwd (`(cd "$project_dir" && codex exec -s read-only …)`) so codex sees the repo (the analogue of claude's `--add-dir`).
- The two sides therefore have asymmetric enforcement (claude: edit-tools-off; codex: read-only sandbox). Hardening the claude side to a full sandbox is out of scope — it would change the existing single-model council behaviour and break the "non-dual path byte-unchanged" guarantee.

### 21.3 Provider abstraction

New `lib/model-provider.sh`:

- `call_model <provider> <prompt> <model> <project_dir> <add_dirs> <max_turns>` → dispatches:
  - `claude` → `claude -p "$prompt" <add_dirs> --model "$model" --max-turns "$max_turns" --disallowedTools Write,Edit,NotebookEdit --setting-sources project` (exactly the existing invocation). **`max_turns` is a parameter** because the codbase uses two different values: expert calls use `6`, the synthesizer uses `4` (`lib/plan-council.sh`). Passing it through `call_model` reproduces each call byte-for-byte — the non-dual path stays unchanged.
  - `codex` → `(cd "$project_dir" && "$codex_bin" exec -s read-only "$prompt")`. (codex has no turn limit; `max_turns` applies to the claude branch only.)
  - unknown provider → non-zero.
- The binary names are env-overridable for testability and prod-safety: `${MRA_CLAUDE_BIN:-claude}` / `${MRA_CODEX_BIN:-codex}`.
- `ensure_codex_available` → `command -v "${MRA_CODEX_BIN:-codex}" >/dev/null` (the preflight gate).
- A provider call that **fails (non-zero) or returns empty output** is non-fatal: that persona keeps the other model's view; the council continues (reusing `run_plan_council`'s existing "warn + continue on a failed persona" behaviour). v1 has **no timeout mechanism** — a call runs to the CLI's own completion/error; per-call timeouts are a future consideration, not promised here.

### 21.4 Dual-run flow & synthesizer decision format

`run_plan_council` gains a `dual` parameter (or a providers list). `dual=false` → the current single-claude path, byte-unchanged. `dual=true`:

- For each persona, spawn TWO background jobs — `call_model claude …` and `call_model codex …` (parallel, same `mktemp` + `&` + `wait` collection as today). The same `build_plan_prompt` output feeds both models.
- Results are tagged by provider:
  ```
  ### <persona> [claude]
  …
  ### <persona> [codex]
  …
  ```
- The 2N tagged perspectives feed the synthesizer (claude — it performs a structured comparison/merge, it does NOT adjudicate disagreements). The synthesizer prompt is extended to emit:
  ```
  # Unified Plan: <task>

  ## High-confidence (both models agree)
  - [persona] <concern raised by both>

  ## ⚠ Model Disagreements (human decides)
  - [persona] claude: <position A> │ codex: <position B>
  - [persona] claude raised X; codex did not

  ## Consolidated Files / Risks / Required Tests / Execution Steps
  (existing format; risks keep expert attribution and may add [agreed]/[claude-only]/[codex-only])
  ```
- **Missing-side sentinel.** When a provider call fails (non-zero) or returns empty, `run_plan_council` writes an explicit sentinel into that provider's tagged block rather than an empty section — e.g.:
  ```
  ### performance-hawk [codex]
  (no response — codex call failed or returned empty)
  ```
  This guarantees the synthesizer always sees an unambiguous signal (not a blank it could misread as "nothing to add"), and the synthesizer places such a persona under **Model Disagreements** noting the missing side. The sentinel string is a fixed, testable marker.

### 21.5 Architecture / module responsibilities

- **`lib/model-provider.sh` (new)** — `call_model` + `ensure_codex_available`; the only place that knows how to invoke each CLI. Pure execution layer, independently testable via the `MRA_*_BIN` seams.
- **`lib/plan-council.sh`** — `run_plan_council` gains the `dual` flag: `dual=false` keeps the current claude-only path verbatim; `dual=true` runs claude+codex per persona via `call_model`, tags `$all` by provider, and uses the agree/disagree synthesizer prompt. `build_plan_prompt` is unchanged (one prompt, two models). The per-persona/synth claude calls migrate to go through `call_model` so both paths share one invocation point.
- **`bin/mra.sh`** — the `plan)` dispatch parses `--dual`; when set, calls `ensure_codex_available` (error + exit if absent) before convening; threads `dual` into `run_plan_council`. Usage line updated.
- Out of scope: `review --strategy debate`/`--personas`, `eval` — their codex wiring is a later phase.

### 21.6 Error handling

- `--dual` without codex available → `log_error` + non-zero exit, before any model call (pre-emit).
- A single provider call failing → warn to stderr, that persona keeps the surviving model's view, council continues (existing behaviour).
- Synthesizer failure / empty output → existing `run_plan_council` handling (warn + non-zero) unchanged.
- Both models run in their planning-safe mode (per §21.2): claude keeps direct edit tools disabled (`--disallowedTools Write,Edit,NotebookEdit`); codex runs in a read-only sandbox (`-s read-only`). Enforcement is asymmetric — see §21.2.

### 21.7 Testing

Stubs use env-overridable binary names (`MRA_CLAUDE_BIN` / `MRA_CODEX_BIN` → stub scripts in a temp dir). This is hermetic, subshell-safe, and prod-neutral (defaults to the real `claude`/`codex`). The real CLIs are never invoked in tests.

**`tests/test_plan_council.sh` (existing) — `call_model` (lib/model-provider.sh):**

1. `call_model claude … 6` (stub `MRA_CLAUDE_BIN`) → the stub is invoked with `-p`, `--disallowedTools Write,Edit,NotebookEdit`, `--model`, and **`--max-turns 6`**; a second call with `4` forwards **`--max-turns 4`** (proves the param is threaded, so expert=6 / synth=4 are both reproduced).
2. `call_model codex …` (stub `MRA_CODEX_BIN`) → invoked with `exec` and `-s read-only`, and with cwd = project_dir.
3. `call_model bogus …` → non-zero exit.

**`tests/test_plan_council.sh` — preflight:**

4. `ensure_codex_available` → 0 when present (real codex / a stub); non-zero when `MRA_CODEX_BIN=__nope__` (a name not on PATH).

**`tests/test_plan_council.sh` — `run_plan_council` (stub both bins, 1 persona):**

5. `dual=true` → a shared record file shows claude(expert, `--max-turns 6`) + codex(expert) + claude(synth, `--max-turns 4`) all ran; output is the synth stub's text; `$all` carries `[claude]` and `[codex]` tags.
6. `dual=false` (default) → only claude is invoked; **codex is never called** (record has no codex line); the expert (max-turns 6) and synth (max-turns 4) claude calls match the pre-Phase-13 invocations — the regression guard for the unchanged single-model path.
7. `dual=true` with a **failing codex stub** (exits non-zero / empty) → the council still produces synth output and exits 0; the synthesizer input for that persona's `[codex]` block contains the fixed missing-side sentinel (assert the sentinel string reached the synth stub's captured input).

**`tests/test_plan_council.sh` — dispatch (real CLI via `MRA_WORKSPACE`):**

8. `mra plan <proj> "task" --dual` with `MRA_CODEX_BIN=__nope__` (codex "absent") → preflight error, non-zero exit, council not convened.
9. usage advertises `--dual`.

**Regression:** `bash test.sh` fully green (no new suite — tests live in the existing `tests/test_plan_council.sh`).

### 21.8 Out of scope (Phase 13)

- Multi-model only for `plan-council`; `review` (debate/personas) and `eval` codex wiring are later phases.
- No `--codex-model` (codex uses its configured default).
- The synthesizer does not adjudicate disagreements — it surfaces them for human decision.
- No automatic cross-model vote / majority decision (dual = 2 sources; a real quorum vote needs ≥3 and is a future consideration).
