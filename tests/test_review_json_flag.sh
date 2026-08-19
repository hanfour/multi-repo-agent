#!/usr/bin/env bash
# lib/review.sh：MRA_REVIEW_EMIT_JSON 旗標。
#
# scripts/backtest-review-adapter.sh 要用 MRA_REVIEW_EMIT_JSON=1 呼叫
# review_project 的 personas／debate 兩條路徑，拿到跟 backtest_match 期待形狀
# 一致的 review_json，不需要人看渲染、不要通知、也不要動到 PKB。這支測試釘住
# 兩件事：未設旗標時原本的行為完全不變(_render_review_json／
# _review_notify_complete／_review_pkb_auto_update 三個都照跑)；設了旗標後
# review_json 原樣印到 stdout，三個都不跑。
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

# 覆寫三個真的會呼叫模型／發通知／動 PKB 的函式，換成純記錄「有沒有被呼叫」
# 的 stub。
_render_review_json()   { : > "$RENDER_MARKER"; return 0; }
_review_notify_complete(){ : > "$NOTIFY_MARKER"; }
_review_pkb_auto_update(){ : > "$PKB_MARKER"; }
run_persona_review()    { printf '%s' "persona findings stub"; }
run_synthesize()        { printf '%s' "$STUB_JSON"; }
run_debate_review()     { printf '%s' "$STUB_JSON"; }

reset_markers() { rm -f "$RENDER_MARKER" "$NOTIFY_MARKER" "$PKB_MARKER"; }

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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
