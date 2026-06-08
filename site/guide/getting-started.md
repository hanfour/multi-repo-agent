# Getting Started

## Prerequisites

| Tool | Install |
|------|---------|
| `git` | Pre-installed on macOS |
| `docker` | [Docker Desktop](https://docker.com) or [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` then `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

## Install

```bash
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
```

## Initialize workspace

```bash
mra init ~/workspace --git-org git@github.com:my-org
```

This clones repos listed in `repos.json`, scans docker-compose for service relationships, and detects dependencies.

## Verify

```bash
mra doctor
```

## First session

```bash
mra my-api --with-deps
```

Claude launches with `my-api` plus all its consumers/dependencies in context.

## Next steps

- [Cross-repo development](/guide/cross-repo-dev)
- [Code review](/commands/review)
- [Project Knowledge Base](/commands/pkb)
