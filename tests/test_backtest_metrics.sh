#!/usr/bin/env bash
# 回測指標計算 (lib/backtest-metrics.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-metrics.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

expected='[
 {"path":"app/a.rb","line":95,"severity":"HIGH","note":"回傳值沒判 nil"},
 {"path":"app/b.rb","line":30,"severity":"CRITICAL","note":"少了權限檢查"},
 {"path":"app/c.rb","line":10,"severity":"MEDIUM","note":"命名不一致"}
]'
review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/a.rb","line":97,"body":"nil 沒處理","severity":"HIGH"},
 {"path":"app/b.rb","line":30,"body":"權限","severity":"MEDIUM"},
 {"path":"app/z.rb","line":5,"body":"別的問題","severity":"LOW"}
]}'

m="$(backtest_match "$review" "$expected" 5)"
eq "三筆期望都有結果" "3" "$(printf '%s' "$m" | jq 'length')"
# a.rb:95 與 comment 的 97 相差 2,在容差 5 內 → 命中
eq "容差內命中"   "97"   "$(printf '%s' "$m" | jq -r '.[0].matched.line')"
# b.rb:30 完全相同 → 命中
eq "同行命中"     "30"   "$(printf '%s' "$m" | jq -r '.[1].matched.line')"
# c.rb 沒有任何 comment → 漏抓
eq "無對應為 null" "null" "$(printf '%s' "$m" | jq -r '.[2].matched')"

# 容差縮到 1,a.rb 就不該命中了
m1="$(backtest_match "$review" "$expected" 1)"
eq "容差 1 不命中" "null" "$(printf '%s' "$m1" | jq -r '.[0].matched')"

r="$(backtest_metrics "$m" "$review")"
eq "期望總數"   "3" "$(printf '%s' "$r" | jq -r '.expected_total')"
eq "漏抓數"     "1" "$(printf '%s' "$r" | jq -r '.missed')"
eq "漏抓率"     "0.33" "$(printf '%s' "$r" | jq -r '.miss_rate')"
eq "comment 總數" "3" "$(printf '%s' "$r" | jq -r '.comments_total')"
eq "未對應數"   "1" "$(printf '%s' "$r" | jq -r '.unmatched')"
eq "未對應率"   "0.33" "$(printf '%s' "$r" | jq -r '.unmatched_rate')"
# 兩筆命中,a.rb 的 HIGH 對、b.rb 標 MEDIUM 但期望 CRITICAL 錯
eq "嚴重度吻合" "1" "$(printf '%s' "$r" | jq -r '.severity_agree')"
eq "嚴重度吻合率" "0.5" "$(printf '%s' "$r" | jq -r '.severity_rate')"

# 特殊情況：沒有任何 comment
r0="$(backtest_metrics "$(backtest_match '{"status":"APPROVED","summary":"x","comments":[]}' "$expected" 5)" \
       '{"status":"APPROVED","summary":"x","comments":[]}')"
eq "全漏抓" "1" "$(printf '%s' "$r0" | jq -r '.miss_rate')"
eq "未對應率 0(無分母時為 0)" "0" "$(printf '%s' "$r0" | jq -r '.unmatched_rate')"
eq "嚴重度率 0(無分母時為 0)" "0" "$(printf '%s' "$r0" | jq -r '.severity_rate')"

# 特殊情況：期望為空
re="$(backtest_metrics "$(backtest_match "$review" '[]' 5)" "$review")"
eq "期望為空時漏抓率 0" "0" "$(printf '%s' "$re" | jq -r '.miss_rate')"

# Fix round 1 — Gap A：容差邊界從沒被踩過。原本的 fixture 裡沒有任何一筆
# |line 差| 剛好等於 tolerance,所以「<=」跟「<」在原本的資料上永遠算出同一個
# 結果。這裡逐一踩過邊界兩側跟邊界本身,各自有獨立命名的斷言,讓比較運算子
# 本身被改壞時直接踩到這裡,而不是要靠下游的某個計數才看得出來。
boundary_expected='[
 {"path":"app/e1.rb","line":100,"severity":"HIGH","note":"邊界測試:距離剛好等於容差"},
 {"path":"app/e2.rb","line":100,"severity":"HIGH","note":"邊界測試:距離等於容差+1"},
 {"path":"app/e3.rb","line":100,"severity":"HIGH","note":"邊界測試:距離等於容差-1"}
]'
boundary_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/e1.rb","line":105,"body":"距離剛好 5,容差邊界本身","severity":"HIGH"},
 {"path":"app/e2.rb","line":106,"body":"距離 6,超出容差","severity":"HIGH"},
 {"path":"app/e3.rb","line":104,"body":"距離 4,容差內","severity":"HIGH"}
]}'
bm="$(backtest_match "$boundary_review" "$boundary_expected" 5)"
eq "距離等於容差(5)仍算命中" "105"  "$(printf '%s' "$bm" | jq -r '.[0].matched.line')"
eq "距離超過容差(6)算漏抓"   "null" "$(printf '%s' "$bm" | jq -r '.[1].matched')"
eq "距離小於容差(4)算命中"   "104"  "$(printf '%s' "$bm" | jq -r '.[2].matched.line')"

