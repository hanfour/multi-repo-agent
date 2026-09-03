#!/usr/bin/env bash
# lib/review.sh：personas 路徑在所有 persona 都失敗時，不得把空的 findings
# 送進 run_synthesize，否則下游會把沒有完成檢查的 PR 誤判成 APPROVED。
#
# 背景：personas 會平行呼叫多個 review agent。當所有 agent 都因為 prompt
# 超過模型上限或其他呼叫錯誤而失敗時，原本的 run_persona_review 仍回傳 0，
# review.sh 便照常呼叫 synthesize；一個只看到空字串的 synthesize stub 就能
# 產出 status=APPROVED、comments=[]，形成 false green。
#
# 這支測試沿用 tests/test_review_personas_synth_validate.sh 的骨架：完整依
# bin/mra.sh 的 MRA_LIBS 清單載入，準備最小 workspace 與 git repo，再覆寫
# run_persona_review／run_synthesize，不連網路，也不使用真正的模型憑證。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1，預期[$2]，實際[$3]"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1，找不到[$3]：$2"; fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else fail "$1，不應含[$3]：$2"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-personas-all-failed.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MRA_CONFIG="$TMP/config.json"
printf '%s' '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' \
  > "$MRA_CONFIG"
export MRA_REVIEW_POST_MODE=none
export MRA_REVIEW_PR_CONTEXT=0
export MRA_REVIEW_PREMISE_CHECK=0
export MRA_REVIEW_PERSONAS=true
export MRA_REVIEW_EMIT_JSON=1

WS="$TMP/ws"
mkdir -p "$WS/.collab" "$WS/proj"
printf '%s' '{"projects":{"proj":{"type":"node","deps":{},"consumedBy":[],"confidence":{}}},"gitOrg":"acme","workspace":"'"$WS"'","version":1,"lastScan":"now"}' \
  > "$WS/.collab/dep-graph.json"

R="$WS/proj"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feature
printf 'two\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m change

eval "$(sed -n '/^MRA_LIBS=(/,/^)/p' "$MRA_DIR/bin/mra.sh")"
for lib in "${MRA_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$MRA_DIR/lib/${lib}.sh"
done

APPROVED_JSON='{"status":"APPROVED","summary":"沒有發現問題","comments":[]}'
SYNTH_FLAG="$TMP/synthesize-called"

# 用旗標檔記錄 synthesize 是否真的被呼叫，因為它會在 command substitution
# 的子 shell 裡執行，不能靠函式外的變數觀察。
run_synthesize() {
  printf '%s\n' "called" > "$SYNTH_FLAG"
  printf '%s' "$APPROVED_JSON"
}

call_review() {
  local out_file="$1" err_file="$2"
  shift 2
  review_project "$WS" proj "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  wait 2>/dev/null || true
  return $rc
}

# 案例一：所有 persona 都失敗時，直接回傳 REVIEW_INCOMPLETE。
run_persona_review() { return 1; }
rm -f "$SYNTH_FLAG"
call_review "$TMP/all-failed.out" "$TMP/all-failed.err" --base main
rc=$?
eq "所有 persona 失敗時 review 退出碼仍為 0" "0" "$rc"
all_failed_out="$(cat "$TMP/all-failed.out")"
if jq -e . "$TMP/all-failed.out" >/dev/null 2>&1; then
  ok "所有 persona 失敗時 stdout 是合法 JSON"
else
  fail "所有 persona 失敗時 stdout 不是合法 JSON：$all_failed_out"
fi
status="$(jq -r '.status' "$TMP/all-failed.out" 2>/dev/null)"
eq "所有 persona 失敗時 status 是 COMMENT" "COMMENT" "$status"
summary="$(jq -r '.summary' "$TMP/all-failed.out" 2>/dev/null)"
contains "summary 含 REVIEW_INCOMPLETE" "$summary" "REVIEW_INCOMPLETE"
contains "summary 說明所有 persona 都失敗" "$summary" "所有 persona 都失敗"
contains "summary 指向 PERSONAS_ALL_FAILED 診斷" "$summary" "PERSONAS_ALL_FAILED"
contains "summary 明確說明這不是核准" "$summary" "不是核准"
comments="$(jq -c '.comments' "$TMP/all-failed.out" 2>/dev/null)"
eq "所有 persona 失敗時 comments 是空陣列" "[]" "$comments"
if [[ -e "$SYNTH_FLAG" ]]; then
  fail "所有 persona 失敗時不應呼叫 run_synthesize"
else
  ok "所有 persona 失敗時沒有呼叫 run_synthesize"
fi
not_contains "所有 persona 失敗時 stdout 不含 APPROVED" "$all_failed_out" "APPROVED"

# 案例二：只要有一個 persona 成功，就維持原本會呼叫 synthesize 的行為。
run_persona_review() { printf '%s' "finding"; return 0; }
rm -f "$SYNTH_FLAG"
call_review "$TMP/partial-success.out" "$TMP/partial-success.err" --base main
rc=$?
eq "有 persona 成功時 review 退出碼為 0" "0" "$rc"
if [[ -e "$SYNTH_FLAG" ]]; then
  ok "有 persona 成功時有呼叫 run_synthesize"
else
  fail "有 persona 成功時應呼叫 run_synthesize"
fi
status="$(jq -r '.status' "$TMP/partial-success.out" 2>/dev/null)"
eq "有 persona 成功時維持 APPROVED 行為" "APPROVED" "$status"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
