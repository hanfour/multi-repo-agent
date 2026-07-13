# mra review

Context-aware code review that auto-selects strategy based on diff size.

## Strategies

| Strategy | When | How |
|----------|------|-----|
| **Light** | < 50 lines, ≤ 3 files | Single pass, 2 turns (~15s) |
| **Standard** | < 300 lines | Single pass, 3 turns (~30s) |
| **Debate** | Large diffs or API changes | 2 analysts + mailbox voting (~3 min) |

```bash
mra review my-api                     # Codex by default
mra review my-api --pr 123            # post inline comments
mra review my-api --provider claude --strategy debate   # force Claude debate mode
mra review my-api --base development  # compare against a specific branch
```

## Providers

Review defaults to Codex. Admins can switch the default:

```bash
mra config review.providerMode codex
mra config review.providerMode claude
mra config review.providerMode fallback
mra config review.providerMode dual
```

CLI `--provider` overrides are blocked unless `review.allowUserOverride` is enabled or `MRA_REVIEW_ADMIN_OVERRIDE=1` is set. `fallback` tries primary then secondary; `dual` runs both providers and merges their standard single-pass findings. In this phase Codex uses single-pass review; debate and personas remain Claude-only.

New installations use Codex plus the standard strategy. Unversioned legacy
configs preserve Claude behavior until explicitly migrated. Codex runs from a
trusted MRA cwd against a sanitized read-only snapshot; repository AGENTS,
Claude rules, and skills are supplied only as untrusted review context.

For machine integrations, use `mra integration describe|doctor|review`. Protocol
v1 is analysis-only, emits a SHA-bound JSON artifact, and never receives GitHub
credentials or approval intent.
Protocol v1 advertises only Codex because it is the provider with enforced
sanitized execution. Claude, fallback, and dual remain available for ordinary
reviews, but their output is not approval-eligible evidence.

## --personas (opt-in)

Swap the two generic debate agents for 5 named domain experts:

```bash
mra review my-api --personas
```

| Persona | Focus |
|---------|-------|
| `security-auditor` | Secrets, injection, auth (Troy Hunt) |
| `api-contract-guardian` | Cross-repo signature drift |
| `performance-hawk` | N+1, hot-path I/O, bundle bloat |
| `refactoring-sage` | Code smells, naming, cohesion (Fowler) |
| `test-architect` | Kent Beck 11 principles |

See [Personas](/features/personas) for the full design.

## Read-only guarantee

All review agents run with `--disallowedTools "Write,Edit,NotebookEdit"`. They cannot modify files — only read and report.
