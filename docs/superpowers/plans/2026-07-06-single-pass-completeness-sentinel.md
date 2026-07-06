# Single-pass review completeness sentinel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the single-pass (light/standard) inline review path a completion sentinel so a cut-off / sentinel-less review is posted as a neutral REVIEW_INCOMPLETE COMMENT, never a false APPROVE.

**Architecture:** Extract the verdict-sentinel primitives (token, verdict parser, neutral-incomplete JSON) from `lib/review-debate.sh` into a shared `lib/review-verdict.sh`; require the sentinel in the inline reviewer prompt; gate the inline single-pass path on it via a testable helper `_review_singlepass_body`.

**Tech Stack:** Bash, jq. Entry point `bin/mra.sh` runs `set -euo pipefail`. Tests are `tests/test_*.sh` run by `test.sh`.

**Spec:** `docs/superpowers/specs/2026-07-06-single-pass-completeness-sentinel-design.md`
**Issue:** #8. **Branch:** `feat/single-pass-completeness-sentinel`.

## Global Constraints

- Scope is **inline (`--pr`) only**. Do NOT touch the terminal branch (`claude_invoke --stream`) or its output.
- Fail-safe: empty response, missing sentinel, or unparseable JSON → REVIEW_INCOMPLETE, NEVER APPROVE.
- Behaviour-preserving refactor: `tests/test_review_debate.sh` and the full suite (`bash test.sh`, currently 68 shell + 24 node) must stay green.
- Reuse, don't duplicate: single-pass and debate share ONE sentinel definition.
- `MRA_REVIEW_SENTINEL_TOKEN` value stays exactly `"MRA-REVIEW-COMPLETE"`.

---

### Task 1: Shared verdict contract — `lib/review-verdict.sh`

**Files:**
- Create: `lib/review-verdict.sh`
- Modify: `bin/mra.sh` (add a `source` line)
- Test: `tests/test_review_verdict.sh` (create)

**Interfaces:**
- Produces:
  - `MRA_REVIEW_SENTINEL_TOKEN` — string `"MRA-REVIEW-COMPLETE"`.
  - `review_verdict_of <text>` → prints `APPROVED` | `CHANGES_REQUESTED` | `NONE`.
  - `review_incomplete_json [reason]` → prints ONE JSON object `{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — <reason>","comments":[]}`.

- [ ] **Step 1: Write the failing test** — create `tests/test_review_verdict.sh`:

```bash
#!/usr/bin/env bash
# Shared review verdict-sentinel primitives (lib/review-verdict.sh).
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/review-verdict.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# token value is stable
eq "token value" "MRA-REVIEW-COMPLETE" "$MRA_REVIEW_SENTINEL_TOKEN"

# review_verdict_of classification
eq "approved sentinel"  "APPROVED"          "$(review_verdict_of 'body ===MRA-REVIEW-COMPLETE: APPROVED===')"
eq "changes sentinel"   "CHANGES_REQUESTED" "$(review_verdict_of 'x ===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED=== ')"
sentinel_after_json="$(printf '%s\n%s' '{"status":"APPROVED","comments":[]}' '===MRA-REVIEW-COMPLETE: APPROVED===')"
eq "sentinel after json" "APPROVED"         "$(review_verdict_of "$sentinel_after_json")"
eq "no sentinel"        "NONE"              "$(review_verdict_of '{"status":"APPROVED","comments":[]}')"
eq "empty -> none"      "NONE"              "$(review_verdict_of '')"

# review_incomplete_json is valid, neutral, never approves
J="$(review_incomplete_json)"
eq "incomplete is valid json" "0" "$(echo "$J" | jq . >/dev/null 2>&1; echo $?)"
eq "incomplete status COMMENT" "COMMENT" "$(echo "$J" | jq -r .status)"
eq "incomplete no comments"    "0"       "$(echo "$J" | jq '.comments | length')"
case "$(echo "$J" | jq -r .summary)" in *REVIEW_INCOMPLETE*) ok "summary carries sentinel word";; *) fail "summary missing REVIEW_INCOMPLETE";; esac
# custom reason is carried
case "$(review_incomplete_json 'custom reason here.' | jq -r .summary)" in *"custom reason here."*) ok "custom reason carried";; *) fail "custom reason dropped";; esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_verdict.sh`
Expected: FAIL — `lib/review-verdict.sh` does not exist (source error / functions undefined).

