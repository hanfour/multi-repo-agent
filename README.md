# multi-repo-agent (mra)

Cross-repository collaboration tool for Claude Code. Orchestrate AI-assisted development across multiple Git repos with automatic dependency detection, Docker-based environments, and structured review workflows.

## Problem

In multi-repo architectures, changing an API in repo A often requires updating the frontend in repo B. Claude Code sessions are scoped to a single directory, making cross-repo coordination manual and error-prone.

**mra** solves this by:
- Launching Claude with access to multiple related repos via `--add-dir`
- Automatically detecting cross-repo dependencies (API calls, shared databases, Docker services)
- Managing Docker environments for consistent testing across different tech stacks
- Providing an orchestrator prompt that guides Claude through cross-repo changes

## Quick Start

```bash
# 1. Install
cd ~/multi-repo-agent
bash install.sh
source ~/.zshrc

# 2. Initialize a workspace
mra init ~/my-workspace --git-org git@github.com:my-org

# 3. Launch Claude with a project and its dependencies
mra erp --with-deps
```

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `git` | Version control | pre-installed on macOS |
| `docker` | Container runtime | [Docker Desktop](https://docker.com) or [OrbStack](https://orbstack.dev) |
| `jq` | JSON parsing | `brew install jq` |
| `gh` | GitHub CLI (repo discovery, PRs) | `brew install gh` then `gh auth login` |
| `yq` | YAML parsing (optional) | `brew install yq` |
| `claude` | Claude Code CLI | [claude.ai/code](https://claude.ai/code) |

## Installation

```bash
git clone https://github.com/your-org/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent
bash install.sh
source ~/.zshrc
```

This adds the `mra` shell function to your `.zshrc` (or `.bashrc`).

## Commands

### `mra init <path> --git-org <url>`

Initialize a workspace. On first run:
1. Runs pre-flight checks (docker, gh, jq, git)
2. If `.collab/repos.json` exists, uses it. Otherwise, fetches the repo list from GitHub and interactively asks which repos to clone
3. Clones selected repos
4. If `.collab/db.json` exists, sets up databases. Otherwise, scans docker-compose files and interactively configures databases
5. Runs all scanners to detect cross-repo dependencies
6. Creates a workspace alias

```bash
mra init ~/OneAD --git-org git@github.com:onead
```

### `mra <project...> [options]`

Launch Claude with access to specified projects.

```bash
mra erp odm-ui              # specific projects
mra erp --with-deps          # include upstream/downstream dependencies
mra erp --with-deps --depth 2  # traverse 2 levels of dependencies
mra --all                    # all projects in the workspace
mra erp --no-sync            # skip git pull before launching
```

### `mra scan [path]`

Run dependency scanners and update `dep-graph.json`. By default, performs a diff scan (only re-scans projects with new commits). Use after pulling new code.

```bash
mra scan                     # scan current workspace
mra scan ~/other-workspace   # scan a specific workspace
```

### `mra deps [project]`

Display the dependency graph.

```bash
mra deps                     # show all dependencies
mra deps erp                 # show erp's dependencies only
```

### `mra db <subcommand>`

Manage workspace databases.

```bash
mra db status                # show database status table
mra db setup                 # start containers + import dumps
mra db import gspadmin       # re-import a specific database/schema
```

### `mra doctor [project]`

Three-level environment health check:

```bash
mra doctor                   # check everything
mra doctor erp               # check only erp
```

Output:
```
[doctor] === Basic Checks ===
[check] git: ok
[check] docker: ok
[check] jq: ok
[doctor] === Database Checks ===
[check] mysql (mysql:5.7): running
[check] mysql: connectable
[check] mysql/gspadmin: 469 tables
[doctor] === Project Checks ===
[check] erp: directory exists
[check] erp: bundle check ok
[doctor] === Summary ===
[doctor] 15 passed, 2 warnings, 0 errors
```

### `mra ask <project> "<question>"`

Query a project's codebase using Claude. Non-interactive by default (returns text answer). Add `--interactive` for a full session with follow-ups.

```bash
mra ask erp "列出所有 order 相關的 API endpoint"
mra ask erp --with-deps "erp 和 partner-api-gateway 之間的 API 依賴"
mra ask erp --interactive "分析 orders controller 的設計模式"
```

### `mra export [project]`

Generate static context files per project for external tools (e.g., reqbot-slack). Includes routes, schema, dependencies, env vars, and file structure.

```bash
mra export erp               # export single project
mra export                   # export all projects
```

Output: `<workspace>/.collab/exports/<project>-context.md`

### `mra config <key> <value>`

Manage settings.

```bash
mra config auto-scan off     # disable auto-scan on startup
mra config auto-scan on      # enable auto-scan on startup
mra config parallel-test on  # enable parallel test execution (advanced)
```

### `mra alias <name> <path>`

Create a workspace shortcut. `mra init` automatically creates one from the directory name.

```bash
mra alias onead ~/OneAD
# Now you can use:
onead erp --with-deps
```

### `mra test <project> [options]`

Run tests in Docker with automatic environment isolation.

```bash
mra test erp                  # auto-detect: API change → integration, otherwise → mock
mra test erp --integration    # force integration tests (start containers, test consumers)
mra test erp --mock           # force unit/mock tests only
```

How it works:
1. Detects changed files via `git diff`
2. Classifies changes: API (high) vs internal (low) using detection matrix
3. For API changes: starts provider container, runs consumer integration tests
4. Always runs the project's own tests in Docker with isolated DB

### `mra clean [--logs-older-than Nd]`

Clean up orphan Docker containers and old log files.

```bash
mra clean                    # default: remove logs older than 7 days
mra clean --logs-older-than 3d
```

## Configuration Files

All configuration lives in `<workspace>/.collab/`:

### `repos.json` - Repository list

Defines which repos to clone. Can be shared with teammates.

```json
{
  "repos": [
    { "name": "erp", "clone": true, "branch": "main", "description": "ERP backend" },
    { "name": "odm-ui", "clone": true, "branch": "main", "description": "ODM frontend" },
    { "name": "old-service", "clone": false, "branch": "main", "description": "Deprecated" }
  ]
}
```

### `db.json` - Database configuration

Supports multiple engines, multi-schema instances, and compressed dumps.

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
        "gspadmin": {
          "source": "./dumps/gspadmin.sql.bz2",
          "usedBy": ["erp", "masa", "api-gateway"]
        },
        "moai": {
          "source": "./dumps/moai.sql.bz2",
          "usedBy": ["moai"]
        }
      }
    }
  }
}
```

Supported dump formats: `.sql`, `.sql.gz`, `.sql.bz2`, `.sql.xz`, `.sql.zst`, `.dump` (pg_restore)

Supported engines: `mysql`, `postgres`

The `platform` field handles Apple Silicon compatibility (e.g., `linux/amd64` for MySQL 5.7).

### `dep-graph.json` - Dependency graph (auto-generated)

Generated by `mra init` and updated by `mra scan`. Contains project metadata and inter-project dependencies.

### `manual-deps.json` - Manual dependency overrides

Add dependencies that scanners can't detect automatically. These override scanner results with `high` confidence.

```json
[
  { "source": "odm-ui", "target": "erp", "type": "api" },
  { "source": "bss-ui", "target": "masa", "type": "api" }
]
```

### `config.json` - Global settings (in mra install directory)

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "aliases": {
    "onead": {
      "workspace": "/Users/you/OneAD",
      "gitOrg": "git@github.com:onead"
    }
  },
  "subAgentWorkflow": {
    "reviewLoopMax": 3,
    "autoCommit": true,
    "autoPR": true
  }
}
```

