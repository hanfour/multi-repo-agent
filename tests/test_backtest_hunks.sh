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
# 斷言須匹配實際呼叫形狀，不被註解綁定：| tr '\n' ';')" awk
func_body=$(sed -n '/^backtest_ranges_overlap()/,/^}/p' "$MRA_DIR/lib/backtest-hunks.sh")
if grep -q "| tr '\\\\n' ';')\" awk" <<< "$func_body"; then
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

# --- 純刪除 hunk（新檔側長度 0）不產生區間
eq "純刪除無區間" "" "$(printf '@@ -5,3 +5,0 @@\n' | backtest_hunks_of)"

# 混合 patch：純刪除 + 正常 hunk，只產生正常的區間
patch_mixed=$(cat <<'P'
@@ -5,3 +5,0 @@
@@ -10,2 +10,3 @@
P
)
eq "混合刪除與新增" "10 12" "$(printf '%s\n' "$patch_mixed" | backtest_hunks_of)"

# --- 逆序區間（起 > 迄）兩側都要擋。A 側與 B 側是各自獨立的程式路徑：
# A 側靠 awk pattern 的 `$1 <= $2`，B 側靠迴圈裡的 `bs[i] <= be[i]`。
# 下面兩個斷言各自只對一側的守衛敏感，拿掉哪一側就紅哪一個，不會互相遮蔽。

# 只有 A 側逆序：拿掉 pattern 的 $1 <= $2 會誤判成重疊（5<=10 且 1<=4）。
if backtest_ranges_overlap "5 4" "1 10"; then fail "A 側逆序應為假"; else ok "A 側逆序不重疊"; fi

# 只有 B 側逆序：拿掉迴圈裡的 bs[i] <= be[i] 會誤判成重疊（1<=4 且 5<=10）。
if backtest_ranges_overlap "1 10" "5 4"; then fail "B 側逆序應為假"; else ok "B 側逆序不重疊"; fi

# 逆序範圍（無效區間）不應與任何東西重疊
# 注意：這筆斷言即使拿掉上面兩側任一個逆序守衛依然會綠燈（純算術巧合），
# 真正把關的是上面 `A 側逆序應為假`／`B 側逆序應為假` 這兩筆，不要把這筆當成守衛有覆蓋到的證據。
if backtest_ranges_overlap "20 10" "15 25"; then fail "逆序範圍應為假"; else ok "逆序範圍不重疊"; fi

# 逆序記錄是「跳過」不是「整組作廢」：同一組裡合法的區間仍要能命中。
if backtest_ranges_overlap "5 4
10 20" "15 25"; then ok "逆序記錄不影響同組其他區間"; else fail "同組合法區間應仍為真"; fi

# 靜態檢查：backtest_ranges_overlap 的空區間防禦守衛必須存在
# 變更 || 為 && 或刪除此行，都會導致此測試失敗。
overlap_func=$(sed -n '/^backtest_ranges_overlap()/,/^}/p' "$MRA_DIR/lib/backtest-hunks.sh")
if grep -q '\[\[ -z "\$a" || -z "\$b" \]\]' <<< "$overlap_func"; then
  ok "空區間防禦守衛存在"
else
  fail "空區間防禦守衛遺漏（會在邊界條件失敗）"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