- [ ] **Step 3: Write minimal implementation** — create `lib/review-verdict.sh`:

```bash
#!/usr/bin/env bash
# Shared review verdict-sentinel contract, used by BOTH the debate path
# (lib/review-debate.sh) and the single-pass path (lib/review.sh). Kept in one
# place so a review can never be judged complete by two different rules.

# The sentinel a completed review ends its output with:
#   ===MRA-REVIEW-COMPLETE: APPROVED===
#   ===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
# Absence == the review did not finish (cutoff/failure), never an approval.
MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"

# Extract a declared verdict from arbitrary review text: APPROVED |
# CHANGES_REQUESTED | NONE. CHANGES_REQUESTED wins if both appear.
review_verdict_of() {
  if printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*CHANGES_REQUESTED"; then
    printf 'CHANGES_REQUESTED'
  elif printf '%s\n' "$1" | grep -qE "${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*APPROVED"; then
    printf 'APPROVED'
  else
    printf 'NONE'
  fi
}

# The canonical neutral "review did not complete" verdict as ONE JSON object.
# $1 = optional full reason clause (already past "⚠️ REVIEW_INCOMPLETE — ").
# status COMMENT + empty comments => the approve gate passes it through, never
# APPROVE. jq -n builds it so the reason is safely escaped.
review_incomplete_json() {
  local reason="${1:-the single-pass review did not emit a completion sentinel (likely a max-turns cutoff or a failed call). This is NOT an approval; re-run or review manually.}"
  jq -cn --arg s "⚠️ REVIEW_INCOMPLETE — ${reason}" \
    '{status:"COMMENT", summary:$s, comments:[]}'
}
```

- [ ] **Step 4: Add the source line to `bin/mra.sh`** — after `source "$MRA_DIR/lib/colors.sh"` (line 7), before `lib/review-select.sh`. Place it right after the `claude-invoke.sh` source (both are low-level, dependency-free helpers):

Change:
```bash
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"
```
to:
```bash
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"
source "$MRA_DIR/lib/review-verdict.sh"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_review_verdict.sh`
Expected: PASS (all lines `PASS:`, `Failed: 0`). Also `bash -n lib/review-verdict.sh` clean.

- [ ] **Step 6: Commit**

```bash
git add lib/review-verdict.sh tests/test_review_verdict.sh bin/mra.sh
git commit -m "feat(review): shared review-verdict contract (token, verdict_of, incomplete_json) (#8)"
```

---

### Task 2: Point the debate path at the shared contract

**Files:**
- Modify: `lib/review-debate.sh` (lines 23, 26–34, 197)
- Modify: `tests/test_review_debate.sh` (add a `source` line)
- Test: `tests/test_review_debate.sh` (existing — must stay green)

**Interfaces:**
- Consumes: `MRA_REVIEW_SENTINEL_TOKEN`, `review_verdict_of`, `review_incomplete_json` (Task 1).
- Produces: `_debate_verdict_of` remains callable (thin alias) for any other reference.

- [ ] **Step 1: Update the debate test to source the shared lib first** — in `tests/test_review_debate.sh`, after `source "$SCRIPT_DIR/lib/colors.sh"` add:

```bash
source "$SCRIPT_DIR/lib/review-verdict.sh"
```

- [ ] **Step 2: Run the debate test to confirm it still passes BEFORE refactor**

Run: `bash tests/test_review_debate.sh`
Expected: PASS (baseline; the sourced shared lib does not yet conflict — the local defs still win).

- [ ] **Step 3: Refactor `lib/review-debate.sh`** — three edits:

(a) Delete the local token definition (now owned by review-verdict.sh). Remove line 23:
```bash
MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"
```
Replace the comment block + line 23 so the file explains the move; keep the surrounding sentinel-explaining comment but drop the assignment:
```bash
# The sentinel token + verdict parser now live in lib/review-verdict.sh so the
# debate and single-pass paths judge completeness by one rule. _debate_verdict_of
# is kept as a thin alias for readability at debate call sites.
```

