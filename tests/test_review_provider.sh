#!/usr/bin/env bash
set -euo pipefail

# Pin the sentinel token so the fixtures below can spell it literally. A real
# run mints a per-run nonce (GHSA-5gjm-rqvq-f877); lib/review-verdict.sh honours
# this override, and tests/test_review_verdict.sh covers the nonce itself.
export MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"

# This file asserts that credentials do NOT reach the model child, so it must
# own its credential environment rather than inherit the developer's.
#
# Without this the checks below are actively misleading. They invoke the review
# path with a `GH_TOKEN=secret ...` command prefix, and bash treats a prefix
# assignment on a function call as a temporary binding: `unset GH_TOKEN` inside
# then removes that binding and REVEALS the outer exported value instead of
# clearing it. With a real GH_TOKEN exported the stub therefore recorded the
# developer's token, the isolation assertion failed, and the failure looked
# like a flaky test rather than a dirty environment (#52). Production is
# unaffected — nothing there passes GH_TOKEN as a command prefix.
unset GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY

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
source "$SCRIPT_DIR/lib/review-post.sh"
source "$SCRIPT_DIR/lib/review-pr-discussion.sh"
source "$SCRIPT_DIR/lib/review-strategy.sh"
source "$SCRIPT_DIR/lib/review-json.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

[[ "$(review_provider_default_mode)" == "codex" ]] && pass "default provider is codex" || fail "default provider should be codex"
[[ "$(review_provider_effective "")" == "codex" ]] && pass "effective provider uses codex default" || fail "effective provider default failed"

printf '{}\n' > "$MRA_CONFIG"
[[ "$(review_provider_default_mode)" == "claude" ]] && pass "legacy unversioned config preserves Claude" || fail "legacy config should preserve Claude"
printf '{"configVersion":2}\n' > "$MRA_CONFIG"

config_set_string "review.providerMode" "codex" >/dev/null
config_set "review.allowUserOverride" "false" >/dev/null
if review_provider_effective "claude" >/dev/null 2>&1; then
  fail "user override should be blocked"
else
  pass "user override blocked by policy"
fi
[[ "$(MRA_REVIEW_ADMIN_OVERRIDE=1 review_provider_effective "claude")" == "claude" ]] && pass "admin override allowed" || fail "admin override failed"

config_set "review.allowUserOverride" "true" >/dev/null
[[ "$(review_provider_effective "claude")" == "claude" ]] && pass "user override allowed when configured" || fail "user override allow failed"

if config_handle "review.primaryProvider" "fallback" >/dev/null 2>&1; then
  fail "primaryProvider should reject fallback"
else
  pass "primaryProvider rejects non-backend values"
fi
if config_handle "review.secondaryProvider" "dual" >/dev/null 2>&1; then
  fail "secondaryProvider should reject dual"
else
  pass "secondaryProvider rejects non-backend values"
fi

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project" "$TMP/dep"
git -C "$TMP/project" init -q
git -C "$TMP/project" config user.email test@example.com
git -C "$TMP/project" config user.name Test
printf 'source\n' > "$TMP/project/app.txt"
printf 'malicious root instruction\n' > "$TMP/project/AGENTS.md"
mkdir -p "$TMP/project/nested/.codex"
printf 'malicious nested instruction\n' > "$TMP/project/nested/CLAUDE.md"
printf 'unsafe config\n' > "$TMP/project/nested/.codex/config.toml"
git -C "$TMP/project" add .
git -C "$TMP/project" commit -qm init
ln -s /etc/passwd "$TMP/project/escape-link"
ln -s /tmp "$TMP/project/AGENTS-link"
git -C "$TMP/project" add escape-link AGENTS-link
git -C "$TMP/project" commit -qm symlinks
snapshot=$(_review_create_sanitized_snapshot "$TMP/project")
if find "$snapshot" -type l | grep -q .; then fail "sanitized snapshot retained a symlink"; else pass "sanitized snapshot removes all tracked symlinks"; fi
chmod -R u+w "$snapshot" && rm -rf "$snapshot"
REC="$TMP/rec"; export REC

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
sleep "${CODEX_STUB_AUTH_CHECK_DELAY:-0}"
auth_state=$([[ -e "$HOME/.codex/auth.json" ]] && echo present || echo absent)
proxy_token_state=$([[ -n "${MRA_CODEX_PROXY_TOKEN:-}" ]] && echo set || echo unset)
real_key_state=$([[ -n "${MRA_CODEX_OPENAI_API_KEY:-}" ]] && echo set || echo unset)
if [[ -n "${ORIGINAL_HOME_FOR_STUB:-}" && -r "$ORIGINAL_HOME_FOR_STUB/.codex/auth.json" ]]; then
  orig_auth=readable
