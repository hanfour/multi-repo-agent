# `mra dev` — Autonomous Implement → Review → Fix → PR Loop — Design

**Date:** 2026-06-26
**Status:** Approved design (v1 / Phase 0). Pending implementation.
**Scope:** Add `mra dev <project> "<task>"` — a deterministic, fully-headless, single-repo state machine that implements a task, runs a debate+verifier code review, fixes findings, opens a PR, runs the post-PR review loop, and reports. The central property is a **false-green firewall**: an unattended loop must never coerce an incomplete/failed/ambiguous review into `APPROVED`.
**Provenance:** Produced via a multi-agent council with a genuine three-way vote (P1 *YAGNI/minimal* won 8.7 avg / Borda 8, P3 *maximal-reuse* 8.6 / 7, P2 *safety-first* 7.8 / 3; three judges), synthesized onto the P1 backbone with P2/P3 grafts, then hardened by an adversarial completeness critic (6 gaps closed, see §10). Every decision below was verified against the real `mra` source.

---

## 1. Problem

`mra` already runs an implement → review → fix → PR loop **interactively**: launching `mra <project>` starts a Claude orchestrator (`agents/orchestrator.md`) that dispatches a sub-agent, runs an in-session `code-reviewer` agent, loops fixes, and opens a PR. Two gaps:

- **It is not runnable headlessly / deterministically.** The loop lives entirely inside an interactive orchestrator session and depends on the model honoring `orchestrator.md`. There is no one-shot command, and nothing structurally enforces the re-review or the round caps.
- **Its in-loop review is the weak reviewer.** The in-session `code-reviewer` is single-pass / single-perspective. The hardened path — debate multi-agent review **plus the adversarial verifier** that guards `APPROVED` (`lib/review-debate.sh`) — only runs from the standalone `mra review`, and is **not wired into the dev loop**.

This spec makes the loop a deterministic shell state machine (`mra dev`) whose review step **is** the debate+verifier path, so the property an autonomous loop most needs — a review that cannot silently report clean — is inherited rather than re-implemented.

## 2. Goals / Non-goals

**Goals**
- A one-shot `mra dev <project> "<task>"` that runs implement → debate review → fix → (loop) → PR → pr-review → report, fully non-interactively.
- A **deterministic** state machine (shell-enforced control flow, caps, escalation) — not prompt-driven self-discipline.
- **High-strength review every round** via forced `--strategy debate` + the adversarial verifier as the real gate.
- A **false-green firewall**: every ambiguity (useless exit code, `REVIEW_INCOMPLETE`, verifier `INCONCLUSIVE`, empty diff, stale GitHub hunks, missing verdict) resolves toward *re-review/escalate*, never toward `APPROVED`.
- Unit-testable in the existing `tests/test_*.sh` plain-bash style.

**Non-goals (v1)**
- **Cross-repo** orchestration (dependency ordering, consumer integration tests, multi-PR chaining) — single repo only. Cross-repo stays with the interactive orchestrator.
- A **test-suite gate** — the gate is review `APPROVED` only (per the approved design).
- **Cost accounting** — `record_usage` has zero callers and the debate path uses bare `claude -p` emitting no usage; a partial number would mislead. Deferred (backlog: `--output-format json`).
- Auto-**merge**. The loop opens/iterates a PR; a binding GitHub `APPROVE` is opt-in (`--auto-approve`); merge stays human.

## 3. Command surface

```
mra dev <project> "<task>" [--base <ref>] [--model M] [--max-rounds N]
                           [--no-pr] [--auto-approve] [--resume] [--dry-run]
```

