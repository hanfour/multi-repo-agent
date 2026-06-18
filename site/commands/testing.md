# Testing & Docker

Run tests in isolated Docker environments, watch for changes, and manage databases. A project must be **trusted** once before mra will run its containers.

```bash
mra trust my-api               # grant Docker trust (one-time, per project)
mra db setup                   # start DB containers and import dumps
mra test my-api                # run tests (auto-detects strategy)
mra watch my-api               # re-run tests on file change
```

## Commands

| Command | Purpose |
|---------|---------|
| `mra trust <project>` | Grant Docker trust for a project; recorded in `.collab/trusted-projects.json`. Required before running its containers. |
| `mra db [setup\|status\|import]` | Manage databases: `setup` starts containers + imports dumps, `status` shows state, `import` loads dumps. |
| `mra test <project> [--integration\|--mock]` | Run the project's tests in Docker. `--integration` runs integration tests; `--mock` uses mocked dependencies. |
| `mra watch <project\|--all>` | Watch files and auto-run tests on change. |

## Database dumps

Place dump files under `<workspace>/dumps/` (e.g. `myapp_db.sql.bz2`); `mra db setup` imports them into the started containers. Dump config lives in `<workspace>/.collab/db.json`.

::: tip
`trust` is a deliberate security gate — mra will not execute a project's Docker containers until you have explicitly trusted it. See the threat model in the repo for the rationale.
:::
