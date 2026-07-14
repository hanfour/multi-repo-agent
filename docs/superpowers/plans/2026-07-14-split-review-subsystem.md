# Split the Review Subsystem's Large Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `lib/review.sh` (1205) and `lib/review-debate.sh` (912) to ~400-line orchestrators by relocating cohesive function groups into new focused modules, with zero behavior change.

**Architecture:** Pure verbatim relocation. Each task moves a set of whole functions from a big file into a new `lib/review-*.sh` module, wires the new module into `bin/mra.sh`'s source list and into every test that sources the parent file, and verifies the full suite stays green. No logic, signature, or prompt edits.

**Tech Stack:** Bash, `awk` (BSD/macOS-compatible), `shellcheck`, the project's `./test.sh` harness.

## Global Constraints

- **Behavior-preserving only:** functions move byte-for-byte. No logic/signature/prompt change. Guarded by `tests/test_review_*.sh` + `shellcheck -S error`.
- **Extraction is safe by structure:** every top-level function spans `^<name>() {` to the next `^}$`; the files have an exact 1:1 function-to-`^}$` count (26/26 and 14/14), so no nested column-0 `}` exists inside any function.
- **Sourcing order is irrelevant:** `bin/mra.sh` sources all `lib/*.sh` before `main()` (dispatch at line 178); Bash resolves calls at call-time. New modules only need a `source` line added.
- **Every moved function must exist in exactly one file afterward:** `grep -c '^<fn>() {'` == 1 in the new module, == 0 in the old file.
- **Final state:** `lib/review.sh` keeps exactly `review_project` and `_review_pkb_auto_update` (2 functions); `lib/review-debate.sh` keeps the 8 non-agent functions. `./test.sh` green with unchanged counts throughout.
- New module naming (collision-checked): `review-strategy.sh` (not `review-select`), `review-pr-discussion.sh` (not `review-context`).

---

## Shared mechanism (used by every task)

Each task moves a list of functions `FNS` from `$SRC` into a new `$NEW`. Use this exact recipe (BSD-awk compatible):

```bash
# 1) Create the new module with a header.
printf '#!/usr/bin/env bash\n# <one-line responsibility>\n\n' > "$NEW"

# 2) Append each function verbatim, in the given order.
for fn in "${FNS[@]}"; do
  awk -v fn="$fn" '$0 ~ ("^"fn"\\(\\) \\{"){f=1} f{print} f&&$0=="}"{f=0}' "$SRC" >> "$NEW"
  printf '\n' >> "$NEW"
done

# 3) Remove each function from the source file.
for fn in "${FNS[@]}"; do
  awk -v fn="$fn" 'skip==0 && $0 ~ ("^"fn"\\(\\) \\{"){skip=1} skip==1{ if($0=="}"){skip=0} ; next } {print}' "$SRC" > "$SRC.tmp" && mv "$SRC.tmp" "$SRC"
done
```

The `awk` extract prints from a function's opening line through its closing `^}$`; the remove skips that same block. Leading comment blocks that directly precede a moved function are NOT captured by name — after step 3, scan `$SRC` for any comment/section-header that described a moved function and delete it (or move it above the function in `$NEW` if substantive). This is a small manual cleanup, verified visually.

**Wiring the new module into `bin/mra.sh`:** add one `source` line in the review block (the existing block is lines ~55–61: `review-diff.sh`, `review-prompt.sh`, `review-context.sh`, `review-provider.sh`, `review.sh`, `review-protocol.sh`, `review-debate.sh`). Place the new module's source line adjacent to the parent's.

**Wiring the new module into tests:** for a module extracted from `lib/review.sh`, run `grep -l 'lib/review\.sh' tests/*.sh`; in each hit, add a `source ".../lib/<newmodule>.sh"` line immediately after the existing `lib/review.sh` source line, mirroring that line's path-variable style. For `review-debate-agents.sh`, use `grep -l 'lib/review-debate\.sh' tests/*.sh`. Adding the source is idempotent (function defs), and `./test.sh` verifies nothing was missed.

