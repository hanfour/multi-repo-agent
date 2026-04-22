# Personas

Named domain-expert prompt fragments used by `mra review --personas`, `mra plan`, and `mra test-audit`.

## Schema

Every persona file under `agents/personas/` follows a fixed shape:

```md
ROLE: <expert title>
STYLE: <voice / inspiration>

FOCUS:
- <concern>
- <concern>

METHOD:
1. <step>
2. <step>

OUTPUT FORMAT:
- [CRITICAL] `file:line` — <issue>
- [HIGH] `file:line` — <issue>
- [MEDIUM] `file:line` — <suggestion>
```

## Severity ladder

| Tier | Meaning |
|------|---------|
| CRITICAL | Must block merge — exploitable, broken, or will hit production |
| HIGH | Strong recommendation, reproducible impact |
| MEDIUM | Polish / defense-in-depth / readability |

A persona MAY omit a tier that doesn't apply (e.g. `refactoring-sage` rarely produces CRITICAL).

## Built-in personas

| Persona | Inspired by | Focus |
|---------|-------------|-------|
| `security-auditor` | Troy Hunt | Secrets, injection, auth, deserialization |
| `api-contract-guardian` | Cross-repo reviewer | Signature drift, response shape changes |
| `performance-hawk` | Vercel performance engineer | N+1, hot-path I/O, bundle bloat |
| `refactoring-sage` | Martin Fowler | Smells, naming, cohesion, dead code |
| `test-architect` | Kent Beck | The 11 testing principles |

## Adding your own

Drop a new markdown file in `agents/personas/<name>.md`. `lib/personas.sh` auto-discovers it. Reference by basename from any persona-aware command.

## Scope boundaries

Personas include `SCOPE NOTE:` blocks to prevent overlap — e.g. `performance-hawk` owns runtime cost, `api-contract-guardian` owns shape/identity.

## Read-only

All persona agents run with `--disallowedTools "Write,Edit,NotebookEdit"`. They can grep and read — nothing else.
