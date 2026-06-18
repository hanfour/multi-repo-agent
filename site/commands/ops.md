# Status & Ops

Observe the workspace, query code, generate CI, and run cross-cutting checks.

```bash
mra status                     # workspace overview (per-repo branch/state)
mra diff                       # cross-repo diff summary
mra ask my-api "where is auth handled?"   # one-shot codebase query via Claude
mra lint --all                 # check JS/TS BLOCKER rules across repos
```

## Observe

| Command | Purpose |
|---------|---------|
| `mra status` | Workspace status overview across all repos. |
| `mra log [project]` | View operation history (audit of mra actions). |
| `mra diff` | Cross-repo diff summary. |
| `mra cost [--reset]` | Show Claude API usage/cost; `--reset` clears the counter. |
| `mra dashboard` | Interactive terminal dashboard. |

## Query & export

| Command | Purpose |
|---------|---------|
| `mra ask <project> "<question>"` | One-shot codebase query via Claude (no interactive session). |
| `mra export [project]` | Export project context files (for sharing or external tools). |

## Quality & automation

| Command | Purpose |
|---------|---------|
| `mra lint <project\|--all>` | Check JS/TS BLOCKER rules. |
| `mra ci <project> [--with-review]` | Generate a GitHub Actions workflow; `--with-review` wires in mra review. |
| `mra eval-review <project> --pr <N> [--baseline <file>] [--strategy S]` | Score an AI review against a human baseline; reports saved to `.collab/eval/` for trend tracking. |
| `mra notify [setup\|status\|test]` | Manage notifications (configure, check, send a test). |
| `mra federation <subcommand>` | Multi-workspace contract management (see `mra federation --help`). |
