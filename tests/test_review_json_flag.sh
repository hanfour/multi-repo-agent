#!/usr/bin/env bash
# lib/review.sh：MRA_REVIEW_EMIT_JSON 旗標。
#
# scripts/backtest-review-adapter.sh 要用 MRA_REVIEW_EMIT_JSON=1 呼叫
# review_project 的 personas／debate／single-pass(standard 策略)三條路徑，
# 拿到跟 backtest_match 期待形狀一致的 review_json，不需要人看渲染、不要
# 通知、也不要動到 PKB。這支測試釘住兩件事：未設旗標時原本的行為完全不變
# (personas／debate 路徑的 _render_review_json／_review_notify_complete／
# _review_pkb_auto_update 三個都照跑；single-pass 走 inline 分支時
# post_inline_review／_review_notify_complete／_review_pkb_auto_update 三個
# 都照跑)；設了旗標後 review_json 原樣印到 stdout，三個都不跑。
#
# single-pass 還有一個 terminal／inline 兩分支的問題：terminal 分支只把模型
# 輸出即時串流出去，從來不組出一份完整的 review_json，也不會要求模型輸出
# STRICT JSON(見 lib/review-prompt.sh)。回測用 --range，不用 --pr，若
# output_mode 判斷式沒有把 MRA_REVIEW_EMIT_JSON 算進去，single-pass／standard
# 策略下 output_mode 永遠是 terminal，旗標形同虛設。這支測試的
# 「standard EMIT_JSON」案例就是在驗這件事：不用 --pr，只靠旗標本身把
# output_mode 逼去 inline。
#
# review_project 內部依賴很多輔助函式(pkb、structural、review-provider…)，
# 只挑幾個 lib 來源很容易漏東西、在測試時炸成 "command not found"。這裡改用
# bin/mra.sh 自己的 MRA_LIBS 清單完整載入，跟正式執行時的來源順序一致，
# 唯一的差別是之後覆寫 run_persona_review／run_synthesize／run_debate_review
# 三個真的會呼叫模型的函式，換成回傳固定 JSON 的 stub，不連網路、不用真的
# credential。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-json-flag-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MRA_CONFIG="$TMP/config.json"
printf '%s' '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' \
  > "$MRA_CONFIG"
export MRA_REVIEW_POST_MODE=none
export MRA_REVIEW_PR_CONTEXT=0
# 停用 premise 過濾，讓 stub 回的 review_json 原封不動地流到底，比對時才能
# 逐位元組釘住「原樣印出」。
export MRA_REVIEW_PREMISE_CHECK=0

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

# 完整依 bin/mra.sh 的 MRA_LIBS 清單載入，順序與正式執行時一致。
eval "$(sed -n '/^MRA_LIBS=(/,/^)/p' "$MRA_DIR/bin/mra.sh")"
for lib in "${MRA_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$MRA_DIR/lib/${lib}.sh"
done

STUB_JSON='{"status":"CHANGES_REQUESTED","summary":"stub 摘要","comments":[{"path":"app/a.rb","line":10,"severity":"HIGH","body":"stub finding"}]}'

RENDER_MARKER="$TMP/render-called"
NOTIFY_MARKER="$TMP/notify-called"
PKB_MARKER="$TMP/pkb-called"
POST_INLINE_MARKER="$TMP/post-inline-called"

# 覆寫真的會呼叫模型／發通知／動 PKB／發文的函式，換成純記錄「有沒有被呼叫」
# 的 stub。single-pass 路徑不經過 run_persona_review／run_synthesize，而是
# review_call_model → _review_singlepass_body(要求原始文字裡有完成 sentinel
# 才會判斷成功，見 lib/review-json.sh)。直接覆寫 _review_singlepass_body
# 跳過 sentinel／JSON 解析這一層，是 brief 允許的「最小函式層測試」；
# _review_refute_findings 用既有的 MRA_REVIEW_REFUTE=0 關掉，不用另外覆寫。
_render_review_json()   { : > "$RENDER_MARKER"; return 0; }
_review_notify_complete(){ : > "$NOTIFY_MARKER"; }
_review_pkb_auto_update(){ : > "$PKB_MARKER"; }
post_inline_review()    { : > "$POST_INLINE_MARKER"; return 0; }
run_persona_review()    { printf '%s' "persona findings stub"; }
run_synthesize()        { printf '%s' "$STUB_JSON"; }
run_debate_review()     { printf '%s' "$STUB_JSON"; }
review_call_model()     { printf '%s' "raw model output(single-pass 用不到，_review_singlepass_body 被整個覆寫掉了)"; }
_review_singlepass_body(){ printf '%s' "$STUB_JSON"; }
export MRA_REVIEW_REFUTE=0

