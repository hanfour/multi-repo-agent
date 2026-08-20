---
id: common-env-var-gated-user-facing-behavior
layer: common
frameworks: []
severity_default: HIGH
---
## 觸發訊號
diff 中出現以 `process.env.NODE_ENV === 'test'`、`process.env.CI`（或其他測試/CI 偵測用環境變數）作為條件判斷，用來切換「使用者實際會看到的輸出或行為」（例如 CLI spinner 的文字/動畫、log 訊息、UI 呈現、功能是否啟用），而不是切換測試替身（mock/stub/fixture）本身；且該分支邏輯寫在正式產品程式碼裡（非測試檔、非建置設定檔）。

## 判準
這類判斷式的原意通常是「讓 Jest snapshot 穩定、避免測試環境印出會變動的 spinner/動畫內容」，但 `NODE_ENV`、`CI` 都是使用者環境可能自行設定的一般變數（某些 CI 平台預設帶 `CI=true`，某些使用者的 shell profile 或工具鏈也會設 `NODE_ENV=test`），一旦命中就會讓真實使用者拿到「測試專用」的降級輸出（例如多出的 `(spinner)` 標記文字、跳過動畫等），使用者完全不知道為什麼行為跟文件描述或別人看到的不一樣，也難以追查。這是把測試考量滲漏進生產路徑的典型味道；正確做法是用明確的注入點（interface/DI、專屬 flag 如 `enableOutput`、建構時決定是否啟用）取代對通用環境變數的窺探，讓測試透過顯式參數關閉輸出，而不是讓正式程式碼反過來猜測「我是不是在測試裡」。

## 嚴重度
CRITICAL：該環境變數判斷改變的是核心行為而非單純輸出格式（例如跳過驗證、關閉重試、改變回傳資料），導致生產環境資料錯誤或安全檢查被繞過。
HIGH：判斷只影響使用者可見的輸出/UI（如 CLI spinner 文字），但沒有可覆寫的顯式開關，使用者只要環境剛好符合條件就會拿到非預期介面，且沒有文件或錯誤訊息說明原因。
MEDIUM：影響範圍很小（例如只多印一行 debug 標記）、程式碼有註解說明理由，但仍應改用顯式參數或依賴注入取代環境變數窺探；同時涵蓋「魔術數字/魔術字串沒有抽成具名常數」這類降低可讀性但不影響行為正確性的問題。

## 反例（不該報）
- 測試檔案（`*.test.ts`、`*.spec.ts`、`__mocks__` 底下）本身用 `NODE_ENV`/`CI` 判斷是否啟用測試專屬 setup，這是測試基礎設施的正常用法，不是滲漏進生產路徑。
- 建置或部署腳本（`webpack.config.js`、CI YAML）依 `NODE_ENV` 切換打包模式（production vs development），這是業界標準慣例，不屬於「使用者可見行為被意外改變」。
- 函式把 `enableOutput`/`silent` 等做成顯式參數，由呼叫端（包含測試）主動決定要不要輸出，函式內部不再自行讀取 `process.env` — 這正是本規則建議的修法，不該被誤報。
- 純粹針對 JSDoc/註解文字準確度的措辭修正建議，不涉及任何行為分支，不適用本規則。

## 出處
- https://github.com/nestjs/nest/pull/10106#discussion_r944874151
- https://github.com/prisma/prisma/pull/12897#discussion_r856399303
- https://github.com/prisma/prisma/pull/12897#discussion_r855950138
- https://github.com/prisma/prisma/pull/12897#discussion_r855852556
