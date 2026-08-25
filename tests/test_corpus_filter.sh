#!/usr/bin/env bash
# 語料篩選五步 (lib/corpus-filter.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-filter.sh"
FX="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
n()    { jq 'length'; }
ids()  { jq -c '[.[].id]'; }

eq "fixture 十筆" "10" "$(n < "$FX")"

eq "1 去 bot 留 7"    "7" "$(corpus_filter_bots < "$FX" | n)"
# id 10 的 .user 是 null（帳號已刪除），和兩個 bot 一起在第 1 步被濾掉。
# 沒有這層守衛的話 is_bot 會對 null 做 ascii_downcase 而讓整個 jq 中止。
eq "1 濾掉 bot 與無法歸屬" "[3,4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | ids)"

eq "2 資深留 6"       "6" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | n)"
eq "2 濾掉 id 3"      "[4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | ids)"
# 上面兩條沒帶第二個參數，是「今天的行為」的逐位元組對照組：corpus_filter_senior
# 不帶陣列時，$top 預設空陣列，any(. == $u) 恆為 false，等於只做 association 判準，
# 跟改動前完全一樣，數字不用改。

# spec 第 2 步的「或該 repo 留言數前 15 名」子句：id 3（outsider，association 是
# NONE）在名單裡就留下，不在名單裡（association 又沒過）就照舊濾掉。
eq "2 帶陣列：NONE 但在名單內被留下" "[3,4,5,6,7,8,9]" \
  "$(corpus_filter_bots < "$FX" | corpus_filter_senior '["outsider"]' | ids)"
eq "2 帶陣列：NONE 且不在名單內仍濾掉 id 3" "[4,5,6,7,8,9]" \
  "$(corpus_filter_bots < "$FX" | corpus_filter_senior '["someone-else"]' | ids)"

eq "3 品質留 5"       "5" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | n)"
eq "3 濾掉 id 4"      "[5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | ids)"

eq "4 有說明留 4"     "4" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"
eq "4 濾掉 id 8"      "[5,6,7,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | ids)"

# corpus_top_commenters：fixture 排掉 bot 與無法歸屬（id 10）之後只剩 4 個
# 不同 login——member1 四則（id 4/5/8/9），outsider/member2/member3 各一則。
eq "top_commenters 預設 n=15，四人全上榜" "[\"member1\",\"member2\",\"member3\",\"outsider\"]" \
  "$(corpus_top_commenters < "$FX" | jq -c .)"
eq "top_commenters n=1 只留留言數最高者" "[\"member1\"]" \
  "$(corpus_top_commenters 1 < "$FX" | jq -c .)"
# n=3 的邊界剛好切在留言數並列（各 1 則）的 outsider/member2/member3 中間：
# 並列時取 login 字母序在前的，member2 < member3 < outsider，outsider 被切掉。
eq "top_commenters n=3 並列取 login 字母序" "[\"member1\",\"member2\",\"member3\"]" \
  "$(corpus_top_commenters 3 < "$FX" | jq -c .)"
eq "top_commenters 不含 bot" "false" \
  "$(corpus_top_commenters < "$FX" | jq 'any(. == "coderabbitai[bot]" or . == "dependabot")')"
eq "top_commenters 不含無法歸屬（null user）" "false" \
  "$(corpus_top_commenters < "$FX" | jq 'any(. == null)')"

# 投影保留 diff_hunk 與出處 URL
proj="$(corpus_project rails/rails rails < "$FX")"
eq "投影保留 diff_hunk" "@@ -10,3 +10,5 @@" "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .diff_hunk')"
eq "投影帶 repo"        "rails/rails"       "$(printf '%s' "$proj" | jq -r '.[0].repo')"
eq "投影帶 layer"       "rails"             "$(printf '%s' "$proj" | jq -r '.[0].layer')"
eq "投影帶出處 URL"     "https://x/5"       "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .url')"
eq "投影帶 reviewer"    "member1"           "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .reviewer')"