**Per-task verification (run all):**
```bash
bash -n "$NEW" && bash -n "$SRC"                 # syntax
shellcheck -S error "$NEW" "$SRC" bin/mra.sh     # lint (clean)
for fn in "${FNS[@]}"; do
  [ "$(grep -c "^${fn}() {" "$NEW")" = 1 ] || echo "MISSING in NEW: $fn"
  [ "$(grep -c "^${fn}() {" "$SRC")" = 0 ] || echo "STILL in SRC: $fn"
done
bash tests/<guard-tests>.sh                       # the task's guard tests
./test.sh                                          # full suite, unchanged counts
```

---

## Task 1: Extract `lib/review-json.sh`

**Files:**
- Create: `lib/review-json.sh`
- Modify: `lib/review.sh` (remove 7 functions), `bin/mra.sh` (+1 source), affected `tests/*.sh` (+1 source each)
- Guard tests: `tests/test_review_verdict.sh`, `tests/test_review_approve_gate.sh`, `tests/test_review_json_repair.sh`, `tests/test_review_singlepass_gate.sh`

**Interfaces:**
- Produces: `lib/review-json.sh` defining `_review_redact_secrets_json`, `_validate_review_json`, `_review_event_for_status`, `_review_effective_status`, `_review_singlepass_body`, `extract_json`, `_repair_review_json` — same signatures, unchanged.

- [ ] **Step 1: Move the functions**

Run the shared mechanism with:
```bash
SRC=lib/review.sh
NEW=lib/review-json.sh
FNS=(_review_redact_secrets_json _validate_review_json _review_event_for_status _review_effective_status _review_singlepass_body extract_json _repair_review_json)
```
Header comment for `$NEW`: `# Review JSON lifecycle: validate, extract, repair, redact, and status mapping.`

- [ ] **Step 2: Wire into bin/mra.sh**

Add after the `source "$MRA_DIR/lib/review-provider.sh"` line:
```bash
source "$MRA_DIR/lib/review-json.sh"
```

- [ ] **Step 3: Wire into tests**