else
  orig_auth=blocked
fi
if ps eww -p $$ 2>/dev/null | grep -q 'MRA_CODEX_OPENAI_API_KEY\|test-only-key'; then
  proc_env=visible
else
  proc_env=hidden
fi
if /usr/sbin/sysctl kern.ostype >/dev/null 2>&1; then
  sysctl_exec=visible
else
  sysctl_exec=hidden
fi
# The prompt arrives on stdin (`codex exec -`), so a stub that only records
# argv can no longer see the reviewer policy it is asked to assert about.
prompt_payload=$(cat)
echo "codex: $* | prompt=$prompt_payload | cwd=$(pwd) | gh=${GH_TOKEN-unset} | github=${GITHUB_TOKEN-unset} | openai=${OPENAI_API_KEY-unset} | proxy-token=$proxy_token_state | real-key=$real_key_state | proc-env=$proc_env | sysctl=$sysctl_exec | home=$HOME | auth=$auth_state | orig-auth=$orig_auth | gh-config=$(cat "$HOME/.config/gh/hosts.yml" 2>/dev/null || true)" >> "$REC"
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"

add_dirs=$(build_add_dir_string "$TMP/dep")
printf 'CANONICAL-REVIEW-POLICY\n' > "$TMP/reviewer.md"
mkdir -p "$TMP/home/.config/gh"
printf 'ambient-gh-secret\n' > "$TMP/home/.config/gh/hosts.yml"
mkdir -p "$TMP/home/.codex"
cat > "$TMP/home/.codex/config.toml" <<'TOML'
model_provider = "Corp"
[model_providers.Corp]
name = "Corp"
base_url = "https://codex.example.test:2880"
wire_api = "responses"
requires_openai_auth = true
[projects."/untrusted"]
trust_level = "trusted"
TOML
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"
mkdir -p "$TMP/home/.claude"
printf '{"claudeAiOauth":{"accessToken":"test-only-token"}}\n' > "$TMP/home/.claude/.credentials.json"
export HOME="$TMP/home"
export MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1
out=$(HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" MRA_REVIEW_MODEL_HOME="$TMP/model-home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_CODEX_AUTH_FILE_TTL_SECONDS=0 CODEX_STUB_AUTH_CHECK_DELAY=1 GH_TOKEN=secret GITHUB_TOKEN=secret2 MRA_CODEX_BIN="$BIN/codex" review_call_model review codex "PROMPT-C" "" "$TMP/project" "$add_dirs" 6 "$TMP/reviewer.md")
[[ "$out" == "<codex-output>" ]] && pass "codex output returned" || fail "codex output wrong: $out"
rec=$(cat "$REC")
case "$rec" in *"exec "*"--cd "*"mra-review-trusted."*" --skip-git-repo-check --ephemeral "*"--add-dir "*"mra-review-snapshot."*) pass "codex uses trusted cwd and sanitized snapshot" ;; *) fail "codex args missing trusted sandbox: $rec" ;; esac
case "$rec" in *"--ignore-user-config --ignore-rules --output-last-message "*" -c shell_environment_policy.inherit=none"*) pass "codex model shell inherits no credential environment and captures final message" ;; *) fail "codex missing shell environment isolation/final capture: $rec" ;; esac
case "$rec" in *"shell_environment_policy.set.PATH="*"/usr/bin:/bin"* ) pass "codex receives deterministic tool PATH" ;; *) fail "codex missing deterministic tool PATH: $rec" ;; esac
case "$rec" in *'model_provider="Corp"'*'model_providers.Corp.base_url="https://codex.example.test:2880"'*'model_providers.Corp.wire_api="responses"'*'model_providers.Corp.requires_openai_auth=true'*) pass "codex receives only validated provider transport overrides" ;; *) fail "codex missing sanitized provider config: $rec" ;; esac
# codex must be sandboxed by exactly one layer. It applies a deny-default
# seatbelt profile per tool command, which macOS refuses inside an existing
# sandbox, so where mra wraps it in sandbox-exec codex has to stand down —
# otherwise every command the model runs fails and the review silently degrades
# to whatever is in the prompt. Where mra cannot wrap it, codex must sandbox
# itself. Neither-of-the-two is the failure this pins.
if command -v sandbox-exec >/dev/null 2>&1; then
  case "$rec" in
    *"--dangerously-bypass-approvals-and-sandbox"*) pass "codex defers sandboxing to mra's outer sandbox-exec" ;;
    *) fail "codex still nests its own sandbox inside mra's — every tool command will fail: $rec" ;;
  esac
