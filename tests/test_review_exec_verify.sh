#!/usr/bin/env bash
# Runtime behaviour claims are checked only through a stubbed, sandboxed Docker call.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/review-exec-verify.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export TMPDIR="$TMP"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project"
PROJECT="$TMP/project"
export DOCKER_LOG="$TMP/docker.log" DOCKER_STDIN="$TMP/docker.stdin"
export MODEL_LOG="$TMP/model.log" PROMPT_FILE="$TMP/prompt"
: > "$DOCKER_LOG"; : > "$MODEL_LOG"

cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
{
  printf 'CALL'
  for arg in "$@"; do printf '<%s>' "$arg"; done
  printf '\n'
} >> "$DOCKER_LOG"
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  if [[ "${DOCKER_INSPECT_HANG:-0}" == "1" ]]; then
    trap '' TERM
    while :; do :; done
  fi
  [[ "${DOCKER_IMAGE_MISSING:-0}" == "1" ]] && exit 1
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  cat > "$DOCKER_STDIN"
  if [[ "${DOCKER_HANG:-0}" == "1" ]]; then
    trap '' TERM
    while :; do :; done
  fi
  printf '%s\n' "${DOCKER_OUTPUT:-0}"
  exit "${DOCKER_EXIT:-0}"
fi
if [[ "${1:-}" == "kill" || "${1:-}" == "rm" ]]; then exit 0; fi
exit 2
DOCKER
chmod +x "$TMP/bin/docker"

cat > "$TMP/bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
{
  printf 'TIMEOUT'
  for arg in "$@"; do printf '<%s>' "$arg"; done
  printf '\n'
} >> "$TIMEOUT_LOG"
while [[ "${1:-}" == "-k" ]]; do shift 2; done
shift
if [[ "${TIMEOUT_MODE:-0}" == "1" && "${2:-}" == "run" ]] \
  || [[ "${TIMEOUT_INSPECT_MODE:-0}" == "1" && "${2:-}" == "image" ]]; then exit 124; fi
exec "$@"
TIMEOUT
chmod +x "$TMP/bin/timeout"

export PATH="$TMP/bin:$PATH"
export TIMEOUT_LOG="$TMP/timeout.log"
: > "$TIMEOUT_LOG"

MODEL_CALLS=0
REPLY='[]'
model_calls() { wc -l < "$MODEL_LOG" | tr -d ' '; }
review_call_model() {
  MODEL_CALLS=$((MODEL_CALLS+1))
  printf 'call\n' >> "$MODEL_LOG"
  printf '%s' "$3" > "$PROMPT_FILE"
  printf '%s' "$REPLY"
}

ONE='{"status":"CHANGES_REQUESTED","summary":"s","comments":[{"path":"a.rb","line":1,"severity":"HIGH","body":"nil.to_i raises NoMethodError"}]}'
TWO='{"status":"CHANGES_REQUESTED","summary":"s","comments":[{"path":"a.rb","line":1,"severity":"HIGH","body":"nil.to_i raises NoMethodError"},{"path":"b.rb","line":2,"severity":"MEDIUM","body":"other issue stays"}]}'
NONE='{"status":"APPROVED","summary":"none","comments":[]}'
RUBY_CLAIM='[{"index":0,"language":"ruby","expression":"nil.to_i","claimed_outcome":"RAISES NoMethodError"}]'
run() { _review_exec_verify_findings "$1" "$PROJECT" claude model "" 4 ""; }
reset_logs() { : > "$DOCKER_LOG"; : > "$MODEL_LOG"; : > "$TIMEOUT_LOG"; : > "$DOCKER_STDIN"; }
comment_count() { printf '%s' "$1" | jq '[.comments[]] | length'; }

printf '2.5.7\n' > "$PROJECT/.ruby-version"

# Sourcing exec-verify without the shared detector safely skips runtime claims.
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" && ! -s "$DOCKER_LOG" ]] \
  && ok "missing shared version helpers keep findings and skip Docker" \
  || fail "missing shared version helpers changed the finding or called Docker"
