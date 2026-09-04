#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/personas.sh"
source "$SCRIPT_DIR/lib/plan-council.sh"
source "$SCRIPT_DIR/lib/args.sh"
# call_model routes through the review path's credential isolation, which
# lives in review-provider.sh (loaded first by bin/mra.sh). State the
# dependency here rather than inherit it from load order.
# call_model copies the operator's codex credential and reads their
# config.toml to learn the provider transport. Without an isolated HOME this
# file would run against the real ones — and on failure would print the
# internal relay host into the log it keeps. Give it a fixture instead.
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/.claude"
# The isolation now refuses to run claude with no credential rather than making
# a call that cannot succeed. Give the fixture one; the real Keychain is not
# reachable from a fake HOME, which is what used to break claude reviews.
printf '{"claudeAiOauth":{"accessToken":"test-only-token"}}\n' > "$FAKE_HOME/.claude/.credentials.json"
printf '{"OPENAI_API_KEY":"plan-council-test-key"}\n' > "$FAKE_HOME/.codex/auth.json"
cat > "$FAKE_HOME/.codex/config.toml" <<'TOML'
model_provider = "TestProvider"
[model_providers.TestProvider]
name = "TestProvider"
base_url = "https://relay.example.test:2880"
wire_api = "responses"
requires_openai_auth = true
TOML
export HOME="$FAKE_HOME" CODEX_HOME="$FAKE_HOME/.codex"
# This file tests call_model's dispatch shape, not the sandbox policy. Where
# sandbox-exec is unavailable — Linux — the isolation refuses codex outright
# (tests/test_plan_credential_isolation.sh is what asserts that, per platform),
# so opt in explicitly here to keep the dispatch reachable everywhere.
export MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1

# call_model now routes claude through claude_invoke (retry + time bound +
# diagnosable failure), so that library is a dependency too.
source "$SCRIPT_DIR/lib/claude-invoke.sh"
source "$SCRIPT_DIR/lib/review-provider.sh"
source "$SCRIPT_DIR/lib/model-provider.sh"

errors=0

output=$(default_plan_personas)
for p in security-auditor api-contract-guardian performance-hawk; do
  if [[ "$output" != *"$p"* ]]; then
    echo "FAIL: default plan personas missing $p"; errors=$((errors+1))
  fi
done

prompt=$(build_plan_prompt "refactoring-sage" "Migrate auth to JWT" "" "")
if [[ "$prompt" != *"ROLE: Refactoring Sage"* ]]; then
  echo "FAIL: plan prompt missing ROLE"; errors=$((errors+1))
fi
if [[ "$prompt" != *"Migrate auth to JWT"* ]]; then
  echo "FAIL: plan prompt missing task"; errors=$((errors+1))
fi
if [[ "$prompt" != *"independent"* ]]; then
  echo "FAIL: plan prompt missing independence instruction"; errors=$((errors+1))
fi

# Unknown persona should fail
if build_plan_prompt "bogus-xyz" "task" 2>/dev/null; then
  echo "FAIL: build_plan_prompt should reject unknown persona"; errors=$((errors+1))
fi

# PKB context should be injected
prompt_pkb=$(build_plan_prompt "security-auditor" "migrate auth" "SENTINEL_PKB")
if [[ "$prompt_pkb" != *"SENTINEL_PKB"* ]]; then
  echo "FAIL: plan prompt missing PKB context"; errors=$((errors+1))
fi

# --- model-provider: call_model dispatch + ensure_codex_available ---
MP_DIR=$(mktemp -d); MP_REC="$MP_DIR/rec"
# stub "claude": record flattened args, emit fixed output
cat > "$MP_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$MP_REC"
echo "<claude-output>"
STUB
# stub "codex": record flattened args + cwd, emit fixed output
cat > "$MP_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex: $* | cwd=$(pwd)" >> "$MP_REC"
echo "<codex-output>"
STUB
chmod +x "$MP_DIR/claude" "$MP_DIR/codex"
export MP_REC

