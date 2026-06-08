# Contributing to multi-repo-agent

Thanks for your interest in improving `mra`. This is a Bash CLI for orchestrating
work across many git repositories, with an MCP server companion.

## Getting started

```bash
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent
./install.sh          # symlinks `mra` onto your PATH
bash test.sh          # run the full suite (shell suites + mcp-server)
```

## Development workflow

1. **Open an issue first** for anything non-trivial, so the design can be discussed.
2. **Branch** off `main` (e.g. `feat/<short-name>`). Don't commit directly to `main`.
3. **Test-driven**: write or extend a test in `tests/test_*.sh` before the code, watch
   it fail, then implement. Run `bash test.sh` and make sure it is fully green.
4. **Keep changes focused** — one logical change per commit.
5. **Open a PR** describing what changed and how you verified it.

Larger features in this repo are designed spec-first: a design doc under
`docs/superpowers/specs/`, then a task-by-task plan under `docs/superpowers/plans/`,
then TDD implementation. You're welcome to follow the same flow, but it isn't required
for small fixes. After editing any `docs/superpowers/*.md`, re-render its HTML sibling
with `python3 docs/superpowers/render-html.py <file.md>`.

## Coding style

- Bash, targeting a POSIX-ish `bash` 4.4+. Library scripts live in `lib/` — keep them
  small and single-purpose; the CLI dispatch lives in `bin/mra.sh`.
- The CLI runs under `set -euo pipefail`; write `set -e`-safe code (capture exit codes
  with `cmd || rc=$?`, guard empty-array expansions).
- Validate input at boundaries; never silently swallow errors.
- **Never commit secrets, credentials, internal hostnames, or private/company-specific
  data.** Use neutral placeholders (`your-org`, `myorg`, `<workspace>`) in examples.
- Prefer many small files over few large ones.

## Commit messages

Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, `perf:`,
`ci:` — e.g. `feat(branch): add 'mra branch status --json'`.

## Tests

- Shell suites: `tests/test_*.sh` (a plain PASS/FAIL harness; no bats required).
- `bash test.sh` runs every suite plus the `mcp-server` npm tests. PRs must keep it green.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