(b) Replace the `_debate_verdict_of` function body (lines 26–34) with a delegating alias:
```bash
_debate_verdict_of() { review_verdict_of "$1"; }
```

(c) Replace the inline REVIEW_INCOMPLETE literal at line 197:
```bash
    echo '{"status":"COMMENT","summary":"⚠️ REVIEW_INCOMPLETE — at least one analysis agent did not finish (no completion verdict; likely an agent failure or a max-turns cutoff — try MRA_REVIEW_AGENT_MAX_TURNS or a PKB). This is NOT an approval; re-run or review manually.","comments":[]}'
```
with:
```bash
    review_incomplete_json "at least one analysis agent did not finish (no completion verdict; likely an agent failure or a max-turns cutoff — try MRA_REVIEW_AGENT_MAX_TURNS or a PKB). This is NOT an approval; re-run or review manually."
```

- [ ] **Step 4: Run the debate test + full suite to verify green**

Run: `bash tests/test_review_debate.sh && bash -n lib/review-debate.sh`
Expected: PASS, syntax clean.
Run: `bash test.sh 2>&1 | grep -E "shell tests:|mcp-server :"`
Expected: `shell tests: N passed, 0 failed` (N is now 69 with the new verdict test).

- [ ] **Step 5: Commit**

```bash
git add lib/review-debate.sh tests/test_review_debate.sh
git commit -m "refactor(review): debate path uses the shared verdict contract (#8)"
```

---

### Task 3: Require the sentinel in the inline reviewer prompt

**Files:**
- Modify: `lib/review-prompt.sh` (end of the `inline` `output_instructions`, ~line 110)
- Test: `tests/test_review_prompt_sentinel.sh` (create)

**Interfaces:**
- Consumes: `build_review_prompt` (existing) with `output_mode` `inline` | `terminal`.
- Produces: the inline prompt string now contains `MRA-REVIEW-COMPLETE`.

- [ ] **Step 1: Write the failing test** — create `tests/test_review_prompt_sentinel.sh`:

```bash
#!/usr/bin/env bash
# build_review_prompt: inline mode requires the completion sentinel; terminal does not.
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-prompt.sh"
# stub collaborators build_review_prompt may call for context
review_diff_text()  { echo "diff"; }
review_diff_files() { echo "x"; }

errors=0; pass=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

inline=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" inline range "" 2>/dev/null)
case "$inline" in *"MRA-REVIEW-COMPLETE"*) ok "inline prompt requires sentinel";; *) fail "inline prompt missing sentinel instruction";; esac

term=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" terminal range "" 2>/dev/null)
case "$term" in *"MRA-REVIEW-COMPLETE"*) fail "terminal prompt should NOT mention sentinel";; *) ok "terminal prompt unchanged";; esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_prompt_sentinel.sh`
Expected: FAIL on "inline prompt missing sentinel instruction".

- [ ] **Step 3: Implement** — in `lib/review-prompt.sh`, the inline `output_instructions` string ends at line 110 with `- For API breaking changes, mention which consumer file and line is affected.'`. Append the sentinel instruction INSIDE that single-quoted string, before its closing `'`:

```bash
- For API breaking changes, mention which consumer file and line is affected.

## Completion (REQUIRED)
After the JSON object, output EXACTLY ONE final line on its own — it confirms the
review finished:
===MRA-REVIEW-COMPLETE: APPROVED===           (status APPROVED)
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===   (status CHANGES_REQUESTED)
Omitting this line marks the review INCOMPLETE (it will not be treated as an approval).'
```