reset_markers() { rm -f "$RENDER_MARKER" "$NOTIFY_MARKER" "$PKB_MARKER" "$POST_INLINE_MARKER"; }

# 直接呼叫 review_project(不透過 $(...) 子殼層)，讓函式內 `... &` 背景工作
# 是這支測試腳本自己的 job，才能用 `wait` 真的等到它跑完，而不是等一個已經
# 隨命令替換子殼層一起消失的孤兒行程。
call_review() {
  local out_file="$1" err_file="$2"
  shift 2
  review_project "$WS" proj "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  wait 2>/dev/null || true
  return $rc
}

# --- personas 路徑：預設(未設 MRA_REVIEW_EMIT_JSON)-------------------------
export MRA_REVIEW_PERSONAS=true
reset_markers
call_review "$TMP/p1.out" "$TMP/p1.err" --base main
rc=$?
eq "personas 預設路徑退出碼 0" "0" "$rc"
[[ -e "$RENDER_MARKER" ]] && ok "personas 預設有走 _render_review_json" \
                          || fail "personas 預設沒有走 _render_review_json"
[[ -e "$NOTIFY_MARKER" ]] && ok "personas 預設有呼叫 _review_notify_complete" \
                          || fail "personas 預設沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && ok "personas 預設有呼叫 _review_pkb_auto_update" \
                          || fail "personas 預設沒有呼叫 _review_pkb_auto_update"
out_p1="$(cat "$TMP/p1.out")"
if [[ "$out_p1" == "$STUB_JSON" ]]; then
  fail "personas 預設不該把 review_json 原樣印到 stdout"
else
  ok "personas 預設 stdout 不是 review_json 原樣(走的是渲染路徑)"
fi

# --- personas 路徑：MRA_REVIEW_EMIT_JSON=1 ---------------------------------
reset_markers
export MRA_REVIEW_EMIT_JSON=1
call_review "$TMP/p2.out" "$TMP/p2.err" --base main
rc=$?
unset MRA_REVIEW_EMIT_JSON
eq "personas EMIT_JSON 退出碼 0" "0" "$rc"
out_p2="$(cat "$TMP/p2.out")"
eq "personas EMIT_JSON 輸出等於 review_json 原樣" "$STUB_JSON" "$out_p2"
[[ -e "$RENDER_MARKER" ]] && fail "personas EMIT_JSON 不該呼叫 _render_review_json" \
                          || ok "personas EMIT_JSON 沒有呼叫 _render_review_json"
[[ -e "$NOTIFY_MARKER" ]] && fail "personas EMIT_JSON 不該呼叫 _review_notify_complete" \
                          || ok "personas EMIT_JSON 沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && fail "personas EMIT_JSON 不該呼叫 _review_pkb_auto_update" \
                          || ok "personas EMIT_JSON 沒有呼叫 _review_pkb_auto_update"
unset MRA_REVIEW_PERSONAS

# --- debate 路徑：預設 ------------------------------------------------------
reset_markers
call_review "$TMP/d1.out" "$TMP/d1.err" --base main --strategy debate
rc=$?
eq "debate 預設路徑退出碼 0" "0" "$rc"
[[ -e "$RENDER_MARKER" ]] && ok "debate 預設有走 _render_review_json" \
                          || fail "debate 預設沒有走 _render_review_json"
[[ -e "$NOTIFY_MARKER" ]] && ok "debate 預設有呼叫 _review_notify_complete" \
                          || fail "debate 預設沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && ok "debate 預設有呼叫 _review_pkb_auto_update" \
                          || fail "debate 預設沒有呼叫 _review_pkb_auto_update"
out_d1="$(cat "$TMP/d1.out")"
if [[ "$out_d1" == "$STUB_JSON" ]]; then
  fail "debate 預設不該把 review_json 原樣印到 stdout"
else
  ok "debate 預設 stdout 不是 review_json 原樣(走的是渲染路徑)"
fi

# --- debate 路徑：MRA_REVIEW_EMIT_JSON=1 ------------------------------------
reset_markers
export MRA_REVIEW_EMIT_JSON=1
call_review "$TMP/d2.out" "$TMP/d2.err" --base main --strategy debate
rc=$?
unset MRA_REVIEW_EMIT_JSON
eq "debate EMIT_JSON 退出碼 0" "0" "$rc"
out_d2="$(cat "$TMP/d2.out")"
eq "debate EMIT_JSON 輸出等於 review_json 原樣" "$STUB_JSON" "$out_d2"
[[ -e "$RENDER_MARKER" ]] && fail "debate EMIT_JSON 不該呼叫 _render_review_json" \
                          || ok "debate EMIT_JSON 沒有呼叫 _render_review_json"
