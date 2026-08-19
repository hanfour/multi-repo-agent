#!/usr/bin/env bash
# lib/review.sh：personas 路徑在 run_synthesize 之後、_review_enforce_*
# 之前，要驗證輸出是不是合法的 review JSON。
#
# 背景：run_synthesize 最後一步是 claude_invoke，會安靜地失敗：5 個 persona
# 全部成功，但 synthesize 這一步吐出空字串／散文／截斷 JSON／缺 .comments，
# mra 整體退出碼仍是 0。_review_enforce_adjudication／_review_enforce_premises
# 對無法解析的輸入原樣放行，結果一路印出一個空的或不合法的 review_json，
# 讓 scripts/backtest-review-adapter.sh 判成 REVIEW_OUTPUT_INVALID(基準線 C
# 三筆 PR 都是這個形狀）。
#
# 絕對不能在這裡補一個 {"status":"APPROVED"} 去頂：那是偽造核准。這支測試
# 釘住的是：不合格時一律退回中立的 review_incomplete_json(status=COMMENT），
# 而且 stderr 要印出「實際拿到什麼」（退出碼、長度、前 200 字元），不是只說
# 「不合法」。
#
# 實測後補的第二個發現：加了上面那道驗證之後，實測 acme/rails-app-1#4830／#4869／
# #4895 抓到的真正原因不是 synthesize 失敗，而是它常常把合法 JSON 包在
# ```json ... ``` 這種 markdown code fence 裡。debate 與 single-pass 兩條
# 路徑都先用 extract_json 剝掉 fence 再驗證，personas 這裡漏了這一步，
# 導致好幾份完整、高品質的 review 被誤判成不合法、整份丟掉。這支測試也釘住
# fence 剝除本身：合法 JSON 不管有沒有被 fence 包住都要正常解析放行，而
# 真正失敗的情況(空字串／散文／缺欄位／退出碼非 0)不能被這道新增的抽取
# 「救」成合法。
#
# 沿用 tests/test_review_json_flag.sh 的作法：完整依 bin/mra.sh 的 MRA_LIBS
# 清單載入，之後覆寫 run_persona_review／run_synthesize 兩個真的會呼叫模型
# 的函式，換成回傳固定內容的 stub，不連網路、不用真的 credential。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1 — expected substring [$3] in [$2]"; fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else fail "$1 — did not expect substring [$3] in [$2]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-personas-synth-validate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MRA_CONFIG="$TMP/config.json"
printf '%s' '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' \
  > "$MRA_CONFIG"
export MRA_REVIEW_POST_MODE=none
export MRA_REVIEW_PR_CONTEXT=0
# 停用 premise 過濾：合格案例的 stub 有一個 comment，過濾邏輯會去查案例中
# 不存在的符號名稱，跟這支測試想驗的東西無關，關掉才能逐位元組比對。
export MRA_REVIEW_PREMISE_CHECK=0
export MRA_REVIEW_PERSONAS=true
# JSON 直吐模式：跟真正踩雷的呼叫形狀一致(scripts/backtest-review-adapter.sh
# 就是這樣呼叫的），stdout 只會是 review_json 原樣，方便逐位元組比對；
# log_warn 的診斷訊息也因此固定走 stderr(見 lib/review.sh 的
# _review_maybe_stderr_log 註解），不用另外分流判斷。
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

VALID_JSON='{"status":"CHANGES_REQUESTED","summary":"stub 摘要","comments":[{"path":"f.txt","line":1,"severity":"HIGH","body":"stub finding"}]}'
VALID_APPROVED_JSON='{"status":"APPROVED","summary":"沒有發現問題","comments":[]}'
MISSING_COMMENTS_JSON='{"status":"CHANGES_REQUESTED","summary":"缺 comments 欄位"}'
PROSE_OUTPUT='I could not finish this review because the diff was too large and I ran out of context budget before producing structured output.'

# 三種 fence 包裝形狀，對應 extract_json(lib/review-json.sh)的三條抽取
# 分支：```json 標記、純 ``` 沒有標記、fence 前後還夾著說明文字或空白行。
FENCED_JSON_LABELED=$'```json\n'"$VALID_JSON"$'\n```'
FENCED_JSON_PLAIN=$'```\n'"$VALID_JSON"$'\n```'
FENCED_JSON_WITH_PROSE=$'這是五個 persona 綜合後的最終 review：\n\n```json\n'"$VALID_JSON"$'\n```\n\n如果還需要別的資訊請告訴我。\n'