(Only the inline branch — leave the `else` / terminal `output_instructions` untouched.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_prompt_sentinel.sh`
Expected: PASS. Also `bash -n lib/review-prompt.sh` clean.

- [ ] **Step 5: Commit**

```bash
git add lib/review-prompt.sh tests/test_review_prompt_sentinel.sh
git commit -m "feat(review): inline single-pass prompt requires the completion sentinel (#8)"
```

---

### Task 4: Gate the inline single-pass path on the sentinel

**Files:**
- Modify: `lib/review.sh` (add `_review_singlepass_body`; rewrite the inline branch ~505–526)
- Test: `tests/test_review_singlepass_gate.sh` (create)

**Interfaces:**
- Consumes: `review_verdict_of`, `review_incomplete_json` (Task 1), `extract_json` (existing, `lib/review.sh`).
- Produces: `_review_singlepass_body <raw>` → prints ONE valid JSON object: the extracted+validated review JSON when the raw output carries a sentinel AND parses; otherwise `review_incomplete_json`.

- [ ] **Step 1: Write the failing test** — create `tests/test_review_singlepass_gate.sh`:

```bash
#!/usr/bin/env bash
# _review_singlepass_body: sentinel + validity gate for single-pass inline review.
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-verdict.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/review.sh"

errors=0; pass=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }
status_of(){ echo "$1" | jq -r .status 2>/dev/null; }

GOOD='{"status":"APPROVED","summary":"ok","comments":[]}'

# valid JSON WITH sentinel -> returned as-is (extracted)
out=$(_review_singlepass_body "$(printf '%s\n%s' "$GOOD" '===MRA-REVIEW-COMPLETE: APPROVED===')")
[[ "$(status_of "$out")" == "APPROVED" ]] && ok "sentinel+valid -> APPROVED body" || fail "sentinel+valid: got [$out]"

# valid JSON WITHOUT sentinel -> REVIEW_INCOMPLETE (never APPROVED)
out=$(_review_singlepass_body "$GOOD")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "no sentinel -> COMMENT" || fail "no sentinel: got [$out]"
case "$(echo "$out" | jq -r .summary)" in *REVIEW_INCOMPLETE*) ok "no sentinel -> REVIEW_INCOMPLETE";; *) fail "no sentinel summary: [$out]";; esac

# empty -> REVIEW_INCOMPLETE
out=$(_review_singlepass_body "")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "empty -> COMMENT" || fail "empty: got [$out]"

# sentinel present but unparseable body -> REVIEW_INCOMPLETE
out=$(_review_singlepass_body "$(printf '%s\n%s' 'not json at all' '===MRA-REVIEW-COMPLETE: APPROVED===')")
[[ "$(status_of "$out")" == "COMMENT" ]] && ok "sentinel+garbage -> COMMENT" || fail "sentinel+garbage: got [$out]"

# always emits exactly one valid JSON object
echo "$out" | jq . >/dev/null 2>&1 && ok "always valid json" || fail "not valid json: [$out]"

# wiring: review.sh actually calls the helper on the inline path
grep -q '_review_singlepass_body' "$MRA_DIR/lib/review.sh" && ok "inline path uses _review_singlepass_body" || fail "review.sh does not call _review_singlepass_body"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_singlepass_gate.sh`
Expected: FAIL — `_review_singlepass_body` undefined.

- [ ] **Step 3: Add the helper** — in `lib/review.sh`, immediately ABOVE `extract_json()` (currently line 639), add:

```bash
# Resolve a single-pass raw review response into the JSON to post. A missing
# completion sentinel (#8), an empty response, or unparseable JSON all mean the
# review did not cleanly complete → the neutral REVIEW_INCOMPLETE verdict (never
# APPROVE). Otherwise the extracted, validated review JSON. Always prints ONE
# valid JSON object.
_review_singlepass_body() {
  local raw="$1"
  if [[ -z "$raw" || "$(review_verdict_of "$raw")" == "NONE" ]]; then
    review_incomplete_json; return 0
  fi
  local j; j=$(extract_json "$raw")
  if echo "$j" | jq . &>/dev/null; then
    printf '%s' "$j"
  else
    review_incomplete_json
  fi
}
```

- [ ] **Step 4: Rewrite the inline branch** — in `lib/review.sh`, replace the inline block (from `local review_json` down through the `post_inline_review` call, currently ~509–526):

```bash
    # Inline mode: get JSON, parse, post to GitHub. `|| true` keeps a total
    # claude failure from aborting under `set -e` — we handle empty below.
    local review_json
    review_json=$(claude_invoke review -p "$prompt" "${claude_args[@]}") || true

    if [[ -z "$review_json" ]]; then
      log_error "Claude returned empty response" "review"
      return 1
    fi

    # Try to extract JSON from response (Claude might wrap it in markdown)
    review_json=$(extract_json "$review_json")

    if ! echo "$review_json" | jq . &>/dev/null; then
      log_error "Claude did not return valid JSON. Raw output:" "review"
      echo "$review_json"
      return 1
    fi

    post_inline_review "$project_dir" "$pr_number" "$review_json"