else
  case "$rec" in
    *"--sandbox read-only"*) pass "codex sandboxes itself when mra cannot" ;;
    *) fail "no sandbox on either layer: $rec" ;;
  esac
fi

case "$rec" in *"env_key="*) fail "codex received env_key credential config: $rec" ;; *) pass "codex does not receive credential env_key config" ;; esac
case "$rec" in *"/untrusted"*) fail "codex inherited project trust config" ;; *) pass "codex does not inherit project trust config" ;; esac
case "$rec" in *"proxy-token=unset"*) pass "codex parent does not receive proxy token env" ;; *) fail "codex parent received proxy token env: $rec" ;; esac
case "$rec" in *"real-key=unset"*) pass "codex parent does not receive the real API key" ;; *) fail "codex parent received real API key: $rec" ;; esac
case "$rec" in *"auth=absent"*) pass "opt-in TTL deletes codex auth file during model execution" ;; *) fail "opt-in TTL left codex auth file exposed: $rec" ;; esac
if command -v sandbox-exec >/dev/null 2>&1; then
  case "$rec" in *"orig-auth=blocked"*) pass "codex OS sandbox blocks original auth file" ;; *) fail "codex OS sandbox did not block original auth file: $rec" ;; esac
  case "$rec" in *"proc-env=hidden"*) pass "codex OS sandbox blocks ps environment inspection" ;; *) fail "codex OS sandbox exposed process environment: $rec" ;; esac
  case "$rec" in *"sysctl=hidden"*) pass "codex OS sandbox blocks sysctl process inspection" ;; *) fail "codex OS sandbox exposed sysctl: $rec" ;; esac
fi
case "$rec" in *"test-only-key"*) fail "codex credential value leaked into logs: $rec" ;; *) pass "codex credential value is not logged" ;; esac
redacted=$(HOME="$TMP/home" _review_redact_secrets_json '{"status":"APPROVED","summary":"test-only-key sk-abcdefghijklmnopqrstuvwxyz123456","comments":[]}')
case "$redacted" in *"test-only-key"*|*"sk-abcdefghijklmnopqrstuvwxyz123456"*) fail "review redactor leaked OpenAI credential: $redacted" ;; *) pass "review redactor masks OpenAI credentials" ;; esac
case "$rec" in *"openai=unset"*) pass "ambient OpenAI credential is not exported to model child environment" ;; *) fail "ambient OpenAI credential leaked through environment: $rec" ;; esac
case "$rec" in *"CANONICAL-REVIEW-POLICY"*) pass "codex receives canonical reviewer policy" ;; *) fail "codex missing canonical reviewer policy: $rec" ;; esac
case "$rec" in *"gh=unset | github=unset"*) pass "codex process cannot read GitHub credentials" ;; *) fail "codex inherited GitHub credentials: $rec" ;; esac
case "$rec" in *"home=$TMP/model-home."*) pass "codex uses a unique isolated HOME" ;; *) fail "codex did not use unique isolated HOME: $rec" ;; esac
case "$rec" in *"ambient-gh-secret"*) fail "codex could read ambient gh config" ;; *) pass "ambient gh config is absent from model HOME" ;; esac
[[ ! -e "$TMP/model-home" ]] && [[ -z "$(find "$TMP" -maxdepth 1 -name 'model-home.*' -print -quit)" ]] && pass "isolated model HOME is cleaned up" || fail "isolated model HOME leaked"

