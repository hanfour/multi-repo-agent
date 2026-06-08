# Commands Overview

mra ships 32 commands organised by purpose.

## Cross-Repo Development

| Command | Purpose |
|---------|---------|
| `mra <project...> [--with-deps]` | Launch Claude orchestrator with specified projects |
| `mra --all` | Load every project in the workspace |
| `mra ask <project> "<question>"` | One-shot codebase query |

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

## Knowledge & Context

| Command | Purpose |
|---------|---------|
| [`mra analyze <project>`](/commands/pkb) | Generate Project Knowledge Base |
| `mra export <project>` | Export project context files |

## Testing & Docker

| Command | Purpose |
|---------|---------|
| `mra db setup` | Start DB containers and import dumps |
| `mra test <project>` | Run tests (auto-detects strategy) |
| `mra watch <project>` | Auto-test on file change |

See the [README](https://github.com/hanfour/multi-repo-agent#command-reference) for the full list.