grep -qF 'evaluate whether the finding is right and do NOT write the behaviour you' "$PROMPT_FILE" \
  && grep -qF 'expect; the program will be run to find out.' "$PROMPT_FILE" \
  && grep -qF 'finding says Integer("12") raises' "$PROMPT_FILE" \
  && grep -qF 'ArgumentError, use {' "$PROMPT_FILE" \
  && grep -qF '"claimed_outcome":"RAISES ArgumentError"' "$PROMPT_FILE" \
  && grep -qF 'even though that expression actually returns 12.' "$PROMPT_FILE" \
  && ok "prompt tells extraction to copy the claimed outcome, including a wrong finding" \
  || fail "prompt is missing the claimed-outcome instruction or wrong-finding example"
grep -qF '"claimed_outcome":"..."' "$PROMPT_FILE" \
  && ! grep -qF 'finding_holds_if' "$PROMPT_FILE" \
  && ok "prompt schema uses only claimed_outcome" \
  || fail "prompt schema still uses the legacy outcome field"

source "$MRA_DIR/lib/stack-versions.sh"

# Disabled and finding-free reviews do not call either dependency.
reset_logs
out=$(run "$ONE")
[[ "$out" == "$ONE" && "$(model_calls)" == "0" && ! -s "$DOCKER_LOG" ]] \
  && ok "disabled verification passes input through without calls" \
  || fail "disabled verification changed input or made a call"
reset_logs; MODEL_CALLS=0
out=$(MRA_REVIEW_EXEC_VERIFY=1 run "$NONE")
[[ "$out" == "$NONE" && "$(model_calls)" == "0" && ! -s "$DOCKER_LOG" ]] \
  && ok "no findings make no model or Docker calls" \
  || fail "finding-free review made a call or changed input"

# A false runtime claim is removed, while the other finding and verdict remain.
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RETURNS 0' run "$TWO" 2>"$TMP/drop.err")
[[ "$(comment_count "$out")" == "1" && "$(jq -r '.comments[0].path' <<<"$out")" == "b.rb" ]] \
  && ok "a refuted runtime claim is dropped and other findings stay" \
  || fail "runtime refutation removed the wrong findings: $out"
[[ "$(jq -r '.status' <<<"$out")" == "CHANGES_REQUESTED" && "$(jq -r '.summary' <<<"$out")" == "s" ]] \
  && ok "dropping a finding preserves refutation status and summary" \
  || fail "runtime verification rewrote status or summary"
grep -qF 'index=0 image=ruby:2.5.7-slim claimed=RAISES\ NoMethodError observed=RETURNS\ 0 exit=0 outcome=dropped' "$TMP/drop.err" && ok "a dropped finding is logged with image, claim, and observation" || fail "drop log lacks claim details: $(cat "$TMP/drop.err")"
[[ "$(grep -c '^exec verification index=' "$TMP/drop.err")" == "1" ]] && ok "each executed claim has exactly one audit log line" || fail "claim audit log count is wrong: $(cat "$TMP/drop.err")"

# Verify the full command contract and exact generated Ruby program on stdin.
grep -Eq 'CALL<run><--rm><--name><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+><--init><-i><--network><none><--read-only><--tmpfs></tmp:rw,size=16m><--memory><256m><--cpus><1><--pids-limit><64><--user><65534:65534><--cap-drop><ALL><--security-opt><no-new-privileges><ruby:2.5.7-slim><ruby><->' "$DOCKER_LOG" \
  && ok "Docker receives every required runtime sandbox flag" \
  || fail "Docker argv omitted a required sandbox flag: $(cat "$DOCKER_LOG")"
if grep -Eq '<(-v|--volume|--mount|-e|--env|--env-file|--privileged|--network=host|--network><host>|--cap-add)>' "$DOCKER_LOG"; then
  fail "Docker argv included a mount or environment pass-through"
else
  ok "Docker argv contains no forbidden mount, environment, privilege, or network flags"
fi
printf 'begin\n\n__mra_v = (nil.to_i)\nputs "RETURNS #{__mra_v.inspect}"\nrescue Exception => __mra_e\nputs "RAISES #{__mra_e.class}"\nend\n' > "$TMP/expected-program"
cmp -s "$DOCKER_STDIN" "$TMP/expected-program" && ok "Docker stdin exactly matches the fixed Ruby template" || fail "Docker stdin differs from the fixed Ruby template"

