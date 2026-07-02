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

**v2.3.0** | 32 CLI commands | 6 AI agents | 9 MCP tools | 35 test suites | 10 TM-tracked security controls

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

### 1b. Branch-Aware Sync & Cross-Repo PRs

Keep many repos on the same feature branch, then ship them together. Every command runs in dependency order and can target a subset of repos.

```bash
mra branch status                 # Repos needing attention (ahead/behind/dirty/PR state)
mra branch new feature/login      # Create the same branch across repos
mra branch pr                     # Push branches + open PRs (deps first)
mra branch merge --wait-ci        # Merge open PRs once CI is green
```

| Command | What it does |
|---------|--------------|
| `mra sync [--safe] [--push] [--review] [--json]` | Clone/pull every repo; `--safe` is ff-only, `--push` pushes, `--review` auto-reviews, `--json` emits per-repo `{repo, action, ok}` |
| `mra branch status [--all] [--fetch] [--json]` | Cross-repo branch overview (default: repos needing attention; `--json`: every repo) |
| `mra branch new\|switch <name>` | Create/switch the same branch across all repos |
| `mra branch pr [--base <ref>] [--dry-run] [repos…]` | Push feature branches and open PRs (deps first; optional `[repos…]` subset) |
| `mra branch merge [--strategy S] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [--dry-run] [repos…]` | Merge open PRs, gated on mergeable + CI; `--wait-ci` polls CI before merging |

`--json` (on `sync` and `branch status`) is designed for piping into other tooling — worker logs go to stderr so stdout stays valid JSON.

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

