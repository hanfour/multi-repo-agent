# multi-repo-agent (mra)

Cross-repository collaboration tool for Claude Code. Orchestrate AI-assisted development across multiple Git repos with automatic dependency detection, Docker-based environments, and structured review workflows.

**v2.0.0** | 44 commits | 91 files | 20 test suites | 24 CLI commands | 9 MCP tools | 5 AI agents

---

## Table of Contents

- [Problem](#problem)
- [Quick Start](#quick-start)
- [Requirements](#requirements)
- [Installation](#installation)
- [Tutorial: First-Time Setup](#tutorial-first-time-setup)
- [Tutorial: Daily Development](#tutorial-daily-development)
- [Tutorial: Onboarding a Teammate](#tutorial-onboarding-a-teammate)
- [Command Reference](#command-reference)
- [Configuration Files](#configuration-files)
- [AI Agent Team](#ai-agent-team)
- [Dependency Scanners](#dependency-scanners)
- [Architecture](#architecture)
- [Integrations](#integrations)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [Roadmap](#roadmap)
- [License](#license)

---

## Problem

In multi-repo architectures, changing an API in repo A often requires updating the frontend in repo B. Claude Code sessions are scoped to a single directory, making cross-repo coordination manual and error-prone.

**mra** solves this by:
- Launching Claude with access to multiple related repos via `--add-dir`
- Automatically detecting cross-repo dependencies (API calls, shared databases, Docker services)
- Managing Docker environments for consistent testing across different tech stacks
- Providing an orchestrator prompt that guides Claude through cross-repo changes
- Including a PM agent for requirement analysis and task decomposition

---

## Quick Start

```bash
# 1. Install
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc

# 2. Initialize workspace (interactive repo selection + DB setup)
mra init ~/my-workspace --git-org git@github.com:my-org

# 3. Check environment health
mra doctor

# 4. Launch Claude with a project and its dependencies
mra my-api --with-deps
```

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `git` | Version control | pre-installed on macOS |
| `docker` | Container runtime | [Docker Desktop](https://docker.com) or [OrbStack](https://orbstack.dev) |
| `jq` | JSON parsing | `brew install jq` |
| `gh` | GitHub CLI (repo discovery, PRs) | `brew install gh` then `gh auth login` |
| `yq` | YAML parsing (optional) | `brew install yq` |
| `claude` | Claude Code CLI | [claude.ai/code](https://claude.ai/code) |
| `fswatch` | File watcher (optional, for `mra watch`) | `brew install fswatch` |

---

## Installation

```bash
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent
bash install.sh
source ~/.zshrc
```

This adds the `mra` shell function to your `.zshrc` (or `.bashrc`).

---

## Tutorial: First-Time Setup

### Step 1: Switch GitHub account (if using org private repos)

```bash
gh auth login
# Select the account with access to your org's private repos
```

### Step 2: Initialize workspace

```bash
mra init ~/my-workspace --git-org git@github.com:my-org
```

This will:
1. Run pre-flight checks (docker, gh, jq, git)
2. Fetch all repos from the GitHub org
3. Ask you which repos to clone (Y/n for each)
4. Clone selected repos
5. Scan docker-compose files for database configuration
6. Ask about database setup (engine, dump files)
7. Detect cross-repo dependencies
8. Create a workspace alias (`my-org`)

### Step 3: Prepare database dumps

```bash
# Place SQL dump files in the workspace
mkdir -p ~/my-workspace/dumps
cp /path/to/myapp_db.sql.bz2 ~/my-workspace/dumps/

# Edit db.json to point to your dump files
# ~/my-workspace/.collab/db.json is created during init
```

db.json format (supports multi-schema per instance):

```json
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "5.7",
      "platform": "linux/amd64",
      "port": 3306,
      "password": "123456",
      "schemas": {
        "myapp_db": {
          "source": "./dumps/myapp_db.sql.bz2",
          "usedBy": ["my-api", "backend-api", "gateway"]
        }
      }
    }
  }
}
```

### Step 4: Setup databases

```bash
mra db setup
# Starts MySQL container, creates schemas, imports dumps
```

### Step 5: Verify everything

```bash
mra doctor
```

Expected output:
```
[doctor] === Basic Checks ===
[check] git: ok
[check] docker: ok
[check] jq: ok
[doctor] === Database Checks ===
[check] mysql (mysql:5.7): running
[check] mysql: connectable
[check] mysql/myapp_db: 469 tables
[doctor] === Project Checks ===
[check] my-api: directory exists
...
[doctor] === Summary ===
[doctor] 22 passed, 0 warnings, 0 errors
```

### Step 6: Create a safety snapshot

```bash
mra snapshot "initial-setup"
```

---

## Tutorial: Daily Development

### Morning: Check workspace status

```bash
mra status        # overview of all projects: branch, changes, type
mra diff          # which repos have uncommitted/unpushed changes
mra dashboard     # interactive TUI with auto-refresh (press q to quit)
```

### Cross-project task: Launch the orchestrator

```bash
# Launch Claude with my-api + all its dependencies
mra my-api --with-deps

# Or use the workspace alias
my-org my-api --with-deps

# Claude starts with access to my-api and api-consumer
# Give it a task:
# > "Modify my-api's order API to return items instead of data, sync update api-consumer"
```

The orchestrator will:
1. Dispatch PM agent for requirement analysis (if needed)
2. Plan changes in dependency order (upstream first)
3. Dispatch sub-agents for each project
4. Run code review after each change
5. Create PRs with cross-project dependency notes

### Quick technical queries (no interactive session)

```bash
mra ask my-api "list all order-related API endpoints"
mra ask backend-api "how does JWT authentication work?"
mra ask my-api --with-deps "my-api 和 api-consumer 之間的 API 依賴"
```

### Run tests

```bash
mra test my-api                  # auto-detect: API change -> integration, otherwise -> mock
mra test my-api --integration    # force full integration test
mra test my-api --mock           # force mock/unit test only
```

### Code quality

```bash
mra lint frontend-app               # check frontend BLOCKER rules (interface, enum, any, etc.)
mra lint --all                 # check all frontend projects
```

### Before pushing

```bash
mra snapshot "before-push"     # safety checkpoint
mra diff                       # review what's changed
mra graph --mermaid            # visualize dependency changes
```

### Something broke? Rollback

```bash
mra rollback my-api                     # rollback to latest snapshot
mra rollback my-api "initial-setup"     # rollback to specific snapshot
mra rollback --all                   # rollback everything
```

### Useful combos

```bash
# Full health check
mra doctor && mra lint --all && mra diff

# Re-scan dependencies + export context
mra scan && mra export

# Track API costs
mra cost
```

---

## Tutorial: Onboarding a Teammate

### What to share

Give the new member these files from `<workspace>/.collab/`:

| File | Content | Required? |
|------|---------|-----------|
| `repos.json` | Which repos to clone | Yes |
| `db.json` | Database configuration | Yes |
| `manual-deps.json` | Manual dependency overrides | Optional |
| SQL dump files | Database data | Yes (separate transfer) |

### New member steps

```bash
# 1. Clone and install mra
git clone <mra-repo-url> ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc

# 2. Switch to org GitHub account
gh auth login

# 3. Create workspace directory
mkdir -p ~/my-workspace/.collab

# 4. Place shared config files
cp /path/from/teammate/repos.json ~/my-workspace/.collab/
cp /path/from/teammate/db.json ~/my-workspace/.collab/

# 5. Place dump files
mkdir -p ~/my-workspace/dumps
cp /path/to/dumps/*.sql.bz2 ~/my-workspace/dumps/

# 6. Initialize (skips interactive — uses existing configs)
mra init ~/my-workspace --git-org git@github.com:my-org

# 7. Setup databases
mra db setup

# 8. Verify
mra doctor
```

### Generate config templates for a new workspace

```bash
mra template              # creates repos.json.template, db.json.template, manual-deps.json.template
```

---

## Command Reference

### Core

| Command | Description |
|---------|-------------|
| `mra init <path> --git-org <url>` | Initialize workspace (clone repos, setup DB, scan deps) |
| `mra scan [path]` | Re-scan dependencies (diff scan by default) |
| `mra deps [project]` | Display dependency graph |
| `mra status` | Workspace overview (all projects, branches, changes, DB) |
| `mra diff` | Cross-repo diff summary (uncommitted/unpushed) |
| `mra log [project]` | View operation history |

### AI & Launch

| Command | Description |
|---------|-------------|
| `mra <project...> [--with-deps] [--depth N] [--no-sync]` | Launch Claude orchestrator |
| `mra --all` | Launch with all projects |
| `mra ask <project> "<question>"` | Non-interactive codebase query |
| `mra ask <project> --interactive "<question>"` | Interactive session with follow-ups |
| `mra export [project]` | Export project context (routes, schema, deps, env) |

### Docker & Testing

| Command | Description |
|---------|-------------|
| `mra db setup` | Start DB containers + import dumps |
| `mra db status` | Show database status table |
| `mra db import <schema>` | Re-import a specific database |
| `mra test <project> [--integration\|--mock]` | Run tests in Docker with isolation |
| `mra setup <project\|--all>` | Auto-install deps (bundle install, pnpm install, etc.) |
| `mra watch <project\|--all>` | Watch files, auto-test on change |

### Quality & Health

| Command | Description |
|---------|-------------|
| `mra doctor [project]` | Three-level health check (tools, DB, projects) |
| `mra lint <project\|--all>` | Check JS/TS BLOCKER rules |
| `mra cost [--reset]` | Claude API usage tracking |

### Safety

| Command | Description |
|---------|-------------|
| `mra snapshot [name]` | Create state checkpoint |
| `mra snapshots` | List all snapshots |
| `mra rollback <project\|--all> [name]` | Restore to snapshot |

### CI/CD & Collaboration

| Command | Description |
|---------|-------------|
| `mra ci <project>` | Generate GitHub Actions workflow |
| `mra federation publish <project>` | Publish API contract |
| `mra federation subscribe <url>` | Subscribe to external contract |
| `mra federation verify` | Verify contracts match |
| `mra federation list` | List all contracts |
| `mra notify setup` | Create webhook config template |
| `mra notify status` | Show configured webhooks |
| `mra notify test` | Send test notification |

### Utilities

| Command | Description |
|---------|-------------|
| `mra graph [--mermaid\|--dot]` | Visualize dependency graph |
| `mra dashboard` | Interactive terminal dashboard |
| `mra open <project> [--with-deps]` | Open in IDE (VS Code/Cursor) |
| `mra template [repos\|db\|deps\|all]` | Generate config templates |
| `mra config <key> <value>` | Manage settings |
| `mra alias <name> <path>` | Create workspace shortcut |
| `mra clean [--logs-older-than Nd]` | Clean orphan containers + old logs |

---

## Configuration Files

All configuration lives in `<workspace>/.collab/`:

| File | Purpose | Shareable? |
|------|---------|------------|
| `repos.json` | Which repos to clone, branch settings | Yes |
| `db.json` | Database engines, schemas, dump paths | Yes |
| `dep-graph.json` | Auto-generated dependency graph | No (auto-generated) |
| `manual-deps.json` | Manual dependency overrides | Yes |
| `notify.json` | Webhook notification config | Yes |
| `usage.json` | Claude API usage tracking | No |
| `exports/` | Exported project context files | No (auto-generated) |
| `contracts/` | Federation contract files | Depends |
| `snapshots/` | State snapshots | No |
| `logs/` | Operation logs | No |
| `scanners/` | Custom scanner plugins | Yes |

### repos.json

```json
{
  "repos": [
    { "name": "my-api", "clone": true, "branch": "main", "description": "ERP backend" },
    { "name": "frontend-app", "clone": true, "branch": "main", "description": "ODM frontend" },
    { "name": "old-service", "clone": false, "branch": "main", "description": "Deprecated" }
  ]
}
```

### db.json

```json
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "5.7",
      "platform": "linux/amd64",
      "port": 3306,
      "password": "123456",
      "schemas": {
        "myapp_db": { "source": "./dumps/myapp_db.sql.bz2", "usedBy": ["my-api", "backend-api"] },
        "secondary_db": { "source": "./dumps/secondary_db.sql.bz2", "usedBy": ["secondary_db"] }
      }
    }
  }
}
```

Supported dump formats: `.sql`, `.sql.gz`, `.sql.bz2`, `.sql.xz`, `.sql.zst`, `.dump`

Supported engines: `mysql`, `postgres`

### manual-deps.json

```json
[
  { "source": "frontend-app", "target": "my-api", "type": "api" },
  { "source": "dashboard-ui", "target": "backend-api", "type": "api" }
]
```

### config.json (global, in mra install directory)

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "aliases": { "my-org": { "workspace": "~/my-workspace", "gitOrg": "git@github.com:my-org" } },
  "subAgentWorkflow": { "reviewLoopMax": 3, "autoCommit": true, "autoPR": true }
}
```

---

## AI Agent Team

| Agent | Role | When dispatched |
|-------|------|----------------|
| **orchestrator** | Coordinates cross-project changes, dispatches sub-agents, API change detection | Always active in `mra <project>` session |
| **pm-agent** | Requirement analysis, task decomposition, acceptance validation | User gives vague requirement or asks for impact analysis |
| **sub-agent** | Writes code, runs tests, commits, follows frontend standards | Orchestrator assigns per-project tasks |
| **code-reviewer** | Reviews diffs for correctness, security, API consistency | After sub-agent commits |
| **pr-reviewer** | Reviews entire PR, checks cross-project dependency notes | After PR is created |

### Sub-agent workflow

```
develop -> commit -> review -> PR -> review
                                       |
                                 pass? no -> fix -> commit -> review -> update PR (max 3 loops)
                                       |
                                      yes -> done
```

### PM agent modes

- **Full (default)**: Requirements -> Planning -> Supervision -> Acceptance
- **Analyze only**: Requirements analysis and task decomposition
- **Document only**: Generate PRD/spec from code changes
- **Review only**: Validate completed work against requirements

---

## Dependency Scanners

| Scanner | Detects | Confidence |
|---------|---------|------------|
| `docker-compose` | `depends_on` service relationships | high |
| `shared-db` | Projects sharing the same database | high |
| `gateway-routes` | API gateway routing to services | medium |
| `shared-packages` | Internal npm/gem dependencies | high |
| `api-calls` | Env var API host references | low |

Low-confidence results require manual confirmation in `manual-deps.json`.

### Custom scanner plugins

Place scripts in `<workspace>/.collab/scanners/*.sh`. Each receives workspace path as `$1` and outputs JSONL:

```json
{"source":"frontend","target":"api","type":"api","confidence":"high","scanner":"custom"}
```

---

## Architecture

```
Host (macOS/Linux)
  |
  +-- mra CLI (shell function, zero dependencies beyond jq/git/docker/gh)
  |     +-- Pre-flight checks
  |     +-- Repo sync (git pull/clone from repos.json)
  |     +-- Dependency scan (5 built-in + custom scanners -> dep-graph.json)
  |     +-- Database setup (Docker containers from db.json)
  |     +-- Launch Claude with --add-dir flags
  |
  +-- Claude Orchestrator Session
  |     +-- Reads dep-graph.json for cross-repo context
  |     +-- Dispatches PM/sub/reviewer agents
  |     +-- Executes tests via docker compose run
  |     +-- API change detection matrix for test strategy
  |
  +-- MCP Server (optional)
  |     +-- 9 tools exposed via Model Context Protocol
  |     +-- Any AI agent can query mra programmatically
  |
  +-- Docker Containers
        +-- Per-project test environments (docker compose run)
        +-- Database instances (MySQL, Postgres)
        +-- Integration test network (mra-test-net)
```

---

## Integrations

### reqbot-slack

Provides technical context during Slack-based requirement intake.

```bash
# In reqbot-slack .env:
MRA_WORKSPACE_PATH=/Users/you/my-workspace
```

```typescript
import { askMra, readProjectContext, getProjectDeps } from "./claude/mra-client.js";

const result = await askMra("my-api", "list order-related APIs");
const context = readProjectContext("my-api");  // 17KB routes, schema, deps
const deps = getProjectDeps("my-api");         // { deps: [...], consumedBy: [...] }
```

### MCP Server

```bash
cd ~/multi-repo-agent/mcp-server && npm install && npm run build
claude mcp add mra node ~/multi-repo-agent/mcp-server/dist/index.js
```

9 tools: `mra_status`, `mra_deps`, `mra_ask`, `mra_export`, `mra_diff`, `mra_doctor`, `mra_graph`, `mra_scan`, `mra_test`

### GitHub Actions

```bash
mra ci my-api    # generates .github/workflows/mra-test.yml
```

### Federation (Cross-Team)

```bash
mra federation publish my-api                    # publish API contract
mra federation subscribe https://url/my-api.json # subscribe
mra federation verify                         # check compatibility
```

### Notifications (Slack/Discord)

```bash
mra notify setup    # create webhook config
mra notify test     # send test notification
```

---

## Testing

```bash
cd ~/multi-repo-agent
for test in tests/test_*.sh; do bash "$test"; done
```

20 test suites covering: colors, config, cost, dashboard, db, deps, detect-type, diff, doctor, federation, graph, init, lint, notify, preflight, scanners (17 sub-tests), snapshot, status, sync, template.

---

## Project Structure

```
~/multi-repo-agent/
+-- install.sh                    # Installation script
+-- config.json                   # Global settings
+-- README.md                     # This file
+-- bin/
|   +-- mra.sh                    # Main CLI entry point (24 commands)
+-- lib/
|   +-- alias.sh                  # Workspace alias management
|   +-- ask.sh                    # AI codebase query
|   +-- change-detector.sh        # API change detection matrix
|   +-- ci.sh                     # GitHub Actions workflow generator
|   +-- cleanup.sh                # Orphan container/log cleanup
|   +-- colors.sh                 # Color output ([tag] format)
|   +-- config.sh                 # Configuration read/write
|   +-- cost.sh                   # Claude API usage tracking
|   +-- dashboard.sh              # Interactive terminal dashboard
|   +-- db.sh                     # Database management
|   +-- deps.sh                   # Dependency graph reader
|   +-- detect-type.sh            # Project type detection
|   +-- diff-summary.sh           # Cross-repo diff summary
|   +-- docker-exec.sh            # Docker execution helpers
|   +-- doctor.sh                 # Environment health checks
|   +-- export.sh                 # Project context exporter
|   +-- federation.sh             # Multi-workspace contracts
|   +-- graph.sh                  # Dependency visualization
|   +-- init.sh                   # Workspace initialization
|   +-- integration-test.sh       # Cross-repo integration testing
|   +-- launch.sh                 # Claude launcher
|   +-- lint.sh                   # JS/TS BLOCKER rule checker
|   +-- log-viewer.sh             # Operation history viewer
|   +-- notify.sh                 # Webhook notifications
|   +-- open-ide.sh               # IDE launcher
|   +-- preflight.sh              # Tool availability checks
|   +-- repos.sh                  # GitHub org repo discovery
|   +-- scan.sh                   # Scanner orchestrator
|   +-- setup-project.sh          # Auto dependency installer
|   +-- snapshot.sh               # Snapshot & rollback
|   +-- status.sh                 # Workspace status overview
|   +-- sync.sh                   # Git pull/clone
|   +-- template.sh               # Config template generator
|   +-- test-runner.sh            # Test execution with isolation
|   +-- watch.sh                  # File change watcher
|   +-- workflow.sh               # Git workflow helpers
+-- scanners/
|   +-- api-calls.sh              # API host env var scanner
|   +-- docker-compose.sh         # Docker Compose scanner
|   +-- gateway-routes.sh         # API gateway route scanner
|   +-- shared-db.sh              # Shared database scanner
|   +-- shared-packages.sh        # Internal package scanner
+-- agents/
|   +-- orchestrator.md           # Orchestrator system prompt
|   +-- pm-agent.md               # PM agent prompt
|   +-- sub-agent.md              # Development sub-agent prompt
|   +-- code-reviewer.md          # Code review agent prompt
|   +-- pr-reviewer.md            # PR review agent prompt
+-- actions/
|   +-- mra-setup/action.yml      # GitHub Action: install mra
|   +-- mra-test/action.yml       # GitHub Action: run tests
+-- mcp-server/
|   +-- src/index.ts              # MCP server entry
|   +-- src/tools.ts              # 9 MCP tool definitions
|   +-- src/mra-executor.ts       # Shell command executor
+-- templates/
|   +-- github-workflow.yml       # CI workflow template
+-- tests/
    +-- test_*.sh                 # 20 test suites
```

---

## Roadmap

### Completed

- [x] Phase 1: CLI skeleton, repos.json, dep-graph, git sync
- [x] Phase 2: 5 automated scanners + diff scan
- [x] Phase 3: Sub-agent workflow with review loops + PM agent
- [x] Phase 4: Docker execution, test isolation, API change detection
- [x] Short-term: status, diff, log, open, scan cache
- [x] Mid-term: watch, setup, graph, custom scanners, cost, templates
- [x] Long-term: MCP server, GitHub Actions, snapshots, dashboard, federation, notifications, lint

### Future

- [ ] Open source release
- [ ] Web dashboard (browser-based dependency graph)
- [ ] `docker exec` into running containers
- [ ] More scanners (GraphQL schema, gRPC proto)
- [ ] Multi-language lint rules (Ruby, Go, Python)

---

## License

MIT
