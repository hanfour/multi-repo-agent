---
id: common-long-positional-param-list-to-options-object
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
函式簽章新增或已有 3 個以上位置參數（positional parameters），且其中多個是同型別（string/string、boolean/boolean）、可選（`?`）或有預設值。例如：
- `resolve(applicationRef, globalPrefix, onRouteResolved?, deferRegistration = false)`
- `sendPanic(error, cliVersion, engineVersion)`（三個都是 string/物件，呼叫端只憑順序區分）
- `handleRetry(retryAttempts = 9, retryDelay = 3000, connectionName = DEFAULT_CONNECTION_NAME)`

尤其要注意「在既有 2 個參數的函式上，diff 又追加第 3、4 個位置參數」這種漸進式劣化，而不是一次性把介面改成物件。

## 判準
呼叫端只能靠參數順序辨識意圖，寫錯順序（尤其是相鄰同型別參數，例如兩個 string 或兩個 boolean）在 TypeScript 下編譯器不會報錯，會是靜默的邏輯錯誤，只能靠執行期行為或測試才抓得到。隨著參數持續累加，呼叫點的可讀性也隨之下降（`fn(a, b, true, false, 'x')` 讀不出各參數含義）。改成 options 物件後：呼叫端具名、順序無關、新增欄位不必改動所有既有呼叫點、也天然支援可選欄位。這是資深 reviewer 在看到函式簽章長出第 3+ 個位置參數時的直覺反應，而不是在函式一開始只有 1–2 個參數時就要求物件化。

## 嚴重度
CRITICAL：相鄰參數為同型別（如兩個 string 或兩個 boolean）且用於安全/權限/資料正確性相關邏輯（例如認證 flag、使用者 ID vs 角色），寫反不會被編譯器攔下，會靜默造成錯誤行為。
HIGH：對外公開 API（exported function / 套件對外介面）新增第 3 個以上位置參數，且多個為 optional 或有預設值，呼叫點會散落在多處難以一次修正。
MEDIUM：內部/私有函式或呼叫點集中（如單一測試腳本、單一 caller）新增位置參數，可讀性下降但風險與修正成本都低。

## 反例（不該報）
- 函式仍只有 1–2 個參數，或參數型別彼此明顯不同（string vs callback vs number），呼叫端不易搞混，不需要物件化。
- 新增的是單一、有清楚語意預設值的尾端可選參數（如 `handleRetry` 加入 `connectionName = DEFAULT_CONNECTION_NAME`），reviewer 本身也只當作「very minor」建議，不構成強制重構理由。
- 純測試/本地手動執行的 script（非測試套件、非對外介面），參數順序錯誤影響範圍極小，不必為此重構介面。
- 已經是物件參數但內部欄位命名爭議（如 `engineVersion` vs `enginesVersion` 單複數），屬命名討論而非本規則要抓的「位置參數過多」問題。

## 出處
- https://github.com/nestjs/nest/pull/16954#discussion_r3246798858
- https://github.com/prisma/prisma/pull/16766#discussion_r1046959890
- https://github.com/nestjs/typeorm/pull/485#discussion_r429638293
