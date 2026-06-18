# Workspace & Graph

Commands for setting up a workspace, mapping cross-repo dependencies, and day-to-day navigation.

```bash
mra init ~/workspace --git-org git@github.com:my-org   # clone repos, scan, detect deps, create aliases
mra scan                       # re-detect dependencies (run after adding a repo)
mra deps my-api                # show one project's dependency graph
mra graph --mermaid            # print the dependency graph as Mermaid (or --dot)
```

## Setup & configuration

| Command | Purpose |
|---------|---------|
| `mra init <path> --git-org <url>` | Initialize a workspace: clone repos, scan `docker-compose`, detect dependencies, create aliases. State lives in `<path>/.collab/`. |
| `mra scan [path]` | Re-scan the dependency graph. Run this after cloning/adding a repo so mra registers it. |
| `mra config <key> <value>` | Set a workspace configuration value. |
| `mra alias <name> <path>` | Create a workspace alias for quick project access. |
| `mra setup <project\|--all>` | Auto-install dependencies for a project (or all). |
| `mra template [repos\|db\|deps\|all]` | Generate config-file templates to bootstrap a workspace. |

## Inspect & navigate

| Command | Purpose |
|---------|---------|
| `mra deps [project]` | Show the dependency graph (all repos, or one project). |
| `mra graph [--mermaid\|--dot]` | Visualize the dependency graph for docs/diagrams. |
| `mra open <project> [--with-deps]` | Open a project (and optionally its dependencies) in your IDE. |
| `mra doctor [project]` | Verify environment health (tooling, containers, config). |
| `mra clean [--logs-older-than Nd]` | Remove orphan containers and prune old logs. |

## Onboarding a new repo

```bash
cd ~/workspace
git clone <repo-url>     # or let `mra sync` clone repos listed in .collab/repos.json
mra scan                 # register it in the dependency graph
mra alias myrepo ~/workspace/myrepo
mra doctor myrepo        # sanity-check the environment
```
