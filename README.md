<p align="center">
  <h1 align="center">multi-repo-agent (mra)</h1>
  <p align="center">
    <strong>AI-powered development across multiple repositories — from a single terminal.</strong>
  </p>
  <p align="center">
    <a href="https://hanfour.github.io/multi-repo-agent/">📖 Documentation Site</a>
  </p>
  <p align="center">
    <a href="./README.md">English</a> |
    <a href="./docs/README.zh-TW.md">繁體中文</a> |
    <a href="./docs/README.ja.md">日本語</a> |
    <a href="./docs/README.ko.md">한국어</a>
  </p>
</p>

---

> Change an API in repo A. mra automatically finds every downstream consumer in repos B, C, D — reviews the impact, updates the code, and opens the PRs. All from one command.

**v2.2.0** | 31 CLI commands | 6 AI agents | 9 MCP tools | 24 test suites

---

## Why mra?

Modern software lives across many repos. One API change can silently break three frontends. Claude Code only sees one directory at a time.

**mra bridges that gap.**

| Without mra | With mra |
|---|---|
| Manually check which repos consume your API | `mra scan` auto-detects cross-repo dependencies |
| Open separate Claude sessions per repo | `mra my-api --with-deps` loads all related repos |
| Hope the reviewer catches breaking changes | `mra review --pr 123` finds `consumer:42` still references the old field |
| Re-explain project context every session | PKB caches project knowledge — agents wake up in ~50 tokens |
| Guess if your review is any good | `mra eval-review` measures precision/recall vs human reviews |

---

## Quick Start

```bash
# Install
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
```

> Full docs: https://hanfour.github.io/multi-repo-agent/

```bash
# Initialize workspace
mra init ~/workspace --git-org git@github.com:my-org

# Verify setup
mra doctor

# Start developing across repos
mra my-api --with-deps
```

---

## Core Features

### 1. Cross-Repo Orchestration

Launch Claude with full visibility into multiple repos and their dependencies.

```bash
mra my-api --with-deps       # Loads my-api + all consumers/dependencies
mra my-api frontend-app      # Load specific repos together
mra --all                    # Load everything
```

The orchestrator dispatches sub-agents per repo, coordinates changes in dependency order, and runs code review after each commit.

### 2. AI Code Review with Debate

Three review strategies auto-selected by diff size:

| Strategy | When | How |
|----------|------|-----|
| **Light** | <50 lines, ≤3 files | Single pass, 2 turns (~15s) |
| **Standard** | <300 lines | Single pass, 3 turns (~30s) |
| **Debate** | Large diffs or API changes | 2 analysts + voting + synthesis (~3min) |

```bash
mra review my-api              # Terminal output (auto-selects strategy)
mra review my-api --pr 123     # Post inline comments on GitHub PR
mra review my-api --strategy debate  # Force thorough review
```

**Debate mode** uses adversarial multi-agent review:

```
Round 1: Two agents independently search the codebase
  Agent A (Impact) → broken references, dead code, API breaks
  Agent B (Quality) → security, patterns, type safety

Round 2: Mailbox voting
  All findings merged → each agent votes KEEP/DROP with evidence
  → Only evidence-backed findings survive

Final: Synthesizer produces structured inline review
```

All review agents are **write-protected** (`--disallowedTools "Write,Edit"`) — they can only read.

### 2b. Persona-Based Review (opt-in)

For PRs where generic Impact/Quality analysis isn't enough, run five named domain experts in parallel:

```bash
mra review my-api --personas          # Use 5 named domain experts
mra review my-api --pr 123 --personas # PR review with personas
```

| Persona | Focus |
|---------|-------|
| `security-auditor` | Secrets, injection, auth, deserialization (Troy Hunt style) |
| `api-contract-guardian` | Cross-repo signature drift, response shape changes |
| `performance-hawk` | N+1 queries, hot-path I/O, bundle bloat (Vercel style) |
| `refactoring-sage` | Code smells, naming, cohesion (Martin Fowler style) |
| `test-architect` | Kent Beck 11 principles |