# The review prompt embeds the whole diff (lib/review-prompt.sh), and argv is
# capped: ARG_MAX is 1 MB on macOS, counting the environment too. On 2026-08-14
# onead/super-dsp-2.0#892 (578 files, pnpm-lock.yaml regenerated) produced a
# 1,009,880-byte diff, execve refused the codex call with E2BIG, and the review
# surfaced as "invalid or mismatched mra protocol artifact" with the real cause
# buried in stderr. `codex exec` reads the prompt from stdin when the prompt
# argument is `-`, which has no such ceiling.
: > "$REC"
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
# Record the transport, not the prompt: a megabyte in $REC helps nobody.
argv="$*"
stdin_bytes=$(cat | wc -c | tr -d ' ')
echo "codex-transport: argv-bytes=${#argv} stdin-bytes=$stdin_bytes" >> "$REC"
echo "<codex-output>"
STUB
chmod +x "$BIN/codex"

# 1.1 MB: over ARG_MAX on its own, so argv transport cannot survive it.
big_prompt=$(head -c 1100000 /dev/zero | tr '\0' 'd')
big_out=$(HOME="$TMP/home" ORIGINAL_HOME_FOR_STUB="$TMP/home" MRA_REVIEW_MODEL_HOME="$TMP/model-home" \
  MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_CODEX_BIN="$BIN/codex" \
  review_call_model review codex "$big_prompt" "" "$TMP/project" "$add_dirs" 6 "" 2>/dev/null) || true
[[ "$big_out" == "<codex-output>" ]] && pass "a diff larger than ARG_MAX still reaches codex" || fail "oversized prompt failed the codex call: '$big_out'"
big_rec=$(grep 'codex-transport:' "$REC" 2>/dev/null | tail -1 || true)
case "$big_rec" in
  *"stdin-bytes=11000"*) pass "the oversized prompt travelled on stdin" ;;
  *) fail "prompt did not travel on stdin: '$big_rec'" ;;
esac
big_argv=${big_rec##*argv-bytes=}; big_argv=${big_argv%% *}
if [[ "$big_argv" =~ ^[0-9]+$ ]] && (( big_argv < 100000 )); then
  pass "argv stays small regardless of diff size"
else
  fail "argv still carries the prompt: '$big_rec'"
fi

: > "$REC"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$REC"
echo "<claude-output>"
STUB
chmod +x "$BIN/claude"

out=$(MRA_CLAUDE_BIN="$BIN/claude" review_call_model review claude "PROMPT-D" "" "$TMP/project" "" 5 "")
[[ "$out" == "<claude-output>" ]] && pass "claude output returned" || fail "claude output wrong: $out"
rec=$(cat "$REC")
case "$rec" in *"--model sonnet"*) pass "claude gets provider default model" ;; *) fail "claude missing default model: $rec" ;; esac
case "$rec" in *"--max-turns 5"*) pass "claude forwards max turns" ;; *) fail "claude missing max turns: $rec" ;; esac

# Same ARG_MAX ceiling as codex: `-p "$prompt"` puts the whole diff in argv.
# claude reads the prompt from stdin when -p carries no prompt argument.
: > "$REC"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
argv="$*"
stdin_bytes=$(cat | wc -c | tr -d ' ')
echo "claude-transport: argv-bytes=${#argv} stdin-bytes=$stdin_bytes" >> "$REC"
echo "<claude-output>"
STUB
chmod +x "$BIN/claude"
big_out=$(MRA_CLAUDE_BIN="$BIN/claude" review_call_model review claude "$big_prompt" "" "$TMP/project" "" 5 "" 2>/dev/null) || true
[[ "$big_out" == "<claude-output>" ]] && pass "a diff larger than ARG_MAX still reaches claude" || fail "oversized prompt failed the claude call: '$big_out'"
big_rec=$(grep 'claude-transport:' "$REC" 2>/dev/null | tail -1 || true)
case "$big_rec" in
  *"stdin-bytes=11000"*) pass "the oversized claude prompt travelled on stdin" ;;
  *) fail "claude prompt did not travel on stdin: '$big_rec'" ;;
