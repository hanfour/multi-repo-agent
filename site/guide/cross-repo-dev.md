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

## See also

- [Getting Started](/guide/getting-started)
- [Commands reference](/commands/)
