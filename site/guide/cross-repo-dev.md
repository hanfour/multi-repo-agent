# Cross-Repo Development

`mra` is designed around one core insight: modern software lives across many repos, but Claude sees only one directory at a time.

## The problem

Change an API in `my-api` — three frontends silently break. You open three Claude sessions, re-explain context each time, and hope the reviewer catches regressions.

## The mra model

```bash
mra my-api --with-deps
```

This command:

1. Loads `my-api` and every consumer declared in `dep-graph.json`
2. Passes a shared context window so Claude sees all related repos
3. Dispatches sub-agents per repo, coordinating changes in dependency order
4. Runs code review after each commit

## Dependency detection

Five built-in scanners infer the graph automatically:

| Scanner | Detects | Confidence |
|---------|---------|------------|
| `docker-compose` | Service relationships | High |
| `shared-db` | Projects sharing databases | High |
| `gateway-routes` | API gateway routing | Medium |
| `shared-packages` | Internal npm/gem packages | High |
| `api-calls` | Env var API host references | Low |

Manual overrides go in `.collab/manual-deps.json`.

## Shipping across repos

Once changes span several repos, the branch-aware commands move them together — always in dependency order:

```bash
mra branch new feature/login    # same branch in every repo
# ...work, commit per repo...
mra sync --safe                 # pull everyone up to date
mra branch status               # ahead/behind/dirty/PR state at a glance
mra branch pr                   # push branches + open PRs (upstream first)
mra branch merge --wait-ci      # merge each PR once its CI is green
```

`branch pr` and `branch merge` accept a `[repos…]` subset, and `merge` gates on mergeable + CI state. See [`mra branch`](/commands/branch) and [`mra sync`](/commands/sync).

## See also

- [Getting Started](/guide/getting-started)
- [Branch-aware sync & PRs](/commands/branch)
- [Commands reference](/commands/)
