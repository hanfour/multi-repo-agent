# FAQ

## Why bash instead of Python / Node?

Zero runtime deps. A laptop with `git`, `jq`, `docker`, and `gh` is already set up. Every extra language server is friction for developers who just want to run a CLI.

## Does mra send my code to Anthropic?

Only the files you explicitly include in the context window. PKB documents are designed so you can review what's being sent. Every `claude -p` invocation uses `--disallowedTools "Write,Edit,NotebookEdit"` for read-only flows.

## How does mra know my repo relationships?

Five scanners (docker-compose, shared-db, gateway-routes, shared-packages, api-calls) infer the graph automatically. Override in `.collab/manual-deps.json`.

## Can I add my own personas?

Yes. Drop a markdown file in `agents/personas/<name>.md` following the `ROLE/STYLE/FOCUS/METHOD/OUTPUT FORMAT` schema. It's auto-discovered.

## Does `--personas` replace debate?

No — it's an opt-in alternative strategy. Default remains auto-selection (light / standard / debate). Use `--personas` for security-critical PRs or cross-repo API changes.

## What's the cost?

Debate review: ~$0.05–$0.20 per PR depending on diff size. Persona review: ~$0.15–$0.40 (5 agents vs 2). `mra analyze` for a 500-file project: ~$0.50 one-time.

Track with `mra cost`.

## Bash < 4.3?

`wait -n` falls back to blocking wait on the oldest pid. All new libs run correctly on macOS bash 3.2.

## Where are logs?

`.collab/logs/<project>/<date>.log` per project.