```

with:

```bash
    # Inline mode: get JSON, gate on the completion sentinel, post to GitHub.
    # `|| true` keeps a total claude failure from aborting under `set -e`.
    local review_json raw_review
    raw_review=$(claude_invoke review -p "$prompt" "${claude_args[@]}") || true
    # Missing sentinel / empty / unparseable => neutral REVIEW_INCOMPLETE (#8),
    # never a false APPROVE. _review_singlepass_body always yields valid JSON.
    review_json=$(_review_singlepass_body "$raw_review")
    # The inline schema only permits APPROVED/CHANGES_REQUESTED, so a COMMENT
    # status can ONLY be the neutral REVIEW_INCOMPLETE verdict — log it.
    if [[ "$(printf '%s' "$review_json" | jq -r .status)" == "COMMENT" ]]; then
      log_warn "single-pass review incomplete (no completion sentinel / empty / unparseable) — posting REVIEW_INCOMPLETE" "review"
    fi
    post_inline_review "$project_dir" "$pr_number" "$review_json"
```

Note: `review_json` stays assigned for the trailing `_review_pkb_auto_update "$project" … "${review_json:-}" &` call (unchanged) — a REVIEW_INCOMPLETE body simply gives the PKB updater nothing actionable.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_review_singlepass_gate.sh`
Expected: PASS. Also `bash -n lib/review.sh` clean.

- [ ] **Step 6: Run the full suite**

Run: `bash test.sh 2>&1 | grep -E "shell tests:|mcp-server :"`
Expected: `shell tests: N passed, 0 failed`, `mcp-server : ok`.

- [ ] **Step 7: Commit**

```bash
git add lib/review.sh tests/test_review_singlepass_gate.sh
git commit -m "feat(review): gate inline single-pass on the completion sentinel (#8)"
```

---

### Task 5: Verify end-to-end + shellcheck

**Files:** none (verification only)

- [ ] **Step 1: shellcheck the new/changed files (CI parity, `-S error`)**

Run: `shellcheck -S error lib/review-verdict.sh lib/review.sh lib/review-debate.sh lib/review-prompt.sh tests/test_review_verdict.sh tests/test_review_prompt_sentinel.sh tests/test_review_singlepass_gate.sh`
Expected: no output (clean). Fix any `SC` error inline; re-run.

- [ ] **Step 2: Integration smoke — sentinel-less single-pass posts REVIEW_INCOMPLETE, not APPROVE**

Run:
```bash
bash -c '
set -euo pipefail
source lib/colors.sh; source lib/review-verdict.sh; source lib/project-path.sh; source lib/review.sh
# even with the approve policy ON, a sentinel-less APPROVED must not approve
export MRA_REVIEW_APPROVE_IF_NO_HIGH=1 MRA_REVIEW_ALLOW_APPROVE=1
body=$(_review_singlepass_body "{\"status\":\"APPROVED\",\"summary\":\"lgtm\",\"comments\":[]}")
eff=$(_review_effective_status "$(echo "$body" | jq -r .status)" "$body")
echo "posted status=$(echo "$body" | jq -r .status)  effective=$eff"
[[ "$eff" != "APPROVED" ]] && echo "PASS: sentinel-less body never approves" || { echo "FAIL: approved a sentinel-less review"; exit 1; }
'
```
Expected: `posted status=COMMENT  effective=COMMENT` then `PASS: sentinel-less body never approves`.

- [ ] **Step 3: Full suite green**

Run: `bash test.sh 2>&1 | tail -4`
Expected: `shell tests: N passed, 0 failed`, `mcp-server : ok`.

- [ ] **Step 4: Push the branch**

```bash
GH_TOKEN=$(gh auth token --user hanfour) git push -u origin feat/single-pass-completeness-sentinel
```