esac

: > "$REC"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $* | prompt=$(cat)" >> "$REC"
echo "<claude-output>"
STUB
chmod +x "$BIN/claude"
out=$(MRA_CLAUDE_BIN="$BIN/claude" review_call_model review claude "PROMPT-STDIN" "" "$TMP/project" "" 5 "")
rec=$(cat "$REC")
case "$rec" in *"prompt=PROMPT-STDIN"*) pass "claude receives the prompt itself on stdin" ;; *) fail "claude lost the prompt: $rec" ;; esac

config_set_string "review.primaryProvider" "codex" >/dev/null
config_set_string "review.secondaryProvider" "claude" >/dev/null
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"APPROVED","summary":"truncated primary","comments":[]}'
STUB
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
{"status":"APPROVED","summary":"complete secondary","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
STUB
chmod +x "$BIN/codex" "$BIN/claude"
out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review fallback "PROMPT-F" "" "$TMP/project" "" 6 "")
case "$out" in *"complete secondary"*) pass "fallback retries an incomplete primary response" ;; *) fail "fallback accepted incomplete primary: $out" ;; esac

config_set_string "review.primaryProvider" "codex" >/dev/null
config_set_string "review.secondaryProvider" "claude" >/dev/null
: > "$REC"
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex-dual: $*" >> "$REC"
cat <<'OUT'
{"status":"APPROVED","summary":"codex found no blockers","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
STUB
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-dual: $*" >> "$REC"
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"claude found a blocker","comments":[{"path":"src/app.ts","line":7,"severity":"HIGH","body":"Fix this before merge."}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
STUB
chmod +x "$BIN/codex" "$BIN/claude"

out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review dual "PROMPT-X" "" "$TMP/project" "" 6 "")
case "$out" in *"MRA-REVIEW-COMPLETE: CHANGES_REQUESTED"*) pass "dual emits merged completion sentinel" ;; *) fail "dual missing merged sentinel: $out" ;; esac
dual_json=$(_review_singlepass_body "$out")
[[ "$(printf '%s' "$dual_json" | jq -r .status)" == "CHANGES_REQUESTED" ]] && pass "dual escalates to changes requested" || fail "dual status wrong: $dual_json"
[[ "$(printf '%s' "$dual_json" | jq '.comments | length')" == "1" ]] && pass "dual preserves comments" || fail "dual comments wrong: $dual_json"
rec=$(cat "$REC")
case "$rec" in *"codex-dual:"*"claude-dual:"*) pass "dual invokes both providers" ;; *) fail "dual did not invoke both providers: $rec" ;; esac

config_set_string "review.dualMergePolicy" "primary" >/dev/null
out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review dual "PROMPT-X" "" "$TMP/project" "" 6 "")
dual_json=$(_review_singlepass_body "$out")
[[ "$(printf '%s' "$dual_json" | jq -r .status)" == "CHANGES_REQUESTED" ]] && pass "dual primary display cannot discard secondary blocker" || fail "dual primary gate wrong: $dual_json"
[[ "$(printf '%s' "$dual_json" | jq '.comments | length')" == "0" ]] && pass "dual primary policy uses primary comments" || fail "dual primary comments wrong: $dual_json"
[[ "$(printf '%s' "$dual_json" | jq '.blockerLedger | length')" == "1" ]] && pass "dual primary keeps blocker ledger" || fail "dual primary blocker ledger wrong: $dual_json"

