---
id: nestjs-test-quality-untested-new-branches
layer: nestjs
frameworks: ["@nestjs/testing@*", "jest@*", "vitest@*"]
severity_default: HIGH
---
## 觸發訊號
diff 裡的生產程式碼（非測試檔）出現以下任一變更時：
1. 新增或修改一個 `try/catch`，且 catch 之後選擇「吞掉錯誤並回退到預設值 / 不中斷主流程」（例如 lookup 失敗仍要讓指令成功、decode 失敗要回傳結構化錯誤而不是讓例外裸奔）。
2. 新增一個早退（early return）、提早終止（consumer 提早 break/return）、或資源釋放／連線關閉／交易回滾的收尾邏輯。
3. 新增一個處理數值或型別邊界的分支（例如安全整數邊界、空陣列、空字串、超過某個範圍才走的路徑）。
4. 新增一個會被外部依賴失敗觸發的分支（driver 斷線、lookup 逾時、codec decode 失敗）。

出現以上任一變更時，去檢查同一 PR 的測試檔是否新增了「觸發這個分支/失敗情境」的測試案例，而不是只延伸/微調既有的成功路徑測試。

## 判準
這類分支或收尾邏輯一旦寫出來語法通常沒問題，真正的風險是「沒有任何測試會在它被意外刪掉或改壞時變紅」。既有測試套件多半只涵蓋 happy path，重構者刪掉一段 catch、提早 return、或邊界判斷後，CI 仍然全綠，問題要等到 production 才會被使用者踩到（例如 unhandled rejection、連線洩漏、交易懸空、精度悄悄丟失）。這正是 reviewer 最容易漏掉的形狀：問題不在被改動的那幾行本身，而在於「旁邊本來該多一個測試案例，卻沒有」，需要主動去看測試目錄有沒有新增對應案例，而不是只讀 diff 裡改動的程式行。

## 嚴重度
CRITICAL：新增的錯誤處理/收尾邏輯涉及連線關閉、交易回滾、或避免 unhandled rejection 導致 process crash，且完全沒有任何測試觸發該路徑（例如 timer callback 失敗仍不能讓 promise reject 外洩、prepared statement 在 consumer 提早結束時仍要 close）。
HIGH：新增的分支是為了讓某個外部依賴失敗時不影響核心流程（lookup/版本檢查/選配功能），但沒有測試證明「依賴失敗時主流程仍然成功」。
MEDIUM：新增的是數值或型別邊界處理（安全整數邊界、空集合），但測試只用了典型值，未覆蓋邊界值本身。

## 反例（不該報）
- 新分支是防禦性檢查，但相同的錯誤情境已經在更底層/更早的模組被測試覆蓋（例如 codec 已在自己的測試裡驗證過某個值一定會被擋下，這裡加同樣的測試只是重複驗證同一件事）。
- 新分支是 TypeScript 編譯期就能排除的不可能情況（例如列舉窮舉後的 `default` 分支），不需要為它寫 runtime 測試。
- 純粹重新命名、搬移既有測試檔案位置、或把測試從一個 describe 移到另一個 describe，語意未變。
- 新增的分支只是把既有邏輯抽成函式或做型別窄化，行為與涵蓋的測試案例都沒有改變。

## 出處
- https://github.com/prisma/prisma/pull/29593#discussion_r3638168414
- https://github.com/prisma/prisma/pull/29994#discussion_r3767252068
- https://github.com/prisma/prisma/pull/29921#discussion_r3756569230
- https://github.com/prisma/prisma/pull/29611#discussion_r3644170240
- https://github.com/prisma/prisma/pull/29902#discussion_r3728918250
- https://github.com/prisma/prisma/pull/29902#discussion_r3728483170
- https://github.com/prisma/prisma/pull/29984#discussion_r3765731455
- https://github.com/prisma/prisma/pull/29890#discussion_r3719473937
- https://github.com/prisma/prisma/pull/29930#discussion_r3740012432
- https://github.com/prisma/prisma/pull/29892#discussion_r3732029576
