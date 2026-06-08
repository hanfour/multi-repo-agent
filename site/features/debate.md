# Mailbox-Voting Debate

How the default `mra review` debate strategy converges on high-precision findings.

## Round 1 — independent analysis

Two agents run in parallel with separate contexts:

- **Agent A (Impact Analyst)** — greps the codebase for broken references, dead code, API breaks
- **Agent B (Quality Auditor)** — checks patterns, security, edge cases

## Round 2 — mailbox voting

Both findings pools are merged and numbered. Each agent votes KEEP / DROP on every numbered finding. The tally survives a finding only when it has net positive votes from both sides.

## Final — synthesis

The synthesiser takes surviving findings, dedupes, and emits structured JSON for terminal output or PR inline comments.

## Token optimisation

- Model tiering — voting uses Haiku, analysis uses Sonnet
- Focused context — non-search rounds use `--add-file` instead of `--add-dir`
- Fast convergence — skip debate when findings are 0 or <5
- PKB integration — knowledge docs replace whole-codebase loading
- Lean prompts — review criteria kept DRY across rounds

## Compared to `--personas`

| Mode | Agents | Cost | When |
|------|--------|------|------|
| Debate | 2 generic + 2 voters | Lower | Default |
| Personas | 5 named experts | Higher | Security-critical or cross-repo |

Both converge on the same JSON format — PR inline comments work identically.