# 用一個全域變數控制 run_synthesize stub 這次要回什麼、退出碼是多少，
# 讓每個測試案例只需要在呼叫前設一次就好，不用另外定義一整組函式。
SYNTH_MODE="valid"
run_synthesize() {
  case "$SYNTH_MODE" in
    valid)             printf '%s' "$VALID_JSON"; return 0 ;;
    valid_approved)    printf '%s' "$VALID_APPROVED_JSON"; return 0 ;;
    fenced_labeled)    printf '%s' "$FENCED_JSON_LABELED"; return 0 ;;
    fenced_plain)      printf '%s' "$FENCED_JSON_PLAIN"; return 0 ;;
    fenced_with_prose) printf '%s' "$FENCED_JSON_WITH_PROSE"; return 0 ;;
    empty)             printf ''; return 0 ;;
    prose)             printf '%s' "$PROSE_OUTPUT"; return 0 ;;
    missing_comments)  printf '%s' "$MISSING_COMMENTS_JSON"; return 0 ;;
    nonzero_exit)      printf '%s' "$VALID_JSON"; return 7 ;;
    *) printf '%s' "$VALID_JSON"; return 0 ;;
  esac
}
run_persona_review() { printf '%s' "persona findings stub(5 個 persona 全部成功)"; }

call_review() {
  local out_file="$1" err_file="$2"
  shift 2
  review_project "$WS" proj "$@" >"$out_file" 2>"$err_file"
  local rc=$?
  wait 2>/dev/null || true
  return $rc
}

# --- 案例 1：synthesize 回合法 JSON 時，行為與現在完全一致 -----------------
SYNTH_MODE="valid"
call_review "$TMP/c1.out" "$TMP/c1.err" --base main
rc=$?
eq "合法 JSON：退出碼 0" "0" "$rc"
out_c1="$(cat "$TMP/c1.out")"
eq "合法 JSON：stdout 原樣等於 synthesize 的輸出(沒有被改寫)" "$VALID_JSON" "$out_c1"
err_c1="$(cat "$TMP/c1.err")"
not_contains "合法 JSON：stderr 不該出現「沒有產生合法的 review JSON」診斷" "$err_c1" "沒有產生合法的 review JSON"

# --- 案例 1b：synthesize 真的回一份合法的 APPROVED JSON 時，原樣放行 -------
SYNTH_MODE="valid_approved"
call_review "$TMP/c1b.out" "$TMP/c1b.err" --base main
rc=$?
eq "合法 APPROVED JSON：退出碼 0" "0" "$rc"
out_c1b="$(cat "$TMP/c1b.out")"
eq "合法 APPROVED JSON：stdout 原樣放行，沒有被改寫成 incomplete" "$VALID_APPROVED_JSON" "$out_c1b"

# --- 案例 1c：synthesize 回被 ```json fence 包住的合法 JSON -----------------
# 這是實測抓到的真正原因：synthesize 沒有失敗，只是被 fence 包住。這條要能
# 單獨 RED：拿掉 lib/review.sh 那行 extract_json 呼叫就要變紅。
SYNTH_MODE="fenced_labeled"
call_review "$TMP/c1c.out" "$TMP/c1c.err" --base main
rc=$?
eq "json code fence：退出碼 0" "0" "$rc"
out_c1c="$(cat "$TMP/c1c.out")"
status_c1c="$(printf '%s' "$out_c1c" | jq -r '.status' 2>/dev/null)"
eq "json code fence：剝掉 fence 後正常解析，status 是原本的 CHANGES_REQUESTED，不是 REVIEW_INCOMPLETE" \
  "CHANGES_REQUESTED" "$status_c1c"
eq "json code fence：剝掉 fence 後的內容跟原本沒被包住時完全一樣" "$VALID_JSON" "$out_c1c"
err_c1c="$(cat "$TMP/c1c.err")"
not_contains "json code fence：stderr 不該出現「沒有產生合法的 review JSON」診斷" \
  "$err_c1c" "沒有產生合法的 review JSON"

# --- 案例 1d：fence 是純 ``` 沒有 json 標記 ----------------------------------
SYNTH_MODE="fenced_plain"
call_review "$TMP/c1d.out" "$TMP/c1d.err" --base main
rc=$?
eq "純 code fence(不帶 json 標記)：退出碼 0" "0" "$rc"
out_c1d="$(cat "$TMP/c1d.out")"
status_c1d="$(printf '%s' "$out_c1d" | jq -r '.status' 2>/dev/null)"
eq "純 code fence(不帶 json 標記)：剝掉 fence 後正常解析，不是 REVIEW_INCOMPLETE" "CHANGES_REQUESTED" "$status_c1d"
eq "純 code fence(不帶 json 標記)：剝掉 fence 後的內容跟原本沒被包住時完全一樣" "$VALID_JSON" "$out_c1d"

