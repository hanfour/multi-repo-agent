#!/usr/bin/env bash
# patch 行號區間解析 (lib/backtest-hunks.sh)。
#
# 區間交集的判定不在這個檔案的測試範圍：正式路徑走 lib/backtest-groundtruth.sh
# 的 backtest_overlap，它的斷言在 tests/test_backtest_groundtruth.sh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 未定義的指令會讓 bash 印 command not found 然後繼續，那個斷言既不算 pass
# 也不算 fail，測試照樣印 Failed: 0。這道讓它直接算成失敗，避免斷言被釘在
# 一個已經不存在的函式上還一路綠燈。
command_not_found_handle() {
  fail "呼叫了未定義的指令 $1（斷言被靜默跳過）"
  return 127
}

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

# --- 純刪除 hunk（新檔側長度 0）不產生區間
eq "純刪除無區間" "" "$(printf '@@ -5,3 +5,0 @@\n' | backtest_hunks_of)"

# 混合 patch：純刪除 + 正常 hunk，只產生正常的區間
patch_mixed=$(cat <<'P'
@@ -5,3 +5,0 @@
@@ -10,2 +10,3 @@
P
)
eq "混合刪除與新增" "10 12" "$(printf '%s\n' "$patch_mixed" | backtest_hunks_of)"

# --- 不變量：輸出的區間恆滿足 起 <= 迄
# 這是下游能省掉逆序守衛的前提。lib/backtest-groundtruth.sh 的 backtest_overlap
# 直接拿 [起,迄] 做 $ra[0] <= $rb[1] 的比較，餵進一個逆序區間會被判成跟一大段
# 行號都重疊，憑空生出從未寫入的行。唯一可能踩到的形狀是長度 0 的純刪除 hunk，
# 靠 `len > 0` 整筆篩掉，而不是把起迄對調。
# 這是行為斷言而不是源碼文字比對：把 `len > 0` 改成 `len >= 0` 或改成對調起迄，
# 這裡都會轉紅。
invariant_patch=$(cat <<'P'
@@ -5,3 +5,0 @@
@@ -10 +10 @@
@@ -0,0 +1,25 @@
@@ -92,7 +92,7 @@ def update
@@ -7,1 +7,0 @@
P
)
inverted="$(printf '%s\n' "$invariant_patch" | backtest_hunks_of | awk 'NF == 2 && $1 > $2')"
eq "沒有任何逆序區間（起 > 迄）" "" "$inverted"

# 同一份輸入裡，長度 >= 1 的 hunk 仍要照常產生區間：上面那筆「沒有逆序」
# 若靠「什麼都不輸出」也會綠，這筆把輸出內容釘死，堵住那條路。
eq "長度 0 之外的 hunk 照常產生區間" "10 10
1 25
92 98" "$(printf '%s\n' "$invariant_patch" | backtest_hunks_of)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