# Fix round 1 — Gap F：一個 expected finding 收到三則落在同一容差窗內的
# comment,是真實 review 常見的形狀(針對同一個缺陷寫好幾則留言),不是例外。
# c2 離缺陷 0 行、c1/c3 各離 2 行,三則都在 tolerance=5 的窗內。c1/c3 的
# severity 刻意跟 expected 的 HIGH 不同(LOW/MEDIUM),c2 才是 HIGH,這樣
# severity_rate 的分母算一次(1/1=1)跟算三次(1/3=0.33)才會是可分辨的兩個值,
# 不會剛好巧合算出同一個數字。
multi_expected='[{"path":"app/f.rb","line":50,"severity":"HIGH","note":"一個缺陷,三則 comment 都在附近"}]'
multi_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/f.rb","line":48,"body":"c1,離 2 行","severity":"LOW"},
 {"path":"app/f.rb","line":50,"body":"c2,離 0 行,應該是被選中的那一筆","severity":"HIGH"},
 {"path":"app/f.rb","line":52,"body":"c3,離 2 行","severity":"MEDIUM"}
]}'
mf="$(backtest_match "$multi_review" "$multi_expected" 5)"
eq "多筆候選只算一筆命中的 expected" "1"  "$(printf '%s' "$mf" | jq 'length')"
eq "多筆候選選最近的那一筆"         "50" "$(printf '%s' "$mf" | jq -r '.[0].matched.line')"
mmf="$(backtest_metrics "$mf" "$multi_review")"
eq "未被選中的兩筆算未對應"           "2" "$(printf '%s' "$mmf" | jq -r '.unmatched')"
eq "嚴重度吻合分母只算命中的一筆(不是三筆)" "1" "$(printf '%s' "$mmf" | jq -r '.severity_rate')"

# Fix round 2 — CRITICAL 1：unmatched 原本只比 comment 的 line 值,不管
# comment 是哪一個(位置)、在哪個檔案。app/g.rb:200 命中之後,unmatched 判斷
# 若還在用 line 值,會把「行號剛好也是 200 但完全是另一個檔案」的 app/h.rb
# comment 誤判成命中——因為兩者的 .line 都是 200,line 值比對分不出來。
crit1_expected='[{"path":"app/g.rb","line":200,"severity":"HIGH","note":"跟 h.rb 的 comment 行號一樣但是不同檔案"}]'
crit1_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/g.rb","line":200,"body":"這則才是真的命中","severity":"HIGH"},
 {"path":"app/h.rb","line":200,"body":"跟上面同行號,但完全是另一個檔案,不該被當命中","severity":"LOW"}
]}'
mc1="$(backtest_match "$crit1_review" "$crit1_expected" 5)"
rc1="$(backtest_metrics "$mc1" "$crit1_review")"
eq "跨檔案同行號的 comment 不能被誤判成命中" "1" "$(printf '%s' "$rc1" | jq -r '.unmatched')"

# Fix round 2 — IMPORTANT 2：兩個 expected finding 的容差窗重疊,搶同一顆
# comment。app/k.rb:100 跟 app/k.rb:103 都在 tolerance 5 內看得到唯一一則
# app/k.rb:101 的 comment。照 (path, line) 排序,line 100 那筆先處理、先搶到；
# line 103 那筆沒有其他候選,只能算漏抓——不能兩個 expected 都各自宣稱命中
# 同一顆 comment。
overlap_expected='[
 {"path":"app/k.rb","line":103,"severity":"MEDIUM","note":"排序後較晚處理,候選被搶走"},
 {"path":"app/k.rb","line":100,"severity":"HIGH","note":"排序後較早處理,先搶到"}
]'
overlap_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/k.rb","line":101,"body":"兩個 expected 的容差窗都罩得到,只能被搶一次","severity":"HIGH"}
]}'
mo="$(backtest_match "$overlap_review" "$overlap_expected" 5)"
# 輸出順序照原始 expected 陣列順序(103 在前、100 在後),跟排序處理順序是兩件事。
eq "重疊容差窗:先搶到的那個(line 100)命中" "101" \
  "$(printf '%s' "$mo" | jq -r '.[] | select(.expected.line == 100) | .matched.line')"
eq "重疊容差窗:候選被搶走的那個(line 103)算漏抓" "null" \
  "$(printf '%s' "$mo" | jq -r '.[] | select(.expected.line == 103) | .matched')"
ro="$(backtest_metrics "$mo" "$overlap_review")"
eq "重疊容差窗不會讓 missed 少算(該漏抓的還是漏抓)" "1" "$(printf '%s' "$ro" | jq -r '.missed')"
eq "重疊容差窗不會讓 severity_agree 被同一顆 comment 重複計算" "1" \
  "$(printf '%s' "$ro" | jq -r '.severity_agree')"

