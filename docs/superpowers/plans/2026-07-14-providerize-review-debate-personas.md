# Providerize Review Debate & Personas (Codex) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the default Codex review provider access to debate and personas, so advanced review no longer requires switching back to Claude.

**Architecture:** Two independent tracks both route through the existing `review_call_model` provider abstraction. Codex uses shapes that fit its single-pass, sanitized-snapshot execution model: debate becomes a 2-pass analysis→adversarial-verify pipeline merged with intersection semantics; personas become N parallel Codex passes. Claude's existing multi-turn agentic debate and personas are untouched.

**Tech Stack:** Bash, jq, the mra review provider layer (`lib/review-provider.sh`, `lib/review-verdict.sh`), Codex CLI (`codex exec`), test doubles via `MRA_CODEX_BIN`.

## Global Constraints

- No false-green: a Codex debate pass with a missing completion sentinel / empty / unparseable output MUST resolve to the neutral `REVIEW_INCOMPLETE` verdict, never an APPROVE. Reuse `lib/review-verdict.sh` primitives.
- Claude's existing debate (`run_debate_review` 5-stage flow) and persona invocation behavior MUST NOT change. Verify by keeping `tests/test_review_debate.sh` and existing persona tests green.
- No new config switches, env flags, or `dual + debate` combination (YAGNI).
- Provider values are exactly `claude` | `codex` at invocation; validate via existing `_review_provider_validate_backend` where a check is needed.
- Sentinel token is `MRA-REVIEW-COMPLETE` via `$MRA_REVIEW_SENTINEL_TOKEN`; do not hardcode.
- Follow existing test-harness pattern: Codex doubles via `MRA_CODEX_BIN`, unsandboxed test path via `MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1`, auth double under `$HOME/.codex/auth.json`, `MRA_CODEX_AUTH_FILE_TTL_SECONDS=0`.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/review-provider.sh` | Add optional merge-policy override arg to `_review_provider_merge_dual_json` (additive, back-compatible). |
| `lib/review-debate.sh` | Add `_run_codex_debate` (2-pass adversarial pipeline) + a provider branch in `run_debate_review` that delegates to it for Codex; Claude path unchanged. |
| `lib/review-personas.sh` | Add a `provider` parameter to `run_persona_review`; route the inner invocation through `review_call_model` instead of calling `claude_invoke` directly. |
| `lib/review.sh` | Remove the two Claude-only guards (personas + debate); thread `$review_provider` into both dispatch calls. |
| `agents/personas/*.md` | Compatibility scan; neutralize any Claude-only tool directives. |
| `tests/test_review_debate_codex.sh` | New. Unit-tests `_run_codex_debate` behavior with a Codex double. |
| `tests/test_review_personas_codex.sh` | New. Unit-tests Codex persona routing with a Codex double. |
| `README.md` | Update the "debate/personas remain Claude-only" self-stated limitation. |

---

## Task 1: Codex-native debate pipeline

**Files:**
- Modify: `lib/review-provider.sh` (`_review_provider_merge_dual_json`, the `policy=` line ~488)
- Modify: `lib/review-debate.sh` (add `_run_codex_debate`; add provider branch in `run_debate_review` after diff/changed_files are computed, ~line 105)
- Test: `tests/test_review_debate_codex.sh` (new)

**Interfaces:**
- Consumes: `review_call_model [--stream] <tag> <provider> <prompt> <model> <project_dir> <add_dirs> <max_turns> <system_prompt_file>` (returns raw provider output incl. sentinel); `_review_provider_singlepass_json <raw> <provider>` (extracts JSON body); `_review_provider_merge_dual_json <primary> <primary_raw> <secondary> <secondary_raw> [policy_override]` (returns merged review JSON, gates either-incomplete → COMMENT); `$MRA_REVIEW_SENTINEL_TOKEN`.
- Produces: `_run_codex_debate <tag> <base_prompt> <model> <project_dir> <add_dirs> <max_turns>` → prints a validated review JSON object `{status,summary,comments,blockerLedger}` to stdout. `run_debate_review` accepts `$16 = review_provider` (default `claude`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_debate_codex.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2}' > "$MRA_CONFIG"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/claude-invoke.sh"
source "$SCRIPT_DIR/lib/review-provider.sh"
source "$SCRIPT_DIR/lib/review.sh"
source "$SCRIPT_DIR/lib/review-debate.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

# --- Codex double harness (mirrors tests/test_review_provider.sh) ---
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init
REC="$TMP/rec"; export REC
export COUNT_FILE="$TMP/count"

# Two-call stub: call 1 = analysis (real + noise), call 2 = adversarial (drops noise).
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
echo "call=$n args=$*" >> "$REC"
if [[ "$n" == "1" ]]; then
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"pass1","comments":[{"path":"a.sh","line":1,"severity":"HIGH","body":"REAL-BUG"},{"path":"b.sh","line":2,"severity":"LOW","body":"REFUTED-NOISE"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
else
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"pass2 verified","comments":[{"path":"a.sh","line":1,"severity":"HIGH","body":"REAL-BUG"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
fi
STUB
chmod +x "$BIN/codex"

mkdir -p "$TMP/home/.codex"
cat > "$TMP/home/.codex/config.toml" <<'TOML'
model_provider = "OpenAI"
[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
requires_openai_auth = true
TOML
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"

run_debate() {
  HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" \
  MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 MRA_CODEX_BIN="$BIN/codex" \
  _run_codex_debate debate "REVIEW THIS DIFF" "" "$TMP/project" "" 6
}

# --- Scenario A: adversarial verify with intersection semantics ---
: > "$REC"; rm -f "$COUNT_FILE"
merged=$(run_debate)
[[ "$(printf '%s' "$merged" | jq -r .status)" == "CHANGES_REQUESTED" ]] \
  && pass "codex debate escalates to CHANGES_REQUESTED on a real blocker" \
  || fail "codex debate status wrong: $merged"
[[ "$(printf '%s' "$merged" | jq '.comments | length')" == "1" ]] \
  && pass "codex debate keeps only the re-verified finding" \
  || fail "codex debate comment count wrong: $merged"
case "$merged" in *REAL-BUG*) pass "codex debate retains the substantiated finding" ;; *) fail "missing REAL-BUG: $merged" ;; esac
case "$merged" in *REFUTED-NOISE*) fail "codex debate kept a refuted finding: $merged" ;; *) pass "codex debate drops the refuted finding" ;; esac
# adversarial wiring: pass2 prompt embeds pass1's finding text
rec=$(cat "$REC")
case "$rec" in *"call=2"*"REAL-BUG"*) pass "adversarial pass2 receives pass1 findings" ;; *) fail "pass2 did not receive pass1 findings: $rec" ;; esac

# --- Scenario B: no false-green when a pass is truncated ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
if [[ "$n" == "1" ]]; then
cat <<'OUT'
{"status":"APPROVED","summary":"pass1 clean","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
else
# truncated: valid JSON but NO sentinel
echo '{"status":"APPROVED","summary":"cut off mid-analysis","comments":[]}'
fi
STUB
chmod +x "$BIN/codex"
: > "$REC"; rm -f "$COUNT_FILE"
merged=$(run_debate)
[[ "$(printf '%s' "$merged" | jq -r .status)" == "COMMENT" ]] \
  && pass "truncated codex pass gates to non-approving COMMENT" \
  || fail "truncated pass was not gated: $merged"
case "$(printf '%s' "$merged" | jq -r .summary)" in *REVIEW_INCOMPLETE*) pass "truncated codex debate reports REVIEW_INCOMPLETE" ;; *) fail "missing REVIEW_INCOMPLETE: $merged" ;; esac

chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"
[[ "$errors" -eq 0 ]] && echo "All codex-debate tests passed" || { echo "$errors failures"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_debate_codex.sh`
Expected: FAIL — `_run_codex_debate: command not found` (function does not exist yet).

- [ ] **Step 3: Add the optional merge-policy override**

In `lib/review-provider.sh`, inside `_review_provider_merge_dual_json`, change the policy resolution line:

```bash
# before:
  policy=$(review_provider_dual_merge_policy)
# after:
  policy="${5:-$(review_provider_dual_merge_policy)}"
```

(No other change; the 5th arg is optional so all existing callers keep current behavior.)

- [ ] **Step 4: Add `_run_codex_debate` to `lib/review-debate.sh`**

Add this function near the other helpers (e.g. just above `run_debate_review`):

```bash
# Codex-native debate: Codex cannot run Claude's multi-turn agentic debate, so we
# approximate its find→verify spirit with two single-pass Codex analyses and keep
# only the findings that survive the adversarial second pass (intersection merge).
# A truncated/garbled pass (no sentinel) gates to REVIEW_INCOMPLETE via the shared
# dual-merge logic — never a false-green APPROVE.
#   _run_codex_debate <tag> <base_prompt> <model> <project_dir> <add_dirs> <max_turns>
_run_codex_debate() {
  local tag="$1" base_prompt="$2" model="$3" project_dir="$4" add_dirs="$5" max_turns="${6:-6}"
  local raw1 raw2 pass1_json findings adversarial_prompt

  raw1=$(review_call_model "$tag" codex "$base_prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "") || raw1=""
  pass1_json=$(_review_provider_singlepass_json "$raw1" codex)
  findings=$(printf '%s' "$pass1_json" | jq -r '
    .comments[]? | "- [\(.severity // "?")] \(.path // "?"):\(.line // "?") — \(.body // "")"' 2>/dev/null || true)

  adversarial_prompt=$(printf '%s\n\n%s\n\n%s\n' \
    "$base_prompt" \
    "## Adversarial verification
A prior reviewer reported the findings below. For EACH: try hard to REFUTE it — is it wrong, out-of-scope, or not substantiated by the actual diff? Keep ONLY findings you can substantiate against the diff; drop the rest. Do not introduce unrelated new issues." \
    "${findings:-(prior reviewer reported no findings)}")

  raw2=$(review_call_model "$tag" codex "$adversarial_prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "") || raw2=""

  # Intersection: a finding survives only if raised in pass 1 AND re-affirmed in pass 2.
  _review_provider_merge_dual_json codex "$raw1" codex "$raw2" intersection
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_review_debate_codex.sh`
Expected: PASS — `All codex-debate tests passed`.

- [ ] **Step 6: Add the provider branch in `run_debate_review`**

In `lib/review-debate.sh`, add a provider param and an early Codex delegation. First, add near the other positional locals (after `local range_expr="${15:-}"`):

```bash
  local review_provider="${16:-claude}"
```

Then, immediately after `changed_files` is computed (the block that runs `review_diff_files`), insert:

```bash
  # Codex cannot run the multi-turn agentic debate below; delegate to the
  # Codex-native 2-pass adversarial pipeline. Claude keeps the flow that follows.
  if [[ "$review_provider" == "codex" ]]; then
    local base_prompt
    base_prompt=$(build_review_prompt \
      "$project" "$project_dir" "$_graph_file" "$_base_ref" \
      "$project_type" "$consumers" "$_deps" "$has_api_change" \
      "$output_language" "inline" "$mode" "$range_expr")
    _run_codex_debate "debate" "$base_prompt" "$model" "$project_dir" \
      "$claude_add_dirs" "${MRA_REVIEW_AGENT_MAX_TURNS:-20}"
    return
  fi
```

- [ ] **Step 7: Verify Claude debate is unregressed**

Run: `bash tests/test_review_debate.sh`
Expected: PASS (all existing assertions — the `codex` branch is never taken with the default `claude` provider).

- [ ] **Step 8: Commit**

```bash
git add lib/review-provider.sh lib/review-debate.sh tests/test_review_debate_codex.sh
git commit -m "feat(review): codex-native 2-pass adversarial debate (#13)"
```

---

## Task 2: Codex personas

**Files:**
- Modify: `lib/review-personas.sh` (`run_persona_review`: add provider param at `$11`; replace the inner `claude_invoke` subshell body ~line 76)
- Scan: `agents/personas/*.md` (neutralize Claude-only tool directives if any)
- Test: `tests/test_review_personas_codex.sh` (new)

**Interfaces:**
- Consumes: `review_call_model <tag> <provider> <prompt> <model> <project_dir> <add_dirs> <max_turns> <system_prompt_file>`; `build_persona_prompt <persona> <diff> <changed_files> <consumers> <pkb_context> <lang_directive>`; `expand_add_dir_string <arrayname> <str>`.
- Produces: `run_persona_review <project> <project_dir> <diff> <changed_files> <personas> <consumers> <lang_directive> <model> <claude_add_dirs> <pkb_context> [provider]` — `provider` defaults to `claude`; behavior for Claude is unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/test_review_personas_codex.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2}' > "$MRA_CONFIG"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/claude-invoke.sh"
source "$SCRIPT_DIR/lib/review-provider.sh"
source "$SCRIPT_DIR/lib/review.sh"
source "$SCRIPT_DIR/lib/review-personas.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init
REC="$TMP/rec"; export REC

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex-persona: $*" >> "$REC"
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"persona found an issue","comments":[{"path":"app.txt","line":1,"severity":"MEDIUM","body":"PERSONA-FINDING"}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
STUB
chmod +x "$BIN/codex"

mkdir -p "$TMP/home/.codex"
cat > "$TMP/home/.codex/config.toml" <<'TOML'
model_provider = "OpenAI"
[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
requires_openai_auth = true
TOML
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"

: > "$REC"
findings=$(HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" \
  MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 \
  MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 MRA_CODEX_BIN="$BIN/codex" \
  run_persona_review "proj" "$TMP/project" "DIFF" "app.txt" \
    "security-auditor test-architect" "" "" "" "" "" codex)

case "$findings" in *PERSONA-FINDING*) pass "codex personas produce findings" ;; *) fail "no persona findings: $findings" ;; esac
rec=$(cat "$REC")
[[ "$(grep -c 'codex-persona:' "$REC")" == "2" ]] && pass "each persona runs a codex pass" || fail "expected 2 codex persona passes: $rec"
case "$rec" in *"exec --sandbox read-only"*) pass "personas route through the codex provider path" ;; *) fail "personas did not use codex exec: $rec" ;; esac

chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"
[[ "$errors" -eq 0 ]] && echo "All codex-persona tests passed" || { echo "$errors failures"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_personas_codex.sh`
Expected: FAIL — the inner call still runs `claude_invoke`, so `$REC` has no `codex-persona:` lines (the codex double is never invoked).

- [ ] **Step 3: Route personas through `review_call_model`**

In `lib/review-personas.sh`, add the provider parameter to `run_persona_review` (after the existing `pkb_context` local):

```bash
  local provider="${11:-claude}"
```

Then replace the inner invocation subshell body. Change:

```bash
      _review_without_github_credentials claude_invoke "review-persona" -p "$prompt" \
        "${_ad_arr[@]}" \
        --model "$model" \
        --max-turns "${MRA_REVIEW_PERSONA_MAX_TURNS:-8}" \
        --disallowedTools "Write,Edit,NotebookEdit"
```

to:

```bash
      review_call_model "review-persona" "$provider" "$prompt" "$model" \
        "$project_dir" "$claude_add_dirs" "${MRA_REVIEW_PERSONA_MAX_TURNS:-8}" ""
```

(`review_call_model`'s claude branch already applies `--disallowedTools Write,Edit,NotebookEdit` and expands `$claude_add_dirs`, so Claude behavior is preserved. The local `_ad_arr` expansion just above may now be unused — leave it if other lines reference it, otherwise remove the two `expand_add_dir_string`/`_ad_arr` lines.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_review_personas_codex.sh`
Expected: PASS — `All codex-persona tests passed`.

- [ ] **Step 5: Persona prompt compatibility scan**

Run: `grep -rniE 'claude|--append-system-prompt|--max-turns|use the .* tool|you have access to' agents/personas/*.md`
Expected: review each hit. Persona files should describe the review lens only. If any file instructs the model to use a Claude-specific tool or names Claude, edit it to a provider-neutral phrasing (e.g. describe the behavior, not the tool). If there are no hits, no edit is needed — record that in the commit body.

- [ ] **Step 6: Verify Claude personas are unregressed**

Run: `for t in tests/test_review*.sh; do bash "$t" >/dev/null 2>&1 && echo "OK $t" || echo "FAIL $t"; done`
Expected: every existing review test prints `OK` (Claude persona path still works via the `claude` default provider).

- [ ] **Step 7: Commit**

```bash
git add lib/review-personas.sh agents/personas tests/test_review_personas_codex.sh
git commit -m "feat(review): providerize personas for codex (#13)"
```

---

## Task 3: Wire dispatch, drop guards, update docs

**Files:**
- Modify: `lib/review.sh` (remove personas guard ~454-456; remove/replace debate guard ~458-465; pass `$review_provider` into the two dispatch calls ~554 and ~576)
- Modify: `README.md` (~120-124, the "debate and personas remain Claude-only" sentence)
- Test: full suite `./test.sh`

**Interfaces:**
- Consumes: `run_debate_review … "$review_provider"` (Task 1, `$16`); `run_persona_review … "$review_provider"` (Task 2, `$11`).
- Produces: `mra review <p> --provider codex --strategy debate` and `--provider codex --personas` run under Codex; no guard rejects them.

- [ ] **Step 1: Write the failing test (guard-removal assertion)**

Append to `tests/test_review_debate_codex.sh`, before the cleanup line, a guard-absence check that greps the source (fast, no full review run):

```bash
# --- Guards removed: review.sh no longer hard-blocks codex debate/personas ---
guard_src="$SCRIPT_DIR/lib/review.sh"
if grep -q 'strategy debate currently supports only --provider claude' "$guard_src"; then
  fail "debate claude-only guard still present in review.sh"
else
  pass "debate claude-only guard removed"
fi
if grep -q 'personas currently supports only --provider claude' "$guard_src"; then
  fail "personas claude-only guard still present in review.sh"
else
  pass "personas claude-only guard removed"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_review_debate_codex.sh`
Expected: FAIL — both guard strings are still present in `lib/review.sh`.

- [ ] **Step 3: Remove the personas guard**

In `lib/review.sh`, delete the block (currently ~454-456):

```bash
  if [[ "$review_personas_flag" == "true" && "$review_provider" != "claude" ]]; then
    log_error "--personas currently supports only --provider claude; Codex persona support is planned for the providerized debate phase" "review"
    return 1
  fi
```

- [ ] **Step 4: Remove the debate downgrade guard**

In `lib/review.sh`, delete the block (currently ~458-465):

```bash
  if [[ "$strategy" == "debate" && "$review_provider" != "claude" ]]; then
    if [[ "$force_strategy" == "debate" ]]; then
      log_error "--strategy debate currently supports only --provider claude; use --no-debate for Codex single-pass review" "review"
      return 1
    fi
    log_warn "provider $review_provider uses standard single-pass until debate is providerized" "review"
    strategy="standard"
  fi
```

- [ ] **Step 5: Thread the provider into both dispatch calls**

In `lib/review.sh`, in the persona dispatch (~554), add `"$review_provider"` as the final argument:

```bash
    persona_findings="$(run_persona_review \
      "$project" "$project_dir" "$persona_diff" "$persona_changed" \
      "$(default_review_personas)" "$consumers" "$persona_lang" "$model" \
      "$claude_add_dirs_str" "$pkb_context" "$review_provider")"
```

In the debate dispatch (~576), add `"$review_provider"` as the final argument:

```bash
    review_json=$(run_debate_review \
      "$project" "$project_dir" "$graph_file" "$base_ref" \
      "$project_type" "$consumers" "$deps" "$has_api_change" \
      "$output_language" "$model" "$claude_add_dirs_str" "$claude_focused_dirs_str" \
      "$pkb_context" "$mode" "$range_expr" "$review_provider")
```

- [ ] **Step 6: Run the codex-debate test to verify guards are gone**

Run: `bash tests/test_review_debate_codex.sh`
Expected: PASS — including the two new guard-absence assertions.

- [ ] **Step 7: Update README**

In `README.md`, replace the sentence (~120-124):

```
In this phase Codex runs single-pass
review; debate and personas remain Claude-only until the providerized debate
phase lands.
```

with:

```
Codex supports single-pass review, debate (a two-pass analysis→adversarial-verify
pipeline), and personas. Claude runs its multi-turn agentic debate; the two
providers each use the debate shape that fits their execution model.
```

- [ ] **Step 8: Run the full suite**

Run: `./test.sh`
Expected: PASS — the existing shell + MCP counts hold and the two new Codex tests are included/green. If `test.sh` does not auto-discover new `tests/test_*.sh`, confirm they are picked up (the suite globs `tests/test_*.sh`); otherwise run them explicitly and note it.

- [ ] **Step 9: Commit**

```bash
git add lib/review.sh README.md tests/test_review_debate_codex.sh
git commit -m "feat(review): allow codex debate/personas; drop claude-only guards, update docs (#13)"
```

---

## Self-Review

**Spec coverage:**
- Track 1 codex-native debate (pass1 → adversarial pass2 → intersection merge, no false-green) → Task 1. ✅
- Track 2 codex personas (route through `review_call_model`, per-persona codex pass, compat scan) → Task 2. ✅
- Remove 2 claude-only guards + thread provider into dispatch → Task 3. ✅
- Tests reuse PR #10 fake codex auth + `MRA_CODEX_BIN` double → Tasks 1 & 2 harness. ✅
- README self-stated limitation update → Task 3 Step 7. ✅
- Zero Claude regression → Task 1 Step 7, Task 2 Step 6, Task 3 Step 8. ✅

**Placeholder scan:** No TBD/TODO; every code + test step shows full content. Compat scan (Task 2 Step 5) is a real grep with a defined decision rule, not a vague "handle edge cases."

**Type consistency:** `_run_codex_debate` args/return match its use in `run_debate_review` (Task 1 Step 6) and its test (Step 1). `run_persona_review`'s new `$11 = provider` matches the dispatch call (Task 3 Step 5). `_review_provider_merge_dual_json`'s optional `$5 = policy_override` is consumed by `_run_codex_debate` with `intersection`. Sentinel via `$MRA_REVIEW_SENTINEL_TOKEN` throughout.