| Flag | Meaning |
|---|---|
| `<project>` | Positional; resolved via `resolve_project_dir` (project-path.sh). |
| `"<task>"` | Free-text task, accumulated like the `plan` parser (bin/mra.sh:830-851). Data only — never `eval`'d. |
| `--base <ref>` | Review/fork base (default `origin/<default-branch>`). Arity-checked; must agree across review and PR. |
| `--model M` | Single model for implement + passed through to review (default `sonnet`; the verifier is the real gate regardless of model). |
| `--max-rounds N` | Per-loop fix-round cap, positive int `^[1-9][0-9]*$` (default 3). Applies to the code-review loop and the pr-review loop separately. |
| `--no-pr` | Run steps 0–3 to `APPROVED` locally, then stop and report the branch. Skips `check_gh_auth`. |
| `--auto-approve` | The ONLY thing that sets `MRA_REVIEW_ALLOW_APPROVE=1` on the `--pr` post. Default off → post a `COMMENT` review and stop (clean-but-not-merged). |
| `--resume` | Reattach to an existing `mra/<slug>` branch / open PR (idempotent). |
| `--dry-run` | `validate()` + print preview, exit before any mutation. |

`check_gh_auth` runs up front (unless `--no-pr`) so a 30-minute run never dies at the final push.

## 4. Architecture

Follows existing `mra` conventions: many small focused files, immutable helpers, verdict transported as a machine artifact (not parsed from prose), all human/log output on stderr.

| File | Action | Purpose |
|---|---|---|
| `lib/dev.sh` | **create** | `dev_project()` state machine + pure/injectable helpers: validate → branch → implement → code-review loop → PR → pr-review loop → report. Owns three-valued verdict handling, round/retry/global caps, no-progress fingerprint, escalation, resume, cwd/`GH_TOKEN` pinning, background-job teardown. |
| `lib/dev-agent.sh` | **create** | Write-enabled headless implement/fix driver. Dispatches `claude -p` with `agents/sub-agent.md` + task/fix-comments; scoped `--allowedTools` incl `Bash(git:*)`; `--setting-sources project`; `--add-dir`; `</dev/null`; outputLanguage injection; comprehensive no-test/no-branch override; emits/parses `===MRA-DEV-DONE===` / `===MRA-DEV-BLOCKED: <reason>===` sentinel + git-state progress; honors `${MRA_DEV_CLAUDE_BIN:-${MRA_CLAUDE_BIN:-claude}}`. |
| `lib/review.sh` | **modify** | Add a verdict-emission mode scoped to the debate `_render_review_json` path: `extract_json → _repair_review_json → _validate_review_json` then write the canonical `review_json` (or synthetic `REVIEW_INCOMPLETE`) to `$MRA_REVIEW_RESULT_FILE`; on the `--pr` path tee at the status branch point **after** repair, independent of `post_inline_review`; parse-time guards rejecting the mode with `--working/--no-debate/light/standard`. Existing terminal/inline output unchanged. |
| `bin/mra.sh` | **modify** | Add the `dev)` dispatch case (copy the `plan` parser); flags per §3; `check_gh_auth` unless `--no-pr`; `resolve_project_dir`; call `dev_project`; add usage help line. (Existing file → `modify`.) |
| `tests/test_dev_state_machine.sh` | **create** | Loop-transition tests (review + dev-agent stubbed as bash functions). |
| `tests/test_dev_verdict.sh` | **create** | Result-file verdict channel + three-valued + false-green guards. |
| `tests/test_dev_cli.sh` | **create** | Arg parsing, mutual-exclusion, `--dry-run`/`--no-pr` terminal semantics, positive-int validation. |

### 4.1 Verdict transport — the load-bearing choice (D1)

`review_project`'s **exit code is structurally useless**: every review path ends `_render_review_json …; _review_pkb_auto_update … &; return`, so it returns the backgrounded job's `0` for `CHANGES_REQUESTED`, `COMMENT`, and malformed JSON alike (verified) — a confirmed false-green vector. Its `log_*` lines also print to stdout. The contest weighed three transports and chose **(a) a result-file channel**, parallel to the existing `SYNC_RESULT_FILE` pattern (sync.sh:285, mra.sh:592):

- `dev_project` exports `MRA_REVIEW_RESULT_FILE=$(mktemp)`.
- `review_project` writes **only** the validated canonical `review_json` there, at the point where `status` exists.
- The loop reads the verdict via `jq -r .status` of the file. **Empty / missing / unparseable ⇒ synthetic `REVIEW_INCOMPLETE`, never `APPROVED`.**
- Rejected: (b) JSON-to-stdout needs every `log_progress/log_info` re-routed to `>&2` and risks non-deterministic `jq` failures on interleaved text; (c) parsing the printed `Status:` line couples to human-format and has no validation on the terminal branch.

