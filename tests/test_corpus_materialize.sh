#!/usr/bin/env bash
# 篩選結果落地成每層一個 JSONL (lib/corpus-materialize.sh)。
#
# 兩條萃取路線都要讀完全一樣的語料，這支測試因此不只驗「跑得完」，還驗輸出
# 檔案本身的形狀：每行是合法 JSON 物件、欄位值對得上來源資料、續跑不重複、
# 壞資料要指名哪個檔、未知 repo 不能悄悄歸進 common 層。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-materialize.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/corpus-materialize-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# MRA_CORPUS_DIR 指到測試專屬目錄，理由同 tests/test_corpus_internal.sh：
# 不設的話 corpus_materialize_repo 會退回 $HOME/.cache/mra-review-corpus，
# 跑這條測試會動到使用者真正的快取。
FAKE="$TMP/corpus"
export MRA_CORPUS_DIR="$FAKE"

#
# corpus_filter_all 第 3 步「品質」要求 body 長度 > 150 字元（或有 in_reply_to
# 或 reactions），兩則留言的 body 都刻意寫到超過門檻：這樣被濾掉的那則能確定
# 是因為「是 bot」，不是因為內容太短——如果內容本身就短到會被品質門檻擋下
# 來，就沒辦法把「因為是 bot」這一個變數單獨隔離出來驗證。
setup_fake_corpus() {
  mkdir -p "$FAKE/nestjs__nest"
  cat > "$FAKE/nestjs__nest/0001.json" <<'JSON'
[
  {"user":{"login":"kamilmysliwiec"},"author_association":"MEMBER",
   "path":"packages/core/a.ts","body":"這段邏輯在 request scope 下會共用同一個 provider 實例，多個並發請求進來時會互相污染彼此的狀態，這是常見的併發安全問題。request-scoped provider 應該在每次請求進來時都重新建立一份，不能被快取或跨請求共用，否則不同使用者的資料可能會互相外洩。建議改成用 factory function 動態建立實例，並確保裡面沒有任何跨請求共用的可變狀態。","diff_hunk":"@@ -1,3 +1,4 @@\n+x","html_url":"https://github.com/nestjs/nest/pull/1#discussion_r1"},
  {"user":{"login":"coderabbitai[bot]"},"author_association":"NONE",
   "path":"packages/core/b.ts","body":"這是一則刻意寫得夠長的 bot 留言，內容長度必須超過一百五十個字元才能通過第 3 步品質篩選的門檻，這樣才能證明這一則留言最後會被濾掉，單純是因為留言者是機器人帳號，而不是因為內容太短或缺乏具體說明——如果內容本身就短到會被品質門檻擋下來，就沒辦法把「因為是 bot」這一個變數單獨隔離出來驗證，測試案例的意義就不完整了。","diff_hunk":"@@ -1,3 +1,4 @@\n+y","html_url":"https://github.com/nestjs/nest/pull/1#discussion_r2"}
]
JSON
}
setup_fake_corpus

# --- 案例 1：bot 被濾掉，真人留下 -------------------------------------------
OUT1="$TMP/out1"
n1_stdout="$(corpus_materialize_repo nestjs/nest "$OUT1")"
n1="$(wc -l < "$OUT1/nestjs.jsonl" | tr -d ' ')"
eq "只留下非 bot 的一則" "1" "$n1"
eq "stdout 印出寫入筆數" "1" "$n1_stdout"

# --- 案例 2：每行是合法 JSON 物件（不是陣列） -------------------------------
while IFS= read -r line; do
  printf '%s' "$line" | jq -e 'type == "object"' >/dev/null || fail "有一行不是 JSON 物件：$line"
done < "$OUT1/nestjs.jsonl"
ok "每行都是 JSON 物件"

# 額外驗欄位值本身，不只是「合法 JSON」：lib/corpus-filter.sh 的 corpus_project
# 已經把 .user.login 改名成 .reviewer、.author_association 改名成
# .association、.html_url 改名成 .url。materialize 如果直接沿用原始 GitHub
# 欄位名去取值，login/association/html_url 會全部悄悄變成 null——每行仍然是
# 合法 JSON 物件，上面那個「每行都是 JSON 物件」的檢查完全看不出來。
line1="$(head -1 "$OUT1/nestjs.jsonl")"
eq "login 對得上留言者" "kamilmysliwiec" "$(printf '%s' "$line1" | jq -r '.login')"
eq "association 對得上原始資料" "MEMBER" "$(printf '%s' "$line1" | jq -r '.association')"
eq "html_url 對得上原始資料" "https://github.com/nestjs/nest/pull/1#discussion_r1" \
  "$(printf '%s' "$line1" | jq -r '.html_url')"
