# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Breaking
- **BREAKING** lint profile `oneAD` renamed to `ts-strict`; update any `.collab/lint-profile.json` using `{"profile":"oneAD"}` to `{"profile":"ts-strict"}`.

### Added
- feat(launch): load each project's CLAUDE.md/AGENTS.md/.claude/rules natively
  (`mra config project-memory on|off`, default on); interactive launch now scopes
  settings to `user,project` to avoid cross-project CLAUDE.local.md leakage.

### Fixed
- `log_error` now writes to stderr; error messages from functions that return
  values via stdout (e.g. `resolve_project_dir`) were silently swallowed by
  command substitution.
- Default `mra sync` pulls with `--ff-only`: a diverged default branch now
  fails loudly instead of silently creating a merge commit (behaviour
  previously depended on the user's `pull.rebase` config).
- Rollback is fail-safe: a failed stash aborts before the destructive
  `git reset --hard`, and `mra rollback --all` finishes the whole batch,
  names the failed projects, and exits non-zero instead of stopping silently
  at the first failure.
- Repo list in `mra init` interactive setup is now actually sorted by name
  (the previous jq filter errored into a silenced fallback).
- `mra config output-language` accepts values containing quotes, and config
  setters clean up their temp file when jq rejects a value.
- PKB age calculation: timestamps are parsed as UTC (previously off by the
  local timezone offset on macOS) with a GNU `date` fallback so PKB freshness
  works on Linux.

### Security
- Every user-facing `<project>` argument (`review`, `plan`, `analyze`,
  `test-audit`, `eval-review`, `rollback`, and the default project-load
  command) is now validated through `resolve_project_dir` — lexical
  allowlist + realpath containment — closing path-traversal and
  symlink-escape gaps (TM-001).
- The MCP server enforces each tool's `inputSchema` server-side
  (required/type/pattern/enum/maxLength) before arguments reach
  `bin/mra.sh`; previously a non-compliant client could bypass the declared
  pattern constraints. `mra_ask` questions are capped at 4096 characters.
- `npm audit fix` for transitive `fast-uri` and `path-to-regexp` advisories
  in the MCP server's dependency tree.

## [2.3.0] - 2026-06-12

### Added
- **Branch-aware sync & review suite** for working across many repos on feature branches:
  - `mra branch status [--all] [--fetch] [--json]` — cross-repo branch overview; `--json`
    emits a machine-readable array of every repo's state.
  - `mra branch new|switch|pr|merge [repos…]` — cross-repo branch lifecycle, with an
    optional `[repos…]` subset; `branch merge` gates on mergeable + CI and supports
    `--wait-ci [--ci-timeout <sec>]` to poll CI before merging.
  - `mra sync [--safe|--push|--review] [--dry-run] [--json]` — branch-aware sync; `--json`
    emits per-repo `{repo, action, ok}` results for the sync/push modes.
  - `mra review <repo> [--working|--range|--head|--pr] [--personas|--strategy …]` —
    code review of working-tree changes, ranges, or PRs.
- **Multi-model planning council** — `mra plan <project> "<task>" [--dual]`. With `--dual`,
  each persona runs on both `claude` and `codex` and the synthesizer marks cross-model
  agreement vs. disagreement. New `lib/model-provider.sh` provider abstraction.
- Standard open-source project files: `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, and this changelog.

### Changed
- Internal/company-specific references in shipped agents, scanners, examples, and configs
  were genericized (neutral placeholders such as `your-org` / `@scope/`), and the
  `shared-packages` scanner now detects any private/scoped dependency rather than a
  hard-coded org.

### Security
- Removed confidential design documents that did not belong to this tool from the
  repository **and its git history**.

[Unreleased]: https://github.com/hanfour/multi-repo-agent/commits/main
[2.3.0]: https://github.com/hanfour/multi-repo-agent/commits/main
