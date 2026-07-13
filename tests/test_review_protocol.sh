#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

mkdir -p "$TMP/work/project" "$TMP/bin"
git -C "$TMP/work/project" init -q
git -C "$TMP/work/project" config user.email test@example.com
git -C "$TMP/work/project" config user.name Test
printf 'base\n' > "$TMP/work/project/app.txt"
git -C "$TMP/work/project" add . && git -C "$TMP/work/project" commit -qm base
base=$(git -C "$TMP/work/project" rev-parse HEAD)
printf 'head\n' >> "$TMP/work/project/app.txt"
git -C "$TMP/work/project" commit -qam head
head=$(git -C "$TMP/work/project" rev-parse HEAD)

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
{"status":"APPROVED","summary":"complete protocol review","comments":[]}
===MRA-REVIEW-COMPLETE: APPROVED===
OUT
STUB
chmod +x "$TMP/bin/codex"
cat > "$TMP/config.json" <<'JSON'
{"review":{"providerMode":"codex","allowUserOverride":true}}
JSON
cat > "$TMP/request.json" <<JSON
{"schema":"io.mra.integration.review-request/v1","protocolVersion":"1.0","requestId":"req-1","subject":{"checkout":"$TMP/work/project","project":"project","pullRequest":1,"baseSha":"$base","headSha":"$head"},"review":{"provider":"codex","strategy":"standard"}}
JSON

describe=$(MRA_CONFIG="$TMP/config.json" "$ROOT/bin/mra.sh" integration describe --json)
[[ "$(jq -r '.capabilities.analysisOnly' <<<"$describe")" == true ]] && pass "describe advertises analysis-only" || fail "describe missing analysisOnly"
[[ "$(jq -r '.capabilities.sanitizedContext' <<<"$describe")" == true ]] && pass "describe advertises sanitized context" || fail "describe missing sanitizedContext"
[[ "$(jq -c '.providers' <<<"$describe")" == '["codex"]' ]] && pass "protocol approval artifact is Codex-only" || fail "protocol must not advertise unsanitized providers"

doctor=$(MRA_CONFIG="$TMP/config.json" MRA_CODEX_BIN="$TMP/bin/codex" "$ROOT/bin/mra.sh" integration doctor --request "$TMP/request.json" --json)
[[ "$(jq -r .ready <<<"$doctor")" == true ]] && pass "doctor validates request readiness" || fail "doctor should pass: $doctor"

env GH_TOKEN=must-not-be-used GITHUB_TOKEN=must-not-be-used MRA_CONFIG="$TMP/config.json" MRA_CODEX_BIN="$TMP/bin/codex" \
  "$ROOT/bin/mra.sh" integration review --request "$TMP/request.json" --result "$TMP/result.json" --events "$TMP/events.jsonl"
[[ "$(jq -r '.analysis.status' "$TMP/result.json")" == complete ]] && pass "protocol writes complete artifact" || fail "artifact incomplete"
[[ "$(jq -r '.analysis.verdict' "$TMP/result.json")" == pass ]] && pass "protocol normalizes pass verdict" || fail "artifact verdict wrong"
[[ "$(jq -r '.subject.headSha' "$TMP/result.json")" == "$head" ]] && pass "artifact is head-bound" || fail "artifact head mismatch"
[[ "$(jq -r '.context.nativeRepositoryInstructions' "$TMP/result.json")" == false ]] && pass "artifact records sanitized context" || fail "artifact context wrong"
[[ "$(wc -l < "$TMP/events.jsonl" | tr -d ' ')" == 2 ]] && pass "protocol emits structured lifecycle events" || fail "event count wrong"

mkdir -p "$TMP/real-results"
ln -s "$TMP/real-results" "$TMP/link-results"
env GH_TOKEN=must-not-be-used GITHUB_TOKEN=must-not-be-used MRA_CONFIG="$TMP/config.json" MRA_CODEX_BIN="$TMP/bin/codex" \
  "$ROOT/bin/mra.sh" integration review --request "$TMP/request.json" --result "$TMP/link-results/result.json" --events "$TMP/link-results/events.jsonl"
[[ "$(jq -r '.analysis.status' "$TMP/link-results/result.json")" == complete ]] && pass "protocol writes artifact through symlinked parent" || fail "symlinked parent artifact failed"
[[ "$(wc -l < "$TMP/link-results/events.jsonl" | tr -d ' ')" == 2 ]] && pass "protocol writes events through symlinked parent" || fail "symlinked parent events failed"

jq '.subject.headSha="0000000000000000000000000000000000000000"' "$TMP/request.json" > "$TMP/bad.json"
if MRA_CONFIG="$TMP/config.json" MRA_CODEX_BIN="$TMP/bin/codex" "$ROOT/bin/mra.sh" integration review --request "$TMP/bad.json" --result "$TMP/bad-result.json" >/dev/null 2>&1; then
  fail "head mismatch must fail closed"
else
  pass "head mismatch fails closed"
fi

jq '.review.provider="claude"' "$TMP/request.json" > "$TMP/claude.json"
if MRA_CONFIG="$TMP/config.json" "$ROOT/bin/mra.sh" integration doctor --request "$TMP/claude.json" --json >/dev/null 2>&1; then
  fail "Claude must not be approval-eligible under sanitized protocol v1"
else
  pass "protocol rejects providers without sanitized execution"
fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: review protocol tests passed"
else
  echo "FAIL: $errors review protocol test(s) failed"
  exit 1
fi