eq "repo 欄位正確" "nestjs/nest" "$(printf '%s' "$line1" | jq -r '.repo')"
eq "layer 欄位正確" "nestjs" "$(printf '%s' "$line1" | jq -r '.layer')"
eq "diff_hunk 欄位保留" "@@ -1,3 +1,4 @@
+x" "$(printf '%s' "$line1" | jq -r '.diff_hunk')"

# --- 案例 3：續跑不重複追加（同一個 repo 跑兩次，筆數不變） -----------------
OUT3="$TMP/out3"
corpus_materialize_repo nestjs/nest "$OUT3" >/dev/null
first="$(wc -l < "$OUT3/nestjs.jsonl" | tr -d ' ')"
corpus_materialize_repo nestjs/nest "$OUT3" >/dev/null
second="$(wc -l < "$OUT3/nestjs.jsonl" | tr -d ' ')"
eq "跑兩次筆數不變" "$first" "$second"
eq "續跑筆數是 1" "1" "$second"

# --- 案例 4：分頁檔壞掉時用自己的 token 報錯，且不寫出半份檔案 --------------
OUT4="$TMP/out4"
printf 'not json' > "$FAKE/nestjs__nest/0002.json"
out4="$(corpus_materialize_repo nestjs/nest "$OUT4" 2>&1 >/dev/null)"; rc4=$?
[ "$rc4" -ne 0 ] && ok "壞掉的分頁檔退出碼非 0" || fail "應退出非 0，得到 $rc4"
has "印出 PAGE_PARSE_FAILED" "$out4" "PAGE_PARSE_FAILED"
has "訊息指名是哪個檔" "$out4" "0002.json"
if [ -f "$OUT4/nestjs.jsonl" ]; then
  fail "壞頁失敗後不該留下半份輸出檔"
else
  ok "壞頁失敗後沒有輸出檔"
fi
# 清掉壞頁，不要污染後面案例（後面案例會再用同一個 nestjs/nest 來源）。
rm -f "$FAKE/nestjs__nest/0002.json"

# --- 案例 5：未知 repo（不在 corpus_targets）要報錯，不要默默進 common 層 ---
OUT5="$TMP/out5"
out5="$(corpus_materialize_repo acme/unknown "$OUT5" 2>&1 >/dev/null)"; rc5=$?
[ "$rc5" -ne 0 ] && ok "未知 repo 退出碼非 0" || fail "應退出非 0，得到 $rc5"
has "印出 UNKNOWN_REPO" "$out5" "UNKNOWN_REPO"
if [ -d "$OUT5" ] && [ -n "$(ls -A "$OUT5" 2>/dev/null)" ]; then
  fail "未知 repo 不該寫出任何檔案"
else
  ok "未知 repo 沒有寫出任何檔案"
fi

# --- 案例 6：同一層的多個來源 repo 要合併進同一個檔，且 manifest 統計正確 --
# nestjs 層在 corpus_targets 裡有四個來源 repo。續跑要靠 repo 專屬的
# .done-<safe_repo> 標記檔判斷，不能只看輸出檔存不存在——輸出檔是整層的累積
# 結果，多個 repo 會疊寫進同一個檔，用「輸出檔已存在」判斷續跑的話，第二個
# repo 會被誤判成「已經跑過」而整個被跳過。
mkdir -p "$FAKE/nestjs__typeorm"
cat > "$FAKE/nestjs__typeorm/0001.json" <<'JSON'
[
  {"user":{"login":"pleerock"},"author_association":"OWNER",
   "path":"src/x.ts","body":"這個 repository pattern 的實作要特別注意 lazy loading 的邊界情況：如果關聯欄位沒有明確指定 eager 或在查詢時用 relations 選項帶出來，存取時就會拋出例外，而不是回傳空陣列，這點跟很多其他 ORM 的預設行為不一樣，很容易讓不熟悉 TypeORM 的人踩坑，建議在文件裡特別註明。","diff_hunk":"@@ -1,2 +1,3 @@\n+z","html_url":"https://github.com/nestjs/typeorm/pull/9#discussion_r9"}
]
JSON
OUT6="$TMP/out6"
corpus_materialize_repo nestjs/nest "$OUT6" >/dev/null
corpus_materialize_repo nestjs/typeorm "$OUT6" >/dev/null
n6="$(wc -l < "$OUT6/nestjs.jsonl" | tr -d ' ')"
eq "兩個 repo 都寫進同一個 nestjs.jsonl，不是互相覆蓋" "2" "$n6"

