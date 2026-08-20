---
id: rails-fragile-dynamic-filter-regex
layer: rails
frameworks: ["rails@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現「動態組出 Regexp 來做 filter/match」的程式碼，具體包含：把陣列（extensions、directories、filter 清單）用字串內插或 `#join("|")` 拼進 `Regexp.new` / `/.../ ` 而沒有先 `Regexp.escape`；用 `.*` 或未加 `\A`/`\z`（或 `^`/`$`）錨點卻期望整字串匹配；greedy `.*` 用在應該是 non-greedy `.*?` 的位置（或反之）；對使用者/選項傳入的 filter 字串（如 `-n`、`CONTROLLER=`、`filter_parameters`）做 regex 比對卻沒處理 nil、多值、或特殊字元跳脫。

## 判準
Regex-based filter（test name filter、path/extension include-exclude、backtrace cleaner、parameter filter）是承載正確性的關鍵面：pattern 只要有一個字元寫錯，就會悄悄改變「哪些檔案被統計進去」「哪些 test 被跑到」「哪些欄位被遮蔽」，而且不會報錯——CI 照樣綠燈，只是跑錯測試或洩漏了不該洩漏的欄位。這批 review 裡實際抓到的錯誤模式：extension/list 拼進 regex 沒 escape 導致特殊字元被當 metacharacter、`inspect` 測試用的 regex 缺 `\A`/`\z` 只做子字串匹配、`PATHS_TO_IGNORE` regex 因為漏了某個路徑分支導致 backtrace 過濾整批失效、`retrieve_variable` 用錯 quantifier（greedy vs lazy）取到錯的子字串、declarative test filter 對空白/底線正規化來回改了好幾輪才穩定。這類問題資深 reviewer 特別在意，因為改一個字元就可能讓 regex 從「完全不匹配」變成「匹配過多」，兩種失效模式都難以從測試輸出直接看出來。

## 嚴重度
CRITICAL：filter 錯誤會導致敏感資料外洩，例如 `filter_parameters`/`ParameterFilter` 沒遮蔽到某個 key、或 backtrace/log 洩漏了內部路徑或憑證
HIGH：功能性正確性錯誤，例如 test filter 誤判導致跑錯/漏跑 test、path/extension 統計漏算或多算、`PATHS_TO_IGNORE` 之類的排除清單因規則錯誤而整批失效
MEDIUM：目前輸入範圍有限所以暫時不會炸，但寫法本身脆弱（沒 escape、沒錨點），只要日後輸入來源變動（例如新增含特殊字元的 extension 或 directory 名稱）就會出錯

## 反例（不該報）
- Regex 作用在固定、受控的常量字串（非動態組合、非使用者輸入），且該常量本身不含 `.`、`(`、`)`、`|` 等 regex 特殊字元
- 已經有 `Regexp.escape` 或等價的跳脫保護，且錨點與 quantifier 語意經過驗證，行為符合預期範圍（例如 PR 中已被 reviewer 確認正確的寫法）
- 純字串比對（`==`、`start_with?`、`in?`）而非 regex，不涉及 regex 特有的跳脫/錨點/quantifier 風險
- 純粹的文件/註解調整，或只是把既有 regex 邏輯抽成方法但邏輯本身沒變

## 出處
- https://github.com/rails/rails/pull/56017#discussion_r2605534586
- https://github.com/rails/rails/pull/55814#discussion_r2399928158
- https://github.com/rails/rails/pull/49141#discussion_r1317927513
- https://github.com/rails/rails/pull/49141#discussion_r1317688054
- https://github.com/rails/rails/pull/47942#discussion_r1168044762
- https://github.com/rails/rails/pull/47942#discussion_r1167638357
- https://github.com/rails/rails/pull/44290#discussion_r795222665
- https://github.com/rails/rails/pull/40172#discussion_r483798535
- https://github.com/rails/rails/pull/38814#discussion_r398263354
- https://github.com/rails/rails/pull/34208#discussion_r225244476
- https://github.com/rails/rails/pull/33455#discussion_r205982635
- https://github.com/rails/rails/pull/33220#discussion_r200164862
- https://github.com/rails/rails/pull/23225#discussion_r51351220
- https://github.com/rails/rails/pull/22833#discussion_r49240273
- https://github.com/rails/rails/pull/20420#discussion_r44198090
- https://github.com/rails/rails/pull/24052#discussion_r55082783
- https://github.com/rails/rails/pull/16616#discussion_r16563399
