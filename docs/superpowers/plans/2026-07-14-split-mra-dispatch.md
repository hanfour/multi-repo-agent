# Split `bin/mra.sh` Dispatch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dispatch smoke-test safety net, then move the 6 biggest inline command bodies out of `bin/mra.sh`'s giant `case` into `cmd_<name>()` functions in their domain libs — zero behaviour change.

**Architecture:** Task 1 captures the current end-to-end behaviour of every command as a committed golden and a test that regenerates + diffs it (the dispatch has almost no e2e coverage today — 3/63 tests invoke the binary). Tasks 2+ extract command bodies verbatim; the smoke net guards each against routing/arg-parse/exit-code regressions. `main()` doesn't shift before the `case` and every big branch exits (never returns), so extraction is `cmd_<name>()` = the branch body verbatim (incl. leading `shift`) and the branch becomes `<name>) cmd_<name> "$@" ;;`.

**Tech Stack:** Bash, `perl` (portable alarm timeout), `shellcheck`, `./test.sh`.

## Global Constraints

- **Behaviour-preserving only.** Command bodies move verbatim; no logic/arg-parse change. Guarded by the smoke golden (exit code + normalized output per command) + existing domain tests + `shellcheck -S error`.
- **Extraction contract (verified):** `main()` runs `local command="${1:-}"; case "$command"` with NO shift, so a branch's `$@` includes the command name and its first line `shift` removes it. Every target branch terminates via `exit` (zero `return`). So: move the body verbatim (incl. leading `shift`) into `cmd_<name>()`; replace the branch with `<name>) cmd_<name> "$@" ;;`. No exit-code glue needed.
- **The smoke golden must be captured from the PRE-refactor binary** (Task 1, before any extraction) and stay byte-unchanged through every later task.
- **Do not touch thin-router branches** (scan/review/deps/plan/analyze/dev/prd*/status/…) — they already call a lib function.
- **Exclude interactive/long-running commands** (`dashboard`, `watch`) from the smoke net — they are TUIs with live clocks (non-deterministic). Documented in the test.
- `./test.sh` green with unchanged counts throughout.

---

## Task 1: Dispatch smoke-test net + committed golden

**Files:** Create `tests/test_dispatch_smoke.sh`, `tests/fixtures/dispatch-smoke.golden`.

**Interfaces:** Produces the safety net every later task relies on. The test runs each command with `--help` in an isolated temp workspace with external tools stubbed, normalizes output, and diffs against the committed golden.

- [ ] **Step 1: Write the smoke runner test**

Create `tests/test_dispatch_smoke.sh`:
```bash
#!/usr/bin/env bash
# Dispatch smoke net: exercises every top-level command's entry (routing + first
# arg-parse + exit code) end-to-end through bin/mra.sh, with external tools stubbed
# and in an empty workspace so nothing does real work or hangs. Asserts the
# normalized (exit + first 3 lines, ANSI/paths stripped) output matches the
# committed golden — catching any routing/arg-parse/exit-code regression from the
# dispatch-extraction refactor (#16).
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$MRA_DIR/tests/fixtures/dispatch-smoke.golden"

# All top-level commands EXCEPT interactive/long-running TUIs (dashboard, watch).
CMDS="alias analyze ask branch ci clean config cost db deps dev diff doctor
eval-review export federation graph init integration lint log notify open plan
prd prd-issues prd-render prd-scaffold review rollback scan setup snapshot
snapshots status sync template test test-audit trust"

run_all() {
  local ws; ws=$(mktemp -d)
  mkdir -p "$ws/.collab" "$ws/stub/bin"
  echo '{"projects":{},"gitOrg":"acme"}' > "$ws/.collab/dep-graph.json"
  local t
  for t in claude codex docker gh; do
    printf '#!/usr/bin/env bash\necho "[stub:%s] $*"\nexit 0\n' "$t" > "$ws/stub/bin/$t"
    chmod +x "$ws/stub/bin/$t"
  done
  local c out ec
  for c in $CMDS; do
    out=$(cd "$ws" && PATH="$ws/stub/bin:$PATH" MRA_WORKSPACE="$ws" \
          MRA_CLAUDE_BIN="$ws/stub/bin/claude" MRA_CODEX_BIN="$ws/stub/bin/codex" \
          perl -e 'alarm 15; exec @ARGV' bash "$MRA_DIR/bin/mra.sh" "$c" --help </dev/null 2>&1)
    ec=$?
    # normalize: strip ANSI, replace dir/ws with placeholders, first 3 lines
    printf '=== %s (exit=%s) ===\n%s\n' "$c" "$ec" \
      "$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*m//g' | sed "s|$MRA_DIR|<DIR>|g; s|$ws|<WS>|g" | head -3)"
  done
  chmod -R u+w "$ws" 2>/dev/null || true; rm -rf "$ws"
}

live=$(run_all)
if [[ "${1:-}" == "--regen" ]]; then
  printf '%s\n' "$live" > "$GOLDEN"
  echo "regenerated $GOLDEN"; exit 0
fi
if diff <(printf '%s\n' "$live") "$GOLDEN" >/dev/null; then
  echo "PASS: dispatch smoke net matches golden ($(echo "$CMDS" | wc -w | tr -d ' ') commands)"
else
  echo "FAIL: dispatch behaviour changed vs golden:"; diff <(printf '%s\n' "$live") "$GOLDEN"; exit 1
fi
```

