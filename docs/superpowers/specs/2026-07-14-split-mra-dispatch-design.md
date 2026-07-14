# Split `bin/mra.sh`'s dispatch — extract big command bodies to lib — Design

**Date:** 2026-07-14
**Issue:** hanfour/multi-repo-agent#16 (follow-up from #12) — `refactor: bin/mra.sh dispatch 下放到 lib`
**Status:** Approved (brainstorming)

## Problem

`bin/mra.sh` (1111 lines) dispatches 42 top-level commands from one giant `case`
in `main()`. Some branches are thin routers that already call a lib function
(`scan) … handle_scan`, `review) … review_project`) — those are fine. But the
largest branches carry substantial inline logic (arg parsing + orchestration) that
belongs in a lib. This is the entry point, so it's the highest-risk refactor.

## Test-coverage reality (assessed first, per #16)

Only **3 of 63** test files invoke `bin/mra.sh` end-to-end; the other 60 are
source-only (they test lib functions directly). The lib functions the big branches
call ARE tested, but the **dispatch's inline arg-parsing + routing + exit codes are
NOT** exercised. So the existing suite cannot verify behaviour-preservation of a
dispatch extraction. **A dispatch smoke-test net must be built first.**

## Extraction contract (verified against the code — low risk)

Two facts make the extraction nearly mechanical:
1. `main()` does **not** `shift` before the `case` (`local command="${1:-}"; case
   "$command"`), so inside a branch `$@` still starts with the command name, which
   the branch's first line `shift` removes.
2. Every big branch terminates via `exit N` exclusively — **zero `return`** (sync
   exit×9, branch exit×24, db/integration/federation/test-audit all exit-only). No
   branch falls through to the rest of `main()`.

Therefore extraction is:
- Move the branch body **verbatim** (including its leading `shift`) into a new
  `cmd_<name>()` in the command's domain lib.
- Replace the dispatch branch with: `<name>) cmd_<name> "$@" ;;`.
- `cmd_<name>` receives the same `$@` the branch had (command name included), does
  the same `shift`, runs identical logic, and `exit`s the process — so no
  exit-code propagation glue is needed. Behaviour is identical.

## Design

### Task 1 — dispatch smoke-test net (`tests/test_dispatch_smoke.sh`)

For each of the 42 commands, run one **safe, deterministic** invocation in an
isolated temp workspace (empty `dep-graph.json`, fixed `MRA_WORKSPACE`, `cwd` = the
temp ws, `</dev/null`), capture **exit code + normalized output**, and assert it
matches a committed golden captured from the **pre-refactor** binary.

- **Invocation per command:** read-only/no-op commands use `--help` (deterministic
  in an empty workspace: `mra status` → "workspace: null", `mra cost` → "no usage
  data", etc.). Commands with side effects (`sync`, `db`, `dev`, `prd`,
  `prd-scaffold`, `prd-issues`) use an argument that fails at arg-parse
  (an unknown option/subcommand → usage error, exit 1/2) so nothing is created or
  mutated. Each command's chosen arg is recorded in the test.
- **Normalization** (so the golden is portable and captures behaviour, not
  environment): strip ANSI color codes; replace the repo dir and the temp-ws path
  with `<DIR>`/`<WS>`; keep exit code + the first N normalized lines.
- **Golden:** `tests/fixtures/dispatch-smoke.golden` — one record per command
  (`<cmd>\t<exit>\t<normalized-first-lines-hash-or-text>`), captured from the
  current binary before any extraction. The test regenerates live and diffs.
- This net catches routing, arg-parse, and exit-code regressions from every later
  extraction. It also documents current behaviour (including a latent `config
  --help` unbound-`$2` quirk — captured as-is; behaviour-preserving means the quirk
  is preserved).

### Task 2+ — extract the big inline branches → `cmd_<name>()` in domain lib

Targets (real body size by `;;` boundary, all have a matching domain lib):

| command | body lines | → domain lib | new fn |
|---|---|---|---|
| `branch` | 135 | `lib/branch.sh` | `cmd_branch` |
| `sync` | 78 | `lib/sync.sh` | `cmd_sync` |
| `federation` | 37 | `lib/federation.sh` | `cmd_federation` |
| `db` | 34 | `lib/db.sh` | `cmd_db` |
| `integration` | 32 | `lib/integration-test.sh` | `cmd_integration` |
| `test-audit` | 27 | `lib/test-audit.sh` | `cmd_test_audit` |

Each is one task: move the body verbatim into `cmd_<name>()`, replace the branch
with `<name>) cmd_<name> "$@" ;;`, verify the smoke golden for that command is
unchanged + the domain's existing tests + shellcheck + full suite.

Thin-router branches (scan, review, deps, plan, analyze, dev, prd*, status, etc.)
are **not** touched — they already route to a lib function.

## Non-goals (YAGNI)

- No logic/arg-parse/behaviour change — verbatim body moves only.
- No touching the thin-router branches.
- No `cmd_*` for the small branches (config/alias/log/… < 25 lines) — not worth it.
- No restructuring of `main()` beyond replacing the 6 target branches with calls.

## Acceptance

- `tests/test_dispatch_smoke.sh` exists, covers all 42 commands, and is green
  against the committed golden — both before AND after every extraction.
- The 6 target branches become one-line `cmd_<name> "$@"` calls; `bin/mra.sh`
  shrinks by ~340 lines; each `cmd_<name>` lives in its domain lib.
- The smoke golden is byte-unchanged by the extractions; existing tests +
  `./test.sh` stay green; `shellcheck -S error` clean.
