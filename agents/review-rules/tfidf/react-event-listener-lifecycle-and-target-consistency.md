---
id: react-event-listener-lifecycle-and-target-consistency
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現「事件監聽器/合成事件狀態」在生命週期或多路徑之間可能不對稱的模式,具體包括:新增 `addEventListener`/`removeEventListener`(或內部等價的 listener 累積結構,如 `_eventListeners`、`listenerMap`、`dispatchListeners`/`dispatchInstances`)且對應的移除/清理路徑(destroy、unmount、clear、destructor)沒有同步處理同一組欄位或同一份 listener 記錄；`getListener`/類似查詢函式在讀取的同時產生副作用(移除一次性 listener、遞增計數器如 `nameIdx`）；用來判斷「同一顆事件是否已處理過」的分支條件(如 `substr(-7) === 'Capture'`、`isCapturePhaseListener`)只用字串比對而未排除已知例外事件名；在 `attemptToDispatchEvent` 等分派路徑上把某分支的 early return 換成改變控制流(例如把原本讓函式提前結束的邏輯改為讓外層繼續呼叫 `dispatchEventForPluginEventSystem`)。

## 判準
事件系統的正確性高度依賴「誰在何時被通知、通知幾次、通知後内部簿記是否同步更新」。這類 bug 通常不會在單元測試裡立刻炸掉,而是在特定情境下才出現:重複觸發(listener 未被正確移除導致重複調用或記憶體洩漏)、遺漏觸發(自己註冊的 imperative listener 沒有被自己 dispatch 到)、狀態與實際 DOM 樹不同步(用 alternate fiber 而非 current fiber 做事件相關判斷)、或行為在重構中悄悄變了(把一個 early-return 路徑挪動位置導致下游函式被呼叫與否改變)。Resident reviewer 對這類 diff 特別敏感,因為 React 的事件系統是全域單例、高頻執行路徑,任何不對稱都會在生產環境用戶身上以難以重現的方式爆出來,而不是在 CI 裡穩定重現。

## 嚴重度
CRITICAL：listener 的新增與移除路徑分岔導致確定性記憶體洩漏(如 `destructor`/`unmount` 未清除新加的欄位),或事件分派邏輯變更导致某條路徑的下游副作用(如 `dispatchEventForPluginEventSystem`)被呼叫與否發生行為改變且未經確認是否為刻意設計。
HIGH：查詢函式(如 `getListener`)夾帶副作用(移除 once listener、更新計數器)但呼叫方把它當純函式使用；用來區分事件類型/階段的字串判斷未涵蓋已知例外(如 `onGotPointerCapture`/`onLostPointerCapture` 之於 `Capture` 後綴判斷);持有的 Fiber 引用只在掛載時賦值一次、之後從未隨 commit 更新,導致之後的讀取可能拿到 alternate 而非 current。
MEDIUM：自己用 `addEventListener` 註冊的 imperative listener 沒有被自己的 `dispatchEvent` 觸發到(行為不直覺但有記錄在案的取捨);listener 相關的公開 API(如 fragment instance 的 `appendChild`/`removeChild`)語意上不該暴露給使用者但目前是 public。

## 反例（不該報）
純粹新增一個全新的、獨立生命週期自成一體的 event plugin 或 responder,且 add/remove 或 mount/unmount 路徑本來就在同一個函式或緊鄰的兩個函式中對稱處理,不算此類問題。單純調整某個既有事件名稱的大小寫、拼字或型別標註(如 `nodeName` 改用 `localName`)、且不涉及 listener 的存留或分派時機,不該報。純測試檔案中新增/刪除事件模擬呼叫,只要不影響生產程式碼中的 listener 生命週期管理,不該報。已經在 PR 討論中被作者明確確認「這是刻意的行為變更且已有相應測試覆蓋」的分派路徑調整,不該再報為此類問題。

## 出處
- https://github.com/react/react/pull/32813#discussion_r2027731685
- https://github.com/react/react/pull/32465#discussion_r1987913753
- https://github.com/react/react/pull/32465#discussion_r1972531324
- https://github.com/react/react/pull/32465#discussion_r1970249574
- https://github.com/react/react/pull/32421#discussion_r1960784623
- https://github.com/react/react/pull/27897#discussion_r1446743518
- https://github.com/react/react/pull/23278#discussion_r814444690
- https://github.com/react/react/pull/23278#discussion_r804897454
- https://github.com/react/react/pull/22680#discussion_r755569413
- https://github.com/react/react/pull/22680#discussion_r746864466
- https://github.com/react/react/pull/22680#discussion_r746035193
- https://github.com/react/react/pull/19487#discussion_r462601783
- https://github.com/react/react/pull/18464#discussion_r402413703
- https://github.com/react/react/pull/18355#discussion_r395753375
- https://github.com/react/react/pull/18270#discussion_r394058260
- https://github.com/react/react/pull/18292#discussion_r391943212
- https://github.com/react/react/pull/17651#discussion_r360660472
- https://github.com/react/react/pull/16725#discussion_r322673985
- https://github.com/react/react/pull/9333#discussion_r211726013
- https://github.com/react/react/pull/9742#discussion_r117787216
