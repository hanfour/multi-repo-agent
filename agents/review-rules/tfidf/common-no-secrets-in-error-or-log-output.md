---
id: common-no-secrets-in-error-or-log-output
layer: common
frameworks: ["@prisma/client@*"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改的程式碼，把底層 driver/engine 拋出的 error、connection string、環境變數值、或使用者輸入的查詢參數，未經脫敏處理就組進：
- 往外拋出的 exception message（例如 `catch (e) { throw new Error(e.message) }`、直接把 driver 的 `error.stack`/`error.message` 原樣包進使用者可見的錯誤）
- 任何預設開啟（非需明確 flag 開啟）的 `console.log`/`console.error`/debug log，尤其是把 `url`、`connectionString`、`datasource.url`、`--url` 參數直接印出
- 傳給遠端 telemetry / query insights / sqlcommenter 等第三方服務的酬載，把 `where`/`data` 裡的實際使用者資料值原樣序列化進去，而非以 placeholder 取代
- 既有的 regex/allowlist 式遮罩邏輯（如 `CONNECTION_STRING_REGEX`、`isPrismaPostgres`、`parameterizeQuery`）在新增協定或新增欄位時沒有同步更新涵蓋範圍

## 判準
這類問題屬於資安等級而非風格問題——即使只出現在 CLI 工具、測試 harness 或 debug 專用路徑裡，只要外洩點存在，密碼、API key、connection string 或使用者資料就可能被貼進 issue tracker、CI log、Sentry 等外部系統，且事後無法收回。resident reviewer 反覆強調的模式是：任何跨越「這個值來自使用者/環境提供的敏感資料」邊界的路徑（driver error → 使用者可見錯誤、config → log、query 參數 → telemetry payload）都必須先脫敏或參數化，且遮罩邏輯要跟著協定/欄位擴充持續維護，不能只在初次實作時驗證過一次就假設永遠涵蓋全部案例（例如新增 `prisma+postgres://` 卻忘了更新既有的協定白名單）。

## 嚴重度
CRITICAL：明確地把密碼／API key／完整 connection string 輸出到公開或預設開啟的通道（例如預設 log、直接拋給呼叫端的 `Error.message`、上傳到遠端 telemetry 服務的酬載），且沒有任何開關或遮罩。
HIGH：新增/修改的錯誤處理或序列化路徑理論上可能夾帶敏感資料（例如把整個底層 error 物件原樣往外拋、意外遺留的 `console.log(url)` 除錯陳述式），需要特定輸入或條件才會觸發，或已有部分遮罩但覆蓋不完整（如遺漏新協定、遺漏巢狀欄位）。
MEDIUM：遮罩/脫敏邏輯本身寫得過於寬鬆或脆弱（例如 regex 未涵蓋所有已知協定變體、只在 happy path 測試過），目前行為正確但有維護債務。

## 反例（不該報）
- 純粹操作/顯示 schema 結構本身（model 名稱、欄位名稱、SQL 關鍵字）而非使用者資料或憑證的錯誤訊息，不算洩漏。
- 測試檔案裡使用假的、非真實的 connection string 常數（如 `postgres://test:test@localhost`）並不構成敏感資料外洩，不需脫敏。
- 只在受信任、本機專屬、且需使用者明確以環境變數（如 `DEBUG=`）開啟才印出的除錯輸出，且該功能本來就是設計給開發者本機診斷用途、文件已告知風險，不在使用者無感知情況下觸發。
- 單純把「找不到某個檔案」「格式不合法」等結構性錯誤（不涉及機密值本身）原樣往外拋。

## 出處
- https://github.com/prisma/prisma/pull/20781#discussion_r1303213875
- https://github.com/prisma/prisma/pull/29014#discussion_r2682601022
- https://github.com/prisma/prisma/pull/29014#discussion_r2682175347
- https://github.com/prisma/prisma/pull/29014#discussion_r2681550805
- https://github.com/prisma/prisma/pull/29014#discussion_r2676840752
- https://github.com/prisma/prisma/pull/29014#discussion_r2676712919
- https://github.com/prisma/prisma/pull/29014#discussion_r2676662370
- https://github.com/prisma/prisma/pull/29014#discussion_r2676618259
- https://github.com/prisma/prisma/pull/29014#discussion_r2676603951
- https://github.com/prisma/prisma/pull/29013#discussion_r2676310672
- https://github.com/prisma/prisma/pull/29392#discussion_r2988062933
- https://github.com/prisma/prisma/pull/28830#discussion_r2589939898
- https://github.com/prisma/prisma/pull/28830#discussion_r2589929284
- https://github.com/prisma/prisma/pull/28830#discussion_r2589847557
- https://github.com/prisma/prisma/pull/28830#discussion_r2589750421
- https://github.com/prisma/prisma/pull/27594#discussion_r2194991963
