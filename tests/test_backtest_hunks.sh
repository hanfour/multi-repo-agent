#!/usr/bin/env bash
# patch 行號區間解析與交集 (lib/backtest-hunks.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- 靜態檢查：backtest_ranges_overlap 必須用 tr '\n' ';' 轉換
# 原因：gawk/mawk 會將 split(lines[1], p, " ") 拆成每個空白符，包括換行；
# 在 CI（ubuntu-latest）上會失落第一個區間之後的所有範圍，無聲遺漏真正的缺陷。
func_body=$(sed -n '/^backtest_ranges_overlap()/,/^}/p' "$MRA_DIR/lib/backtest-hunks.sh")
if [[ "$func_body" == *"tr '\n' ';'"* ]]; then
  ok "tr '\\n' ';' 轉換存在"
else
  fail "tr '\\n' ';' 轉換遺漏（會在 gawk/mawk 上失敗）"
fi

# 取自 acme/rails-app-1#4919 的真實 hunk header
patch=$(cat <<'P'
@@ -92,7 +92,7 @@ def update
           record.from_sales_id,
@@ -44,6 +44,6 @@ class Foo
   something
@@ -153,20 +153,23 @@ def bar
   other
P
)
eq "三個區間" "92 98
44 49
153 175" "$(printf '%s\n' "$patch" | backtest_hunks_of)"

# 沒有長度的 hunk header 視為一行
eq "單行 hunk" "10 10" "$(printf '@@ -10 +10 @@\n' | backtest_hunks_of)"

# 新增檔案：舊側是 0,0
eq "新檔整段" "1 25" "$(printf '@@ -0,0 +1,25 @@\n' | backtest_hunks_of)"

# 非 patch 內容不產生區間
eq "無 hunk" "" "$(printf 'no hunks here\n' | backtest_hunks_of)"

# --- 交集
if backtest_ranges_overlap "10 20" "15 25"; then ok "部分重疊"; else fail "部分重疊應為真"; fi
if backtest_ranges_overlap "10 20" "20 30"; then ok "端點相接算重疊"; else fail "端點相接應為真"; fi
if backtest_ranges_overlap "10 20" "21 30"; then fail "相鄰不應算重疊"; else ok "相鄰不算重疊"; fi
if backtest_ranges_overlap "1 5
100 110" "105 120"; then ok "多區間任一重疊即為真"; else fail "多區間應為真"; fi
if backtest_ranges_overlap "1 5" "10 20
30 40"; then fail "全不重疊應為假"; else ok "全不重疊為假"; fi
if backtest_ranges_overlap "" "10 20"; then fail "空區間應為假"; else ok "空區間為假"; fi
if backtest_ranges_overlap "10 20" ""; then fail "空區間應為假"; else ok "空區間為假(反向)"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