# 1. call_model claude forwards -p / --disallowedTools / --model / --max-turns (param)
: > "$MP_REC"
out=$(MRA_CLAUDE_BIN="$MP_DIR/claude" call_model claude "PROMPT-A" sonnet "$MP_DIR" "" 6)
[[ "$out" == "<claude-output>" ]] || { echo "FAIL: call_model claude output: $out"; errors=$((errors+1)); }
rec=$(cat "$MP_REC")
case "$rec" in *"-p"*) : ;; *) echo "FAIL: claude missing -p: $rec"; errors=$((errors+1)) ;; esac
# 比對整份共用清單，不是硬寫的前綴：寫成字面量時，清單多一個工具這條斷言
# 照樣通過，於是「這個呼叫點跟上了嗎」變成沒人守。清單本身由
# tests/test_disallowed_tools.sh 驗。
case "$rec" in *"--disallowedTools $MRA_CLAUDE_DISALLOWED_TOOLS"*) : ;; *) echo "FAIL: claude missing disallowedTools: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--model sonnet"*) : ;; *) echo "FAIL: claude missing --model: $rec"; errors=$((errors+1)) ;; esac
# This one passes 6 explicitly — it asserts call_model FORWARDS the cap it was
# given, not what the council chooses.
case "$rec" in *"--max-turns 6"*) : ;; *) echo "FAIL: call_model did not forward the given max-turns: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--setting-sources project"*) : ;; *) echo "FAIL: claude missing --setting-sources project: $rec"; errors=$((errors+1)) ;; esac
# max_turns is a real parameter (4 for the synthesizer)
: > "$MP_REC"
MRA_CLAUDE_BIN="$MP_DIR/claude" call_model claude "PROMPT-S" sonnet "$MP_DIR" "" 4 >/dev/null
case "$(cat "$MP_REC")" in *"--max-turns 4"*) : ;; *) echo "FAIL: claude should forward --max-turns 4: $(cat "$MP_REC")"; errors=$((errors+1)) ;; esac

# 2. call_model codex uses `exec -s read-only` and runs with cwd = project_dir
: > "$MP_REC"
out=$(MRA_CODEX_BIN="$MP_DIR/codex" call_model codex "PROMPT-B" sonnet "$MP_DIR" "" 6)
[[ "$out" == "<codex-output>" ]] || { echo "FAIL: call_model codex output: $out"; errors=$((errors+1)); }
rec=$(cat "$MP_REC")
# Sandboxing must land on exactly one layer: codex stands down where mra's
# sandbox-exec wraps it (nesting a deny-default profile is refused by macOS and
# would make every command fail), and sandboxes itself where mra cannot.
if command -v sandbox-exec >/dev/null 2>&1; then
  case "$rec" in *"--dangerously-bypass-approvals-and-sandbox"*) : ;; *) echo "FAIL: codex nests its own sandbox inside mra's: $rec"; errors=$((errors+1)) ;; esac
else
  case "$rec" in *"-s read-only"*) : ;; *) echo "FAIL: no sandbox on either layer: $rec"; errors=$((errors+1)) ;; esac
fi
case "$rec" in *"cwd=$MP_DIR"*) : ;; *) echo "FAIL: codex cwd should be project_dir: $rec"; errors=$((errors+1)) ;; esac

# 2b. Turn caps: the expert cap was hardcoded 6 and real experts hit it
# ("Error: Reached max turns (6)" x3 in a live `mra plan --dual`). It must clear
# the review path's measured requirement, and stay overridable.
[[ "$(_plan_expert_max_turns)" -ge 10 ]] \
  || { echo "FAIL: expert cap $(_plan_expert_max_turns) is below what a real expert needed"; errors=$((errors+1)); }
[[ "$(MRA_PLAN_EXPERT_MAX_TURNS=7 _plan_expert_max_turns)" == "7" ]] \
  || { echo "FAIL: MRA_PLAN_EXPERT_MAX_TURNS ignored"; errors=$((errors+1)); }
[[ "$(MRA_PLAN_SYNTH_MAX_TURNS=9 _plan_synth_max_turns)" == "9" ]] \
  || { echo "FAIL: MRA_PLAN_SYNTH_MAX_TURNS ignored"; errors=$((errors+1)); }

# 3. unknown provider -> non-zero
if call_model bogus "P" sonnet "$MP_DIR" "" 6 >/dev/null 2>&1; then echo "FAIL: unknown provider should fail"; errors=$((errors+1)); fi

# 4. ensure_codex_available: present (stub) vs absent
if ! MRA_CODEX_BIN="$MP_DIR/codex" ensure_codex_available; then echo "FAIL: ensure_codex_available should pass with a real bin"; errors=$((errors+1)); fi
if MRA_CODEX_BIN="__nope_not_a_real_bin__" ensure_codex_available; then echo "FAIL: ensure_codex_available should fail when bin absent"; errors=$((errors+1)); fi
rm -rf "$MP_DIR"; unset MP_REC

# --- run_plan_council dual mode (stub both bins) ---
RC_DIR=$(mktemp -d); RC_REC="$RC_DIR/rec"; RC_PROJ="$RC_DIR/proj"; mkdir -p "$RC_PROJ"
cat > "$RC_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$RC_REC"
echo "<claude-output>"
STUB
cat > "$RC_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex: $*" >> "$RC_REC"
echo "<codex-output>"
STUB
cat > "$RC_DIR/codex-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$RC_DIR/claude" "$RC_DIR/codex" "$RC_DIR/codex-fail"
export RC_REC