> Note: this **supersedes** the earlier-approved "`--json` to stdout" idea. Same intent, lower blast radius, no stdout-auditing.

## 5. State machine (with §10 critic fixes applied)

```
dev_project(workspace, project, task, opts):           # workspace threaded (§10-4)
  # logs -> &2 ; verdict ONLY via $MRA_REVIEW_RESULT_FILE ; never trust exit code

  ## 0 VALIDATE
  dir = resolve_project_dir(workspace, project)              else ABORT
  assert `git -C dir status --porcelain` empty               else ABORT "dirty tree"
  default = origin/<default>; base = opts.base || default
  assert current branch NOT in protected set                 else ABORT
  slug = slugify(task)
  if branch mra/<slug> exists and !opts.resume:               ABORT "exists; use --resume"
  if !opts.no_pr: check_gh_auth                               else ABORT
  if opts.dry_run: print preview; return 0                    # pre-mutation exit
  RF = mktemp; export MRA_REVIEW_RESULT_FILE=RF
  LOG = $(mra_log "$workspace" "$project" start)              # capture path once; echo->&2
  global=0; GLOBAL_CAP=MRA_DEV_MAX_REVIEWS; wall_start=now

  ## 1 BRANCH  (dev owns it; fork from base, NOT current HEAD)
  git -C dir fetch; git -C dir checkout -B mra/<slug> base    # --resume -> reuse

  ## 2 IMPLEMENT
  pre = HEAD
  r = dev_agent(dir, IMPLEMENT, task, IMPLEMENT_MAX_TURNS)    # agent self-commits surgically
  if r.sentinel==BLOCKED:                  escalate(r.reason)
  if HEAD==pre OR empty(base...HEAD):       escalate("no diff produced")
  ensure_pkb(dir)                           # build-if-missing before first review (D14)

  ## helper review_one(mode):   mode = code | pr:N
  :> RF
  env = MRA_REVIEW_VERIFY_APPROVE=1                            # force-export (D5)
  if mode==pr:N: env += MRA_REVIEW_PR_CONTEXT=0 [+ MRA_REVIEW_ALLOW_APPROVE=1 iff opts.auto_approve]
  env review_project(workspace, project, --strategy debate <verdict-mode> [--pr N]) 1>&2 || true   # §10-1: guard set -e
  global++; if global>GLOBAL_CAP or now-wall_start>WALL:  escalate("ceiling")
  v  = jq -r .status RF 2>/dev/null || echo REVIEW_INCOMPLETE  # empty/invalid -> INCOMPLETE, never APPROVED
  fp = fingerprint(sorted path:line:severity from RF.comments[])
  return (v, fp)

  ## 3 CODE-REVIEW LOOP
  round=0; retry=0; prev_fp=""
  loop:
    (v, fp) = review_one(code)
    case v:
      APPROVED:                   break
      COMMENT|REVIEW_INCOMPLETE:  retry++; if retry>RETRY_CAP: escalate("review never completed"); continue
      CHANGES_REQUESTED:
         if fp==prev_fp:          escalate("no progress: identical findings")
         f = dev_agent(dir, FIX, RF.comments, FIX_MAX_TURNS)
         if f.sentinel==BLOCKED:  escalate(f.reason)
         if empty(new diff):      escalate("fix produced no diff")
         prev_fp=fp; round++; if round>=MAX_ROUNDS: escalate("code-review cap"); continue
  if opts.no_pr: report(branch, status=APPROVED-local); teardown; return 0

  ## 4 PR  (idempotent; pin cwd + GH_TOKEN)
  git -C dir push -u origin mra/<slug>
  N = `gh pr view --json number` || mra_pr_create(dir, title, body)   # update-or-create

  ## 5 PR-REVIEW LOOP  (mirror orchestrator.md:163-201)
  round=0; retry=0; prev_fp=""
  loop:
    git -C dir push origin mra/<slug>       # UNCONDITIONAL top-of-loop push (D11): local HEAD==GitHub head
    (v, fp) = review_one(pr:N)              # verdict from result file; GitHub review UPDATED in place (single pinned, §10-3)
    case v:
      APPROVED:                   break
      COMMENT|REVIEW_INCOMPLETE:  retry++; if retry>RETRY_CAP: escalate("pr-review never completed"); continue
      CHANGES_REQUESTED:
         if fp==prev_fp:          escalate("no progress")
         f = dev_agent(dir, FIX, RF.comments, FIX_MAX_TURNS)
         if f.sentinel==BLOCKED or empty diff: escalate
         prev_fp=fp; round++; if round>=MAX_ROUNDS: escalate("pr-review cap"); continue
         # next iteration's top-of-loop push + --pr review IS the re-confirm (§10-2: no separate v2)

  ## 6 REPORT
  wait/disable background _review_pkb_auto_update jobs
  report(branch, PR url=N, code_rounds, pr_rounds, final=APPROVED|COMMENT)
  unset MRA_REVIEW_RESULT_FILE; return 0

escalate(reason):
  mra_log "$workspace" "$project" reason; notify_escalation "$workspace" "$project" reason   # §10-4: 3-arg
  print branch+PR state to &2; teardown bg jobs; unset RF; return 2     # NEVER silently approve

TERMINATION: both loops bounded by round cap + retry sub-cap + global ceiling
             + wall-clock + no-progress fingerprint -> always escalate, never infinite.
```