## Dependency Scanners

mra includes 5 scanners that automatically detect cross-repo relationships:

| Scanner | Detects | Confidence |
|---------|---------|------------|
| `docker-compose` | `depends_on` relationships between services | high |
| `shared-db` | Projects sharing the same database name | high |
| `gateway-routes` | API gateway routing to upstream services | medium |
| `shared-packages` | Internal npm/gem package dependencies | high |
| `api-calls` | Environment variable API host references | low |

Low-confidence results are excluded by default. Confirm them in `manual-deps.json` to include.

## Architecture

```
Host (macOS/Linux)
  |
  +-- mra CLI (shell function)
  |     +-- Pre-flight checks (docker, gh, jq, git)
  |     +-- Repo sync (git pull/clone from repos.json)
  |     +-- Dependency scan (5 scanners -> dep-graph.json)
  |     +-- Database setup (docker containers from db.json)
  |     +-- Launch Claude with --add-dir flags
  |
  +-- Claude Orchestrator Session
        +-- Reads dep-graph.json for cross-repo context
        +-- Reads/writes code across all loaded projects
        +-- Dispatches sub-agents for project-specific tasks
        +-- Executes tests via docker compose run
```

Claude runs on the host (preserving all plugins, MCP servers, and hooks). Docker containers are used only for executing environment-specific commands (tests, builds, linting).