# Matching output confirms the runtime claim and keeps the finding. Extraction
# tolerates leading prose and a surrounding JSON fence.
reset_logs; MODEL_CALLS=0
REPLY=$'Here is the result:\n```json\n[{"index":0,"language":"ruby","expression":"nil.to_i","claimed_outcome":"RAISES NoMethodError"}]\n```'
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RAISES NoMethodError' run "$ONE" 2>"$TMP/confirmed.err")
[[ "$(comment_count "$out")" == "1" ]] && ok "a confirmed runtime claim is kept" \
  || fail "a confirmed claim was removed"

grep -qF 'index=0 image=ruby:2.5.7-slim claimed=RAISES\ NoMethodError observed=RAISES\ NoMethodError exit=0 outcome=kept' "$TMP/confirmed.err" && ok "a confirmed claim is logged as kept" || fail "confirmed claim audit log is missing"

# Both sides are trimmed and exception-message suffixes are ignored.
reset_logs; MODEL_CALLS=0
REPLY='[{"index":0,"language":"ruby","expression":"nil.to_i","claimed_outcome":"  RAISES NoMethodError: expected message  "}]'
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='  RAISES NoMethodError: observed message  ' run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" ]] && ok "trimmed exception lines with different messages compare equal" \
  || fail "exception normalization removed a confirmed finding"

# Setup statements are inserted before the expression.
reset_logs; MODEL_CALLS=0
REPLY='[{"index":0,"language":"ruby","setup":"setup_value = nil","expression":"setup_value.to_i","claimed_outcome":"RETURNS 0"}]'
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RETURNS 0' run "$ONE" 2>/dev/null)
if [[ "$(comment_count "$out")" == "1" && "$(sed -n '2p' "$DOCKER_STDIN")" == "setup_value = nil" && "$(sed -n '3p' "$DOCKER_STDIN")" == "__mra_v = (setup_value.to_i)" ]]; then ok "setup is inserted before the expression"; else fail "setup or expression was misplaced in the generated Ruby program"; fi

# Matching RETURNS output confirms the claim and keeps the finding.
reset_logs; MODEL_CALLS=0
REPLY='[{"index":0,"language":"ruby","expression":"nil.to_i","claimed_outcome":"RETURNS 0"}]'
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RETURNS 0' run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" ]] && ok "matching RETURNS 0 output keeps the finding" || fail "matching RETURNS output removed the finding"

# Older model replies using finding_holds_if remain parseable as a fallback.
reset_logs; MODEL_CALLS=0
REPLY='[{"index":0,"language":"ruby","expression":"nil.to_i","finding_holds_if":"RAISES NoMethodError"}]'
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RETURNS 0' run "$ONE" 2>"$TMP/legacy.err")
[[ "$(comment_count "$out")" == "0" ]] \
  && grep -qF 'claimed=RAISES\ NoMethodError' "$TMP/legacy.err" \
  && ok "legacy finding_holds_if replies use the claimed-outcome fallback" \
  || fail "legacy outcome field was not accepted as a fallback"

# Successful output without a recognized prefix keeps the finding.
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT=0 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" ]] && ok "unrecognized successful output keeps the finding" || fail "unrecognized output removed the finding"

# Legacy free-form snippets are accepted only to be skipped.
reset_logs; MODEL_CALLS=0
REPLY='[{"index":0,"language":"ruby","snippet":"puts 0","claimed_outcome":"RETURNS 0"}]'
out=$(MRA_REVIEW_EXEC_VERIFY=1 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" && ! -s "$DOCKER_LOG" ]] && ok "snippet-only legacy claims are skipped without running Docker" || fail "a snippet-only legacy claim was executed or removed"

# When all findings are removed, the verifier keeps the original verdict like refutation does.
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RETURNS 0' run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "0" && "$(jq -r '.status' <<<"$out")" == "CHANGES_REQUESTED" ]] \
  && ok "removing every finding leaves status unchanged like refutation" \
  || fail "empty result status differs from the refutation contract: $out"

# Missing Docker image, timed-out execution, and nonzero execution keep findings.
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_IMAGE_MISSING=1 run "$ONE" 2>"$TMP/missing-image.err")
[[ "$(comment_count "$out")" == "1" ]] && grep -q 'docker pull ruby:2.5.7-slim' "$TMP/missing-image.err" \
  && ok "missing local images keep findings and suggest docker pull" \
  || fail "missing image did not safely skip the claim"

reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 TIMEOUT_MODE=1 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" && -s "$TIMEOUT_LOG" ]] \
  && ok "timeout keeps the finding" || fail "timeout dropped the finding"
grep -q '<-k><2><20>' "$TIMEOUT_LOG" \
  && ok "the timeout utility receives a two-second kill grace" \
  || fail "timeout did not receive the kill grace: $(cat "$TIMEOUT_LOG")"
grep -Eq 'CALL<kill><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+>' "$DOCKER_LOG" \
  && ok "timeout cleanup kills the named container" \
  || fail "timeout cleanup did not issue docker kill: $(cat "$DOCKER_LOG")"
grep -Eq 'CALL<rm><-f><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+>' "$DOCKER_LOG" \
  && ok "timeout cleanup removes the named container" \
  || fail "timeout cleanup did not issue docker rm: $(cat "$DOCKER_LOG")"

reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 TIMEOUT_INSPECT_MODE=1 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" && "$(grep -c 'CALL<run>' "$DOCKER_LOG")" == "0" ]] \
  && ok "a timed-out image inspection skips execution and keeps the finding" \
  || fail "image-inspect timeout did not safely skip the finding"

reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT=0 DOCKER_EXIT=9 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" ]] && ok "nonzero container exit keeps the finding" \
  || fail "nonzero container exit dropped the finding"

# Unsafe runtime versions are rejected before making any Docker call.
for hostile_version in '2.5.7; rm -rf /' 'latest --privileged'; do
  printf '%s\n' "$hostile_version" > "$PROJECT/.ruby-version"
  reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
  out=$(MRA_REVIEW_EXEC_VERIFY=1 run "$ONE" 2>/dev/null)
  [[ "$(comment_count "$out")" == "1" && ! -s "$DOCKER_LOG" ]] \
    && ok "hostile .ruby-version is rejected: $hostile_version" \
    || fail "hostile .ruby-version reached Docker or changed the finding: $hostile_version"
done
printf '2.5.7\n' > "$PROJECT/.ruby-version"

# Prefixed/suffixed Ruby versions still map to the plain image tag.
printf 'ruby-2.5.7\n' > "$PROJECT/.ruby-version"
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RAISES NoMethodError' run "$ONE" >/dev/null 2>&1
grep -q '<ruby:2.5.7-slim><ruby><->' "$DOCKER_LOG" \
  && ok ".ruby-version ruby-2.5.7 selects ruby:2.5.7-slim" \
  || fail ".ruby-version ruby-2.5.7 did not select ruby:2.5.7-slim"
rm -f "$PROJECT/.ruby-version"
printf 'GEM\n  specs:\n\nRUBY VERSION\n   ruby 2.5.8p206\n' > "$PROJECT/Gemfile.lock"
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT='RAISES NoMethodError' run "$ONE" >/dev/null 2>&1
grep -q '<ruby:2.5.8-slim><ruby><->' "$DOCKER_LOG" \
  && ok "Gemfile.lock ruby 2.5.8p206 selects ruby:2.5.8-slim" \
  || fail "Gemfile.lock ruby 2.5.8p206 did not select ruby:2.5.8-slim"
rm -f "$PROJECT/Gemfile.lock"
printf '2.5.7\n' > "$PROJECT/.ruby-version"

# Malformed extraction is a no-op after exactly one model call.
reset_logs; MODEL_CALLS=0; REPLY='not json'
out=$(MRA_REVIEW_EXEC_VERIFY=1 run "$ONE" 2>/dev/null)
[[ "$out" == "$ONE" && "$(model_calls)" == "1" && ! -s "$DOCKER_LOG" ]] \
  && ok "unparseable extraction keeps every finding and skips Docker" \
  || fail "malformed extraction changed the review or reached Docker"

