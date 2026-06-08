# mra sync

Clone or pull every repo in the workspace in one pass. Branch-aware: each repo is synced on its current branch.

```bash
mra sync                # clone missing repos, pull the rest
mra sync --safe         # fast-forward only (never rewrites local work)
mra sync --push         # also push local commits after pulling
mra sync --review       # auto-review what each pull brought in
```

## Modes

| Flag | Effect |
|------|--------|
| `--safe` | Fast-forward-only pull; a repo that would need a merge is skipped and reported, not force-updated |
| `--push` | After syncing, push the current branch of each repo |
| `--review` | Run a code review over the newly pulled changes (cannot combine with `--json`) |
| `--dry-run` | Print what would happen without touching any repo |
| `--json` | Emit a machine-readable result array (see below) |

## JSON output

`--json` prints one object per repo to stdout — worker logs go to stderr, so stdout stays valid JSON:

```json
[
  { "repo": "my-api", "action": "pulled", "ok": true },
  { "repo": "frontend-app", "action": "skipped", "ok": true }
]
```

`action` is one of `cloned` / `pulled` / `pushed` / `skipped`; `ok` is `false` when that repo's operation failed. Pipe into `jq` to gate other tooling:

```bash
mra sync --safe --json | jq -e 'all(.ok)'
```

`--json` works with the default, `--safe`, and `--push` modes — but not with `--review`.
