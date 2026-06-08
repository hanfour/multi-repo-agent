# mra test-audit

Audit test files against Kent Beck's 11 principles of good tests.

```bash
mra test-audit frontend-app
MRA_AUDIT_PARALLEL=3 mra test-audit frontend-app   # cap concurrent audits
```

## Discovery

Finds files matching:
- `*.test.*` (JS / TS)
- `*_test.*` (Go)
- `*.spec.*` (Ruby, JS)

Excludes `node_modules`, `dist`, `build`, `vendor`, `.git`.

## The 11 principles

1. **Isolated** — tests do not depend on each other's state
2. **Composable** — small units combine cleanly
3. **Fast** — the whole suite runs in seconds
4. **Inspiring** — the design of tests inspires the design of code
5. **Writable** — tests are cheap to write
6. **Readable** — tests read as specifications
7. **Behavioural** — tests verify behaviour, not implementation
8. **Structure-insensitive** — refactors do not break tests
9. **Automated** — tests run without human intervention
10. **Specific** — a failure points to a single cause
11. **Deterministic** — same inputs, same result, every time

## Output

Markdown per file with CRITICAL/HIGH/MEDIUM findings tagged by principle number and file:line evidence.
