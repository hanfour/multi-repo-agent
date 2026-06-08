# mra review

Context-aware code review that auto-selects strategy based on diff size.

## Strategies

| Strategy | When | How |
|----------|------|-----|
| **Light** | < 50 lines, ≤ 3 files | Single pass, 2 turns (~15s) |
| **Standard** | < 300 lines | Single pass, 3 turns (~30s) |
| **Debate** | Large diffs or API changes | 2 analysts + mailbox voting (~3 min) |

```bash
mra review my-api                     # auto-select
mra review my-api --pr 123            # post inline comments
mra review my-api --strategy debate   # force debate mode
mra review my-api --base development  # compare against a specific branch
```

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