# --- 案例 1e：fence 前後夾著說明文字與空白行 ---------------------------------
SYNTH_MODE="fenced_with_prose"
call_review "$TMP/c1e.out" "$TMP/c1e.err" --base main
rc=$?
eq "fence 前後有說明文字：退出碼 0" "0" "$rc"
out_c1e="$(cat "$TMP/c1e.out")"
status_c1e="$(printf '%s' "$out_c1e" | jq -r '.status' 2>/dev/null)"
eq "fence 前後有說明文字：剝掉 fence 跟前後文字後正常解析，不是 REVIEW_INCOMPLETE" \
  "CHANGES_REQUESTED" "$status_c1e"
eq "fence 前後有說明文字：剝掉後的內容跟原本沒被包住時完全一樣" "$VALID_JSON" "$out_c1e"

# --- 案例 2：synthesize 回空字串 --------------------------------------------
SYNTH_MODE="empty"
call_review "$TMP/c2.out" "$TMP/c2.err" --base main
rc=$?
eq "空字串：退出碼 0(mra 本身不因此失敗)" "0" "$rc"
out_c2="$(cat "$TMP/c2.out")"
status_c2="$(printf '%s' "$out_c2" | jq -r '.status' 2>/dev/null)"
eq "空字串：輸出是中立的 review_incomplete_json(status=COMMENT)" "COMMENT" "$status_c2"
comments_c2="$(printf '%s' "$out_c2" | jq -c '.comments' 2>/dev/null)"
eq "空字串：comments 是空陣列" "[]" "$comments_c2"
err_c2="$(cat "$TMP/c2.err")"
contains "空字串：stderr 有印出退出碼 exit=0" "$err_c2" "exit=0"
contains "空字串：stderr 有印出長度 長度=0" "$err_c2" "長度=0"

# --- 案例 3：synthesize 回非 JSON 散文 --------------------------------------
SYNTH_MODE="prose"
call_review "$TMP/c3.out" "$TMP/c3.err" --base main
rc=$?
eq "散文：退出碼 0" "0" "$rc"
out_c3="$(cat "$TMP/c3.out")"
status_c3="$(printf '%s' "$out_c3" | jq -r '.status' 2>/dev/null)"
eq "散文：輸出是中立的 review_incomplete_json(status=COMMENT)" "COMMENT" "$status_c3"
err_c3="$(cat "$TMP/c3.err")"
contains "散文：stderr 有印出那段散文的前綴" "$err_c3" "I could not finish this review"

# --- 案例 4：synthesize 回合法 JSON 但缺 .comments --------------------------
SYNTH_MODE="missing_comments"
call_review "$TMP/c4.out" "$TMP/c4.err" --base main
rc=$?
eq "缺 comments：退出碼 0" "0" "$rc"
out_c4="$(cat "$TMP/c4.out")"
status_c4="$(printf '%s' "$out_c4" | jq -r '.status' 2>/dev/null)"
eq "缺 comments：輸出是中立的 review_incomplete_json(status=COMMENT)" "COMMENT" "$status_c4"
err_c4="$(cat "$TMP/c4.err")"
contains "缺 comments：stderr 有印出這段合法但缺欄位的原始輸出" "$err_c4" "缺 comments 欄位"

# --- 案例 5：synthesize 退出碼非 0 -------------------------------------------
SYNTH_MODE="nonzero_exit"
call_review "$TMP/c5.out" "$TMP/c5.err" --base main
rc=$?
eq "退出碼非 0：mra 整體仍是 0(不因 synthesize 失敗而整個中斷)" "0" "$rc"
out_c5="$(cat "$TMP/c5.out")"
status_c5="$(printf '%s' "$out_c5" | jq -r '.status' 2>/dev/null)"
eq "退出碼非 0：即使輸出內容看起來合法，仍退回 review_incomplete_json" "COMMENT" "$status_c5"
err_c5="$(cat "$TMP/c5.err")"
contains "退出碼非 0：訊息裡有那個退出碼 exit=7" "$err_c5" "exit=7"

# --- 案例 6：不可以有任何不合格情況產出 status=APPROVED ---------------------
for mode in empty prose missing_comments nonzero_exit; do
  SYNTH_MODE="$mode"
  call_review "$TMP/c6-$mode.out" "$TMP/c6-$mode.err" --base main
  out="$(cat "$TMP/c6-$mode.out")"
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [[ "$status" == "APPROVED" ]]; then
    fail "不合格情況($mode)絕對不能得到 status=APPROVED，實際是 [$status]"
  else
    ok "不合格情況($mode)沒有偽造出 status=APPROVED(實際是 [$status])"
  fi
done

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
