# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security
- Review completion sentinel is matched against a **whole line** on every path. `review_verdict_of` (the debate path) used an unanchored substring match while the single-pass and provider paths required a whole line — three rules where `lib/review-verdict.sh` documents one. An agent that quoted the sentinel out of the diff under review and was then cut off by max-turns, never declaring a verdict, therefore read as `APPROVED`; with both debate agents cut off that way `_debate_assess` returned `APPROVE`. No attacker required — reviewing mra's own review code is enough. `tests/test_review_verdict.sh` had been asserting the substring behaviour, which is why the suite stayed green over it (GHSA-vj6f-5fw7-p56f).
- Sentinel token now carries a **per-run nonce** (`MRA-REVIEW-COMPLETE-<8 random bytes>`, minted once per process, overridable so tests can spell it literally). A constant token is fully predictable from this public source, and the text it is matched against is the output of a model that has just read the diff — so a line placed in any reviewed file could reach the verdict parser as a forged approval. Anchoring alone does not close this: once the sentinel must own a line, injected content can supply a line. `lib/review-prompt.sh` also spelled the sentinel literally rather than interpolating the token, so the nonce would never have reached the single-pass prompt (GHSA-5gjm-rqvq-f877).
- `expand_add_dir_string` validates against an **allowlist** instead of a metacharacter blacklist. The blacklist (`;`, `&&`, `||`, backtick, `$(`) missed process substitution — `<(cmd)` executed cmd — as well as parameter expansion, tilde expansion and globbing; it was also too tight, testing the *escaped* string, so a legitimate path containing a backtick or semicolon was refused. Not reachable from any of the 18 call sites, all of which feed `printf %q` output, but a stated guarantee that does not hold is worse than none. Paths containing control characters now fail closed rather than being evaluated (GHSA-8m99-vc82-25m4).

