#!/usr/bin/env bash
# The integration path is the one in production, and it is the one that could
# not see a reply at all: `context.pr` carried {title, body, updatedAt} under
# `additionalProperties: false`, and the analysis stage runs with no GitHub
# credential by design, so MRA could neither be told nor go and look.
#
# This drives the whole path with a stub model: a request carrying a prior
# finding and the reply that refutes it, and a model that tries to re-report
# the finding without answering.
set -uo pipefail

export MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
errors=0; pass_n=0
ok()   { echo "PASS: $1"; pass_n=$((pass_n+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

mkdir -p "$TMP/work/project" "$TMP/bin" "$TMP/home/.codex"
git -C "$TMP/work/project" init -q
git -C "$TMP/work/project" config user.email t@t.t
git -C "$TMP/work/project" config user.name t
printf 'base\n' > "$TMP/work/project/focus.ts"
git -C "$TMP/work/project" add . && git -C "$TMP/work/project" commit -qm base
base=$(git -C "$TMP/work/project" rev-parse HEAD)
printf 'head\n' >> "$TMP/work/project/focus.ts"
git -C "$TMP/work/project" commit -qam head
head=$(git -C "$TMP/work/project" rev-parse HEAD)

printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"
echo '{"review":{"providerMode":"codex","allowUserOverride":true}}' > "$TMP/config.json"

REBUTTAL='不改。前提不成立 — 該事件 bubbles: true，會傳到 window。三項驗證：(1) 上游函式庫如此實作；(2) 規格明列唯一例外；(3) 手動實測通過。'

# A stub model that records the prompt it was handed and answers as told.
make_stub() {
  cat > "$TMP/bin/codex" <<STUB
#!/usr/bin/env bash
{ printf '%s\n' "\$*"; cat; } > "$TMP/prompt.txt" 2>/dev/null
cat <<'OUT'
$1
===MRA-REVIEW-COMPLETE: CHANGES_REQUESTED===
OUT
STUB
  chmod +x "$TMP/bin/codex"
}

write_request() {
  jq -n --arg co "$TMP/work/project" --arg b "$base" --arg h "$head" --arg rb "$REBUTTAL" '{
    schema:"io.mra.integration.review-request/v1", protocolVersion:"1.0", requestId:"req-1",
    subject:{checkout:$co, project:"project", pullRequest:1, baseSha:$b, headSha:$h},
    review:{provider:"codex", strategy:"standard"},
    context:{pr:{title:"t", body:"b", updatedAt:"2026-08-11T00:00:00Z", discussion:[
      {id:1, inReplyToId:null, author:"op", kind:"inline", path:"focus.ts", line:22,
       body:"[HIGH] 事件綁在錯誤的目標上", createdAt:"2026-08-11T01:40:11Z", isPriorReview:true},
      {id:2, inReplyToId:1, author:"ryan", kind:"inline", path:"focus.ts", line:22,
       body:$rb, createdAt:"2026-08-11T01:49:59Z", isPriorReview:false}]}}}' > "$TMP/request.json"
}

run_it() {
  PATH="$TMP/bin:$PATH" HOME="$TMP/home" MRA_CONFIG="$TMP/config.json" \
    "$ROOT/bin/mra.sh" integration review \
    --request "$TMP/request.json" --result "$TMP/result.json" --events "$TMP/events.jsonl" \
    >/dev/null 2>&1 || true
}

# --- 1. the reply reaches the model, whole and attached ---------------------
write_request
make_stub '{"status":"CHANGES_REQUESTED","summary":"still broken","comments":[{"path":"focus.ts","line":22,"severity":"HIGH","body":"事件綁在錯誤的目標上"}]}'
run_it

if [[ -s "$TMP/prompt.txt" ]]; then
  ok "the stub model was invoked and its prompt captured"
else
  fail "no prompt captured — the run did not reach the model"
fi
grep -qF "三項驗證" "$TMP/prompt.txt" 2>/dev/null \
  && ok "the rebuttal reached the model with its evidence intact" \
  || fail "the rebuttal did not reach the model (this is the production defect)"
grep -qF "手動實測通過" "$TMP/prompt.txt" 2>/dev/null \
  && ok "the rebuttal was not truncated" || fail "the rebuttal was truncated"
grep -q "ADJUDICATION" "$TMP/prompt.txt" 2>/dev/null \
  && ok "the model was told it must adjudicate" || fail "no adjudication contract in the prompt"

# --- 2. re-reporting it without answering is not allowed to stand -----------
n=$(jq -r '[.findings[]? | select(.path=="focus.ts" and .line==22)] | length' "$TMP/result.json" 2>/dev/null || echo ERR)
[[ "$n" == "0" ]] \
  && ok "a refuted finding re-reported with no answer does not reach the result" \
  || fail "the refuted finding survived into the result (count=$n)"

# --- 3. upholding it, with an argument, does ---------------------------------
write_request
make_stub '{"status":"CHANGES_REQUESTED","summary":"ADJUDICATION focus.ts:22 UPHELD — the reply describes the default listener, this one is registered in the capture phase.","comments":[{"path":"focus.ts","line":22,"severity":"HIGH","body":"事件綁在錯誤的目標上"}]}'
run_it
n=$(jq -r '[.findings[]? | select(.path=="focus.ts" and .line==22)] | length' "$TMP/result.json" 2>/dev/null || echo ERR)
[[ "$n" == "1" ]] \
  && ok "an upheld finding survives — the model may disagree, with an argument" \
  || fail "upholding was refused (count=$n)"

# --- 4. a request with no discussion behaves exactly as before --------------
jq 'del(.context.pr.discussion)' "$TMP/request.json" > "$TMP/r2.json" && mv "$TMP/r2.json" "$TMP/request.json"
make_stub '{"status":"CHANGES_REQUESTED","summary":"plain","comments":[{"path":"focus.ts","line":22,"severity":"HIGH","body":"x"}]}'
run_it
n=$(jq -r '[.findings[]? | select(.path=="focus.ts")] | length' "$TMP/result.json" 2>/dev/null || echo ERR)
[[ "$n" == "1" ]] \
  && ok "with no discussion supplied, nothing is gated" \
  || fail "the gate fired with nothing to adjudicate (count=$n)"
grep -q "ADJUDICATION" "$TMP/prompt.txt" 2>/dev/null \
  && fail "the adjudication contract leaked into a review with no prior findings" \
  || ok "no adjudication text when there is nothing to adjudicate"

# --- 5. the analysis stage still holds no GitHub credential -----------------
grep -q 'unset GH_TOKEN GITHUB_TOKEN' "$ROOT/lib/review-protocol.sh" \
  && ok "the analysis stage still runs without a GitHub credential" \
  || fail "the credential isolation of the analysis stage was weakened"

echo "---"; echo "Passed: $pass_n"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