- [ ] **Step 2: Capture the golden from the current (pre-refactor) binary**

Run: `bash tests/test_dispatch_smoke.sh --regen`
Then run `bash tests/test_dispatch_smoke.sh` → must print `PASS`. Inspect
`tests/fixtures/dispatch-smoke.golden` — it should have one `=== <cmd> (exit=N) ===`
block per command with deterministic content (usage/errors/empty-workspace output).
Confirm the 6 extraction targets (`branch`, `sync`, `federation`, `db`,
`integration`, `test-audit`) each have a stable block.

- [ ] **Step 3: Verify determinism**

Run `bash tests/test_dispatch_smoke.sh` twice more — both `PASS` (no flaky
timestamp/path leakage). If any command's block differs run-to-run, add it to an
exclusion list in `CMDS` with a comment (like dashboard/watch) and re-regen.

- [ ] **Step 4: Full suite**

Run: `./test.sh` — green; `test_dispatch_smoke.sh` auto-discovered and passing.
`shellcheck -S error tests/test_dispatch_smoke.sh`.

- [ ] **Step 5: Commit**
```bash
git add tests/test_dispatch_smoke.sh tests/fixtures/dispatch-smoke.golden
git commit -m "test(cli): dispatch smoke net + golden baseline before extraction (#16)"
```

---

## Shared extraction mechanism (Tasks 2–4)

For each target command `<name>` with domain lib `lib/<domain>.sh`:

1. In `bin/mra.sh`, find the branch: `grep -nE "^    <name>\)" bin/mra.sh`; its body
   runs from that line to its closing `      ;;`.
2. **Move the body verbatim** (from the line AFTER `<name>)` through the line BEFORE
   `;;`, i.e. the `shift` + everything down to the last `exit`) into a new function
   at the end of `lib/<domain>.sh`:
   ```bash
   # <name> command handler (extracted from bin/mra.sh dispatch, #16)
   cmd_<name>() {
     <verbatim body>
   }
   ```
3. **Replace the branch** in `bin/mra.sh` with exactly:
   ```bash
       <name>)
         cmd_<name> "$@"
         ;;
   ```
4. **Verify** (run all):
   ```bash
   bash -n bin/mra.sh && bash -n lib/<domain>.sh
   shellcheck -S error bin/mra.sh lib/<domain>.sh
   bash tests/test_dispatch_smoke.sh          # golden UNCHANGED — the key gate
   bash tests/<domain guard test>.sh           # e.g. test_sync.sh, test_branch*.sh
   ./test.sh
   ```
   The smoke golden must still `PASS` byte-identically (behaviour preserved). If it
   fails, the extraction changed behaviour — STOP.
5. **Commit:** `git commit -m "refactor(cli): extract cmd_<name> to lib/<domain>.sh (#16)"`

Note: `cmd_<name>` is defined in a lib sourced by `bin/mra.sh` before `main()`, so
it resolves at call-time. The body is byte-identical, incl. its leading `shift`
(which now shifts the function's `$@`, = the args `cmd_<name> "$@"` received =
the same `$@` the branch had). All target bodies `exit`, so no return-code glue.

