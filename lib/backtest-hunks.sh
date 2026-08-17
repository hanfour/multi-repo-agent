#!/usr/bin/env bash
# 從 unified diff 的 hunk header 取出新檔側的行號區間，並判斷兩組區間有無交集。
#
# hunk header 形如 `@@ -92,7 +92,7 @@`。省略長度時（`@@ -10 +10 @@`）長度為 1。
# 只看新檔側（+ 那一半），因為要問的是「後來的 fix 改到了這個 PR 新寫的哪幾行」。

backtest_hunks_of() {
  grep -oE '^@@ -[0-9,]+ \+[0-9]+(,[0-9]+)? @@' \
    | sed -E 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@/\1 \3/' \
    | awk '{ len = ($2 == "" ? 1 : $2); if (len > 0) print $1, $1 + len - 1 }'
}
# 注意：純刪除的 hunk（`@@ -5,3 +5,0 @@`）長度為 0，不產生區間。
# PR 純粹刪除行時不引入新行，無可指派行號的概念，所以區間集為空。
# 這是誠實的結果，不是遺漏。

# B 用分號串接再透過 ENVIRON 傳給 awk。兩個原因：
#   1. tr '\n' ';' 是 load-bearing。gawk/mawk（CI 用 ubuntu-latest）會將 split(lines[1], p, " ")
#      拆成每個空白符包括換行，失落第一個區間之後的所有範圍，無聲遺漏真正的缺陷。
#      BWK awk（macOS）的非標準行為會分割 ";" 卻遇到換行，所以兩邊都需要 tr。
#   2. 用 ENVIRON 而不是 -v。這裡的值只有數字與分號，-v 的反斜線跳脫咬不到，
#      但全 repo 一律不用 -v 傳計算出來的字串，不留「這裡可以」的例外給人抄。
backtest_ranges_overlap() {
  local a="$1" b="$2"
  # 防禦性檢查：兩邊都必須非空。變更此處邏輯時務必同時更新測試的空區間斷言。
  [[ -z "$a" || -z "$b" ]] && return 1
  # tr '\n' ';' 轉換是必要的，見上面的註解。
  BT_RANGES_B="$(printf '%s' "$b" | tr '\n' ';')" awk '
    BEGIN {
      n = split(ENVIRON["BT_RANGES_B"], lines, ";")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], p, " "); bs[i] = p[1]; be[i] = p[2]
      }
    }
    # A 側的逆序守衛放在 pattern，因為 pattern 正是 awk 用來決定「這筆記錄算不算
    # 一個區間」的位置；逆序的記錄根本不是區間，在進比對迴圈前就該被丟掉。
    # 不做 normalization（把起迄對調）：逆序來自純刪除 hunk，語意上沒有「新寫的行」，
    # 對調會憑空生出一段從未寫入的行區間，正好是會發明缺陷的那種錯。
    # 少了這個守衛，`overlap "5 4" "1 10"` 會判成重疊（5<=10 且 1<=4）。
    NF == 2 && $1 <= $2 {
      for (i = 1; i <= n; i++)
        # B 側同理，在迴圈裡跳過逆序的範圍。兩側是各自獨立的路徑，都要守。
        if (bs[i] != "" && bs[i] <= be[i] && $1 <= be[i] && bs[i] <= $2) { found = 1; exit }
    }
    END { exit !found }
  ' <<< "$a"
}