Each persona has a focused lens and writes to the same severity ladder (CRITICAL/HIGH/MEDIUM). Findings are merged and synthesised into the same JSON the debate path produces — PR inline comments work identically.

Add your own by dropping a markdown file in `agents/personas/`. See `agents/personas/README.md`.

### 3. Project Knowledge Base (PKB)

Instead of re-reading the entire codebase every session, PKB distills project knowledge into reusable documents.

```bash
mra analyze my-api    # One-time: 4 agents scan project in parallel
```

Generates:

| Document | Content |
|----------|---------|
| `identity.md` | Project name, type, one-line purpose (~50 tokens) |
| `sitemap.md` | File tree + module purpose index |
| `architecture.md` | Patterns, data flow, tech stack |
| `conventions.md` | Coding style with `[CONVENTION]`/`[PATTERN]`/`[DECISION]` tags |
| `api-surface.md` | Endpoints, exports, event contracts |
| `tunnels.md` | Cross-module entity references (auto-detected) |
| `modules/*.md` | Per-module deep summaries |

**4-Layer Memory Stack** (inspired by [mempalace](https://github.com/milla-jovovich/mempalace)):

| Layer | Content | Tokens | When loaded |
|-------|---------|--------|-------------|
| L0: Identity | Name + type + purpose | ~50 | Always |
| L1: Essential | Tagged conventions + patterns | ~200 | Always |
| L2: Room Recall | Sitemap + architecture + relevant modules | ~500 | On review/ask |
| L3: Deep Search | Full API surface + all modules | ~800+ | On orchestrator launch |

**Result**: Review wake-up cost drops from ~150K tokens to ~250 tokens.

PKB auto-updates after each review (background, non-blocking) and uses **mtime detection** to skip unchanged modules.

### 4. Cross-Repo Dependency Detection

Five built-in scanners + custom plugins:

| Scanner | Detects | Confidence |
|---------|---------|------------|
| `docker-compose` | Service relationships | High |
| `shared-db` | Projects sharing databases | High |
| `gateway-routes` | API gateway routing | Medium |
| `shared-packages` | Internal npm/gem packages | High |
| `api-calls` | Env var API host references | Low |

```bash
mra scan                 # Auto-detect dependencies
mra deps my-api          # Show dependency tree
mra graph --mermaid      # Visual dependency graph
```

### 5. Review Quality Evaluation

Measure review accuracy against human reviewers:

```bash
mra eval-review my-api --pr 123
```

Compares MRA findings vs human reviews on the same PR:
- **Precision** — what % of MRA findings are real issues?
- **Recall** — what % of human findings did MRA catch?
- **F1 Score** — balanced quality metric

Reports saved to `.collab/eval/` for trend tracking.

### 6. Docker Environments & Testing

```bash
mra db setup                     # Start DB containers + import dumps
mra test my-api                  # Auto-detect test strategy
mra test my-api --integration    # Full integration test
mra watch my-api                 # Auto-test on file change
```

---

## Tutorials

### First-Time Setup

<details>
<summary><strong>Step-by-step workspace initialization</strong></summary>

#### 1. Prerequisites

| Tool | Install |
|------|---------|
| `git` | Pre-installed on macOS |
| `docker` | [Docker Desktop](https://docker.com) or [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` then `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

Optional: `yq` (`brew install yq`), `fswatch` (`brew install fswatch`)

#### 2. Initialize workspace

```bash
gh auth login                    # Switch to org account if needed
mra init ~/workspace --git-org git@github.com:my-org
```

This clones repos, scans docker-compose files, detects dependencies, and creates workspace aliases.

#### 3. Setup databases

```bash
mkdir -p ~/workspace/dumps
cp /path/to/myapp_db.sql.bz2 ~/workspace/dumps/
mra db setup
```

db.json format:

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
          "usedBy": ["my-api", "backend-api"]
        }
      }
    }
  }
}
```

Supported formats: `.sql`, `.sql.gz`, `.sql.bz2`, `.sql.xz`, `.sql.zst`, `.dump` | Engines: `mysql`, `postgres`

#### 4. Verify and snapshot

```bash
mra doctor                       # Health check
mra snapshot "initial-setup"     # Safety checkpoint
```

</details>

### Daily Development

<details>
<summary><strong>Common workflows and commands</strong></summary>

```bash
# Morning check
mra status                       # All projects overview
mra diff                         # Uncommitted/unpushed changes
mra dashboard                    # Interactive TUI