## 6. The false-green firewall (D1–D7)

- **D1/D2/D3 — verdict source.** Verdict comes only from the validated `status` in `$MRA_REVIEW_RESULT_FILE`; emission is scoped to the debate `_render_review_json` path through `extract_json → repair → validate`; on `--pr`, tee **after** repair so a malformed PR verdict is never misread as clean. Force `--strategy debate` (the single-pass block is dead surface here).
- **D4 — three-valued switch.** `APPROVED → advance`; `CHANGES_REQUESTED → FIX`; `COMMENT == REVIEW_INCOMPLETE → re-review under a *separate* retry sub-cap (`MRA_DEV_REVIEW_RETRY_CAP`, default 2)` then escalate. `REVIEW_INCOMPLETE` (review-debate.sh:181 — agent failure / max-turns cutoff) means *the review failed*: re-review, never re-implement, never approve.
- **D5 — verifier is the gate.** Force-export `MRA_REVIEW_VERIFY_APPROVE=1` every loop-internal review so an operator's global `=0` cannot silently weaken the unattended gate to 2-agent approval. `MRA_REVIEW_ALLOW_APPROVE=1` only around the `--pr` post and only under `--auto-approve`. Verifier `INCONCLUSIVE` → D4 retry, never approve.
- **D6 — GitHub APPROVE opt-in.** Default posts a `COMMENT` review and stops (review.sh documents model-APPROVE as "unsafe by default" because the reviewer sees potentially prompt-injectable PR content). The loop-control verdict (result file) is decoupled from what is posted.
- **D7 — fresh-diff re-review.** Export `MRA_REVIEW_PR_CONTEXT=0` on loop-internal re-reviews so the bot's own prior comments aren't fetched-and-suppressed into a cross-round false green. (PR-context denoising is correct for human `mra review --pr`, dangerous for the bot's own loop.)

## 7. Headless write-agent (D8–D10)

- **D8 — least-privilege write grant.** `--allowedTools 'Edit,Write,Read,Grep,Glob,Bash(git:*)'` via `--setting-sources project` + `</dev/null`; env-overridable `MRA_DEV_ALLOWED_TOOLS`. **Reject** `--permission-mode acceptEdits` (auto-accepts Write/Edit but NOT Bash → stalls at `git commit` → perpetual empty-diff-escalate) and `--dangerously-skip-permissions` (security.md). The colon syntax `Bash(git:*)` is load-bearing (`Bash(git*)` silently fails to match) and must be empirically confirmed in Task 0. This is the only net-new capability in `mra` — every existing `claude -p` is read-only with `--disallowedTools 'Write,Edit,NotebookEdit'`.
- **D9 — surgical self-commit, comprehensive override.** The agent self-commits surgically (reuse `sub-agent.md` staging discipline); `dev_project` owns branch creation; never use `mra_commit` (its `git add -A` would sweep `.mra/` + untracked files). The dispatch must **comprehensively neutralize** the parts of `sub-agent.md` that fight headless single-repo dev (§10-6): the mandatory mra-test DONE-gate, the Step-2 TDD-first mandate, the Step-4 Docker test runs, the "DONE only after `mra test` exit 0" rule, and self-branch-creation — replaced with "branch already exists; review-APPROVED is the only gate; commit surgically."
- **D10 — git ground truth + hardened sentinel.** Progress = `git rev-list base..HEAD` count + non-empty `git diff base...HEAD`, plus an explicit `===MRA-DEV-DONE===` / `===MRA-DEV-BLOCKED: <reason>===` sentinel (the review subsystem abandoned regex-on-prose precisely because counting free-text caused false greens). Empty diff OR `BLOCKED` ⇒ escalate, never review (the default-range path has no empty-diff guard and `run_debate_review` fakes `diff='(diff unavailable)'` which agents trivially approve).

## 8. Loop control & robustness (D11–D13)

- **D11 — push invariant.** Step 3 reviews local `base...HEAD`. Step 5 does an **unconditional `git push` at the top of every pr-review iteration** so local HEAD == GitHub PR head — otherwise `post_inline_review`'s GitHub-hunk filter drops all inline comments and the verdict reflects un-pushed state (a critical false-clean).
- **D12 — validate / resume / idempotent PR / account pinning.** Clean tree, non-protected branch, fork from `origin/<default>` (not `mra_branch_create`'s current-HEAD stale-resume), refuse existing `mra/<slug>` unless `--resume`; idempotent PR via `gh pr view → update-or-create`; **pin cwd + `GH_TOKEN`** (the dual-gh-account per-directory binding means a long loop could otherwise push under the wrong account); all logs on stderr.
- **D13 — caps & no-progress.** Per-loop round caps (default 3 each) + retry sub-cap (D4) + hard global ceiling `MRA_DEV_MAX_REVIEWS` (~12) + wall-clock timeout, all forcing escalation; a no-progress detector fingerprints the sorted finding set (`path:line:severity`) and escalates on unchanged fingerprint OR empty fix-diff. Turn knobs: `MRA_DEV_IMPLEMENT_MAX_TURNS` (~40–50), `MRA_DEV_FIX_MAX_TURNS` (~15–25). Background `_review_pkb_auto_update &` jobs are tracked and waited/disabled at every teardown. (Fan-out is multiplicative: a pr-review round nests a full code-review debate → ~50+ `claude` calls at cap 3/3 without a ceiling.)

## 9. Context, testing, CLI (D14–D16)

- **D14 — PKB before first review.** `ensure_pkb` (build-if-missing) before the first code-review — missing PKB is the key driver of `REVIEW_INCOMPLETE` (project memory: `mra_review_false_green_fix`), and a fresh `mra/` branch's new code is exactly what review must understand. Implement/fix agent uses `--setting-sources project --add-dir <project>` + PKB full tier with a graceful "no PKB → suggest `mra analyze`" fallback; inject the `outputLanguage` directive (protocol tokens stay English).
- **D15 — plain-bash tests + correct mock seam.** Tests are `tests/test_dev_*.sh` in the existing plain-bash assertion style (`test.sh` globs only `tests/test_*.sh`; **bats is not installed** — a `.bats` file is silently skipped and shows CI-green with the safety-critical loop untested). Mock at the **`review_project` function boundary** (debate agents call **bare** `claude`, so `MRA_CLAUDE_BIN` does not intercept them); the dev-agent driver honors `${MRA_DEV_CLAUDE_BIN:-…}`. Reserve a PATH-shim `claude` only for integration.
- **D16 — CLI.** Copy the `plan` parser (project positional + accumulated task); `--max-rounds` positive-int guard; single `--model` default `sonnet`; `--dry-run` = validate+preview then exit before mutation; `--no-pr` = steps 0–3 then stop; `--auto-approve` / `--resume`; `check_gh_auth` up front unless `--no-pr`; capture the `mra_log` path once and route its stdout echo off the verdict channel. `bin/mra.sh` is **modified**, not created.

## 10. Critic gaps closed

The adversarial critic ran against the synthesized plan; all six findings are folded into §5/§7/§8 above:

1. **(HIGH) `set -e` firewall bypass.** `bin/mra.sh` is `set -euo pipefail`; `review_project` returns `1` non-exceptionally on the malformed-JSON path — the *same* `REVIEW_INCOMPLETE` case the firewall treats as normal — which would fire `ERR` and abort `dev_project` *before* the result-file fallback runs, leaving a half-built branch + orphaned background jobs. **Fix:** guard every `review_project` / `dev_agent` / `jq` / `grep -c` call with `|| true` and rely solely on the result-file status; add a test that a `review_project` returning 1 still yields `REVIEW_INCOMPLETE` under `set -e` (see §13).
2. **(MED) PR-review re-confirm was a no-op.** The synthesized step-5 computed `v2 = review_one(code)` but discarded it. **Fix:** drop the redundant local re-confirm entirely — the next iteration's top-of-loop push + `--pr` review *is* the re-confirm, so the verdict that gates the loop always reflects the pushed GitHub state.
3. **(MED) PR comment-noise accumulation.** `post_inline_review` POSTs a brand-new review each call → a multi-round loop stacks N redundant reviews (only the fallback-comment path dedups, review.sh:924-928). **Fix:** maintain a **single pinned MRA review** — before posting each round, dismiss/replace the bot's prior MRA review so the PR carries exactly one evolving review (mechanism is a Task-5 detail via `gh api`).
4. **(MED) workspace threading + signature mismatches.** `dev_project` must thread `workspace`: `resolve_project_dir(workspace,…)`, `review_project(workspace,…)`, `notify_escalation(workspace, project, summary)` (3-arg), `mra_log(workspace, project, msg)` (captures via `$()` since it echoes the log path). **Fixed in §5 signatures.**
5. **(MED) `--allowedTools` breadth.** A git-only Bash allowlist denies `mkdir/mv/rm` → file renames/dir restructuring get silently denied headless → spurious empty-diff escalate. **Fix:** widen Task 0 acceptance to a realistic multi-file task **including a file rename**; document the `MRA_DEV_ALLOWED_TOOLS` override and any intentionally-denied verbs; broaden the default to common safe verbs (`mkdir/mv/cp`) only if Task 0 shows it is needed.
6. **(MED) incomplete `sub-agent.md` override.** Covered in D9 (§7): neutralize the TDD-first step, the Docker/mra-test steps, the DONE-after-tests rule, and self-branch-creation — not just the test gate.

## 11. Safety summary

False-green firewall (verdict only from validated result-file status; missing/empty/invalid ⇒ `REVIEW_INCOMPLETE`, never `APPROVED`) · force `MRA_REVIEW_VERIFY_APPROVE=1` · GitHub APPROVE opt-in only · `MRA_REVIEW_PR_CONTEXT=0` on re-reviews · empty-diff guard before every review · unconditional top-of-loop push · scoped write grant (no `acceptEdits`/`--dangerously-skip`) · no `git add -A` · fork from `origin/<default>` · cwd+`GH_TOKEN` pinned · all logs on stderr · `|| true` guards under `set -e`.

## 12. Failure handling

Dirty tree / unresolved project / protected branch / missing gh auth → ABORT before mutation. Existing `mra/<slug>` → refuse unless `--resume`. IMPLEMENT empty-diff or `BLOCKED` → escalate, no review fired. `claude -p` stall → `</dev/null` + explicit allowlist so it never waits on a prompt; per-phase wall-clock → treat as `BLOCKED`. `review_project` transient / empty result file → `REVIEW_INCOMPLETE` retry sub-cap then escalate. Malformed JSON → repair → still bad → `REVIEW_INCOMPLETE`. No-progress (identical fingerprint OR empty fix diff) → escalate. Global ceiling + wall-clock → escalate even if per-loop caps not hit. PR already open → update-or-create. `gh`/push failure → escalate with branch state for resume. Background PKB jobs waited/disabled on every teardown. Every escalate path calls `notify_escalation` + `mra_log` + a stderr message carrying the reason, so a headless run with no operator still surfaces.

## 13. Testing plan

`tests/test_dev_verdict.sh` — result-file written with canonical object on debate path; empty/malformed-after-repair → `REVIEW_INCOMPLETE` (not approved); **`review_project` returning 1 under `set -e` still yields `REVIEW_INCOMPLETE`, loop not aborted** (§10-1); exit-code-0-with-`CHANGES_REQUESTED` does not advance; status drives verdict independently of exit code; `COMMENT/INCOMPLETE` never treated as `CHANGES_REQUESTED`; logs on stdout do not contaminate the channel; verdict object exposes `comments[]` for the fingerprint; `--pr` path both posts and writes the file orthogonally; teed after repair; mode rejected with `--working/--no-debate` at parse time.

`tests/test_dev_state_machine.sh` — validate aborts on dirty tree / protected branch; branch forks from `origin/<default>` not current HEAD; existing branch refused without `--resume`; implement empty-diff / `BLOCKED` escalate before review; approved-first advances; changes-requested → fix → re-review; incomplete → retry sub-cap → escalate; no-progress fingerprint escalates; empty-fix-diff escalates; code-review round cap escalates; global ceiling escalates; pr-review pushes before each review; **pr-review fix → next iteration's `--pr` review re-confirms (no separate `v2`, §10-2)**; pr-review keeps a single pinned review across rounds (§10-3); pr-review approved completes; `MRA_REVIEW_VERIFY_APPROVE` force-exported `1` even when env `0`; pr-context disabled on re-review; existing open PR updates not recreates; escalation calls notify + mra_log; background PKB jobs waited on teardown.

`tests/test_dev_cli.sh` — missing project/task → usage nonzero; `--max-rounds` rejects non-positive int / default 3; `--dry-run` validates and exits before mutation; `--no-pr` stops at approved local branch (no push) and skips `check_gh_auth`; default posts COMMENT (no `ALLOW_APPROVE`); `--auto-approve` sets `ALLOW_APPROVE` on the PR post only; `--base` arity checked and agrees across review and PR; dev-agent honors `MRA_DEV_CLAUDE_BIN` mock seam.

## 14. Task breakdown

| # | Task | Deps | Acceptance |
|---|---|---|---|
| **0** | **De-risk the write-enabled `claude -p`** | — | A one-off `claude -p <prompt> --allowedTools 'Edit,Write,Read,Bash(git:*)' --setting-sources project --add-dir <repo> </dev/null` in a scratch repo WRITES a file, **renames/moves a file**, AND runs `git add`/`git commit` non-interactively with no permission prompt and no TTY; exact flag names + colon syntax recorded; documented fallback if the grant can't cover `Bash(git)` without `--dangerously-skip`. **Blocks all later tasks.** |
| 1 | `review.sh` verdict-emission mode + result-file channel (D1/D2/D3) | — | Debate path writes canonical validated `review_json` (synthetic `REVIEW_INCOMPLETE` on failure) to `$MRA_REVIEW_RESULT_FILE`; `--pr` tees after repair; parse-time guards; existing output unchanged. `test_dev_verdict.sh` green. |
| 2 | `lib/dev-agent.sh` headless write-driver (D8/D9/D10/D14) | 0 | Dispatches `claude -p` with `sub-agent.md` + task/fix text, scoped allowlist incl `Bash(git:*)` + `</dev/null` + `--setting-sources project` + `--add-dir` + outputLanguage + comprehensive no-test/no-branch override; emits/parses sentinel; returns `BLOCKED` reason; self-commits surgically; honors `MRA_DEV_CLAUDE_BIN`. Unit-mockable. |
| 3 | `lib/dev.sh` validate + branch ownership + implement + PKB ensure (D9/D12/D14) | 2 | Preconditions; forks `mra/<slug>` from `origin/<default>` via `checkout -B`; `--resume` reattaches; `ensure_pkb` before first review; empty-diff/`BLOCKED` escalate before any review; `mra_log` path captured once on stderr; cwd/`GH_TOKEN` pinned; workspace threaded. |
| 4 | `lib/dev.sh` code-review loop — three-valued + caps + no-progress + `set -e` guards (D4/D5/D13, §10-1) | 1,3 | APPROVED advances; CHANGES_REQUESTED → FIX → re-review; COMMENT/INCOMPLETE → retry sub-cap; empty/BLOCKED/identical-fingerprint/ceiling/wall-clock → escalate; `VERIFY_APPROVE` forced on; verdict only from result file; `|| true` guards verified. `test_dev_state_machine.sh` loop cases green. |
| 5 | `lib/dev.sh` PR step + pr-review loop (top-of-loop push, single pinned review) (D6/D7/D11/D12, §10-2/3) | 4 | Idempotent `gh pr view`→update-or-create; unconditional push at top of each iteration; `--pr` review each round with `MRA_REVIEW_PR_CONTEXT=0`; default COMMENT, `--auto-approve` gates `ALLOW_APPROVE` on post only; prior MRA review dismissed/replaced so exactly one pinned review persists; next iteration re-confirms (no `v2`); caps escalate. |
| 6 | `bin/mra.sh` dev dispatch + flags (D16) | 3,4,5 | Plan-style parser; `--max-rounds` positive-int; all flags per §3; `check_gh_auth` unless `--no-pr`; dry-run exits before mutation; usage line added; file **modified**. `test_dev_cli.sh` green. |
| 7 | Escalation/report/teardown wiring (D12/D13, §10-4) | 4,5 | Every terminal/escalate path calls `notify_escalation` (3-arg) + `mra_log` on stderr, prints branch/PR/rounds report, waits/disables background `_review_pkb_auto_update` jobs, unsets `MRA_REVIEW_RESULT_FILE`. |
| 8 | Tests pass via `test.sh` + docs note | 6,7 | `tests/test_dev_*.sh` auto-discovered and green under `./test.sh`; brief usage + env-knob doc; cost-accounting deferral recorded in backlog. |

## 15. Residual risks & deferrals

- **The write-enabled `claude -p` is net-new with zero precedent.** Even with Task 0 + the `Bash(git:*)` allowlist, real risk the headless agent stalls/refuses edits → perpetual empty-diff-escalate. Needs an early smoke test on a real repo before the loop is trusted. CLI flag names/syntax may drift between `claude` versions and must be re-verified at Task 0.
- **Verifier `INCONCLUSIVE` is not directly observable** (internal to `run_debate_review`, falls back to 2-agent approval). Force-`VERIFY=1` + D7 fresh-diff re-review mitigate but do not eliminate a residual false-green if the verifier is flaky AND both agents wrongly approve.
- **No-progress fingerprint** can mis-fire if a fix shifts line numbers without resolving the issue; kept conservative (exact-set match) — tune after first real runs.
- **Global ceiling (~12) and wall-clock defaults are guesses**; multiplicative cost on large diffs may force re-tuning.
- **No per-phase `claude -p` watchdog today**; the wall-clock ceiling bounds the whole run but a single hung agent still burns to max-turns within it — a per-phase timeout→`BLOCKED` is a fast-follow.
- **Deferred:** cross-repo orchestration; test-suite gate; cost reporting (`--output-format json`); slugify-collision UX; PR-review re-flow beyond v1's single mirror.

## 16. Provenance

Designed by a multi-agent council (4 recon lenses → 16 canonical decisions → 3 philosophy planners → 4 judges → synthesize + adversarial critic). Genuine three-way vote: **P1 (YAGNI) 8.7/Borda 8 won**, P3 (maximal-reuse) 8.6/7, P2 (safety-first) 7.8/3. The winning plan is P1's minimal backbone with the decisive grafts noted inline (D8 allowlist + `acceptEdits` rejection from P1; result-file naming + top-of-loop push from P3; Task 0 de-risk from P2; tee-after-repair from a judge). Six adversarial-critic gaps closed (§10).