# 串完整管線：stdout 是結果，stderr 是留存數。
# 加了「前 15 名」子句之後，id 3（outsider）在第 2 步不再被濾掉——fixture 裡扣掉
# bot 只剩 4 個不同 login，預設 n=15 全部上榜。id 3 的內文長度刻意超過 150 字元
# 且不是純 suggestion 區塊，所以一路留到品質、有說明兩關，鏈變成 10→7→7→6→5，
# 最終 id 集合從 [5,6,7,9] 變成 [3,5,6,7,9]。
err="$(mktemp "${TMPDIR:-/tmp}/corpus-filter-test.XXXXXX")"
out="$(corpus_filter_all rails/rails rails < "$FX" 2>"$err")"
eq "全管線留 5" "5" "$(printf '%s' "$out" | n)"
eq "全管線最終 id" "[3,5,6,7,9]" "$(printf '%s' "$out" | ids)"
eq "留存數 TSV" "RETENTION	rails/rails	10	7	7	6	5" "$(cat "$err")"
rm -f "$err"

# 空輸入不炸
eq "空陣列進出都是 0" "0" "$(printf '[]' | corpus_filter_bots | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"
eq "空陣列走全管線退出 0" "0" "$(printf '[]' | corpus_filter_all r l >/dev/null 2>&1; echo $?)"

# 壞掉的輸入必須失敗，不能靜默回 0。下游 build-corpus.sh 用這個退出碼判斷
# 該 repo 算不算失敗，回 0 的話壞資料會被當成「篩完 0 筆、一切正常」。
err2="$(mktemp)"
printf '{not valid json' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
eq "壞輸入退出 1" "1" "$rc"
case "$(cat "$err2")" in FILTER_INPUT_INVALID*) ok "印出 FILTER_INPUT_INVALID" ;; *) fail "缺 FILTER_INPUT_INVALID：$(cat "$err2")" ;; esac
case "$(cat "$err2")" in *RETENTION*) fail "壞輸入不該印 RETENTION" ;; *) ok "壞輸入不印 RETENTION" ;; esac

# 非陣列的合法 JSON 也算壞輸入
printf '{"a":1}' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
eq "JSON 物件也退出 1" "1" "$rc"

# 四個階段各自驗一次失敗會往上傳，而且錯誤訊息要指得出是哪一階段。
#
# 不要只測其中一個階段。守衛寫成 `local s1="$(...)" || {...}` 時 $? 恆為 0、守衛變成
# 死碼，只測 quality 的話另外三個階段被這樣寫也不會有人發現。實測過：只測 quality
# 時，把 bots 階段折成 local 一行寫法，整套仍然全綠。
for stage in bots senior quality prose; do
  orig_fn="$(declare -f "corpus_filter_$stage")"
  eval "corpus_filter_$stage() { return 5; }"
  printf '[]' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
  eq "$stage 階段失敗退出 1" "1" "$rc"
  case "$(cat "$err2")" in
    *"FILTER_STAGE_FAILED"*"$stage"*) ok "$stage 階段名有印出" ;;
    *) fail "$stage 缺階段名：$(cat "$err2")" ;;
  esac
  eval "$orig_fn"
done

# corpus_top_commenters 是 corpus_filter_all 的第五個階段（函式名不叫
# corpus_filter_top_commenters，跟上面迴圈的命名慣例對不上，所以另外測），
# 失敗一樣要往上傳並指名階段。
orig_top_fn="$(declare -f corpus_top_commenters)"
corpus_top_commenters() { return 5; }
printf '[]' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
eq "top_commenters 階段失敗退出 1" "1" "$rc"
case "$(cat "$err2")" in
  *"FILTER_STAGE_FAILED"*"top_commenters"*) ok "top_commenters 階段名有印出" ;;
  *) fail "top_commenters 缺階段名：$(cat "$err2")" ;;
esac
eval "$orig_top_fn"
rm -f "$err2"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