# Cross-project development
mra my-api --with-deps           # Launch orchestrator
# Give Claude a task:
# > "Modify order API to return items instead of data, sync consumers"

# Quick queries (no interactive session)
mra ask my-api "list all order-related API endpoints"
mra ask my-api --with-deps "API dependencies between my-api and frontend"

# Code quality
mra lint frontend-app            # Check BLOCKER rules
mra lint --all                   # All frontend projects

# Before pushing
mra snapshot "before-push"
mra review my-api --pr 123       # Inline PR review

# Something broke?
mra rollback my-api              # Restore to latest snapshot
```

#### Multi-Expert Planning

```bash
mra plan my-api "Migrate session tokens to JWT"
```

Five domain experts independently propose implementation strategies, then a synthesizer merges them into one unified plan (consolidated files, risk-ranked concerns, execution steps). Output goes to stdout — pipe to a file to save.

#### Test Quality Audit

```bash
mra test-audit frontend-app        # Kent Beck 11-principles audit of all test files
MRA_AUDIT_PARALLEL=3 mra test-audit frontend-app  # Cap concurrent audits
```

Discovers `*.test.*`, `*_test.*`, `*.spec.*` files (excluding `node_modules`, `dist`, `build`, `vendor`, `.git`) and audits each against Kent Beck's 11 testing principles via the `test-architect` persona.

</details>

### Code Review

<details>
<summary><strong>Local review, PR inline comments, CI automation</strong></summary>

```bash
# Local terminal review
mra review my-api                         # Auto-selects strategy
mra review my-api --base development      # Against specific branch
mra review my-api --strategy debate       # Force thorough review

# GitHub PR inline review
mra review my-api --pr 123               # Posts inline comments
mra review my-api --pr 123 --model opus  # Use stronger model

# Automated CI review
mra ci my-api --with-review              # Generate GitHub Actions workflow
```

Add `ANTHROPIC_API_KEY` to repo secrets. The workflow triggers on every PR, posts inline comments, and updates on subsequent pushes.

**Token optimization strategies:**
- PKB integration (knowledge docs vs full codebase)
- Model tiering (haiku for voting, sonnet for analysis)
- Focused context (only load changed-file directories)
- Findings compression (summary-only in later rounds)

</details>

### Project Knowledge Base

<details>
<summary><strong>Generate, use, and maintain project knowledge</strong></summary>

```bash
# Generate PKB (one-time investment)
mra analyze my-api
mra analyze my-api --model haiku    # Cheaper for module summaries

# PKB is auto-used by all commands
mra review my-api --pr 123          # Uses PKB context
mra my-api --with-deps              # Orchestrator gets full PKB
mra ask my-api "how does auth work?"  # Standard tier PKB
```

After every review, PKB auto-updates:
- Changed modules get updated summaries (background, haiku)
- New files update the sitemap
- CRITICAL/HIGH findings get captured as `[DECISION]` tags in conventions.md
- Tunnel links regenerated for cross-module references

Falls back to full codebase loading if no PKB exists.

</details>

### Onboarding a Teammate

<details>
<summary><strong>Share workspace config with new team members</strong></summary>

Share these files from `<workspace>/.collab/`:

| File | Required |
|------|----------|
| `repos.json` | Yes |
| `db.json` | Yes |
| `manual-deps.json` | Optional |
| SQL dump files | Yes |

New member steps:

```bash
git clone <mra-repo> ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
gh auth login

