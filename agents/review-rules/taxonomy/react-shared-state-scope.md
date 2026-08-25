---
id: react-shared-state-scope
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
diff 新增或修改了一個生命週期比單次呼叫更長的可變狀態容器——宣告在檔案最外層（module-level `let`/`const` 指向可變物件）、掛在 `global.`/`globalThis.`/`window.` 上、或是被多個元件/多次 render/多次 request 共用的 closure 變數——而讀寫它的函式原本應該改成把值當參數傳入、或存在 per-instance／per-render／per-request 的物件上。另一種訊號是新增一個「push / start / mark」類的函式，把值堆進某個累積結構或設成某個旗標，但同一個 diff 裡找不到在所有離開路徑（正常完成、每個 sibling 各自完成、提前 return、丟出例外、unmount）都會執行的對應「pop / reset / restore」。看到這兩種訊號時，要去確認：這個狀態的存活範圍有沒有被誤拉長到跨元件、跨 render、跨 request、跨測試、跨 build 呼叫的範圍。

## 判準
Module-level 或 global 的可變狀態，其生命週期是「直到程式被 reload / process 結束」，遠長於單一 render、單一 request 或單一測試。當兩個呼叫交錯執行（並發請求、sibling 元件、下一個 render、下一個測試）或某次呼叫非正常結束（丟例外、提前 return、component 被 unmount）時，缺乏配對 reset/pop 的狀態就會洩漏到下一個使用者身上，或是把上一次殘留的值當成這一次的初始值。這類 bug 很難被單一測試或單一 render 的正常路徑抓到，只有在特定交錯順序或異常路徑下才會出現，所以格外依賴 review 時主動去追蹤這段狀態的作用域，而不是等測試失敗。在 server 端（Fizz/Flight 等）這種洩漏等同於把一個 request 的資料混進另一個 request 的 response。

## 嚴重度
CRITICAL：狀態在 server-side 程式碼（Fizz/Flight/streaming renderer 等）被多個並發 request 共用、且沒有 per-request 隔離，可能造成跨使用者資料混淆或錯誤 response。
HIGH：狀態會跨元件（sibling）或跨 render 洩漏，且缺乏配對的 reset/pop（例如 push 沒有對應 pop、component-scoped 的旗標被寫成 module-level 變數），會在 production 造成難以重現的 bug。
MEDIUM：共用範圍侷限在 test / build / dev-only 程式碼（例如 module-level counter 沒有在呼叫間 reset、helper 被宣告成 global 只影響單一頁面的注入 script），不會外洩到終端使用者，但會造成跨測試污染或跨 build 的不確定性。

## 反例（不該報）
- 模組層級變數是唯讀常數或不隨呼叫變化的單例（例如 `Intl.ListFormat` formatter、regex literal、純函式表），沒有被任何呼叫寫入。
- 有明確、成對的 save/restore（例如測試裡 `beforeEach` 存下舊值、`afterEach`／finally 還原 global），這是刻意管理全域狀態的正確做法。
- 該變數每次呼叫都重新賦值成新物件（例如每次進入都 `= new Map()`）、且沒有任何路徑會在賦值前讀到上次殘留的值，等同於沒有真正跨呼叫共用。
- Cache 的 key 已經涵蓋所有會變動的維度（例如以 `(fiber, propName)` 為 key 的 memoization map），語意上就是要跨呼叫共用、且不會因此產生錯誤結果。

## 出處
- https://github.com/react/react/pull/36780#discussion_r3413455463
- https://github.com/react/react/pull/34648#discussion_r2391928962
- https://github.com/react/react/pull/33456#discussion_r2132280385
- https://github.com/react/react/pull/32224#discussion_r1941844675
- https://github.com/react/react/pull/31398#discussion_r1869504738
- https://github.com/react/react/pull/30177#discussion_r1673349938
- https://github.com/react/react/pull/29811#discussion_r1631771125
- https://github.com/react/react/pull/28116#discussion_r1469999001
- https://github.com/react/react/pull/28086#discussion_r1467798038
