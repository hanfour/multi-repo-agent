---
id: rails-gsub-chain-regex-interp
layer: rails
frameworks: ["rails@*"]
severity_default: HIGH
---
## 觸發訊號
- diff 新增或修改「連續多次」呼叫 `gsub`/`gsub!`/`sub`/`sub!` 對同一個字串做多段替換（尤其是逐字元跳脫、quote 處理、把某個字元當分隔符切出 schema.table 這類組字串邏輯）
- diff 把字串（尤其是檔案路徑、使用者輸入、動態變數）直接用 `#{}` 內插進 `Regexp.new` 或 `/.../` 字面值，且該字串沒有先經過 `Regexp.escape`
- diff 把原本用固定 `case/when` whitelist 判斷的邏輯，改成用該值本身去動態查表/比對（如 `Rouge::Lexer.find(language)`），但沒有處理該值含有特殊字元或未知值時的行為

## 判準
連續 gsub 的輸出可能被下一個 gsub 的 pattern 再次比對到，造成非預期的二次替換（double-escaping）或漏轉義；而拿某個字元當分隔符切字串（例如把 `.` 當 schema/table 分隔符）如果不排除該資料本來就合法含有該字元的情況（識別字/欄位名稱含 `.`），會產生錯誤的字串結構。把未經跳脫的字串塞進 Regexp 字面值，是把「一般字串比對」誤用成「正規表示式比對」——若該字串含有 `.`、`+`、`(`、`)`、`[]` 等正規表示式特殊字元，比對結果會偏離字面意圖（誤判命中不該命中的字串，或反過來漏判），在做路徑前綴、權限、白名單判斷時尤其危險，因為這類 bug 平常測試不容易觸發，只有特殊字元的輸入才會暴露。

## 嚴重度
CRITICAL：該正規表示式或字串轉換用於權限/邊界判斷（例如判斷路徑是否落在允許的應用程式目錄內、SQL identifier 跳脫），特殊字元可能導致誤判放行或注入。
HIGH：轉換結果會被寫入資料庫、產生的 SQL、或作為使用者可見輸出（JSON escape、identifier quoting），資料中若含有被操作的特殊字元會產生錯誤結果但不一定被立刻察覺。
MEDIUM：僅影響顯示/文件產生（如 guides 的語法高亮語言判斷），錯誤結果頂多是誤顯示，不影響資料正確性或安全性。

## 反例（不該報）
- 對已知範圍受限的常數字串（寫死的 enum、已知安全字元集的 slug）做單一次 gsub，不構成鏈式替換問題。
- Regexp 內插的變數本身就是程式內部產生、值域可控且不含特殊字元的常數（例如版本號 `\d+\.\d+` 本身就是刻意寫的正規表示式片段，不是要被跳脫的字面字串）。
- 已用 `String#start_with?`、`String#include?`、或先 `Regexp.escape` 過再內插的字串比對。
- 單純新增/刪除固定字串常數、不涉及動態組出 pattern 的一般 gsub（如移除 clipboard prompt 文字這類與跳脫/切分無關的替換）。

## 出處
- https://github.com/rails/rails/pull/51527#discussion_r1557774725
- https://github.com/rails/rails/pull/48669#discussion_r1253727041
- https://github.com/rails/rails/pull/39901#discussion_r460906609
- https://github.com/rails/rails/pull/39901#discussion_r460459938
- https://github.com/rails/rails/pull/34626#discussion_r239136217
- https://github.com/rails/rails/pull/28062#discussion_r102798948
- https://github.com/rails/rails/pull/8303#discussion_r2215061
