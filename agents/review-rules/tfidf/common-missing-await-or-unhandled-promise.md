---
id: common-missing-await-or-unhandled-promise
layer: common
frameworks: ["typescript@*", "node@*"]
severity_default: HIGH
---
## 觸發訊號
- diff 把一個原本同步的函式改成 `async`（新增 `async` 關键字或改成回傳 `Promise`），但呼叫端沒有同步補上 `await`／`.then()`，導致下游把 `Promise` 物件當成已解析的值使用（例如直接內插進字串、當比較值、當參數傳給其他函式）。
- diff 新增或保留一個「頂層/fire-and-forget」的 async 呼叫（例如 `main()`、CLI entrypoint、背景任務啟動），呼叫式後面沒有 `.catch(...)`、沒有 `await` 包在 `try/catch` 裡、也沒有任何顯式的 rejection handler。
- 呼叫某函式的簽名在同一個 PR 或最近變更中改成 `async`，但 diff 只改了函式定義、沒有同步搜尋並更新所有呼叫點。

## 判準
JS/TS 對「忘記 await」不會在執行期立刻報錯——Promise 物件會被當成一般值繼續往下跑，直到某個下游操作用到它時才會產生詭異但不易追蹤的症狀（字串裡出現 `[object Promise]`、比較永遠不相等、if 判斷永遠是 truthy）。而未處理的 rejection 在 Node 較新版本會直接讓 process 以非零碼結束（或印出 `UnhandledPromiseRejectionWarning`），對 CLI/script 這代表使用者看不到真正的錯誤訊息就先看到 crash 或 exit code 不對；對長駐 server process 這代表一次沒接住的 rejection 可能拖垮整個服務。這類問題最常見的觸發時機就是「把某個函式從同步改成 async」的重構，因為 TypeScript 在沒有開嚴格檢查、或呼叫端本身也回傳 `any`/被忽略回傳值時未必會報型別錯誤，很容易被 code review 以外的流程漏掉。

## 嚴重度
CRITICAL：未接住的 rejection 發生在長駐 server / 常駐 process 中，可能造成整個服務崩潰或未預期地中止正在進行的其他請求；或者漏掉的 `await` 導致資料寫入/交易類操作在「以為已完成」的狀態下就繼續往後執行（例如漏 await 一個 DB write 後就回傳成功）。
HIGH：漏掉的 `await` 讓一個 Promise 物件直接被當成字串/值用在使用者看得到的輸出（錯誤訊息、CLI 輸出、log）裡，產生明顯錯誤內容；或者 CLI/script 的 `main()` 沒有 `.catch()`，導致失敗時 exit code 不正確、或錯誤訊息完全被吞掉看不到。
MEDIUM：漏掉的 `await`／`.catch()` 出現在測試輔助腳本、開發用工具，或該路徑本身沒有實際會 reject 的分支（但仍建議補上以避免未來變成隱患）。

## 反例（不該報）
- 呼叫的函式雖然簽名是 `async`，但函式本體完全沒有 `await`／不會拋出、也沒有任何非同步 I/O（等同一個包了 Promise wrapper 的同步函式），此時漏掉 `await` 不會造成實際行為差異。
- 明確是刻意設計成 fire-and-forget 的呼叫（例如事件通知、非關鍵的背景 metrics 上報），且程式碼或註解已表明這個 Promise 的 rejection 是可接受被忽略的、不影響主流程正確性。
- 呼叫端根本沒有使用該函式的回傳值，且該函式除了「回傳一個 Promise」以外沒有任何會失敗的副作用（例如純同步邏輯包了一層 Promise.resolve）。
- 純粹是測試流程/CI 觸發重跑的留言（例如 "committed changes to rerun tests"）、或 review 討論串裡的致謝/閒聊回覆，本身不構成程式碼缺陷。

## 出處
- https://github.com/nestjs/nest/pull/10809#discussion_r1063371240
- https://github.com/nestjs/nest/pull/10390#discussion_r1030994767
- https://github.com/nestjs/nest/pull/10390#discussion_r1030747625
- https://github.com/prisma/prisma/pull/19772#discussion_r1231484811
- https://github.com/prisma/prisma/pull/13736#discussion_r903385963
- https://github.com/prisma/prisma/pull/11003#discussion_r805665713
- https://github.com/prisma/prisma/pull/8620#discussion_r684323781
- https://github.com/prisma/prisma/pull/7663#discussion_r651681429