# Docker absent from PATH keeps claims without reaching a real executable.
NO_DOCKER="$TMP/no-docker"; mkdir -p "$NO_DOCKER"
jq_bin=$(command -v jq); ln -s "$jq_bin" "$NO_DOCKER/jq"
cat_bin=$(command -v cat); ln -s "$cat_bin" "$NO_DOCKER/cat"
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
out=$(PATH="$NO_DOCKER" MRA_REVIEW_EXEC_VERIFY=1 run "$ONE" 2>/dev/null)
[[ "$(comment_count "$out")" == "1" && "$(model_calls)" == "1" ]] \
  && ok "missing Docker keeps the finding" || fail "missing Docker altered the finding"

# The no-timeout fallback kills the CLI and cleans up the named container.
NO_TIMEOUT="$TMP/no-timeout"; mkdir -p "$NO_TIMEOUT"
for utility in jq sed mktemp rm tail cat bash; do
  utility_path=$(command -v "$utility")
  ln -s "$utility_path" "$NO_TIMEOUT/$utility"
done
ln -s "$TMP/bin/docker" "$NO_TIMEOUT/docker"
cat > "$NO_TIMEOUT/sleep" <<'SLEEP'
#!/bin/sh
case "${1:-}" in
  20) /bin/sleep 5 ;;
  2) /bin/sleep 0.1 ;;
  *) /bin/sleep "${1:-0}" ;;
esac
SLEEP
chmod +x "$NO_TIMEOUT/sleep"
if PATH="$NO_TIMEOUT" command -v timeout >/dev/null 2>&1 || PATH="$NO_TIMEOUT" command -v gtimeout >/dev/null 2>&1; then
  fail "fallback PATH unexpectedly contains a timeout utility"
else
  ok "fallback PATH has neither timeout utility"
fi
reset_logs; MODEL_CALLS=0; REPLY="$RUBY_CLAIM"
unset DOCKER_IMAGE_MISSING DOCKER_INSPECT_HANG
hash -r
out=$(PATH="$NO_TIMEOUT" MRA_REVIEW_EXEC_VERIFY=1 DOCKER_HANG=1 run "$ONE" 2>"$TMP/fallback.err")
[[ "$(comment_count "$out")" == "1" ]] && ok "fallback timeout keeps the finding" \
  || fail "fallback timeout dropped the finding: $(cat "$TMP/fallback.err")"
grep -Eq 'CALL<run><--rm><--name><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+><--init><-i><--network><none><--read-only><--tmpfs></tmp:rw,size=16m><--memory><256m><--cpus><1><--pids-limit><64><--user><65534:65534><--cap-drop><ALL><--security-opt><no-new-privileges><ruby:2.5.7-slim><ruby><->' "$DOCKER_LOG" \
  && ok "fallback Docker argv includes all sandbox flags and container controls" \
  || fail "fallback Docker argv is incomplete: $(cat "$DOCKER_LOG"); $(cat "$TMP/fallback.err")"
grep -Eq 'CALL<kill><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+>' "$DOCKER_LOG" \
  && ok "fallback timeout kills the named container" \
  || fail "fallback timeout did not issue docker kill: $(cat "$DOCKER_LOG")"
grep -Eq 'CALL<rm><-f><mra-exec-verify-[0-9]+-[0-9]+-[0-9]+>' "$DOCKER_LOG" \
  && ok "fallback timeout removes the named container" \
  || fail "fallback timeout did not issue docker rm: $(cat "$DOCKER_LOG")"

# Runtime tags come from the project's local version markers.
reset_logs; MODEL_CALLS=0; REPLY="[{\"index\":0,\"language\":\"node\",\"expression\":\"process.version\",\"claimed_outcome\":\"RETURNS 'v20.19.5'\"}]"
printf 'v20.19.5\n' > "$PROJECT/.nvmrc"
out=$(MRA_REVIEW_EXEC_VERIFY=1 DOCKER_OUTPUT="RETURNS 'v20.19.5'" run "$ONE" 2>/dev/null)
grep -q '<node:20-slim><node><->' "$DOCKER_LOG" \
  && ok ".nvmrc v20.19.5 selects node:20-slim" \
  || fail "Node version tag was not detected: $(cat "$DOCKER_LOG")"
grep -qF 'const __mra_v = (process.version);' "$DOCKER_STDIN" && ok "Node expressions are wrapped in parentheses" || fail "Node template did not wrap its expression"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
