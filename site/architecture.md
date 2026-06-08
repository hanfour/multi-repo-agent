# Architecture

mra is a pure bash CLI with zero runtime dependencies beyond `jq`, `git`, `docker`, and `gh`.

## Components

```
mra CLI (bin/mra.sh)
  |
  +-- Workspace Manager
  |     Repo sync, dependency scan, database setup
  |
  +-- Project Knowledge Base (PKB)
  |     L0-L3 memory stack, auto-classification tags,
  |     tunnel linking, mtime-based incremental updates
  |
  +-- Code Review Engine
  |     Auto-strategy selection, mailbox voting debate,
  |     persona-based review, write-protected agents,
  |     model tiering, eval framework
  |
  +-- Claude Orchestrator
  |     Multi-repo context, PM/sub/reviewer dispatch,
  |     Docker test execution, API change detection
  |
  +-- Integrations
        MCP server (9 tools), GitHub Actions, Federation, Slack/Discord
```

## Data flow — `mra review --pr 123`

1. Resolve PR base ref via `gh pr view`
2. Collect diff + changed files
3. Load PKB context for the project (if generated)
4. Detect API change via `lib/change-detector.sh`
5. Select strategy based on diff size + API change
6. Dispatch agent(s) in parallel with `claude -p`
7. Synthesiser produces JSON — status, summary, inline comments
8. Post to GitHub PR via `gh api`
9. Fire `_review_pkb_auto_update` in background to refresh PKB

## Safety primitives

- All review agents run with `--disallowedTools "Write,Edit,NotebookEdit"`
- Heredoc injection blocked via `<<'TEMPLATE'` + parameter substitution
- Stderr retained on worker failure for operator inspection
- Arg validation runs before workspace resolution — usage prints outside workspaces
- Snapshots before destructive operations; `mra rollback` to restore
