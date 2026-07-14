# Split the review subsystem's large files — Design

**Date:** 2026-07-14
**Issue:** hanfour/multi-repo-agent#12 — `refactor: 拆分超大檔案` (this design covers the **review subsystem** slice; `lib/pkb.sh` and `bin/mra.sh` are deferred to a follow-up issue)
**Status:** Approved (brainstorming)

## Problem

Two files in the review subsystem are an order of magnitude larger than the other
`review-*.sh` modules and are the complexity hotspots:

- `lib/review.sh` — 1205 lines (dominated by `review_project()` ~360 lines and
  `post_inline_review()` ~260 lines).
- `lib/review-debate.sh` — 912 lines (dominated by six agent runners carrying large
  inline prompt heredocs).

The subsystem already has a split precedent — `review-provider.sh`,
`review-protocol.sh`, `review-verdict.sh`, `review-diff.sh`, `review-context.sh`,
etc. — but the two main files kept growing.

## Principle: behavior-preserving relocation only

Each extraction moves **whole functions verbatim** into a new module. No logic
changes, no signature changes, no prompt edits. Correctness is guarded by the
existing `tests/test_review_*.sh` suite (run after each extraction) plus
`shellcheck`. This keeps every step a pure cut-paste a reviewer can verify by
diff.

## Why order doesn't matter (sourcing)

`bin/mra.sh` sources every `lib/*.sh` (lines 7–67) before `main()` is ever called
(dispatch begins at line 178). All these files are function-definition-only, so
Bash resolves calls at call-time, not source-time. Adding new `source` lines in
the review block (near lines 55–63) is sufficient; relative order among the
function-definition files is irrelevant.

## Naming-collision resolution (checked)

- `review-select.sh` holds `review_targets()` (which repos to auto-review after a
  sync) — unrelated to `select_review_strategy` (light/standard/debate). New file
  is `review-strategy.sh`; no collision.
- `review-context.sh` holds `review_context_*` (normalizing AGENTS.md/CLAUDE.md for
  providers) — unrelated to PR-discussion context. To avoid confusion the new file
  is named **`review-pr-discussion.sh`** (not `review-pr-context.sh`).

## Design

### Part A — `lib/review.sh` (1205) → orchestrator + 4 modules

| New module | Functions moved (verbatim) | Guarding tests |
|---|---|---|
| `lib/review-json.sh` | `_review_redact_secrets_json`, `_validate_review_json`, `_review_event_for_status`, `_review_effective_status`, `_review_singlepass_body`, `extract_json`, `_repair_review_json` | `test_review_verdict.sh`, `test_review_approve_gate.sh`, `test_review_json_repair.sh`, `test_review_singlepass_gate.sh` |
| `lib/review-strategy.sh` | `select_review_strategy`, `_review_strategy_turns`, `build_focused_context` | `test_review_safety.sh` |
| `lib/review-pr-discussion.sh` | `_review_format_pr_discussion`, `_review_format_pr_scope`, `_review_pr_discussion_prompt`, `_review_prompt_with_pr_discussion`, `_review_fetch_pr_discussion` | `test_review_pr_context.sh` |
| `lib/review-post.sh` | `_review_validate_expected_head`, `_render_review_json`, `_review_emit_verdict`, `_review_status_for_notify`, `_review_notify_complete`, `_review_issues_display`, `resolve_pr_base`, `post_inline_review`, `post_fallback_comment` | `test_review_approve_gate.sh` (emit/effective-status), full suite smoke |

**Stays in `review.sh`:** `review_project()` (the orchestrator) and
`_review_pkb_auto_update`. Target ~420 lines.

### Part B — `lib/review-debate.sh` (912) → orchestrator + 1 module

| New module | Functions moved (verbatim) | Guarding tests |
|---|---|---|
| `lib/review-debate-agents.sh` | `run_agent_a`, `run_agent_b`, `run_agent_verify`, `run_critique_and_refine`, `run_vote`, `run_synthesize` | `test_review_debate.sh` |

**Stays in `review-debate.sh`:** `run_debate_review` (orchestrator), the `_debate_*`
deciders (`_debate_verdict_of`, `_debate_assess`, `_debate_verify_gate`,
`_debate_count_findings`), `_run_codex_debate`, `_build_findings_pool`,
`_tally_votes`. Target ~400 lines.

We deliberately do NOT further split the debate prompts out of the agent functions
— that would require rewriting each agent to call a prompt builder (a logic
change), breaking the behavior-preserving guarantee. Moving whole agent functions
is a pure relocation.

### Sourcing wiring (`bin/mra.sh`)

Add five `source` lines in the review block (after the existing review sources,
before `main()`):

```
source "$MRA_DIR/lib/review-json.sh"
source "$MRA_DIR/lib/review-strategy.sh"
source "$MRA_DIR/lib/review-pr-discussion.sh"
source "$MRA_DIR/lib/review-post.sh"
source "$MRA_DIR/lib/review-debate-agents.sh"
```

Any test harness that sources `lib/review.sh` / `lib/review-debate.sh` directly
(e.g. `tests/test_review_*.sh`) must also source the new modules it needs — the
plan updates each affected test's source block.

## Data flow

Unchanged. `review_project()` still orchestrates collect → strategy → PKB →
provider/debate/personas → post; it now calls functions that live in sibling
modules instead of the same file. `run_debate_review()` still orchestrates the
rounds; the agent runners it calls now live in `review-debate-agents.sh`.

## Error handling

Unchanged — no logic touched. `set -euo pipefail` behavior is identical because the
functions are byte-for-byte the same and sourcing order is irrelevant (all
definitions load before any dispatch).

## Testing

- After each module extraction: run that module's guarding tests, then the full
  `./test.sh` (shell + mcp-server) — must stay green with the same counts.
- `shellcheck -S error` on every new and modified file — clean.
- No new test logic is required (behavior is unchanged); if `review-post.sh` has no
  direct unit test today, rely on the existing integration coverage and the full
  suite, and note the gap rather than inventing tests for un-changed behavior.

## Files touched

| File | Action |
|---|---|
| `lib/review-json.sh` | new (moved fns) |
| `lib/review-strategy.sh` | new (moved fns) |
| `lib/review-pr-discussion.sh` | new (moved fns) |
| `lib/review-post.sh` | new (moved fns) |
| `lib/review-debate-agents.sh` | new (moved fns) |
| `lib/review.sh` | shrunk to orchestrator |
| `lib/review-debate.sh` | shrunk to orchestrator |
| `bin/mra.sh` | +5 source lines |
| `tests/test_review_*.sh` | add new-module sources where a test sources review.sh/review-debate.sh directly |

## Non-goals (YAGNI)

- No logic, signature, or prompt changes.
- No split of `lib/pkb.sh` or `bin/mra.sh` (deferred follow-up issue).
- No further sub-splitting of the debate prompts.
- No new behavior or features.

## Acceptance

- `lib/review.sh` and `lib/review-debate.sh` each drop to ~400 lines; each new
  module has one clear responsibility and is < ~300 lines.
- `./test.sh` stays green with unchanged counts; `shellcheck -S error` clean.
- No function is lost or duplicated (each moved exactly once); `bin/mra.sh` sources
  every new module.