---

## Task 2: Extract `cmd_branch` (135 lines — the giant)

**Files:** Modify `bin/mra.sh` (branch @ ~699), `lib/branch.sh` (+`cmd_branch`).
Guard: `tests/test_branch.sh`, `tests/test_branch_ops.sh`.

- [ ] **Step 1:** Apply the shared extraction mechanism for `<name>=branch`, `<domain>=branch`.
- [ ] **Step 2:** Verify — smoke golden's `=== branch (exit=…) ===` block byte-unchanged; `bash -n`/shellcheck clean; `test_branch.sh` + `test_branch_ops.sh` pass; `./test.sh` counts unchanged.
- [ ] **Step 3:** Commit `refactor(cli): extract cmd_branch to lib/branch.sh (#16)`.

## Task 3: Extract `cmd_sync` (78 lines)

**Files:** Modify `bin/mra.sh` (sync @ ~620), `lib/sync.sh` (+`cmd_sync`).
Guard: `tests/test_sync.sh`.

- [ ] **Step 1:** Apply the shared mechanism for `<name>=sync`, `<domain>=sync`.
- [ ] **Step 2:** Verify — smoke golden `=== sync ===` block unchanged; shellcheck/bash -n clean; `test_sync.sh` passes; `./test.sh` unchanged.
- [ ] **Step 3:** Commit `refactor(cli): extract cmd_sync to lib/sync.sh (#16)`.

## Task 4: Extract the 4 medium branches (`federation`, `db`, `integration`, `test-audit`)

**Files:** Modify `bin/mra.sh`; add `cmd_federation`→`lib/federation.sh`, `cmd_db`→`lib/db.sh`, `cmd_integration`→`lib/integration-test.sh`, `cmd_test_audit`→`lib/test-audit.sh`.
Guard: `tests/test_federation.sh`, `tests/test_doctor_security.sh` (federation), `tests/test_protocol*`/`test_integration*` (integration), plus the smoke net for all.

Apply the shared mechanism once per command (do them in sequence, committing each, so a regression is isolated):

- [ ] **Step 1:** `cmd_federation` → `lib/federation.sh`; verify (smoke `=== federation ===` unchanged + `test_federation.sh`); commit `refactor(cli): extract cmd_federation (#16)`.
- [ ] **Step 2:** `cmd_db` → `lib/db.sh`; verify (smoke `=== db ===` unchanged + any db test); commit `refactor(cli): extract cmd_db (#16)`.
- [ ] **Step 3:** `cmd_integration` → `lib/integration-test.sh`; verify (smoke `=== integration ===` unchanged + integration/protocol tests); commit `refactor(cli): extract cmd_integration (#16)`.
- [ ] **Step 4:** `cmd_test_audit` → `lib/test-audit.sh`; verify (smoke `=== test-audit ===` unchanged); commit `refactor(cli): extract cmd_test_audit (#16)`.
- [ ] **Step 5:** Final `./test.sh` green; `bin/mra.sh` reduced by ~340 lines total. Report the new `wc -l bin/mra.sh`.

Note the function name for `test-audit` is `cmd_test_audit` (hyphen → underscore, since a hyphen is illegal in a Bash function name); the dispatch branch stays `test-audit) cmd_test_audit "$@" ;;`.

---

## Self-Review

**Spec coverage:** smoke net (Task 1) → the missing e2e safety net; 6 extractions (Tasks 2–4) → the biggest inline branches to domain libs; thin routers untouched. ✅

**Placeholder scan:** Task 1 gives the full, prototype-validated runner script; the shared mechanism gives exact grep/move/replace steps + the exact dispatch replacement; each target names its domain lib + guard tests. No vague steps.

**Contract consistency:** every extraction uses the same verbatim-body + `<name>) cmd_<name> "$@" ;;` replacement; the exit-only/no-shift facts (verified in the spec) mean no exit-code glue; the smoke golden is the cross-cutting behaviour gate for all of them. `cmd_test_audit` underscore-vs-hyphen naming is called out.

**Risk:** entry-point refactor — mitigated by (a) the smoke golden capturing pre-refactor behaviour of all ~40 commands and gating every extraction, (b) verbatim body moves (no logic edits), (c) one commit per command so any regression is isolated and revertable.
