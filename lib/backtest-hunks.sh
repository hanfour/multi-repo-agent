#!/usr/bin/env bash
# 從 unified diff 的 hunk header 取出新檔側的行號區間，並判斷兩組區間有無交集。
#
# hunk header 形如 `@@ -92,7 +92,7 @@`。省略長度時（`@@ -10 +10 @@`）長度為 1。
# 只看新檔側（+ 那一半），因為要問的是「後來的 fix 改到了這個 PR 新寫的哪幾行」。

backtest_hunks_of() {
  grep -oE '^@@ -[0-9,]+ \+[0-9]+(,[0-9]+)? @@' \
    | sed -E 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@/\1 \3/' \
    | awk '{ len = ($2 == "" ? 1 : $2); print $1, $1 + len - 1 }'
}

# B 用分號串接再透過 ENVIRON 傳給 awk。兩個原因：
#   1. 不能傳多行字串。macOS 的 awk 會報 `newline in string`，整個判斷靜默失效，
#      重疊一律變成「否」，而且不會有錯誤訊息。
#   2. 用 ENVIRON 而不是 -v。這裡的值只有數字與分號，-v 的反斜線跳脫咬不到，
#      但全 repo 一律不用 -v 傳計算出來的字串，不留「這裡可以」的例外給人抄。
backtest_ranges_overlap() {
  local a="$1" b="$2"
  [[ -z "$a" || -z "$b" ]] && return 1
  BT_RANGES_B="$(printf '%s' "$b" | tr '\n' ';')" awk '
    BEGIN {
      n = split(ENVIRON["BT_RANGES_B"], lines, ";")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], p, " "); bs[i] = p[1]; be[i] = p[2]
      }
    }
    NF == 2 {
      for (i = 1; i <= n; i++)
        if (bs[i] != "" && $1 <= be[i] && bs[i] <= $2) { found = 1; exit }
    }
    END { exit !found }
  ' <<< "$a"
}
