---
id: vue-tracking-pause-resume-needs-try-finally
layer: vue
frameworks: ["vue@3.x"]
severity_default: HIGH

---
## 觸發訊號
diff 中出現「暫停/暫緩全域追蹤旗標」的呼叫（如 `pauseTracking()`、`enableTracking()` 或存下 `shouldTrack`/`activeEffect` 等模組層級全域變數後修改它），接著呼叫一段可能拋出例外的程式碼（使用者自訂 callback、`fn()`、`applyOptions()`、cleanup 函式等），然後才呼叫對應的還原函式（如 `resetTracking()`）——但這個還原呼叫沒有包在 `try/finally` 裡，而是與可能拋錯的呼叫並列在同一層（例如 `pauseTracking(); doWork(); resetTracking()` 這種線性排列，或還原呼叫被放進 `try` 區塊而非 `finally`）。

## 判準
`pauseTracking`/`resetTracking` 操作的是模組層級共享的全域可變狀態（tracking stack），不是區域變數。一旦中間執行的程式碼拋出例外，還原呼叫就不會執行，全域追蹤狀態會永久卡在「paused」，導致後續所有元件的 reactivity 追蹤悄悄失效——沒有錯誤訊息、沒有 stack trace，只有「畫面不更新」這種難以回溯的症狀。這類 bug 只有在被包住的程式碼真的拋出例外時才會觸發，一般測試路徑跑不到，所以特別容易在 code review 階段漏掉、上線後才被回報。

## 嚴重度
CRITICAL：被包住的程式碼是使用者可控的（如 `onScopeDispose` 的 cleanup callback、`applyOptions` 執行的 options API hooks），使用者程式碼隨時可能拋錯，且波及範圍是整個 app 的 reactivity 系統而非單一元件。
HIGH：被包住的程式碼是內部邏輯但涉及呼叫外部/使用者提供的函式（如 effect 的 `fn()`），拋錯機率中等但後果同樣是全域狀態損毀。
MEDIUM：被包住的程式碼幾乎不可能拋錯（純內部同步邏輯、無使用者程式碼介入），但仍缺少防禦性的 `try/finally`，屬於「應該修但風險較低」。

## 反例（不該報）
- 還原呼叫已經正確放在 `try/finally` 的 `finally` 區塊內。
- pause/resume 之間執行的程式碼保證不拋錯（純 getter、無使用者程式碼、無外部呼叫），且該保證在同一段 diff 中可驗證。
- 只是儲存/還原一個純區域變數（非模組層級全域狀態），且該區塊沒有 pause/resume 語意、拋錯也不會造成跨元件的殘留副作用。

## 出處
- https://github.com/vuejs/core/pull/7265#discussion_r1722647505
- https://github.com/vuejs/core/pull/7265#discussion_r1697040264
- https://github.com/vuejs/core/pull/7265#discussion_r1623093650
- https://github.com/vuejs/core/pull/7743#discussion_r1198448805
- https://github.com/vuejs/core/pull/7743#discussion_r1114550214
