# Security Policy

## Supported versions

`multi-repo-agent` is distributed from the `main` branch; security fixes land on `main`.
There are no separately maintained release branches at this time.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via GitHub Security Advisories:
<https://github.com/hanfour/multi-repo-agent/security/advisories/new>

Please include:
- a description of the issue and its impact,
- steps to reproduce (a minimal repro if possible),
- affected files/commands and any relevant environment details.

You can expect an initial acknowledgement within a few days. Once a fix is available,
we will coordinate disclosure.

## Scope notes

`mra` shells out to `git`, `gh`, `claude`, `codex`, and other tools, and reads a
workspace's `repos.json` / `.collab/dep-graph.json`. Of particular interest:
- command/argument injection via crafted project names, branch names, or config values
  (the codebase validates names and uses `jq --arg` to avoid filter injection);
- path traversal in workspace/project resolution;
- any path that could execute or write outside the intended workspace.

Findings in these areas are especially welcome.