mkdir -p ~/workspace/.collab ~/workspace/dumps
cp /from/teammate/repos.json ~/workspace/.collab/
cp /from/teammate/db.json ~/workspace/.collab/
cp /from/teammate/*.sql.bz2 ~/workspace/dumps/

mra init ~/workspace --git-org git@github.com:my-org
mra db setup
mra doctor
```

Generate templates: `mra template`

</details>

---

## Command Reference

<details>
<summary><strong>All 28 commands</strong></summary>

### Core

| Command | Description |
|---------|-------------|
| `mra init <path> --git-org <url>` | Initialize workspace |
| `mra scan` | Re-scan dependencies |
| `mra deps [project]` | Display dependency graph |
| `mra status` | Workspace overview |
| `mra diff` | Cross-repo diff summary |
| `mra log [project]` | Operation history |

### AI & Development

| Command | Description |
|---------|-------------|
| `mra <project...> [--with-deps]` | Launch Claude orchestrator |
| `mra ask <project> "<question>"` | Codebase query |
| `mra export [project]` | Export project context |

### Code Review & Analysis

| Command | Description |
|---------|-------------|
| `mra review <project> [--pr N] [--strategy S] [--base ref] [--personas]` | Code review (add --personas for 5 named experts) |
| `mra plan <project> "<task>" [--model M]` | Multi-expert implementation plan |
| `mra test-audit <project> [--model M]` | Kent Beck 11-principles test audit |
| `mra analyze <project> [--model M]` | Generate PKB |
| `mra eval-review <project> --pr N [--baseline file]` | Evaluate review quality |

### Docker & Testing

| Command | Description |
|---------|-------------|
| `mra db setup\|status\|import` | Database management |
| `mra test <project> [--integration\|--mock]` | Run tests |
| `mra setup <project\|--all>` | Install dependencies |
| `mra watch <project>` | Auto-test on change |

### Quality & Safety

| Command | Description |
|---------|-------------|
| `mra doctor` | Health check |
| `mra lint <project\|--all>` | JS/TS BLOCKER rules |
| `mra cost [--reset]` | API usage tracking |
| `mra snapshot [name]` | Create checkpoint |
| `mra rollback <project> [name]` | Restore snapshot |

### CI/CD & Collaboration

| Command | Description |
|---------|-------------|
| `mra ci <project> [--with-review]` | Generate GitHub Actions |
| `mra federation publish\|subscribe\|verify` | Cross-team contracts |
| `mra notify setup\|test` | Webhook notifications |

### Utilities

| Command | Description |
|---------|-------------|
| `mra graph [--mermaid\|--dot]` | Dependency visualization |
| `mra dashboard` | Interactive TUI |
| `mra open <project>` | Open in IDE |
| `mra config <key> <value>` | Settings |
| `mra clean` | Cleanup |

</details>

---

## AI Agent Team

| Agent | Role |
|-------|------|
| **Orchestrator** | Coordinates cross-project changes, dispatches sub-agents |
| **PM Agent** | Requirement analysis, task decomposition |
| **Sub-Agent** | Writes code, runs tests, commits per project |
| **Code Reviewer** | Reviews diffs for correctness, security, API consistency |
| **PR Reviewer** | Reviews entire PR with cross-project context |
| **PKB Analyzer** | Deep project analysis, generates knowledge documents |

### Debate Review Agents

| Agent | Model | Role |
|-------|-------|------|
| Impact Analyst | sonnet | Search for broken references, dead code |
| Quality Auditor | sonnet | Check patterns, security, type safety |
| Voter A/B | haiku | Vote KEEP/DROP on findings pool |
| Synthesizer | sonnet | Merge surviving findings into JSON |

All review agents are **read-only** (write tools disabled).

---

## Architecture

```
mra CLI (pure shell, zero runtime deps beyond jq/git/docker/gh)
  |
  +-- Workspace Manager
  |     Repo sync, dependency scan (5 scanners), database setup
  |
  +-- Project Knowledge Base (PKB)
  |     L0-L3 memory stack, auto-classification tags,
  |     tunnel linking, mtime-based incremental updates
  |
  +-- Code Review Engine
  |     Auto-strategy selection, mailbox voting debate,
  |     write-protected agents, model tiering, eval framework
  |
  +-- Claude Orchestrator
  |     Multi-repo context, PM/sub/reviewer dispatch,
  |     Docker test execution, API change detection
  |
  +-- Integrations
        MCP server (9 tools), GitHub Actions, Federation, Slack/Discord
```

---

## Integrations

<details>
<summary><strong>MCP Server, GitHub Actions, Federation, Notifications</strong></summary>

### MCP Server

```bash
cd ~/multi-repo-agent/mcp-server && npm install && npm run build
claude mcp add mra node ~/multi-repo-agent/mcp-server/dist/index.js
```

9 tools: `mra_status`, `mra_deps`, `mra_ask`, `mra_export`, `mra_diff`, `mra_doctor`, `mra_graph`, `mra_scan`, `mra_test`

**Restrict workspace access (recommended for shared machines):**

```bash
# Pin the MCP server to specific workspace roots; calls outside the list are rejected.
export MRA_ALLOWED_WORKSPACES="$HOME/workspace:$HOME/sandbox"
```

When unset, any path is accepted (open mode); the server logs a warning at startup so you remember to lock it down.

### GitHub Actions

```bash
mra ci my-api --with-review    # Generates CI + review workflows
```

### Federation

```bash
mra federation publish my-api              # Publish API contract
mra federation subscribe https://url.json  # Subscribe
mra federation verify                      # Check compatibility
```

### Notifications

```bash
mra notify setup    # Create webhook config (Slack/Discord)
mra notify test     # Send test notification
```

</details>

---

## Configuration

<details>
<summary><strong>Workspace and global settings</strong></summary>

All workspace config lives in `<workspace>/.collab/`:

| File | Purpose | Shareable |
|------|---------|-----------|
| `repos.json` | Which repos to clone | Yes |
| `db.json` | Database configuration | Yes |
| `dep-graph.json` | Auto-generated dependency graph | No |
| `manual-deps.json` | Manual dependency overrides | Yes |
| `lint-profile.json` | Selects a lint rule set (`{"profile":"oneAD"}` or inline `rules`) | Yes |
| `notify.json` | Webhook config | Yes |
| `eval/` | Review evaluation reports | No |

JSON Schemas for `repos.json`, `db.json`, `dep-graph.json`, `manual-deps.json`, and scanner JSONL records live under [`schemas/`](./schemas/). Add `"$schema"` to the top of each `.collab/*.json` to get inline IDE validation. `mra doctor` runs structural checks automatically.

**Lint profiles** ship under [`templates/lint-profiles/`](./templates/lint-profiles/):

| Profile | Use |
|---------|-----|
| `default` | No rules — lint passes silently |
| `oneAD` | OneAD frontend BLOCKER rules (no-interface / no-enum / no-any / no-non-null / no-var) |

Opt in by writing `<workspace>/.collab/lint-profile.json`:

```json
{ "profile": "oneAD" }
```

Or inline custom rules (each with `id`, `severity`, `pattern`, `message`, `line_excludes`, `file_excludes`):

```json
{ "rules": [{ "id": "no-todo", "severity": "warn", "pattern": "TODO", "message": "TODO left in code", "line_excludes": [], "file_excludes": [] }] }
```

Global config: `~/multi-repo-agent/config.json`

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "outputLanguage": "繁體中文台灣用語",
  "subAgentWorkflow": { "reviewLoopMax": 3, "autoCommit": true, "autoPR": true }
}
```

</details>

---

## Roadmap

### Recently Added

- Auto-strategy review (light/standard/debate)
- Mailbox voting debate system
- Project Knowledge Base with L0-L3 memory stack
- Auto-classification tags (`[CONVENTION]`/`[PATTERN]`/`[DECISION]`)
- Cross-module tunnel linking
- mtime-based incremental PKB updates
- Review eval framework (precision/recall/F1)
- Write-protected review agents
- Decision auto-capture from reviews

### Future

- Playwright E2E test integration
- Web dashboard (browser-based dependency graph)
- PKB semantic search (embedding-based retrieval)
- Cross-repo PKB linking (shared type contracts)
- Eval trend dashboard

---

## Development

```bash
make test         # run all shell tests under tests/ + mcp-server node tests
make build        # tsc-build the mcp-server
make lint         # shellcheck (warnings only) over lib/, bin/, scanners/, tests/, test.sh
```

`bash test.sh` is the same entry point as `make test` and is what CI runs (see `.github/workflows/repo-tests.yml`).

## License

MIT
