# Single-pass review completeness sentinel — design

**Date:** 2026-07-06
**Issue:** [#8](https://github.com/hanfour/multi-repo-agent/issues/8)
**Status:** design (pending review)

## Problem

The **debate** strategy requires each agent to end its output with an explicit
verdict sentinel (`===MRA-REVIEW-COMPLETE: APPROVED===` /
`CHANGES_REQUESTED`, `lib/review-debate.sh`); `_debate_assess` treats a missing
sentinel as `ERROR → REVIEW_INCOMPLETE`, so a cut-off agent can never
masquerade as a clean review.

The **single-pass** strategies (`light` / `standard`, `lib/review.sh`) have **no
such signal**. They run Claude under a low `--max-turns` (light=2, standard=6)
and trust whatever comes back. On a max-turns cutoff Claude emits
`Error: Reached max turns …` (not valid JSON), which the current code catches
with a hard `return 1` — safe from a false green, but an unstructured error: the
gateway / `mra dev` see a raw non-zero exit rather than a REVIEW_INCOMPLETE
verdict, and any future cutoff shape that happens to yield valid-looking JSON
would slip through with no completion check at all.

## Scope — what this catches, and what it does not

**Catches (the value):** a truncated / cut-off single-pass review. Absent the
completion sentinel, the review is reported as a structured `REVIEW_INCOMPLETE`
(never APPROVE), matching the debate contract, instead of a raw error — and it
covers any cutoff that yields a syntactically valid but sentinel-less body.

**Does NOT catch (explicit non-goal):** a model that emits a *complete but
blind* review in one shot (valid JSON + sentinel, having done no real
investigation). The debate sentinel has the same blind spot — that is a
reviewer-**quality** concern owned by `agents/code-reviewer.md`, not a
completeness signal. Out of scope here.

**Scope: `inline` (JSON, `--pr`) only.** That is the only path that posts to
GitHub and runs the approve gate — the only false-green surface. `terminal`
(prose, local print) has no posting / APPROVE path, so it keeps its live
streaming (`claude_invoke --stream`, added in PR #7) unchanged and is out of
scope for the sentinel — no benefit to justify losing the stream.

## Design

### 1. Shared verdict contract — `lib/review-verdict.sh` (new)

Extract the primitives currently living in `lib/review-debate.sh` so both the
debate and single-pass paths share one definition (DRY; lets `lib/review.sh` use
them without a runtime dependency on `review-debate.sh` being sourced, and keeps
unit tests isolated):

- `MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"` (moved here).
- `review_verdict_of "<text>"` → `APPROVED` | `CHANGES_REQUESTED` | `NONE`
  (moved from `_debate_verdict_of`; grep for the token).
- `review_incomplete_json [reason]` → the canonical neutral incomplete verdict
  `{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — …","comments":[]}`
  (factored from the literal currently inlined in `run_debate_review`).

`lib/review-debate.sh` keeps `_debate_verdict_of` / `MRA_REVIEW_SENTINEL_TOKEN`
as thin aliases delegating to the shared names (behaviour-preserving; the
existing debate tests must stay green). `bin/mra.sh` sources
`review-verdict.sh` before both `review.sh` and `review-debate.sh`.

### 2. Prompt contract — `lib/review-prompt.sh` (`build_review_prompt`)

Append, to the `inline` (STRICT JSON) output-format block only, a required
final line:

> After the JSON, output EXACTLY ONE final line on its own:
> `===MRA-REVIEW-COMPLETE: APPROVED===` or
> `===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===`.
> Omitting it marks the review incomplete.

This is tolerated by `extract_json` (its `/^{/,/^}/p` fallback grabs the JSON
object and ignores the trailing sentinel line). The `terminal` block is
unchanged.

### 3. Detection + handling — `lib/review.sh` single-pass path (inline branch only)

The `inline` branch already **buffers** the response
(`review_json=$(claude_invoke review …)`), so the sentinel is inspectable with
no change to I/O. After the call, before extract/validate/post:

- Compute `verdict=$(review_verdict_of "$review_json")`.
- **Sentinel present** (`APPROVED`/`CHANGES_REQUESTED`): proceed exactly as
  today — `extract_json` → validate → `post_inline_review`. The JSON's own
  `status` still governs the posted verdict; the sentinel is only completion
  proof.
- **Sentinel absent** (`NONE`): replace the body with `review_incomplete_json`
  and route it through `post_inline_review` → posts a neutral **COMMENT** (the
  round-3 gate passes COMMENT through, never APPROVE). Replaces today's
  `return 1` on the incomplete case.

The `terminal` branch is untouched — it keeps `claude_invoke --stream` and its
live output; no sentinel handling there (no posting / APPROVE path).

### 4. Error handling

Fail-safe throughout: a missing/garbled sentinel, an empty response, or a jq
failure all resolve to REVIEW_INCOMPLETE (COMMENT / notice), **never** APPROVE.

## Testing

Mirror `tests/test_review_debate.sh`'s sentinel assertions in a new
`tests/test_review_verdict.sh` + additions to the single-pass tests:

- `review_verdict_of`: APPROVED / CHANGES_REQUESTED / NONE classification
  (incl. token embedded after a JSON body).
- `review_incomplete_json`: valid JSON, `status==COMMENT`, empty comments,
  summary contains `REVIEW_INCOMPLETE`.
- Single-pass inline handling (with a stubbed `claude`/`MRA_CLAUDE_BIN`):
  - sentinel present → normal verdict flows to `post_inline_review`.
  - sentinel absent → `post_inline_review` receives the incomplete JSON;
    effective event is COMMENT, never APPROVE (even with the `:a:` policy +
    `MRA_REVIEW_ALLOW_APPROVE=1`).
- `build_review_prompt` inline mode includes the sentinel instruction; terminal
  mode does not.
- Regression: `tests/test_review_debate.sh` stays green (aliases preserved).

## Out of scope

- Blind-but-complete review detection (reviewer-quality; `code-reviewer.md`).
- Auto-retry / max-turns bump on incomplete (max-turns is already env-tunable
  via `MRA_REVIEW_STANDARD_MAX_TURNS` / `MRA_REVIEW_LIGHT_MAX_TURNS`).