## Integration: reqbot-slack

mra integrates with [reqbot-slack](reqbot-slack/) to provide technical context during requirement intake conversations.

### How it works

1. `mra export` generates static context files per project
2. reqbot-slack reads these files when building prompts for Claude
3. When a user mentions "ERP 訂單" in Slack, reqbot detects the relevant project and injects its technical context
4. reqbot can also call `mra ask` for on-demand technical queries

### Setup

```bash
# In reqbot-slack .env:
MRA_WORKSPACE_PATH=/Users/you/OneAD
# MRA_BIN_PATH=/Users/you/multi-repo-agent/bin/mra.sh  (optional, auto-detected)
```

### Available functions (from mra-client.ts)

```typescript
import { askMra, readProjectContext, getProjectDeps } from "./claude/mra-client.js";

// Query codebase (calls mra ask)
const result = await askMra("erp", "列出 order 相關的 API");

// Read pre-exported context
const context = readProjectContext("erp");  // 17KB of routes, schema, deps

// Get dependency info
const deps = getProjectDeps("erp");
// { deps: ["mysql", "redis"], consumedBy: ["partner-api-gateway"] }
```

## Project Structure

```
~/multi-repo-agent/
+-- install.sh              # Installation script
+-- config.json             # Global settings
+-- bin/
|   +-- mra.sh              # Main CLI entry point
+-- lib/
|   +-- alias.sh            # Workspace alias management
|   +-- ask.sh              # Codebase query (mra ask)
|   +-- cleanup.sh          # Orphan container/log cleanup
|   +-- colors.sh           # Color output ([tag] format)
|   +-- export.sh           # Project context exporter
|   +-- config.sh           # Configuration read/write
|   +-- db.sh               # Database management
|   +-- deps.sh             # Dependency graph reader
|   +-- detect-type.sh      # Project type detection
|   +-- doctor.sh           # Environment health checks
|   +-- init.sh             # Workspace initialization
|   +-- launch.sh           # Claude launcher
|   +-- preflight.sh        # Tool availability checks
|   +-- repos.sh            # GitHub org repo discovery
|   +-- scan.sh             # Scanner orchestrator
|   +-- sync.sh             # Git pull/clone
|   +-- change-detector.sh     # API change detection matrix
|   +-- docker-exec.sh         # Docker execution helpers
|   +-- integration-test.sh    # Cross-repo integration testing
|   +-- test-runner.sh         # Test execution with isolation
+-- scanners/
|   +-- api-calls.sh        # API host env var scanner
|   +-- docker-compose.sh   # Docker Compose scanner
|   +-- gateway-routes.sh   # API gateway route scanner
|   +-- shared-db.sh        # Shared database scanner
|   +-- shared-packages.sh  # Internal package scanner
+-- agents/
|   +-- orchestrator.md     # Claude orchestrator system prompt
+-- tests/
    +-- test_*.sh           # 10 test suites
```

## Testing

```bash
cd ~/multi-repo-agent
for test in tests/test_*.sh; do bash "$test"; done
```

## Sharing with Teammates

To onboard a new team member:

1. They clone this repo and run `install.sh`
2. Share your `repos.json` and `db.json` files (these are not in `.gitignore`)
3. They place both files in `<workspace>/.collab/`
4. Share database dump files (or provide a download URL in `db.json`)
5. Run `mra init <workspace> --git-org <url>` - it will use the existing config files

## Roadmap

- [x] **Phase 3**: Sub-agent workflow with develop-commit-review-PR loop
- [x] **Phase 4**: Docker container execution with test isolation
- [ ] Open source release
- [ ] Web dashboard for dependency graph visualization
- [ ] Support for `docker exec` into running containers
- [ ] More scanner strategies (GraphQL schema, gRPC proto)

## License

MIT