[[ -e "$NOTIFY_MARKER" ]] && fail "debate EMIT_JSON 不該呼叫 _review_notify_complete" \
                          || ok "debate EMIT_JSON 沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && fail "debate EMIT_JSON 不該呼叫 _review_pkb_auto_update" \
                          || ok "debate EMIT_JSON 沒有呼叫 _review_pkb_auto_update"

# --- standard(single-pass)路徑：預設，用 --pr 讓它走 inline 分支 -----------
# single-pass 只有在 output_mode=inline 時才會組出 review_json；不用 --pr
# 又沒設 EMIT_JSON 的話會落到 terminal 分支(即時串流，沒有 review_json 這個
# 產物可以測)，所以這裡明講 --pr 1 走 inline，驗證「旗標沒開時，inline 分支
# 本來的行為(發文／通知／PKB 更新)完全不變」。本地沒有 origin remote，
# review_project 檢查 PR head 那段會 fail open(見 lib/review.sh 對這段的
# 註解)，不會被擋下來。
#
# 這裡刻意把檔案開頭全域設的 MRA_REVIEW_POST_MODE=none 換回預設值：那個全域
# 設定是給其他測試段落防呆用的，但 post_inline_review 本身就是被這個變數
# 直接擋掉(POST_MODE=none 時 inline 分支根本不會呼叫它)，若照舊沿用會讓這裡
# 測不出「旗標沒開時 post_inline_review 有沒有被呼叫」，變成一個看起來會過、
# 實際上沒驗到東西的空斷言。
reset_markers
MRA_REVIEW_POST_MODE=github call_review "$TMP/s1.out" "$TMP/s1.err" --pr 1 --base main --strategy standard
rc=$?
eq "standard 預設(inline)路徑退出碼 0" "0" "$rc"
[[ -e "$POST_INLINE_MARKER" ]] && ok "standard 預設有走 post_inline_review" \
                                || fail "standard 預設沒有走 post_inline_review"
[[ -e "$NOTIFY_MARKER" ]] && ok "standard 預設有呼叫 _review_notify_complete" \
                          || fail "standard 預設沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && ok "standard 預設有呼叫 _review_pkb_auto_update" \
                          || fail "standard 預設沒有呼叫 _review_pkb_auto_update"
out_s1="$(cat "$TMP/s1.out")"
if [[ "$out_s1" == "$STUB_JSON" ]]; then
  fail "standard 預設不該把 review_json 原樣印到 stdout"
else
  ok "standard 預設 stdout 不是 review_json 原樣(走的是發文路徑)"
fi

# --- standard 路徑：MRA_REVIEW_EMIT_JSON=1，不用 --pr ----------------------
# 這是這次新增的關鍵行為：不靠 --pr，單靠 MRA_REVIEW_EMIT_JSON=1 本身就要
# 把 output_mode 逼成 inline，否則 single-pass／standard 策略下旗標形同虛設
# (回測的呼叫形狀是 --range，從來不帶 --pr)。這裡也照上面同一個理由把
# MRA_REVIEW_POST_MODE 換回 github：POST_MODE=none 本身就會擋掉
# post_inline_review，若沿用檔案開頭的全域設定，「旗標開啟時不該呼叫
# post_inline_review」這條斷言不管旗標有沒有生效都會通過，變成測不出東西
# 的假斷言。
reset_markers
export MRA_REVIEW_EMIT_JSON=1
MRA_REVIEW_POST_MODE=github call_review "$TMP/s2.out" "$TMP/s2.err" --base main --strategy standard
rc=$?
unset MRA_REVIEW_EMIT_JSON
eq "standard EMIT_JSON 退出碼 0" "0" "$rc"
out_s2="$(cat "$TMP/s2.out")"
eq "standard EMIT_JSON 輸出等於 review_json 原樣" "$STUB_JSON" "$out_s2"
[[ -e "$POST_INLINE_MARKER" ]] && fail "standard EMIT_JSON 不該呼叫 post_inline_review" \
                                || ok "standard EMIT_JSON 沒有呼叫 post_inline_review"
[[ -e "$NOTIFY_MARKER" ]] && fail "standard EMIT_JSON 不該呼叫 _review_notify_complete" \
                          || ok "standard EMIT_JSON 沒有呼叫 _review_notify_complete"
[[ -e "$PKB_MARKER" ]]    && fail "standard EMIT_JSON 不該呼叫 _review_pkb_auto_update" \
                          || ok "standard EMIT_JSON 沒有呼叫 _review_pkb_auto_update"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
