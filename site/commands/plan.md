# mra plan

Convene 5 domain experts to propose implementation strategies independently, then synthesise them into one plan.

```bash
mra plan my-api "Migrate session tokens to JWT"
```

## Flow

1. **Parallel dispatch** — 5 personas each receive the task + PKB context + project code access.
2. **Independent advice** — each writes its own strategy (files to touch, risks ranked CRITICAL/HIGH/MEDIUM, required tests).
3. **Synthesis** — a final pass merges overlapping files, orders risks by severity with expert attribution, emits a numbered TODO list.

## Output shape

```
# Unified Plan: Migrate session tokens to JWT

## Consolidated Files
- `lib/auth.ts` — rewrite token issuance
- `lib/middleware.ts` — validate signatures

## Risks (sorted)
- [CRITICAL] [security-auditor] JWT secret rotation strategy missing
- [HIGH]     [api-contract-guardian] 401 response shape changed

## Required Tests
- Integration: round-trip JWT over /login → /me

## Execution Steps
1. Add JWT secret to env
2. ...
```

## Options

| Flag | Effect |
|------|--------|
| `--model sonnet` | Default; use `opus` for deeper reasoning |
| `--dual` | Run each persona through both claude and codex, then reconcile |

## --dual (multi-model council)

With `--dual`, every persona is run through **both** the `claude` and `codex` CLIs. The synthesiser then reconciles the two models' proposals — highlighting where they agree and surfacing where they disagree — so you get a cross-model consensus rather than a single model's view.

```bash
mra plan my-api "Migrate session tokens to JWT" --dual
```

Requires the `codex` CLI on `PATH`.

Pipe to a file to save:

```bash
mra plan my-api "Migrate session tokens to JWT" > plans/jwt-migration.md
```
