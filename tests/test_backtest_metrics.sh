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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
