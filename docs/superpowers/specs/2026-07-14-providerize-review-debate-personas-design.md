# Providerize review debate & personas (Codex support) — Design

**Date:** 2026-07-14
**Issue:** hanfour/multi-repo-agent#13 — `feat(review): providerize debate/personas,消除 codex 預設 provider 的能力落差`
**Status:** Approved (brainstorming)

## Problem

Codex is the default review provider (`config.json providerMode: "codex"`), but the
two advanced review paths — **debate** and **personas** — still call `claude_invoke`
directly and are therefore Claude-only. Two `review.sh` guards enforce this: a
`--personas`-only-claude error and a `--strategy debate`-only-claude downgrade. The
result: the default provider can only run single-pass review; to get debate or the
5 personas the operator must switch back to Claude.

Single-pass already routes through the `review_call_model` → `_review_call_one_provider`
abstraction (claude/codex branches). Debate and personas bypass it.

## Key constraint: Codex ≠ Claude execution model

Codex cannot run Claude's multi-turn agentic debate. The Codex provider
(`_review_call_one_provider` codex branch) is a **single analysis pass** over a
**sanitized snapshot** (`codex exec --sandbox read-only`, `--ignore-rules`,
ephemeral auth, protocol v1: analysis-only, SHA-bound). Claude debate is multi-turn
agentic (max-turns 20) over the **live** repo + add-dirs + PKB, running tools.

Therefore each provider uses the shape that fits it. Claude keeps its 5-stage
agentic debate unchanged; Codex gets a native lightweight debate.

## Design

Two independent providerization tracks, both routing through the existing
`review_call_model` abstraction.

### Track 1 — Codex-native debate (`lib/review-debate.sh`)

`run_debate_review` gains a provider branch at its entry:

- **provider = claude** → existing 5-stage agentic flow, **completely unchanged**
  (zero-risk isolation).
- **provider = codex** → new thin `_run_codex_debate`:
  1. **pass 1** — Codex analysis: find issues (`review_call_model … codex`).
  2. **pass 2** — Codex **adversarial-verify**: fed pass 1's findings, instructed to
     refute / substantiate each. This mirrors Claude debate's agent→verifier spirit
     and is more faithful than two identical passes.
  3. **merge** — reuse the existing `_review_provider_merge_dual_json` + verdict
     sentinel logic (already used by the `dual` provider mode).

Remove the `review.sh` guard that downgrades `debate → standard` for non-Claude
providers; allow Codex debate instead.

**Completeness contract (no false-green):** if either Codex pass returns no
completion sentinel / empty / unparseable output, the merged result is the neutral
`REVIEW_INCOMPLETE` verdict — never an APPROVE. This reuses the shared
`review-verdict.sh` primitives (the #8 contract), so debate and single-pass agree.

### Track 2 — Codex personas (`lib/review-personas.sh`)

`run_persona_review` currently spawns N parallel `claude_invoke` subshells (`:76`).
Minimal change:

- Add a `provider` parameter. The inner subshell replaces the direct `claude_invoke`
  with:
  `review_call_model "review-persona" "$provider" "$prompt" "$model" "$project_dir" "$claude_add_dirs" "${MRA_REVIEW_PERSONA_MAX_TURNS:-8}"`.
- **Codex:** each persona = one Codex pass. Persona identity is already embedded in
  the `build_persona_prompt` `-p` prompt, which `_review_provider_codex_prompt`
  carries through correctly — no prompt-structure change needed.
- **Compatibility scan:** review `agents/personas/*.md` (5 files) for Claude-only
  tool instructions; neutralize if any exist.
- Remove the `review.sh` personas-only-claude guard.

Note: `_review_call_one_provider`'s claude branch already applies
`--disallowedTools Write,Edit,NotebookEdit` and takes `max_turns` as a parameter, so
routing personas through `review_call_model` preserves current Claude behavior.

## Data flow

```
mra review <project> --provider codex --strategy debate
  └─ run_debate_review(provider=codex)
       └─ _run_codex_debate
            ├─ review_call_model(codex, analysis prompt)      → pass1 JSON
            ├─ review_call_model(codex, adversarial prompt)   → pass2 JSON
            └─ _review_provider_merge_dual_json(pass1, pass2) → merged + sentinel
                 └─ missing sentinel on either → REVIEW_INCOMPLETE

mra review <project> --provider codex --personas
  └─ run_persona_review(provider=codex)
       └─ for each persona: review_call_model(codex, persona prompt) [parallel]
            └─ merge findings (unchanged synthesis)
```

## Error handling

- Either Codex debate pass incomplete → merged `REVIEW_INCOMPLETE` (never APPROVE),
  via shared `review-verdict.sh` sentinel check.
- A persona pass that fails → logged with its stderr file (existing behavior);
  surviving personas still merge.
- Provider validation reuses `_review_provider_validate_backend`.

## Testing (reuse PR #10 fake codex auth + `MRA_CODEX_BIN` double)

- `tests/test_review_debate_codex.sh`:
  - Codex debate produces a merged verdict + completion sentinel.
  - One pass incomplete (no sentinel) → `REVIEW_INCOMPLETE`, never APPROVE.
  - pass 2 receives pass 1's findings (adversarial-verify wiring).
- `tests/test_review_personas_codex.sh`:
  - Codex personas run in parallel and merge findings.
  - Persona prompt reaches the Codex double intact.
- Existing `tests/test_review_debate.sh` / persona tests stay green (zero Claude
  regression).

## Files touched

| File | Change |
|---|---|
| `lib/review-debate.sh` | +provider branch in `run_debate_review`, +`_run_codex_debate` |
| `lib/review-personas.sh` | inner call → `review_call_model`, +provider param |
| `lib/review.sh` | remove 2 claude-only guards; thread provider into debate/persona dispatch |
| `agents/personas/*.md` | compatibility scan (neutralize if needed) |
| `tests/test_review_debate_codex.sh` | new |
| `tests/test_review_personas_codex.sh` | new |
| `README.md:120-122` | update the "debate/personas Claude-only" self-stated limitation |

## Non-goals (YAGNI)

- No change to Claude's existing debate/persona paths.
- No new config switches or env flags.
- No `dual + debate` combination.
- No change to the Codex protocol/snapshot machinery itself.

## Acceptance

- `mra review <p> --provider codex --strategy debate` runs a 2-pass adversarial
  Codex debate and posts a real verdict (or `REVIEW_INCOMPLETE`), never a
  false-green APPROVE.
- `mra review <p> --provider codex --personas` runs the 5 personas under Codex.
- The two claude-only guards are gone; README no longer claims the limitation.
- New Codex tests pass; all existing review tests stay green.