# Sync & feature branches across repos
mra sync --safe                  # Fast-forward pull every repo
mra branch status                # Which repos need attention
mra branch pr                    # Open PRs across repos (deps first)
mra branch merge --wait-ci       # Merge each PR once its CI is green

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
mra plan my-api "Migrate session tokens to JWT" --dual   # claude + codex council
```

Five domain experts independently propose implementation strategies, then a synthesizer merges them into one unified plan (consolidated files, risk-ranked concerns, execution steps). Output goes to stdout — pipe to a file to save.

With `--dual`, each persona is run through **both** the `claude` and `codex` CLIs and the synthesizer reconciles the two models' proposals (agreements highlighted, disagreements surfaced). Requires the `codex` CLI on `PATH`.

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
<summary><strong>All commands</strong></summary>

### Core

| Command | Description |
|---------|-------------|
| `mra init <path> --git-org <url>` | Initialize workspace |
| `mra scan` | Re-scan dependencies |
| `mra deps [project]` | Display dependency graph |
| `mra status` | Workspace overview |
| `mra diff` | Cross-repo diff summary |
| `mra log [project]` | Operation history |

### Branch & Sync

| Command | Description |
|---------|-------------|
| `mra sync [--safe] [--push] [--review] [--json]` | Clone/pull all repos (`--json`: per-repo `{repo, action, ok}`) |
| `mra branch status [--all] [--fetch] [--json]` | Cross-repo branch overview |
| `mra branch new\|switch <name>` | Create/switch the same branch across repos |
| `mra branch pr [--base <ref>] [--dry-run] [repos…]` | Push branches and open PRs (deps first; optional subset) |
| `mra branch merge [--strategy S] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [--dry-run] [repos…]` | Merge open PRs (mergeable + CI gated) |

### AI & Development

| Command | Description |
|---------|-------------|
| `mra <project...> [--with-deps]` | Launch Claude orchestrator |
| `mra ask <project> "<question>"` | Codebase query |
| `mra export [project]` | Export project context |
| `mra dev <project> "<task>" [--no-pr] [--auto-approve] [--resume] [--dry-run]` | Autonomous headless implement→review→fix→PR loop (single repo; debate+verifier gate) |
| `mra prd [projects…]` | Interactive cross-repo PRD/spec planner — brainstorms FE/BE/data, writes HTML PRD + per-repo specs + a task plan under `.collab/`, opens **no** issues (reads repos as-is; run `mra sync` first for fresh code) |
| `mra prd-issues --req <ID> [--confirm]` | Apply step (operator-run, TTY-gated): open the planned dependency-ordered GitHub issues |
| `mra prd --new <name>` | Greenfield: interactive from-scratch architecture brainstorm → proposes a repo split → writes PRD + specs + task plan + a scaffold plan under `.collab/` (creates nothing) |
| `mra prd-scaffold --req <ID> [--confirm]` | Apply step (operator-run, TTY-gated): `gh repo create` the planned repos + seed + register into the dep-graph; **adopts (with a per-repo [y/N] confirm) any that already exist** rather than failing |

**Greenfield flow** (for brand-new projects): `mra prd --new <name>` → `mra prd-scaffold --req <ID> --confirm` → `mra prd-issues --req <ID> --confirm` → `mra dev <repo> "<task>"`. Requires an already-`mra init`'d workspace (`.collab/dep-graph.json`) and a `ghAccounts` mapping for the org.

### Code Review & Analysis

| Command | Description |
|---------|-------------|
| `mra review <project> [--pr N] [--strategy S] [--base ref] [--personas]` | Code review (add --personas for 5 named experts) |
| `mra plan <project> "<task>" [--model M] [--dual]` | Multi-expert plan (`--dual`: claude + codex council) |
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
| `mra snapshots` | List snapshots |
| `mra rollback <project> [name]` | Restore snapshot |
| `mra trust <project>` | Grant Docker trust for a project |

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
| `mra alias <name> <path>` | Workspace alias |
| `mra template [repos\|db\|deps\|all]` | Generate config templates |
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

**Workspace access policy (secure by default):**

```bash
# Pin the MCP server to specific workspace roots; calls outside the list are rejected.
export MRA_ALLOWED_WORKSPACES="$HOME/workspace:$HOME/sandbox"
```

The server **denies every tool call by default** when `MRA_ALLOWED_WORKSPACES` is unset or empty. Set the variable above to authorize specific workspaces (POSIX paths joined by `:`; on Windows use `;`).

For trusted single-user setups that genuinely want the legacy "any path" behaviour you can opt in explicitly:

```bash
export MRA_MCP_OPEN_MODE=1   # accept any workspace; not recommended
```

`MRA_MCP_OPEN_MODE` must equal the literal string `1`; any other value (including `true`/`yes`) leaves the server in deny mode. A configured allowlist always wins over open mode.

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
| `lint-profile.json` | Selects a lint rule set (`{"profile":"ts-strict"}` or inline `rules`) | Yes |
| `notify.json` | Webhook config | Yes |
| `eval/` | Review evaluation reports | No |

JSON Schemas for `repos.json`, `db.json`, `dep-graph.json`, `manual-deps.json`, and scanner JSONL records live under [`schemas/`](./schemas/). Add `"$schema"` to the top of each `.collab/*.json` to get inline IDE validation. `mra doctor` runs structural checks automatically.

> **⚠ Migration note (lint default changed)**: Earlier versions hardcoded the
> built-in BLOCKER rules in `lib/lint.sh`. Lint is now profile-driven and the
> default profile is empty. To keep the previous behavior, drop a one-line
> file in your workspace:
> ```bash
> echo '{"profile":"ts-strict"}' > <workspace>/.collab/lint-profile.json
> ```

**Lint profiles** ship under [`templates/lint-profiles/`](./templates/lint-profiles/):

| Profile | Use |
|---------|-----|
| `default` | No rules — lint passes silently |
| `ts-strict` | Strict TypeScript BLOCKER rules (no-interface / no-enum / no-any / no-non-null / no-var) |

Opt in by writing `<workspace>/.collab/lint-profile.json`:

```json
{ "profile": "ts-strict" }
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

### Project memory

`mra config project-memory on|off` (default **on**) controls whether each loaded
project's native **CLAUDE.md**, **AGENTS.md**, and **.claude/rules/** load into
the `claude` session mra launches. It does **not** affect Agent Skills
(`.claude/skills/`, already auto-loaded via `--add-dir`) or `settings.local.json`.
The interactive orchestrator uses `--setting-sources user,project`, so a repo's
gitignored `CLAUDE.local.md` is never pulled into the shared cross-repo context.

### Issue creation accounts

`mra config ghAccounts '{"acme":"acme-bot"}'` maps an owner-org to a `gh` login for per-repo issue creation (used by `mra prd-issues`). Without an entry for an owner, the default authenticated account is used.

> **⚠ Do not allowlist `gh` or `mra prd-issues`** in your Claude Code `settings.json`. The `mra prd-issues` create gate relies on an interactive TTY prompt — allowlisting `gh` bypasses that gate and enables unsupervised issue creation.

</details>

<details>
<summary><strong>Security environment variables</strong></summary>

mra ships secure-by-default for the threats listed in
[`multi-repo-agent-threat-model.md`](./multi-repo-agent-threat-model.md).
The flags below relax specific controls; set them only when you understand
what the default was protecting against and have an explicit reason to
override it.

| Variable | Default | What setting it does | Threat |
|---|---|---|---|
| `MRA_ALLOWED_WORKSPACES` | unset → deny all MCP calls | Colon (POSIX) or semicolon (Windows) separated list of workspace roots the MCP server will accept. | TM-002 |
| `MRA_MCP_OPEN_MODE` | unset → deny | Set to literal `1` to re-enable legacy "any workspace path is accepted" behaviour. Any other value (including `true`/`yes`) is ignored. A configured allowlist always wins. | TM-002 |
| `MRA_ROLLBACK_FORCE` | unset → confirm | Set to `1` to skip the y/N prompt before `mra rollback` issues `git reset --hard`. Required for non-interactive rollback (CI / scripts). | TM-009 |
| `MRA_ROLLBACK_IGNORE_INTEGRITY` | unset → verify hash | Set to `1` to skip the SHA-256 check on `.collab/snapshots/snapshots.json`. Use only when you intentionally hand-edited the snapshot file. | TM-009 |
| `MRA_DOCKER_TRUST_FORCE` | unset → prompt on first use | Set to `1` to auto-grant Docker trust for the project being tested/built and record it in `.collab/trusted-projects.json`. Required for CI to run `mra test`. | TM-005 |
| `MRA_ALLOW_LOCAL_ENDPOINTS` | unset → reject | Set to `1` to allow federation/notify URLs that point at loopback / RFC1918 / link-local hosts. Needed for self-hosted webhooks on the same network. | TM-008 |
| `MRA_ALLOW_HTTP` | unset → reject | Set to `1` to allow plaintext `http://` URLs in federation/notify. HTTPS is otherwise required. | TM-008 |
| `MRA_INIT_AUTO_DB` | unset → skip in non-tty | Set to `1` to let `mra init` auto-trigger `setup_all_databases` when stdin is not a terminal. Interactive shells run the setup unconditionally. | TM-004 |
| `MRA_DB_DUMP_MAX_BYTES` | `2147483648` (2 GB) | Maximum size (bytes) for remote DB dump downloads via `mra db setup`. Smaller values protect smaller workstations / CI runners. | TM-004 |
| `MRA_REVIEW_ALLOW_APPROVE` | unset → cap to COMMENT | Set to `1` to let the model's `status: "APPROVED"` actually approve the PR via the GitHub API. Without this, APPROVED is downgraded to a COMMENT review. | TM-007 |

`mra trust <project>` is a convenience command that grants Docker trust
ahead of time without running the gated docker call; useful for
provisioning a CI workspace.

</details>

---

## Roadmap

### Recently Added

- Branch-aware sync & cross-repo PRs (`mra sync`, `mra branch status|new|switch|pr|merge`)
- CI-polling auto-merge (`branch merge --wait-ci [--ci-timeout]`)
- Per-repo subset targeting for `branch pr|merge` (`[repos…]`)
- Machine-readable JSON output (`sync --json`, `branch status --json`)
- Multi-model planning council (`mra plan --dual` — claude + codex)
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