# 5. dual=true, 1 persona -> claude(expert,6) + codex(expert) + claude(synth,4) all ran; tags present; synth output returned
: > "$RC_REC"
out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" true)
case "$out" in *"<claude-output>"*) : ;; *) echo "FAIL: dual run should return synth (claude) output: $out"; errors=$((errors+1)) ;; esac
rec=$(cat "$RC_REC")
case "$rec" in *"--max-turns $(_plan_expert_max_turns)"*) : ;; *) echo "FAIL: dual expert claude cap should match _plan_expert_max_turns: $rec"; errors=$((errors+1)) ;; esac
if command -v sandbox-exec >/dev/null 2>&1; then
  case "$rec" in *"--dangerously-bypass-approvals-and-sandbox"*) : ;; *) echo "FAIL: dual missing codex expert call: $rec"; errors=$((errors+1)) ;; esac
else
  case "$rec" in *"-s read-only"*) : ;; *) echo "FAIL: dual missing codex expert call: $rec"; errors=$((errors+1)) ;; esac
fi
case "$rec" in *"--max-turns 4"*) : ;; *) echo "FAIL: dual missing synth claude --max-turns 4: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"[claude]"*) : ;; *) echo "FAIL: synth input missing [claude] tag: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"[codex]"*) : ;; *) echo "FAIL: synth input missing [codex] tag: $rec"; errors=$((errors+1)) ;; esac

# 6. dual=false (default) -> ONLY claude; codex never called; expert(6)+synth(4) present
: > "$RC_REC"
out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" false)
rec=$(cat "$RC_REC")
if printf '%s' "$rec" | grep -q 'codex:'; then echo "FAIL: non-dual must NOT call codex: $rec"; errors=$((errors+1)); fi
case "$rec" in *"--max-turns $(_plan_expert_max_turns)"*) : ;; *) echo "FAIL: non-dual expert cap should match _plan_expert_max_turns: $rec"; errors=$((errors+1)) ;; esac
case "$rec" in *"--max-turns 4"*) : ;; *) echo "FAIL: non-dual missing synth --max-turns 4: $rec"; errors=$((errors+1)) ;; esac
if printf '%s' "$rec" | grep -q '\[codex\]'; then echo "FAIL: non-dual synth input must not carry provider tags: $rec"; errors=$((errors+1)); fi

# 7. dual=true with a FAILING codex -> council still produces output (exit 0), sentinel reaches synth input
: > "$RC_REC"
if out=$(MRA_CLAUDE_BIN="$RC_DIR/claude" MRA_CODEX_BIN="$RC_DIR/codex-fail" \
  run_plan_council proj "$RC_PROJ" "do a thing" "security-auditor" sonnet "" "" "" true); then rc=0; else rc=$?; fi
[[ $rc -eq 0 ]] || { echo "FAIL: failing codex should not break the council (rc=$rc)"; errors=$((errors+1)); }
case "$out" in *"<claude-output>"*) : ;; *) echo "FAIL: council should still return synth output on codex failure: $out"; errors=$((errors+1)) ;; esac
case "$(cat "$RC_REC")" in *"no response"*) : ;; *) echo "FAIL: missing-side sentinel should reach synth input: $(cat "$RC_REC")"; errors=$((errors+1)) ;; esac
rm -rf "$RC_DIR"; unset RC_REC

# --- mra plan --dual dispatch (real CLI via MRA_WORKSPACE) ---
PD_WS=$(mktemp -d); mkdir -p "$PD_WS/.collab" "$PD_WS/app"
echo '{"gitOrg":"x","projects":{"app":{"deps":{},"consumedBy":[]}}}' > "$PD_WS/.collab/dep-graph.json"
git -C "$PD_WS/app" init -b main &>/dev/null
git -C "$PD_WS/app" config user.email t@t.t; git -C "$PD_WS/app" config user.name t
git -C "$PD_WS/app" commit --allow-empty -m init &>/dev/null
# 8. --dual with codex absent -> preflight error, non-zero, council not convened
if out=$(MRA_WORKSPACE="$PD_WS" MRA_CODEX_BIN="__nope_not_real__" bash "$SCRIPT_DIR/bin/mra.sh" plan app "do a thing" --dual 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: --dual without codex should exit non-zero"; errors=$((errors+1)); }
case "$out" in *codex*) : ;; *) echo "FAIL: preflight error should mention codex: $out"; errors=$((errors+1)) ;; esac
case "$out" in *"convening council"*) echo "FAIL: council must NOT convene when codex absent: $out"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$PD_WS"
# 9. usage advertises --dual
grep -q 'plan .*--dual' "$SCRIPT_DIR/bin/mra.sh" || { echo "FAIL: usage should advertise plan --dual"; errors=$((errors+1)); }

if [[ $errors -eq 0 ]]; then
  echo "PASS: all plan-council tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