manifest6="$(corpus_materialize_manifest "$OUT6")"
has "manifest 印出 nestjs 層筆數 2" "$manifest6" "$(printf 'nestjs\t2\t')"
has "manifest 來源清單含 nestjs/nest" "$manifest6" "nestjs/nest"
has "manifest 來源清單含 nestjs/typeorm" "$manifest6" "nestjs/typeorm"
has "沒有語料的層顯示 0 筆" "$manifest6" "$(printf 'common\t0\t')"

# --- 案例 7：多分頁一定要先合併再篩選一次，不能逐頁各自跑 corpus_filter_all -
# lib/corpus-filter.sh 第 2 步「該 repo 留言數前 15 名」是以整個 repo 的
# 留言人口統計出來的。這裡刻意造兩頁、每頁各 10 個不同的 outsider（association
# 全是 NONE，留言數全部剛好 1 次），每則留言長度都過品質門檻。
#   - 逐頁各自跑 corpus_filter_all：每頁人口只有 10 人，不到 top-15 的截斷點，
#     兩頁完全不截斷，20 人全部通過，總數會是 20。
#   - 先合併兩頁成 20 人的陣列再篩一次：top-15 對 20 人截斷，留言數並列時取
#     login 字母序在前的（corpus_filter_senior 的既有行為），outsider01..15
#     留下、outsider16..20 被濾掉，總數會是 15。
# 對得上真實語料的實測：TanStack/query 逐頁跑總計 2,493 筆，合併後跑一次是
# 1,630 筆，跟 retention.tsv 記錄的 n4_prose 對得上的是合併後這個數字。
gen_outsider_page() {
  local start="$1" end="$2" outfile="$3"
  jq -n --argjson start "$start" --argjson end "$end" '
    [range($start; $end+1) | . as $i |
      { user: { login: ("outsider" + (if $i < 10 then "0" else "" end) + ($i | tostring)) },
        author_association: "NONE",
        path: ("src/f" + ($i|tostring) + ".ts"),
        body: ("這是一則長度足以通過品質篩選門檻的留言，內容重複填充以確保超過一百五十個字元，方便在測試中驗證 top-15 commenters 的合併行為是否正確而不是各頁各自獨立計算，項目編號 " + ($i|tostring) + "，這段文字純粹是為了拉長長度用，不代表真正的程式碼審查意見內容，只是佔位用途填充字數而已，多寫幾個字確保穩穩超過門檻不要卡在邊界上。"),
        diff_hunk: ("@@ -1,1 +1,2 @@\n+x" + ($i|tostring)),
        html_url: ("https://github.com/nestjs/swagger/pull/1#discussion_r" + ($i|tostring)) }
    ]' > "$outfile"
}
mkdir -p "$FAKE/nestjs__swagger"
gen_outsider_page 1 10 "$FAKE/nestjs__swagger/0001.json"
gen_outsider_page 11 20 "$FAKE/nestjs__swagger/0002.json"

OUT7="$TMP/out7"
corpus_materialize_repo nestjs/swagger "$OUT7" >/dev/null
n7="$(wc -l < "$OUT7/nestjs.jsonl" | tr -d ' ')"
eq "跨頁先合併再篩一次 top-15：20 人截斷成 15，不是逐頁各自不截斷的 20" "15" "$n7"

logins7="$(jq -r '.login' "$OUT7/nestjs.jsonl" | sort)"
eq "留下的是字母序前 15 名（outsider01..15），不是任意 15 人" \
  "$(printf 'outsider01\noutsider02\noutsider03\noutsider04\noutsider05\noutsider06\noutsider07\noutsider08\noutsider09\noutsider10\noutsider11\noutsider12\noutsider13\noutsider14\noutsider15')" \
  "$logins7"

