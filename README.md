# multi-repo-agent (mra)

Cross-repository collaboration tool for Claude Code. Orchestrate AI-assisted development across multiple Git repos with automatic dependency detection, Docker-based environments, and structured review workflows.

**v2.2.0** | 93 files | 20 test suites | 28 CLI commands | 9 MCP tools | 5 AI agents

---

## Table of Contents

- [Problem](#problem)
- [Quick Start](#quick-start)
- [Requirements](#requirements)
- [Installation](#installation)
- [Tutorial: First-Time Setup](#tutorial-first-time-setup)
- [Tutorial: Daily Development](#tutorial-daily-development)
- [Tutorial: Code Review](#tutorial-code-review)
- [Tutorial: Project Knowledge Base](#tutorial-project-knowledge-base)
- [Tutorial: Review Quality Evaluation](#tutorial-review-quality-evaluation)
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

## Tutorial: Code Review

mra provides context-aware code review with **automatic strategy selection**, **Project Knowledge Base (PKB)** support, and an **adversarial multi-agent debate** system with mailbox voting.

### Auto-strategy: right level of review for every PR

mra automatically selects a review strategy based on diff size, file count, and API change detection:

| Strategy | Criteria | Agents | Typical tokens |
|----------|----------|--------|---------------|
| **light** | <50 diff lines, ≤3 files, no API change | 1 reviewer, 2 turns | 30K–60K |
| **standard** | <300 diff lines, no API change | 1 reviewer, 3 turns | 50K–150K |
| **debate** | ≥300 lines or API change detected | 2 analysts + voter + synthesizer | 100K–300K |

You can override with `--strategy light|standard|debate` or `--no-debate`.

### How debate review works

```
Round 1: Independent Analysis (parallel)
  Agent A (Impact Analyst)  → grep/read to find broken references, dead code
  Agent B (Quality Auditor) → check patterns, security, edge cases, type safety
  ↓
  Fast convergence: 0 findings → APPROVED instantly
                    ≤5 findings → skip debate, direct synthesis

Round 2: Mailbox Voting (parallel)
  All findings merged into numbered pool (deduplicated)
  Agent A votes KEEP/DROP on each finding (with evidence)
  Agent B votes KEEP/DROP on each finding (with evidence)
  → Findings with net positive votes survive

Final: Synthesizer merges surviving findings → inline review JSON
```

### Token optimization

Review agents use several strategies to minimize token consumption:

- **PKB integration**: If a Project Knowledge Base exists (`mra analyze`), agents use distilled knowledge instead of loading the full codebase
- **Tiered PKB loading**: Critique agents get `minimal` tier (conventions only), review agents get `standard` tier
- **Focused context**: Non-search agents only load directories containing changed files
- **Model tiering**: Voting agents use `haiku` (3x cheaper), analysis agents use `sonnet`
- **Findings compression**: Round 3+ uses summary-only findings (OpenHarness-inspired micro-compaction)
- **Write protection**: All review agents run with `--disallowedTools "Write,Edit,NotebookEdit"`

### Local review (terminal output)

```bash
# Review current branch vs main (auto-selects strategy)
mra review my-api

# Review against a specific branch
mra review my-api --base development

# Force a specific strategy
mra review my-api --strategy light
mra review my-api --strategy debate

# Quick single-pass review (same as --strategy standard)
mra review my-api --no-debate
```

### Inline PR review (posts comments on GitHub)

```bash
# Review PR #123 — inline comments on specific code lines + summary
mra review my-api --pr 123

# With specific base branch
mra review my-api --pr 123 --base development

# Use a different model
mra review my-api --pr 123 --model opus

# Force debate for thorough review
mra review my-api --pr 123 --strategy debate
```

This will:
1. Auto-select strategy based on diff size and API change detection
2. Load PKB context if available (or fall back to full codebase)
3. Run analysis agents (1 for light/standard, 2 for debate)
4. Debate mode: merge findings → mailbox voting → filter by evidence
5. Post inline comments on exact lines with issues + summary on the PR
6. Trigger background PKB update for changed modules

Example inline comment:

> **[CRITICAL]** `app/serializers/order.rb:15` — Field renamed from `data` to `items`, but `api-consumer/src/services/order.ts:42` still references `response.data`. This is a breaking change.

### Strategy comparison

| | Light | Standard | Debate |
|---|---|---|---|
| Agents | 1 reviewer | 1 reviewer | 2 analysts + 2 voters + synthesizer |
| Method | Read diff only | Read diff + source files | Search codebase → vote → verify |
| Quality | Surface-level | Good for most PRs | Highest — evidence-backed findings |
| Speed | ~15 seconds | ~30 seconds | 2-4 minutes |
| Tokens | 30K-60K | 50K-150K | 100K-300K |
| Use when | Typos, docs, config | Most daily PRs | Merging to main, API changes |

### Automated review in CI

Generate a GitHub Actions workflow that runs review on every PR:

```bash
# Single project
mra ci my-api --with-review

# All projects
for proj in $(jq -r '.projects | keys[]' .collab/dep-graph.json); do
  mra ci "$proj" --with-review
done
```

Then add `ANTHROPIC_API_KEY` to each repo's GitHub Settings > Secrets and variables > Actions.

The CI workflow:
- Triggers on PR open/sync/reopen
- Clones consumer repos automatically
- Posts inline review comments
- Updates the same comment on subsequent pushes (no spam)
- Cancels previous runs on new pushes

### Configure review language

```bash
# Reviews will use this language for all output
mra config output-language "繁體中文台灣用語"

# Or English
mra config output-language "English"
```

---

## Tutorial: Project Knowledge Base

The **Project Knowledge Base (PKB)** is a cumulative knowledge system that distills project understanding into reusable documents. Instead of re-reading the entire codebase on every review or development session, agents use the PKB as their primary context — dramatically reducing token usage.

### How it works

```
First time:  mra analyze my-api  →  4 agents scan project in parallel
                                     → sitemap.md, architecture.md, conventions.md, api-surface.md
                                     → Per-module summaries (auth.md, users.md, ...)

Every review: PKB context injected instead of --add-dir full project
              → Agents understand project from ~500 lines of knowledge docs
              → Only read source files when verifying specific findings

After review: Background update of affected module summaries (haiku, non-blocking)
```

### Generate PKB for a project

```bash
# Full analysis (4 parallel agents + module summaries)
mra analyze my-api

# Use a cheaper model for module summaries
mra analyze my-api --model haiku
```

This creates `<project>/.mra/pkb/` with:

| File | Content | Size |
|------|---------|------|
| `sitemap.md` | File tree + module purpose index | ~100 lines |
| `architecture.md` | Patterns, data flow, tech stack | ~150 lines |
| `conventions.md` | Coding style, naming, tooling | ~120 lines |
| `api-surface.md` | Endpoints, exports, event contracts | ~100 lines |
| `modules/*.md` | Per-module deep summaries | ~50 lines each |
| `meta.json` | Version, timestamps, commit hash | metadata |

### PKB tier system

Not every agent needs all knowledge. PKB loads in tiers to save tokens:

| Tier | Includes | Tokens | Used by |
|------|----------|--------|---------|
| `minimal` | sitemap + conventions | ~200-400 | Voting/critique agents |
| `standard` | + architecture + api-surface | ~500-800 | Review, ask |
| `full` | + all module summaries | ~800-1500 | Orchestrator (mra launch) |

### Token savings with PKB

| Scenario | Without PKB | With PKB | Savings |
|----------|------------|----------|---------|
| Standard review | 50K-150K | 15K-40K | **~70%** |
| Debate review | 300K-600K | 80K-200K | **~65%** |
| mra launch/ask | Re-reads codebase | Uses cached knowledge | **~60%** |

### Auto-update after review

After every review, mra automatically updates the PKB in the background:
- Identifies which modules were affected by the diff
- Updates only those module summaries (using haiku for cost efficiency)
- Updates sitemap if new files were added

### Integration with other commands

PKB is automatically used by all agent-facing commands when available:

```bash
mra review my-api --pr 123   # Uses PKB for review context
mra my-api --with-deps        # Orchestrator gets full PKB
mra ask my-api "how does auth work?"  # Standard tier PKB
```

If no PKB exists, all commands fall back to the original behavior (loading full codebase).

---

## Tutorial: Review Quality Evaluation

`mra eval-review` measures how well the automated review performs compared to human reviewers.

### Run an evaluation

```bash
# Compare MRA review against human reviews on a PR
mra eval-review my-api --pr 123

# Specify base branch
mra eval-review my-api --pr 123 --base development

# Force a specific strategy for comparison
mra eval-review my-api --pr 123 --strategy debate

# Use a custom baseline file
mra eval-review my-api --pr 123 --baseline human-review.json
```

### How it works

1. **Collect baseline**: Fetches human review comments from the GitHub PR (excludes bot/MRA comments)
2. **Run MRA review**: Executes a fresh review and captures the JSON output
3. **Compare**: Uses LLM-assisted semantic matching to pair MRA findings with human findings
4. **Report**: Calculates Precision, Recall, and F1 Score

### Metrics explained

| Metric | Formula | Meaning |
|--------|---------|---------|
| **Precision** | true_positives / total_mra_findings | What % of MRA findings are real issues? |
| **Recall** | caught / total_human_findings | What % of human findings did MRA catch? |
| **F1 Score** | 2 × precision × recall / (precision + recall) | Balanced quality score |

### Reports

Reports are saved to `<workspace>/.collab/eval/` as JSON files with timestamps, enabling trend tracking over time.

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

### Code Review & Analysis

| Command | Description |
|---------|-------------|
| `mra review <project>` | Auto-strategy review (terminal output) |
| `mra review <project> --pr <N>` | Inline review on GitHub PR (comments on code lines) |
| `mra review <project> --base <ref>` | Review against specific branch |
| `mra review <project> --model <model>` | Use specific Claude model |
| `mra review <project> --strategy <s>` | Force strategy: `light`, `standard`, or `debate` |
| `mra review <project> --no-debate` | Quick single-pass review (same as `--strategy standard`) |
| `mra analyze <project>` | Generate Project Knowledge Base (PKB) |
| `mra analyze <project> --model <model>` | Use specific model for PKB generation |
| `mra eval-review <project> --pr <N>` | Evaluate review quality vs human baseline |
| `mra eval-review <project> --pr <N> --baseline <file>` | Use custom baseline JSON |

### CI/CD & Collaboration

| Command | Description |
|---------|-------------|
| `mra ci <project> [--with-review]` | Generate GitHub Actions workflow (optionally with code review) |
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
| `eval/` | Review evaluation reports | No (auto-generated) |
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
  "outputLanguage": "繁體中文台灣用語",
  "aliases": { "my-org": { "workspace": "~/my-workspace", "gitOrg": "git@github.com:my-org" } },
  "subAgentWorkflow": { "reviewLoopMax": 3, "autoCommit": true, "autoPR": true }
}
```

| Key | Values | Description |
|-----|--------|-------------|
| `autoScan` | `on` / `off` | Auto-scan dependencies on launch |
| `output-language` | any language string | Language for all agent output |
| `parallel-test` | `on` / `off` | Parallel test execution |

---

## AI Agent Team

| Agent | Role | When dispatched |
|-------|------|----------------|
| **orchestrator** | Coordinates cross-project changes, dispatches sub-agents, API change detection | Always active in `mra <project>` session |
| **pm-agent** | Requirement analysis, task decomposition, acceptance validation | User gives vague requirement or asks for impact analysis |
| **sub-agent** | Writes code, runs tests, commits, follows frontend standards | Orchestrator assigns per-project tasks |
| **code-reviewer** | Reviews diffs for correctness, security, API consistency, architecture patterns | After sub-agent commits, or via `mra review` |
| **pr-reviewer** | Reviews entire PR, checks cross-project dependency notes | After PR is created |
| **pkb-analyzer** | Deep project analysis, generates knowledge base documents | Via `mra analyze` |

### Debate review agents (internal)

These agents are spawned during `--strategy debate` reviews:

| Agent | Model | Role | Write access |
|-------|-------|------|-------------|
| **Agent A** (Impact Analyst) | sonnet | Search codebase for broken references, dead code | Read-only |
| **Agent B** (Quality Auditor) | sonnet | Check patterns, security, type safety, conventions | Read-only |
| **Voter A/B** | haiku | Vote KEEP/DROP on merged findings pool | Read-only |
| **Synthesizer** | sonnet | Merge surviving findings into structured JSON | Read-only |

### Code reviewer checks

The code-reviewer agent applies these checks (in addition to standard correctness/security):

- **Architecture**: server data in TanStack Query (not Zustand), store access via hooks, Zod validation for API types
- **Performance**: static data hoisted outside components, appropriate `useMemo` usage
- **Tailwind**: `cn()` for conditional classes, no hardcoded colors, no redundant width/max-width
- **Code smell**: duplicate definitions/imports, nested map/filter → flatMap, test artifacts, unused constants
- **Project conventions**: reads `AGENTS.md` / `CLAUDE.md` / `.claude/rules/` for project-specific rules

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
  +-- Project Knowledge Base (PKB)
  |     +-- mra analyze: 4 parallel agents → sitemap, architecture, conventions, api-surface
  |     +-- Per-module summaries (auto-discovered features/modules)
  |     +-- Tiered loading: minimal/standard/full per agent role
  |     +-- Auto-update after each review (background, non-blocking)
  |     +-- Stored in <project>/.mra/pkb/
  |
  +-- Code Review Engine
  |     +-- Auto-strategy selection (light/standard/debate by diff size)
  |     +-- Debate: Round 1 analysis → Mailbox voting → Synthesis
  |     +-- PKB-aware: uses knowledge docs instead of full codebase when available
  |     +-- Write-protected agents (--disallowedTools Write,Edit)
  |     +-- Model tiering: sonnet for analysis, haiku for voting
  |     +-- Eval framework: precision/recall/F1 vs human baseline
  |
  +-- Claude Orchestrator Session
  |     +-- Reads dep-graph.json + PKB for cross-repo context
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
mra ci my-api                  # generates .github/workflows/mra-test.yml
mra ci my-api --with-review    # also generates .github/workflows/mra-code-review.yml
```

The code review workflow requires `ANTHROPIC_API_KEY` in repo secrets. It triggers on every PR and posts inline comments with cross-repo context.

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
|   +-- review.sh                 # Context-aware code review (auto-strategy + PKB)
|   +-- review-debate.sh          # Multi-agent debate with mailbox voting
|   +-- review-prompt.sh          # Review prompt builder (terminal + JSON modes)
|   +-- pkb.sh                    # Project Knowledge Base engine
|   +-- eval.sh                   # Review quality evaluation framework
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
|   +-- mra-code-review/action.yml # GitHub Action: context-aware PR review
+-- mcp-server/
|   +-- src/index.ts              # MCP server entry
|   +-- src/tools.ts              # 9 MCP tool definitions
|   +-- src/mra-executor.ts       # Shell command executor
+-- templates/
|   +-- github-workflow.yml       # CI test workflow template
|   +-- code-review-workflow.yml  # CI code review workflow template
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

### Recently Added

- [x] Context-aware code review (`mra review` + inline PR comments)
- [x] CI code review workflow (`mra ci --with-review`)
- [x] Configurable output language (`mra config output-language`)
- [x] Improved doctor checks (Docker-based, ActiveRecord detection)
- [x] **Auto-strategy review** — light/standard/debate selected by diff size
- [x] **Mailbox voting** — replaced iterative critique rounds with parallel voting
- [x] **Token optimization** — model tiering, focused context, findings compression
- [x] **Project Knowledge Base** (`mra analyze`) — cumulative project understanding
- [x] **PKB tiered loading** — minimal/standard/full per agent role
- [x] **Review eval framework** (`mra eval-review`) — precision/recall vs human baseline
- [x] **Write-protected review agents** — `--disallowedTools` prevents accidental edits

### Future

- [ ] Playwright E2E test integration
- [ ] Web dashboard (browser-based dependency graph)
- [ ] `docker exec` into running containers
- [ ] More scanners (GraphQL schema, gRPC proto)
- [ ] Multi-language lint rules (Ruby, Go, Python)
- [ ] PKB semantic search (embedding-based module retrieval)
- [ ] Cross-repo PKB linking (shared type contracts)
- [ ] Eval dashboard (trend tracking across PRs)

---

## License

MIT
