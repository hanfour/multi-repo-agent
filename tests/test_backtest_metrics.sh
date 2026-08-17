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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
