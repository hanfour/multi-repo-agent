# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet publish tagged releases; changes accumulate under
**Unreleased** until a versioning scheme is adopted.

## [Unreleased]

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