# --- 案例 8：corpus_filter_all 的診斷不能被吞掉 -----------------------------
# lib/corpus-filter.sh 自己用各自的 token 報 FILTER_STAGE_FAILED（還指出是
# bots／senior／quality／prose 哪一階段）。原本這裡對 corpus_filter_all 的
# stderr 是 2>/dev/null，失敗時只看得到外層包出來的 FILTER_FAILED，查不出是
# 四步裡的哪一步炸的——階段二 run-backtest.sh 對每次 review 呼叫做過同一件事
# （2>/dev/null），結果整輪跑完拿到一個 0 bytes 的 log，完全無法診斷，而失敗
# 原因後來證實有四種不同的形狀。
OUT8="$TMP/out8"
orig_quality_fn="$(declare -f corpus_filter_quality)"
corpus_filter_quality() { return 5; }
out8_diag="$(corpus_materialize_repo nestjs/nest "$OUT8" 2>&1 >/dev/null)"; rc8_diag=$?
eval "$orig_quality_fn"
[ "$rc8_diag" -ne 0 ] && ok "篩選階段失敗時退出碼非 0" || fail "應退出非 0，得到 $rc8_diag"
has "印出外層的 FILTER_FAILED" "$out8_diag" "FILTER_FAILED"
has "印出 corpus_filter_all 自己的 FILTER_STAGE_FAILED" "$out8_diag" "FILTER_STAGE_FAILED"
has "指出是 quality 階段" "$out8_diag" "quality"

# --- 案例 9：marker 已經原子寫入、layer.jsonl 還沒寫完就中斷——續跑要嘛短少
# 要嘛跳過，絕對不能重複 --------------------------------------------------
# 用一個「目標是 .jsonl 結尾就失敗、其餘照常放行」的假 mv 蓋過 PATH，模擬
# 「被中斷在 marker 已經 mv 成功、layer.jsonl 還沒 mv 完」這個時間點——這正是
# 修正後的設計刻意選的失敗方向：marker 先於 layer.jsonl 落地，中斷只會造成
# 短少（可以跟 retention.tsv 對照抓出來），不會造成重複（兩條萃取路線會讀到
# 被污染的語料卻毫無錯誤訊息）。
OUT9="$TMP/out9"
mkdir -p "$OUT9"
STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/mv" <<'STUB'
#!/usr/bin/env bash
# 只讓「目標是 .jsonl 結尾」的 mv 失敗（模擬 layer.jsonl 那次 mv 被中斷），
# marker（.done-*）與鎖目錄用到的 mv 照常放行。
last="${@: -1}"
case "$last" in
  *.jsonl) exit 1 ;;
  *) exec /bin/mv "$@" ;;
esac
STUB
chmod +x "$STUBBIN/mv"

out9_crash="$(PATH="$STUBBIN:$PATH" corpus_materialize_repo nestjs/nest "$OUT9" 2>&1 >/dev/null)"
rc9_crash=$?
[ "$rc9_crash" -ne 0 ] && ok "layer.jsonl 寫入被中斷時退出碼非 0" || fail "應退出非 0，得到 $rc9_crash"
has "印出 LAYER_WRITE_FAILED" "$out9_crash" "LAYER_WRITE_FAILED"
if [ -f "$OUT9/.done-nestjs__nest" ]; then
  ok "marker 確實先於 layer.jsonl 原子寫入成功（設計的重點）"
else
  fail "marker 應該已經寫成功——marker 要先於 layer.jsonl 落地才對"
fi
if [ -f "$OUT9/nestjs.jsonl" ]; then
  fail "layer.jsonl 不該在這個中斷點被建立（mv 已被攔截失敗）"
else
  ok "layer.jsonl 確實還沒寫入（符合模擬的中斷點）"
fi

# 中斷後續跑（换回真正的 mv）：marker 已存在，應該直接短路跳過，不會重新
# 處理、也不會把 layer.jsonl 補上——這正是「短少而非重複」的設計取捨，續跑
# 本身仍然成功、不會有任何錯誤訊息，但筆數不能翻倍。
out9_retry="$(corpus_materialize_repo nestjs/nest "$OUT9")"; rc9_retry=$?
eq "續跑（真正的 mv）退出碼是 0（短路跳過）" "0" "$rc9_retry"
eq "續跑印出跟 marker 一致的筆數" "1" "$out9_retry"
if [ -f "$OUT9/nestjs.jsonl" ]; then
  n9="$(wc -l < "$OUT9/nestjs.jsonl" | tr -d ' ')"
  eq "layer.jsonl 筆數是 1（短少過的狀態），不是 2（沒有重複）" "1" "$n9"
else
  ok "layer.jsonl 仍然缺席（短少而非重複——短路後不會補寫）"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