config_set_string "review.dualMergePolicy" "intersection" >/dev/null
out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review dual "PROMPT-X" "" "$TMP/project" "" 6 "")
dual_json=$(_review_singlepass_body "$out")
[[ "$(printf '%s' "$dual_json" | jq -r .status)" == "CHANGES_REQUESTED" ]] && pass "dual intersection cannot discard provider-only blocker" || fail "dual intersection status wrong: $dual_json"
[[ "$(printf '%s' "$dual_json" | jq '.comments | length')" == "0" ]] && pass "dual intersection drops non-common comments" || fail "dual intersection comments wrong: $dual_json"

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
{"status":"CHANGES_REQUESTED","summary":"codex found same blocker","comments":[{"path":"src/app.ts","line":7,"severity":"HIGH","body":"Codex wording."}]}
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
STUB
chmod +x "$BIN/codex"
out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review dual "PROMPT-X" "" "$TMP/project" "" 6 "")
dual_json=$(_review_singlepass_body "$out")
[[ "$(printf '%s' "$dual_json" | jq -r .status)" == "CHANGES_REQUESTED" ]] && pass "dual intersection blocks on common high finding" || fail "dual intersection common status wrong: $dual_json"
[[ "$(printf '%s' "$dual_json" | jq '.comments | length')" == "1" ]] && pass "dual intersection keeps common finding" || fail "dual intersection common comments wrong: $dual_json"

config_set_string "review.dualMergePolicy" "union" >/dev/null
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
{"status":"APPROVED","summary":"complete","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
STUB
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo 'provider stopped before its completion sentinel'
STUB
chmod +x "$BIN/codex" "$BIN/claude"
out=$(MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" review_call_model review dual "PROMPT-X" "" "$TMP/project" "" 6 "")
dual_json=$(_review_singlepass_body "$out")
[[ "$(printf '%s' "$dual_json" | jq -r .status)" == "COMMENT" ]] && pass "dual fails closed when either provider is incomplete" || fail "dual incomplete status wrong: $dual_json"
case "$out" in *"MRA-REVIEW-COMPLETE: APPROVED"*) fail "dual incomplete output must not emit approval sentinel" ;; *) pass "dual incomplete output has no approval sentinel" ;; esac

# --- codex must retry a transient failure, as claude does --------------------
# A single 503 from the relay killed a whole review and escalated the `mra dev`
# loop that depended on it. claude retries transient failures with backoff;
# codex — the DEFAULT provider — had none, so one blip on a shared endpoint
# lost the run. Observed live: "unexpected status 503 Service Unavailable",
# five codex-internal reconnects, then REVIEW_INCOMPLETE.
CX_REC="$TMP/cx-retry-rec"; : > "$CX_REC"; export CX_REC
CX_BIN="$TMP/codex-flaky"
cat > "$CX_BIN" <<'STUB'
#!/usr/bin/env bash
echo "call" >> "$CX_REC"
if [[ "$(wc -l < "$CX_REC" | tr -d ' ')" -lt 2 ]]; then
  echo "unexpected status 503 Service Unavailable: Service temporarily unavailable" >&2
  exit 1
fi
last=""; want=0
for a in "$@"; do
  if [[ "$want" == 1 ]]; then last="$a"; want=0; fi
  [[ "$a" == "--output-last-message" ]] && want=1
done
printf '{"status":"APPROVED","summary":"ok","comments":[]}\n===%s: APPROVED===\n' "$MRA_REVIEW_SENTINEL_TOKEN" > "$last"
exit 0
STUB
chmod +x "$CX_BIN"
cx_out=$(HOME="$TMP/home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_CLAUDE_RETRY_DELAY=0          MRA_CODEX_BIN="$CX_BIN"          review_call_model review codex "PROMPT-R" "" "$TMP/project" "" 6 "" 2>/dev/null || true)
cx_calls=$(wc -l < "$CX_REC" | tr -d ' ')
[[ "$cx_calls" -ge 2 ]] \
  && pass "codex retries a transient failure ($cx_calls calls)" \
  || fail "codex did not retry a 503 — one relay blip loses the review ($cx_calls call)"
case "$cx_out" in *APPROVED*) pass "codex recovers on the retry" ;; *) fail "codex retry did not recover: $cx_out" ;; esac

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review provider tests passed"
else
  echo "FAIL: $errors review provider test(s) failed"
  exit 1
fi