# Fix round 2 — IMPORTANT 3a：容差窗內兩則候選距離打平(genuine tie)時,選
# review.comments 陣列裡排比較前面的那一筆——這是目前的既定行為,之前沒有任何
# fixture 造出真正的 tie(Gap F 那組 c2 距離 0 是唯一最近,不是 tie),所以「把
# 候選陣列反過來讓 tie 選到另一筆」這種改法完全不會被踩到。這裡直接釘住結果。
tie_expected='[{"path":"app/tie.rb","line":100,"severity":"HIGH","note":"兩則候選距離打平"}]'
tie_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/tie.rb","line":98,"body":"距離 2,陣列裡排第一個","severity":"HIGH"},
 {"path":"app/tie.rb","line":102,"body":"距離也是 2,陣列裡排第二個","severity":"LOW"}
]}'
mt="$(backtest_match "$tie_review" "$tie_expected" 5)"
eq "距離打平時選陣列裡排前面的那一筆" "98" "$(printf '%s' "$mt" | jq -r '.[0].matched.line')"

# Fix round 2 — IMPORTANT 3b：沒給容差引數時預設是 5,是校準過的值。這裡的
# comment 離期望的行號差 6——預設 5 的話應該漏抓,預設被悄悄改成 6(或更大)
# 就會變成命中,藉此釘住預設值本身,不只是「有給引數時容差生效」這件事。
default_tol_expected='[{"path":"app/def.rb","line":50,"severity":"HIGH","note":"驗證預設容差是 5"}]'
default_tol_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/def.rb","line":56,"body":"距離 6,預設容差 5 應該漏抓","severity":"HIGH"}
]}'
mdt="$(backtest_match "$default_tol_review" "$default_tol_expected")"
eq "不給容差引數時預設值是 5(距離 6 應該漏抓)" "null" "$(printf '%s' "$mdt" | jq -r '.[0].matched')"

# --- backtest_file_missed：檔案層級的漏抓 -------------------------------
# 行號容差指標對錨點高度敏感，這個指標用來分辨「沒看到那個檔案」與「看到了但
# 錨點落在幾十行外」。
fm_expected='[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"},
              {"path":"app/b.rb","line":20,"severity":"HIGH","note":"b"}]'

# 同檔有講但離很遠：行號容差算漏，檔案層級不算漏。這是這個指標存在的理由。
fm_far='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/a.rb","line":99,"body":"同檔但離 89 行","severity":"HIGH"}]}'
eq "同檔有 comment 就不算檔案層級漏抓(即使離 89 行)" "1" \
  "$(backtest_file_missed "$fm_far" "$fm_expected")"
eq "對照：同一組資料在 ±15 之下兩條都算漏抓" "2" \
  "$(backtest_match "$fm_far" "$fm_expected" 15 | jq -r '[.[] | select(.matched == null)] | length')"

eq "兩個檔案都沒 comment 時全算漏" "2" \
  "$(backtest_file_missed '{"status":"APPROVED","summary":"x","comments":[]}' "$fm_expected")"
eq "expected 為空時是 0" "0" \
  "$(backtest_file_missed "$fm_far" '[]')"

# 同一個檔案有多條 comment 不會讓漏抓數變成負的，也不會重複扣。
fm_multi='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/a.rb","line":1,"body":"x","severity":"HIGH"},
 {"path":"app/a.rb","line":2,"body":"y","severity":"HIGH"},
 {"path":"app/a.rb","line":3,"body":"z","severity":"HIGH"}]}'
eq "同檔多條 comment 只抵銷該檔的 expected" "1" \
  "$(backtest_file_missed "$fm_multi" "$fm_expected")"

# 這個函式一定要逐 PR 呼叫。攤平多個 PR 的 comment 之後，A 的 expected 會配到
# B 的同名檔案 comment，漏抓數偏低。這裡把那個誤用的後果釘住，讓以後有人想把
# 它改成吃攤平陣列時，測試會告訴他為什麼不行。
pr_a_expected='[{"path":"app/shared.rb","line":10,"severity":"HIGH","note":"PR A 的缺陷"}]'
pr_a_review='{"status":"APPROVED","summary":"x","comments":[]}'
pr_b_review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/shared.rb","line":500,"body":"PR B 對同名檔案的意見","severity":"HIGH"}]}'
eq "逐 PR 算：PR A 沒講到 shared.rb，算 1 條漏抓" "1" \
  "$(backtest_file_missed "$pr_a_review" "$pr_a_expected")"
flattened="$(jq -n --argjson a "$pr_a_review" --argjson b "$pr_b_review" \
  '{status:"CHANGES_REQUESTED", summary:"x", comments: ($a.comments + $b.comments)}')"
eq "攤平後會誤判成 0（這就是不能餵攤平陣列的原因）" "0" \
  "$(backtest_file_missed "$flattened" "$pr_a_expected")"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
