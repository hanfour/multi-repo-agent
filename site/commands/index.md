# Commands Overview

mra ships 32 commands organised by purpose.

## Cross-Repo Development

| Command | Purpose |
|---------|---------|
| `mra <project...> [--with-deps]` | Launch Claude orchestrator with specified projects |
| `mra --all` | Load every project in the workspace |
| [`mra ask <project> "<question>"`](/commands/ops) | One-shot codebase query |

## Workspace & Graph

| Command | Purpose |
|---------|---------|
| [`mra init <path> --git-org <url>`](/commands/workspace) | Initialize a workspace |
| [`mra scan [path]`](/commands/workspace) | Re-scan dependencies |
| [`mra deps [project]`](/commands/workspace) | Show dependency graph |
| [`mra graph [--mermaid\|--dot]`](/commands/workspace) | Visualize the dependency graph |
| [`mra alias`](/commands/workspace) · [`config`](/commands/workspace) · [`setup`](/commands/workspace) · [`template`](/commands/workspace) · [`open`](/commands/workspace) · [`doctor`](/commands/workspace) · [`clean`](/commands/workspace) | Setup, navigation & maintenance |

## Branch & Sync

| Command | Purpose |
|---------|---------|
| [`mra sync`](/commands/sync) | Clone/pull every repo (`--safe`/`--push`/`--review`/`--json`) |
| [`mra branch status`](/commands/branch) | Cross-repo branch overview (`--all`/`--fetch`/`--json`) |
| [`mra branch new\|switch <name>`](/commands/branch) | Create/switch the same branch across repos |
| [`mra branch pr [repos…]`](/commands/branch) | Push branches and open PRs (deps first) |
| [`mra branch merge [repos…]`](/commands/branch) | Merge open PRs, mergeable + CI gated (`--wait-ci`) |

## Code Review

| Command | Purpose |
|---------|---------|
| [`mra review <project>`](/commands/review) | Local terminal review |
| `mra review <project> --pr N` | Post inline comments on a GitHub PR |
| `mra review <project> --personas` | Run 5 named domain-expert personas |
| [`mra plan <project> "<task>"`](/commands/plan) | Multi-expert implementation plan (`--dual`: claude + codex) |
| [`mra test-audit <project>`](/commands/test-audit) | Kent Beck 11-principles test audit |
| [`mra eval-review <project> --pr N`](/commands/ops) | Score an AI review against a human baseline |

## Knowledge & Context

| Command | Purpose |
|---------|---------|
| [`mra analyze <project>`](/commands/pkb) | Generate Project Knowledge Base |
| [`mra export <project>`](/commands/ops) | Export project context files |

## Testing & Docker

| Command | Purpose |
|---------|---------|
| [`mra trust <project>`](/commands/testing) | Grant Docker trust (one-time, per project) |
| [`mra db [setup\|status\|import]`](/commands/testing) | Start DB containers and import dumps |
| [`mra test <project>`](/commands/testing) | Run tests (auto-detects strategy) |
| [`mra watch <project>`](/commands/testing) | Auto-test on file change |

## Snapshots & Rollback

| Command | Purpose |
|---------|---------|
| [`mra snapshot [name]`](/commands/snapshots) · [`snapshots`](/commands/snapshots) | Capture / list state snapshots |
| [`mra rollback <project> [name]`](/commands/snapshots) | Restore to a snapshot (asks before destroying) |

## Status & Ops

| Command | Purpose |
|---------|---------|
| [`mra status`](/commands/ops) · [`log`](/commands/ops) · [`diff`](/commands/ops) · [`cost`](/commands/ops) · [`dashboard`](/commands/ops) | Observe the workspace |
| [`mra lint <project\|--all>`](/commands/ops) | Check JS/TS BLOCKER rules |
| [`mra ci <project>`](/commands/ops) | Generate a GitHub Actions workflow |
| [`mra notify`](/commands/ops) · [`federation`](/commands/ops) | Notifications & multi-workspace contracts |

See the [README](https://github.com/hanfour/multi-repo-agent#command-reference) for the full list.
