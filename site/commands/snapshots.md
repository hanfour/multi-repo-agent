# Snapshots & Rollback

Capture and restore workspace state so risky operations are reversible.

```bash
mra snapshot before-refactor       # capture a named state snapshot
mra snapshots                      # list all snapshots
mra rollback my-api before-refactor   # restore one project (asks before destroying)
mra rollback --all before-refactor    # restore every project (single batch confirmation)
```

## Commands

| Command | Purpose |
|---------|---------|
| `mra snapshot [name]` | Create a state snapshot (optionally named). |
| `mra snapshots` | List all snapshots. |
| `mra rollback <project> [name] [--force] [--ignore-integrity]` | Roll one project back to a snapshot. Prompts before destroying current state. |
| `mra rollback --all [name] [--force] [--ignore-integrity]` | Roll all projects back, with a single confirmation for the batch. |

## Flags

| Flag | Effect |
|------|--------|
| `--force` | Skip the confirmation prompt. |
| `--ignore-integrity` | Proceed even if the snapshot fails its integrity check (use with care). |

::: warning
Rollback is destructive — it overwrites current working state with the snapshot. mra asks before destroying unless `--force` is given.
:::