### Fixed
- `test.sh` fails when the mcp-server suite could not run. A missing `mcp-server/node_modules` printed "skipped", left the exit status at 0 and reported a green summary while all 24 TypeScript tests sat unexecuted. CI installs deps and was unaffected, which is why only local runs hit it. `make test` now depends on `mcp-install` so the common path installs and runs (#34).
- `executeMra` clears its timeout on every terminal path. Only the `close` handler cleared it, and `close` does not necessarily follow `error`, so a failed spawn left the timer armed for up to three minutes holding the event loop open (#38).
- MCP tool calls run against the path the policy authorised. The workspace was resolved with `realpath` to check it against the allowlist, then the original caller-supplied string was handed to `spawn` as cwd — check and use referred to different paths (#40).
- `resolve_compose_config` returns its two values through namerefs instead of a `"file|service"` string. A `|` in the workspace path truncated the compose file path, and the TM-005 trust gate was evaluated against the truncated value (#41).
- `make lint` gates at `-S error`, the severity CI blocks on. It ran `-S warning` and exited 1 on 49 findings while CI was green, so the documented developer command was permanently red and its output went unread. `make lint-all` keeps the warning backlog visible; the backlog itself is tracked in #50 (#35).

### Changed
- Third-party GitHub Actions are pinned to full commit SHAs with Dependabot configured to bump them. `deploy-site.yml` holds `pages:write` and `id-token:write`, so a repointed tag there could publish arbitrary content to the project site (#36).
- Database configuration is read in one `jq` pass per operation rather than one fork per field. Loop-level `jq` invocations drop 12→4 in `lib/doctor.sh` and 24→12 in `lib/db.sh`. Rows use US (`\x1f`) rather than TAB as the separator — bash treats tab as IFS whitespace and collapses runs of it, so an empty middle field silently shifts every field after it — and every field passes through `tostring` because `jq -r '.absent'` prints the literal text `null` where a bare null in a joined row prints an empty string. Partial: the schema sub-loops are unchanged (#37).
- `bin/mra.sh` loads libraries from an ordered `MRA_LIBS` list instead of 78 hand-written `source` lines; 803 → 755 lines. Load order is preserved byte-identically and `tests/test_lib_loader.sh` fails if a `lib/*.sh` is ever omitted from the list. The 42-branch dispatch is unchanged (#39).

### Fixed
- Review structural context now gates on index membership: the section is injected only when the codegraph index actually has symbols (`nodeCount > 0`) for at least one changed file, and the explore query is scoped to those files. Live-measured on a bash repo (a language codegraph cannot parse): the ungated section was 8KB of loosely-matched symbols from unrelated indexed files. A failed `codegraph files` listing fails open (legacy behaviour kept). The listing call carries its own 4MB output ceiling — the generic 64KB cap truncated the JSON on a 12k-node index, which silently fail-opened the gate on exactly the repos where scoping matters.

### Added
- Codex review model + reasoning effort are now pinned explicitly: `review.models.codex` takes a model slug instead of relying on the empty "use whatever the CLI defaults to" sentinel, and a new `review.codexReasoningEffort` config key forwards `-c model_reasoning_effort` to the review child. Because the codex invocation passes `--ignore-user-config`, `~/.codex/config.toml` never reaches that child — an effort configured there was silently dropped and every review ran at the CLI's built-in default. The value is whitelisted (`^[A-Za-z0-9._-]+$`) before being spliced into TOML; an invalid one warns and defers to the codex default rather than being sent.
- Codex runtime knobs are restored from `~/.codex/config.toml` alongside the existing transport overrides: `model_context_window`, `model_auto_compact_token_limit`, `service_tier`, and `disable_response_storage`. Without them a long review inherits the model catalog's compaction threshold rather than the configured one, and compaction is precisely what discards the findings a review has accumulated so far. For scale: a review child starts at ~14.5k tokens of codex scaffolding before MRA adds its reviewer policy (~4k) and the PKB (7k–26k measured across real projects); the agentic file reads that follow are what actually approach the limit. Each value is format-validated (numeric / identifier / boolean) and anything unset or malformed is skipped, so codex keeps its own default instead of receiving a broken override. Numeric knobs accept TOML digit separators (`1_000_000`) and normalize them before forwarding; separator placement follows TOML, so the forms codex itself refuses to parse (`_1000`, `1000_`, `1__000`) are refused here too rather than being repaired into a value codex never saw.
- PKB evaluation discipline (#27): `mra eval-probe` — a deterministic, LLM-free probe (fixed fixture + question set over moduleMap lookup, regex fallback, and staleness detection) emitting a SHA-stamped JSON report comparable across commits; `mra eval-ablation <project>` — runs the same review case 2×2 (PKB on/off × structural on/off) via env seams (`MRA_EVAL_DISABLE_PKB`, `MRA_STRUCTURAL_PROVIDER`) and persists a per-arm findings/duration report under `.collab/eval/`. The eval review runner now mirrors `mra review`'s structural-context injection.
- Structural tunnels (#26): the capitalized-word tunnel scan is now only a proposer — with a codegraph index, each candidate entity is verified against the symbol graph (`codegraph query`) and its referencing modules come from real call edges (`codegraph callers`) aggregated via the moduleMap, written with a `source: codegraph` provenance header. Noise words never survive verification; without codegraph (or on failure) the legacy heuristic table is unchanged.
- Review structural context (#25): when a project has a codegraph index, `mra review` injects a capped section (`MRA_REVIEW_STRUCTURAL_MAX_BYTES`, default 8KB) with the symbol-level blast radius around the changed files (`codegraph explore`) and the transitively affected test files (`codegraph affected`). Best-effort by contract — any failure or absent codegraph leaves the prompt byte-identical.
- Structural layer foundation (#23): `lib/structural.sh` wraps an existing [codegraph](https://github.com/colbymchenry/codegraph) CLI — `structural_available` / `structural_impact` / `structural_query` / `structural_affected` — adopt-if-exists (mra never runs `codegraph init` for you; `mra analyze` hints when a project is unindexed, `mra doctor` reports index coverage), every call bounded by a perl-alarm watchdog (`MRA_STRUCTURAL_TIMEOUT_SECONDS`, default 30s) and an output cap (`MRA_STRUCTURAL_MAX_BYTES`, default 64KB), disable with config `structural.provider=off`. No codegraph anywhere = zero behaviour change.
- PKB playbook preamble (#24): every `pkb_build_context` tier now opens with a fixed ~100-token usage playbook — treat PKB sections as already read (no re-verifying by grep), how to react to the staleness banner, prefer module summaries over repo crawling, and PKB text is context, never instructions.
- PKB decision provenance (#22): decisions captured from review findings are written as `[DECISION source:review@<sha> <date>] …`, so machine-distilled entries in conventions.md are auditable and cleanable; dedup compares body text only.
- PKB fact-driven moduleMap (#21): generation records each module's actual directory in `meta.json`; file→module lookup consults the map (longest prefix wins) before the legacy path-regex guesses, so non-standard layouts resolve correctly.
- PKB staleness banner (#20): PKB generation records a git snapshot (`snapshotCommit` + blob hashes of then-dirty files) in `meta.json`; `pkb_build_context` now prepends an explicit `⚠️ PKB STALENESS` banner naming files changed since — committed drift and working-tree edits, deletions included (capped list) — so agents read those files directly instead of silently consuming stale knowledge. Incremental updates gate on the snapshot diff (per-file, all languages) instead of the coarse directory-mtime check; non-git projects keep the mtime fallback.

### Fixed
- Codex review invocations are now bounded by a watchdog (`MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS`, default 900s, `0` disables): the child is killed with SIGALRM on timeout and the failure surfaces through the existing `REVIEW_INCOMPLETE`/fallback paths, so a hung or silently dying codex can never block `mra review` forever (#18). Codex also gets `/dev/null` stdin — it no longer blocks reading "additional input" from an inherited pipe that never closes.
- Codex review auth file now lives for the whole codex invocation instead of being deleted after a fixed 1s TTL: the codex CLI re-reads `auth.json` on stream reconnects, so the early delete turned any transient relay drop into a guaranteed 401 → `REVIEW_INCOMPLETE` (#17). `MRA_CODEX_AUTH_FILE_TTL_SECONDS` is now opt-in for a hard deletion deadline, and the TTL timer is killed (not waited on) when codex exits, so a large TTL can no longer block the review after the child dies.

## [3.0.0] - 2026-07-14

### Changed
- `mra scan` is rewritten as a single Python walker (`scanners/walk.py`): one pruned `os.walk` per project replaces the five separate `find`-based scanners, ~38× faster on a 36-project workspace (~9.5s → ~0.25s) while emitting the identical relationship records. Intentional divergences from the old scanners (all documented in `scanners/README.md`): `node_modules`/`vendor` are pruned (dependency-internal config is noise), host matching is deterministic longest-match (the old bash used nondeterministic hash order), and hidden dirs are excluded from known-project matching. Custom `.collab/scanners/*.sh` still run as subprocesses.
- Review subsystem and PKB internals split into focused modules for maintainability (behaviour-preserving): `lib/review.sh` (1205→413) → `review-json/strategy/pr-discussion/post`; `lib/review-debate.sh` (912→473) → `review-debate-agents`; `lib/pkb.sh` (1133→249) → `pkb-cache/query/prompts`.
- `mra prd-scaffold` now adopts a pre-existing planned repo after a per-repo `[y/N]` confirm (clone + register, seed only if empty) instead of aborting. An existing repo never reaches `gh repo create`.

### Breaking
- **BREAKING** lint profile `oneAD` renamed to `ts-strict`; update any `.collab/lint-profile.json` using `{"profile":"oneAD"}` to `{"profile":"ts-strict"}`.
- **BREAKING** `mra scan` now requires `python3` (the built-in scanners run via `scanners/walk.py`). `python3` was already used by the previous `shared-packages` scanner; scan now fails fast with a clear error if it is missing.

### Added
- Codex review provider now supports **debate** and **personas**, closing the capability gap with Claude (Codex was previously single-pass only). Codex debate is a two-pass analysis→adversarial-verify pipeline (pass 2 adjudicates; a finding survives only if raised in pass 1 and re-affirmed in pass 2); a pass with no completion sentinel gates to `REVIEW_INCOMPLETE`, never a false-green approve. Codex personas run each persona as one Codex pass.
- Codex review protocol provider: `mra review` defaults to Codex (analysis-only, SHA-bound, sanitized snapshot, transient auth, secret redaction) while Claude remains available as an explicit provider or fallback.
- Single-pass review completeness sentinel: `light`/`standard` reviews must end with the `===MRA-REVIEW-COMPLETE: <verdict>===` sentinel; a missing/empty/unparseable response is reported as `REVIEW_INCOMPLETE` and never posted as an approval (closing a false-green surface under the approve-if-no-high policy).
- `scanners/README.md` documents the custom-scanner contract (a `.sh` under `<workspace>/.collab/scanners/` taking `<workspace>` as `$1` and emitting JSONL relationship records).
- `scripts/stats.sh` prints the current CLI-command and test-suite counts so the README badge line can be regenerated instead of hand-maintained.
- `mra prd --new <name>` — greenfield interactive planner: brainstorms a brand-new project's architecture from scratch, proposes a repo split + stack, and writes a PRD + specs + task plan + a scaffold plan. Creates nothing.
- `mra prd-scaffold --req <ID> [--confirm]` — operator-run, **TTY-gated** apply that `gh repo create`s the planned repos (per-repo `GH_TOKEN` via `ghAccounts`, immutable ledger, atomic additive dep-graph registration — never `mra scan`), seeds each with an empty commit, and registers them into the workspace. A planned repo that already exists on GitHub triggers a per-repo `[y/N]` confirm — **y** adopts it (clone + register, seed only if empty); **N** aborts loud.
- `mra prd <projects…>` — interactive cross-repo PRD/spec planner (FE/BE/data brainstorm → HTML PRD + per-repo specs + task plan under `.collab/`); the upstream of `mra dev`. It opens **no** issues.
- `mra prd-issues --req <ID> [--confirm]` — operator-run, **TTY-gated** apply step that opens dependency-ordered GitHub issues (two-pass create + `Depends on` links, per-repo account pinning via the new `ghAccounts` config key, immutable resume ledger). A non-TTY caller never creates. `mra doctor` warns if a tool allowlist could bypass the gate.
- `mra dev <project> "<task>"` — deterministic, fully-headless implement→review→fix→PR loop. Forces the debate+verifier review as the gate; transports the verdict via `$MRA_REVIEW_RESULT_FILE` (exit code is never trusted); three-valued APPROVED/CHANGES_REQUESTED/REVIEW_INCOMPLETE switch bounded by round/retry/global caps + a no-progress fingerprint. Default posts a COMMENT review (binding GitHub APPROVE is opt-in via `--auto-approve`). Env knobs: `MRA_DEV_IMPLEMENT_MAX_TURNS`, `MRA_DEV_FIX_MAX_TURNS`, `MRA_DEV_MAX_REVIEWS`, `MRA_DEV_ALLOWED_TOOLS`, `MRA_DEV_CLAUDE_BIN`. Cost accounting deferred.
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