`grep -l 'lib/review\.sh' tests/*.sh`; in each, add after the `lib/review.sh` source line a matching `source ".../lib/review-json.sh"` (mirror the file's own path-variable, e.g. `$SCRIPT_DIR`).

- [ ] **Step 4: Verify**

Run the per-task verification block. Guard tests: `test_review_verdict.sh`, `test_review_approve_gate.sh`, `test_review_json_repair.sh`, `test_review_singlepass_gate.sh`. Expected: all grep checks silent (no MISSING/STILL lines), shellcheck clean, guard tests pass, `./test.sh` shows the same shell+mcp counts as before (77 shell / 0 failed + mcp ok).

- [ ] **Step 5: Commit**
```bash
git add lib/review-json.sh lib/review.sh bin/mra.sh tests
git commit -m "refactor(review): extract review-json.sh from review.sh (#12)"
```

---

## Task 2: Extract `lib/review-strategy.sh`

**Files:**
- Create: `lib/review-strategy.sh`
- Modify: `lib/review.sh` (remove 3 functions), `bin/mra.sh` (+1 source), affected `tests/*.sh`
- Guard tests: `tests/test_review_safety.sh`

**Interfaces:**
- Produces: `lib/review-strategy.sh` defining `select_review_strategy`, `_review_strategy_turns`, `build_focused_context` — unchanged.

- [ ] **Step 1: Move the functions**
```bash
SRC=lib/review.sh
NEW=lib/review-strategy.sh
FNS=(select_review_strategy _review_strategy_turns build_focused_context)
```
Header: `# Review strategy selection (light/standard/debate), turn budgets, and focused context.`

- [ ] **Step 2: Wire into bin/mra.sh**

Add after the `source "$MRA_DIR/lib/review-json.sh"` line:
```bash
source "$MRA_DIR/lib/review-strategy.sh"
```

- [ ] **Step 3: Wire into tests**

`grep -l 'lib/review\.sh' tests/*.sh`; add `source ".../lib/review-strategy.sh"` after the `lib/review.sh` source line in each.

- [ ] **Step 4: Verify**

Per-task verification. Guard: `test_review_safety.sh`. Expected: grep checks silent, shellcheck clean, guard passes, `./test.sh` counts unchanged.

- [ ] **Step 5: Commit**
```bash
git add lib/review-strategy.sh lib/review.sh bin/mra.sh tests
git commit -m "refactor(review): extract review-strategy.sh from review.sh (#12)"
```

---

## Task 3: Extract `lib/review-pr-discussion.sh`

**Files:**
- Create: `lib/review-pr-discussion.sh`
- Modify: `lib/review.sh` (remove 5 functions), `bin/mra.sh` (+1 source), affected `tests/*.sh`
- Guard tests: `tests/test_review_pr_context.sh`

**Interfaces:**
- Produces: `lib/review-pr-discussion.sh` defining `_review_format_pr_discussion`, `_review_format_pr_scope`, `_review_pr_discussion_prompt`, `_review_prompt_with_pr_discussion`, `_review_fetch_pr_discussion` — unchanged.

- [ ] **Step 1: Move the functions**
```bash
SRC=lib/review.sh
NEW=lib/review-pr-discussion.sh
FNS=(_review_format_pr_discussion _review_format_pr_scope _review_pr_discussion_prompt _review_prompt_with_pr_discussion _review_fetch_pr_discussion)
```
Header: `# PR discussion / scope context: fetch and format an open PR's comments for the review prompt.`

- [ ] **Step 2: Wire into bin/mra.sh**

Add after the `source "$MRA_DIR/lib/review-strategy.sh"` line:
```bash
source "$MRA_DIR/lib/review-pr-discussion.sh"
```

- [ ] **Step 3: Wire into tests**

`grep -l 'lib/review\.sh' tests/*.sh`; add `source ".../lib/review-pr-discussion.sh"` after the `lib/review.sh` source line in each.

- [ ] **Step 4: Verify**

Per-task verification. Guard: `test_review_pr_context.sh`. Expected: grep checks silent, shellcheck clean, guard passes, `./test.sh` counts unchanged.

- [ ] **Step 5: Commit**
```bash
git add lib/review-pr-discussion.sh lib/review.sh bin/mra.sh tests
git commit -m "refactor(review): extract review-pr-discussion.sh from review.sh (#12)"
```

---

## Task 4: Extract `lib/review-post.sh`

**Files:**
- Create: `lib/review-post.sh`
- Modify: `lib/review.sh` (remove 9 functions), `bin/mra.sh` (+1 source), affected `tests/*.sh`
- Guard tests: `tests/test_review_approve_gate.sh` (uses `_review_emit_verdict`/status), plus full suite

**Interfaces:**
- Produces: `lib/review-post.sh` defining `_review_validate_expected_head`, `_render_review_json`, `_review_emit_verdict`, `_review_status_for_notify`, `_review_notify_complete`, `_review_issues_display`, `resolve_pr_base`, `post_inline_review`, `post_fallback_comment` — unchanged.
- After this task `lib/review.sh` contains exactly `review_project` and `_review_pkb_auto_update`.

- [ ] **Step 1: Move the functions**
```bash
SRC=lib/review.sh
NEW=lib/review-post.sh
FNS=(_review_validate_expected_head _render_review_json _review_emit_verdict _review_status_for_notify _review_notify_complete _review_issues_display resolve_pr_base post_inline_review post_fallback_comment)
```
Header: `# Review result rendering + GitHub posting: emit verdict, notify, post inline / fallback review.`

- [ ] **Step 2: Wire into bin/mra.sh**

Add after the `source "$MRA_DIR/lib/review-pr-discussion.sh"` line:
```bash
source "$MRA_DIR/lib/review-post.sh"
```

- [ ] **Step 3: Wire into tests**

`grep -l 'lib/review\.sh' tests/*.sh`; add `source ".../lib/review-post.sh"` after the `lib/review.sh` source line in each.

- [ ] **Step 4: Verify**

Per-task verification. Additionally assert the final review.sh shape:
```bash
[ "$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' lib/review.sh)" = 2 ] && echo "review.sh has 2 functions (OK)" || echo "review.sh function count wrong"
grep -nE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' lib/review.sh   # expect: review_project, _review_pkb_auto_update
```
Guard: `test_review_approve_gate.sh` + `./test.sh` counts unchanged.

- [ ] **Step 5: Commit**
```bash
git add lib/review-post.sh lib/review.sh bin/mra.sh tests
git commit -m "refactor(review): extract review-post.sh from review.sh (#12)"
```

---

## Task 5: Extract `lib/review-debate-agents.sh`

**Files:**
- Create: `lib/review-debate-agents.sh`
- Modify: `lib/review-debate.sh` (remove 6 functions), `bin/mra.sh` (+1 source), affected `tests/*.sh`
- Guard tests: `tests/test_review_debate.sh`, `tests/test_review_debate_codex.sh`

**Interfaces:**
- Produces: `lib/review-debate-agents.sh` defining `run_agent_a`, `run_agent_verify`, `run_agent_b`, `run_critique_and_refine`, `run_vote`, `run_synthesize` — unchanged.
- After this task `lib/review-debate.sh` keeps the 8 non-agent functions (`_debate_verdict_of`, `_debate_assess`, `_debate_verify_gate`, `_debate_count_findings`, `_run_codex_debate`, `run_debate_review`, `_build_findings_pool`, `_tally_votes`).

- [ ] **Step 1: Move the functions**
```bash
SRC=lib/review-debate.sh
NEW=lib/review-debate-agents.sh
FNS=(run_agent_a run_agent_verify run_agent_b run_critique_and_refine run_vote run_synthesize)
```
Header: `# Debate agent runners (Impact Analyst, Quality Auditor, adversarial verifier, critique-refine, vote, synthesize) with their prompts.`

- [ ] **Step 2: Wire into bin/mra.sh**

Add after the `source "$MRA_DIR/lib/review-debate.sh"` line:
```bash
source "$MRA_DIR/lib/review-debate-agents.sh"
```

- [ ] **Step 3: Wire into tests**

`grep -l 'lib/review-debate\.sh' tests/*.sh`; add `source ".../lib/review-debate-agents.sh"` after the `lib/review-debate.sh` source line in each.

- [ ] **Step 4: Verify**

Per-task verification (with `SRC=lib/review-debate.sh`). Additionally:
```bash
[ "$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' lib/review-debate.sh)" = 8 ] && echo "review-debate.sh has 8 functions (OK)" || echo "review-debate.sh function count wrong"
```
Note: `_debate_verdict_of` is a one-line function (`^_debate_verdict_of() { ...; }`) — it stays; confirm it's still present. Guard: `test_review_debate.sh`, `test_review_debate_codex.sh` + `./test.sh` counts unchanged.

- [ ] **Step 5: Commit**
```bash
git add lib/review-debate-agents.sh lib/review-debate.sh bin/mra.sh tests
git commit -m "refactor(review): extract review-debate-agents.sh from review-debate.sh (#12)"
```

---

## Self-Review

**Spec coverage:**
- `review.sh` → 4 modules (json/strategy/pr-discussion/post) → Tasks 1–4. ✅
- `review-debate.sh` → `review-debate-agents.sh` → Task 5. ✅
- Behavior-preserving relocation, tests as guards → shared mechanism + per-task verification. ✅
- Naming collisions resolved → `review-strategy.sh`, `review-pr-discussion.sh`. ✅
- bin/mra.sh sourcing → Step 2 of each task. ✅
- Test-file sourcing → Step 3 of each task. ✅

**Function accounting (no loss/duplication):** review.sh 26 = 7 (T1) + 3 (T2) + 5 (T3) + 9 (T4) + 2 (stay). review-debate.sh 14 = 6 (T5) + 8 (stay). Every function is moved exactly once or explicitly stays. ✅

**Placeholder scan:** the shared mechanism gives the exact `awk` recipe and verification commands; per-task steps give exact function lists, exact source lines, and exact grep assertions. The one judgment step (orphaned-comment cleanup) is bounded and defined. No TBD/TODO.

**Consistency:** module names match between spec, tasks, `bin/mra.sh` source lines, and test-wiring greps. The `SRC`/`NEW`/`FNS` variables are consistent with the shared mechanism in every task.
